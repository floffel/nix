<?php
# One-off migration tooling for the Nextcloud -> Garage S3 primary-storage
# switch (2026-10-31).  Kept for reproducibility: re-running the copy is how a
# delta pass is done, and nc-s3-inventory.php is how the bucket is reconciled
# against oc_filecache.
#
# NOTE: these scripts reference the Nix store paths of Nextcloud 33.0.10 and its
# bundled PHP/AWS SDK, which change on every upgrade.  Resolve them again with:
#     readlink -f "$(command -v nextcloud-occ)"   # or: systemctl cat phpfpm-nextcloud
# They expect /var/lib/nc-s3-migration/{manifest.tsv,creds.json} and run as the
# nextcloud user.  See README.md ("Nextcloud user files on Garage S3").
/**
 * Inventory the Garage bucket and reconcile it against the migration manifest.
 *
 *   dump  -> writes inventory.tsv (fileid, size, etag) for every urn:oid: object
 *   check -> compares inventory.tsv with manifest.tsv and reports the delta
 *
 * Read-only: lists and heads objects, never writes or deletes.
 */
require '/nix/store/rcf578iqfd75f3zxwkahsnv605xszg9x-nextcloud-33.0.10/3rdparty/autoload.php';

use Aws\S3\S3Client;

$mode = $argv[1] ?? 'check';
$STATE = '/var/lib/nc-s3-migration';
$creds = json_decode(file_get_contents("$STATE/creds.json"), true);
$prefix = 'urn:oid:';

$s3 = new S3Client([
    'version' => 'latest',
    'region' => $creds['region'],
    'endpoint' => $creds['endpoint'],
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => $creds['key'], 'secret' => $creds['secret']],
    'http' => ['connect_timeout' => 10, 'timeout' => 600],
    'retries' => ['mode' => 'standard', 'max_attempts' => 8],
]);
$bucket = $creds['bucket'];

if ($mode === 'dump') {
    $out = fopen("$STATE/inventory.tsv", 'w');
    $count = 0;
    $bytes = 0;
    $other = 0;
    $token = null;
    do {
        $args = ['Bucket' => $bucket, 'MaxKeys' => 1000];
        if ($token !== null) {
            $args['ContinuationToken'] = $token;
        }
        $res = $s3->listObjectsV2($args);
        foreach ($res['Contents'] ?? [] as $o) {
            $key = (string)$o['Key'];
            if (!str_starts_with($key, $prefix)) {
                $other++;
                fwrite(STDERR, "non-conforming key: $key\n");
                continue;
            }
            $fileid = (int)substr($key, strlen($prefix));
            $etag = trim((string)$o['ETag'], '"');
            // NOTE: string interpolation must use array access.  "$o->Size" on
            // an Aws\Result silently expands to the empty string, which made
            // every size read as 0 and produced 35672 false size mismatches.
            fwrite($out, "$fileid\t" . (int)$o['Size'] . "\t$etag\n");
            $count++;
            $bytes += (int)$o['Size'];
        }
        $token = ($res['IsTruncated'] ?? false) ? ($res['NextContinuationToken'] ?? null) : null;
        if ($count % 5000 === 0 && $count > 0) {
            fwrite(STDERR, "listed $count ...\n");
        }
    } while ($token !== null);
    fclose($out);
    printf("objects=%d bytes=%.1f GB non_conforming=%d\n", $count, $bytes / 1073741824, $other);
    exit(0);
}

// check
$manifest = [];
foreach (file("$STATE/manifest.tsv") as $l) {
    $f = explode("\t", rtrim($l, "\n"));
    if (count($f) < 4) {
        continue;
    }
    $manifest[(int)$f[0]] = ['uid' => $f[1], 'path' => $f[2], 'size' => (int)$f[3]];
}
$objects = [];
foreach (file("$STATE/inventory.tsv") as $l) {
    $f = explode("\t", rtrim($l, "\n"));
    if (count($f) < 3) {
        continue;
    }
    $objects[(int)$f[0]] = ['size' => (int)$f[1], 'etag' => $f[2]];
}

$missing = [];
$sizemismatch = [];
foreach ($manifest as $fileid => $m) {
    if (!isset($objects[$fileid])) {
        $missing[] = $fileid;
    } elseif ($objects[$fileid]['size'] !== $m['size']) {
        $sizemismatch[] = $fileid;
    }
}
$extra = array_diff_key($objects, $manifest);

printf("manifest_files=%d bucket_objects=%d\n", count($manifest), count($objects));
printf("missing=%d size_mismatch=%d extra=%d\n", count($missing), count($sizemismatch), count($extra));
$mbytes = 0;
foreach ($missing as $id) {
    $mbytes += $manifest[$id]['size'];
}
printf("missing_bytes=%.1f MB\n", $mbytes / 1048576);
file_put_contents("$STATE/missing.tsv", implode("\n", $missing) . ( $missing ? "\n" : ''));
file_put_contents("$STATE/size-mismatch.tsv", implode("\n", $sizemismatch) . ($sizemismatch ? "\n" : ''));
file_put_contents("$STATE/extra.tsv", implode("\n", $extra) . ($extra ? "\n" : ''));
foreach (array_slice($missing, 0, 5) as $id) {
    echo "  missing e.g. $id {$manifest[$id]['uid']} {$manifest[$id]['path']}\n";
}
foreach (array_slice($sizemismatch, 0, 5) as $id) {
    echo "  mismatch e.g. $id manifest={$manifest[$id]['size']} bucket={$objects[$id]['size']}\n";
}

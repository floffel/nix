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
 * Read a sample of existing user files through Nextcloud's own storage layer
 * and compare the bytes against the original on the NFS datadir.
 *
 * Run this BEFORE and AFTER the objectstore cutover: it resolves whichever
 * storage id the user currently has (home::<uid> = local, object::user:<uid> =
 * Garage S3), so an identical result on both sides proves the migration did not
 * change what Nextcloud serves — and the reported storage id proves which
 * backend the bytes came from.
 */
define('PHPCLI', true);
define('OC_CONSOLE', 1);

$CODE = '/nix/store/vg0kcvkjc2mhdjaxrg80jvmrr2fnqxbj-nextcloud-33.0.10-with-apps';
$datadir = '/var/lib/nextcloud-data/data/';
$samplePerUser = (int)($argv[1] ?? 4);
$users = ['florian@minnecker.com', 'sabine@minnecker.com', 'helena@minnecker.com'];

chdir($CODE);
require $CODE . '/lib/base.php';
require $CODE . '/3rdparty/autoload.php';

// Baseline for the comparison.  While the datadir still lived on the NAS the
// original bytes were an independent witness; after part C they are not
// mounted any more, so fall back to the object in the bucket -- otherwise
// every sample reports FAIL just because the original is gone.
$creds = json_decode(file_get_contents('/var/lib/nc-s3-migration/creds.json'), true);
$s3 = new Aws\S3\S3Client([
    'version' => 'latest', 'region' => $creds['region'], 'endpoint' => $creds['endpoint'],
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => $creds['key'], 'secret' => $creds['secret']],
    'http' => ['connect_timeout' => 10, 'timeout' => 600],
]);

$root = \OC::$server->getRootFolder();
$conn = \OC::$server->getDatabaseConnection();
$I = \OCP\DB\QueryBuilder\IQueryBuilder::PARAM_INT;

$ok = 0;
$fail = 0;
$seenKeys = [];

foreach ($users as $uid) {
    $st = $conn->executeQuery(
        'SELECT numeric_id, id FROM oc_storages WHERE id IN (?, ?) ORDER BY id DESC LIMIT 1',
        ['object::user:' . $uid, 'home::' . $uid]
    )->fetch();
    if ($st === false) {
        echo "SKIP $uid: no storage row\n";
        continue;
    }
    printf("\n== %s  storage=%d (%s)\n", $uid, (int)$st['numeric_id'], $st['id']);

    $folder = $root->getUserFolder($uid);

    $rows = $conn->executeQuery(
        'SELECT fileid, path, size FROM oc_filecache WHERE storage = ? AND mimetype <> 2'
        . ' AND size > 100000 AND size < 20000000 AND path LIKE ?',
        [(int)$st['numeric_id'], 'files/%']
    )->fetchAll();
    shuffle($rows);
    $rows = array_slice($rows, 0, $samplePerUser);

    foreach ($rows as $row) {
        $rel = preg_replace('#^files/#', '', $row['path']);
        try {
            $node = $folder->get($rel);
            $stream = $node->fopen('r');
            $hash = hash_init('md5');
            $bytes = 0;
            while (!feof($stream)) {
                $chunk = fread($stream, 1048576);
                if ($chunk === false || $chunk === '') {
                    break;
                }
                hash_update($hash, $chunk);
                $bytes += strlen($chunk);
            }
            fclose($stream);
            $ncMd5 = hash_final($hash);
            $orig = $datadir . $uid . '/files/' . $rel;
            $key = 'urn:oid:' . $node->getId();
            if (is_file($orig)) {
                $origMd5 = md5_file($orig);
                $witness = 'disk';
            } else {
                $tmp = tempnam('/tmp', 'ncread');
                $s3->getObject(['Bucket' => $creds['bucket'], 'Key' => $key, 'SaveAs' => $tmp]);
                $origMd5 = md5_file($tmp);
                unlink($tmp);
                $witness = 'bucket';
            }
            $match = ($ncMd5 === $origMd5) && ($bytes === (int)$row['size']);
            $seenKeys[] = 'urn:oid:' . $node->getId();
            printf("  %-4s %9d B  nextcloud=%s %s=%s  %s\n",
                $match ? 'OK' : 'FAIL', $bytes, $ncMd5, $witness, substr($origMd5, 0, 12), $rel);
            $match ? $ok++ : $fail++;
        } catch (\Throwable $e) {
            printf("  FAIL %s: %s\n", $rel, $e->getMessage());
            $fail++;
        }
    }
}

printf("\nreadable through Nextcloud: %d, failures: %d\n", $ok, $fail);
printf("example keys for these fileids: %s\n", implode(', ', array_slice($seenKeys, 0, 2)));

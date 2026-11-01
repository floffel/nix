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
 * Warm copy of Nextcloud user files into Garage S3, keyed as Nextcloud's
 * primary object store expects: key = urn:oid:<oc_filecache.fileid>.
 *
 * Additive only: never deletes or modifies anything on the NAS or in S3.
 * Resumable: completed fileids are appended to a per-worker done file, and an
 * object that already exists with matching size+ETag is skipped.
 *
 * Integrity: the body is streamed through a tee that updates an MD5 context
 * while the SDK uploads, so each object is verified against a digest computed
 * from the exact bytes that were sent (single read of the NAS).
 */
require '/nix/store/rcf578iqfd75f3zxwkahsnv605xszg9x-nextcloud-33.0.10/3rdparty/autoload.php';

use Aws\S3\S3Client;
use Aws\S3\MultipartUploader;
use Aws\Exception\AwsException;

final class TeeHashStream
{
    public $context;
    public static string $lastDigest = '';
    private $fh = null;
    private $hash = null;
    private string $file = '';

    public function stream_open(string $path, string $mode, int $options, ?string &$opened): bool
    {
        $this->file = substr($path, strlen('teehash://'));
        $this->fh = @fopen($this->file, 'rb');
        if ($this->fh === false) {
            return false;
        }
        $this->hash = hash_init('md5');
        return true;
    }

    public function stream_read(int $count): string|false
    {
        $data = fread($this->fh, $count);
        if ($data === false) {
            return false;
        }
        if ($data !== '') {
            hash_update($this->hash, $data);
        }
        return $data;
    }

    public function stream_seek(int $offset, int $whence = SEEK_SET): bool
    {
        if (fseek($this->fh, $offset, $whence) !== 0) {
            return false;
        }
        if ($offset === 0) {
            // SDK retry rewinds the body: restart the digest so it still
            // describes exactly what is sent.
            $this->hash = hash_init('md5');
        }
        return true;
    }

    public function stream_eof(): bool
    {
        return feof($this->fh);
    }

    public function stream_tell(): int|false
    {
        return ftell($this->fh);
    }

    public function stream_flush(): bool
    {
        return true;
    }

    public function stream_stat(): array|false
    {
        return fstat($this->fh);
    }

    public function stream_write(string $data): int
    {
        return 0; // read-only wrapper
    }

    public function stream_close(): void
    {
        self::$lastDigest = hash_final($this->hash);
        $this->hash = null;
        if (is_resource($this->fh)) {
            fclose($this->fh);
        }
    }
}
stream_wrapper_register('teehash', TeeHashStream::class);

$opts = getopt('', ['worker:', 'workers:', 'prefix:', 'limit:', 'only-fileid:', 'dry-run', 'force',
                    'multipart-above:', 'part-size:', 'multipart-concurrency:']);
$worker = (int)($opts['worker'] ?? 0);
$workers = max(1, (int)($opts['workers'] ?? 1));
$prefix = $opts['prefix'] ?? 'urn:oid:';
$limit = isset($opts['limit']) ? (int)$opts['limit'] : -1;
$onlyFileid = isset($opts['only-fileid']) ? (int)$opts['only-fileid'] : null;
$dryRun = isset($opts['dry-run']);
// --force re-uploads even when the fileid is already in a done ledger, which
// is how a known-bad object gets repaired.  --only-fileid implies it.
$force = isset($opts['force']) || $onlyFileid !== null;
$multipartAbove = (int)($opts['multipart-above'] ?? 2147483648);
$partSize = (int)($opts['part-size'] ?? 33554432);
$mpConcurrency = (int)($opts['multipart-concurrency'] ?? 2);

$STATE = '/var/lib/nc-s3-migration';
$MANIFEST = getenv('NC_MANIFEST') ?: "$STATE/manifest.tsv";
$DATADIR = getenv('NC_DATADIR') ?: '/var/lib/nextcloud-data/data/';
$doneFile = "$STATE/done-w$worker.txt";
$failFile = "$STATE/failed-w$worker.tsv";
$progressFile = "$STATE/progress-w$worker.txt";

$creds = json_decode(file_get_contents("$STATE/creds.json"), true);
if (!is_array($creds) || empty($creds['key'])) {
    fwrite(STDERR, "bad creds.json\n");
    exit(2);
}

// The done files are the ledger of "verified present in the bucket": a fileid
// is only ever appended after a successful size+ETag check.  Load every
// worker's ledger, not only ours, so a re-run with a different --workers
// count stays resumable instead of silently re-uploading everything.
$done = [];
foreach (glob("$STATE/done-w*.txt") ?: [] as $ledger) {
    foreach (file($ledger) as $entry) {
        $entry = (int)trim($entry);
        if ($entry > 0) {
            $done[$entry] = true;
        }
    }
}

$s3 = null;
if (!$dryRun) {
    $s3 = new S3Client([
        'version' => 'latest',
        'region' => $creds['region'],
        'endpoint' => $creds['endpoint'],
        'use_path_style_endpoint' => true,
        'credentials' => ['key' => $creds['key'], 'secret' => $creds['secret']],
        'http' => ['connect_timeout' => 10, 'timeout' => 3600],
        'retries' => ['mode' => 'standard', 'max_attempts' => 8],
    ]);
}
$bucket = $creds['bucket'];

/**
 * Candidate composite ETags for a multipart object, most likely first.
 *
 * Garage does NOT use the S3 formula.  Measured against a controlled 3-part
 * upload of random data: S3 returns md5(raw part digests)-N, Garage returns
 * md5(HEX part digests)-N.  Both are returned so the check survives a Garage
 * change and still works against real S3.  (Assuming the S3 formula cost a
 * false "corrupt upload" report on the only file larger than 2 GiB.)
 *
 * Parts are hashed from explicit seek offsets and read until the part is full:
 * fread() may short-read on NFS, and the SDK loops until a part is full, so a
 * short read would shift every following boundary and yield an ETag with the
 * right part count but the wrong digest.
 */
function multipartEtags(string $path, int $partSize): array
{
    $fh = fopen($path, 'rb');
    if ($fh === false) {
        throw new RuntimeException("cannot open $path");
    }
    $size = (int)filesize($path);
    $raw = '';
    $hex = '';
    $parts = 0;
    $offset = 0;
    while ($offset < $size) {
        $remaining = min($partSize, $size - $offset);
        $ctx = hash_init('md5');
        while ($remaining > 0) {
            $chunk = fread($fh, (int)min(1048576, $remaining));
            if ($chunk === false || $chunk === '') {
                break;
            }
            hash_update($ctx, $chunk);
            $read = strlen($chunk);
            $remaining -= $read;
            $offset += $read;
        }
        if ($remaining !== 0) {
            fclose($fh);
            throw new RuntimeException("short read at offset $offset: $remaining bytes missing");
        }
        $d = hash_final($ctx, true);
        $raw .= $d;
        $hex .= bin2hex($d);
        $parts++;
    }
    fclose($fh);
    return [md5($hex, false) . '-' . $parts, md5($raw, false) . '-' . $parts];
}

$fp = fopen($MANIFEST, 'r');
$doneFp = fopen($doneFile, 'a');
$failFp = fopen($failFile, 'a');
$progFp = fopen($progressFile, 'w');

$stat = ['done' => 0, 'already' => 0, 'skipped' => 0, 'missing' => 0, 'sizechg' => 0, 'failed' => 0, 'bytes' => 0];
$start = microtime(true);
$scanned = 0;

while (($line = fgets($fp)) !== false) {
    $line = rtrim($line, "\n");
    if ($line === '') {
        continue;
    }
    $f = explode("\t", $line);
    if (count($f) < 4) {
        continue;
    }
    [$fileid, $uid, $relpath, $size] = $f;
    if ($onlyFileid !== null && (int)$fileid !== $onlyFileid) {
        continue;
    }
    if ((int)$fileid % $workers !== $worker) {
        continue;
    }
    $scanned++;
    if (!$force && isset($done[$fileid])) {
        $stat['skipped']++;
        continue;
    }
    if ($limit >= 0 && ($stat['done'] + $stat['failed'] + $stat['already']) >= $limit) {
        break;
    }

    $key = $prefix . $fileid;
    $local = $DATADIR . $uid . '/' . $relpath;

    if (!is_file($local)) {
        $stat['missing']++;
        fwrite($failFp, "$fileid\tmissing\t$relpath\t$size\n");
        fflush($failFp);
        continue;
    }
    $diskSize = filesize($local);
    if ((int)$size !== $diskSize) {
        $stat['sizechg']++;
    }

    if ($dryRun) {
        $stat['done']++;
        $stat['bytes'] += $diskSize;
        continue;
    }

    try {
        // Already migrated? (idempotent re-run). 404 means "not yet" and is
        // detected by status code, not exception class, because the SDK's
        // exception namespace differs between versions.
        $existing = null;
        try {
            $existing = $s3->headObject(['Bucket' => $bucket, 'Key' => $key]);
        } catch (\Throwable $e) {
            $status = method_exists($e, 'getStatusCode') ? (int)$e->getStatusCode() : 0;
            if ($status !== 404) {
                throw $e;
            }
        }
        // Matching size is not proof of matching content.  Only accept the
        // object when the ETag verifies as well, otherwise a corrupt or stale
        // object would be marked done and never repaired.
        if ($existing !== null && (int)$existing['ContentLength'] === $diskSize) {
            $existingEtag = trim((string)$existing['ETag'], '"');
            $localEtags = $diskSize > $multipartAbove
                ? multipartEtags($local, $partSize)
                : [(string)@md5_file($local)];
            if (in_array($existingEtag, $localEtags, true)) {
                $stat['already']++;
                fwrite($doneFp, "$fileid\n");
                fflush($doneFp);
                continue;
            }
            fwrite(STDERR, "stale object $key local=" . implode('/', $localEtags)
                           . " remote=$existingEtag, re-uploading\n");
        }

        if ($diskSize > $multipartAbove) {
            $expected = multipartEtags($local, $partSize);
            $uploader = new MultipartUploader($s3, $local, [
                'bucket' => $bucket,
                'key' => $key,
                'part_size' => $partSize,
                'concurrency' => $mpConcurrency,
                'params' => ['ACL' => 'private'],
            ]);
            $uploader->upload();
        } else {
            $body = fopen('teehash://' . $local, 'rb');
            if ($body === false) {
                throw new RuntimeException("cannot open $local");
            }
            $s3->putObject([
                'Bucket' => $bucket,
                'Key' => $key,
                'Body' => $body,
                'ContentLength' => $diskSize,
                'ACL' => 'private',
            ]);
            fclose($body);
            $expected = [TeeHashStream::$lastDigest];
        }

        $head = $s3->headObject(['Bucket' => $bucket, 'Key' => $key]);
        $remoteLen = (int)$head['ContentLength'];
        $remoteEtag = trim((string)$head['ETag'], '"');
        if ($remoteLen !== $diskSize) {
            throw new RuntimeException("length mismatch local=$diskSize remote=$remoteLen");
        }
        if (!in_array($remoteEtag, $expected, true)) {
            throw new RuntimeException('etag mismatch expected=' . implode('/', $expected)
                                       . " remote=$remoteEtag");
        }

        $stat['done']++;
        $stat['bytes'] += $diskSize;
        fwrite($doneFp, "$fileid\n");
        fflush($doneFp);
    } catch (AwsException $e) {
        $stat['failed']++;
        $msg = $e->getAwsErrorMessage() ?? $e->getMessage();
        fwrite($failFp, "$fileid\taws\t$relpath\t$diskSize\t" . str_replace("\n", ' ', $msg) . "\n");
        fflush($failFp);
    } catch (Throwable $e) {
        $stat['failed']++;
        fwrite($failFp, "$fileid\terr\t$relpath\t$diskSize\t" . str_replace("\n", ' ', $e->getMessage()) . "\n");
        fflush($failFp);
    }

    if (($stat['done'] + $stat['failed']) % 50 === 0) {
        $el = max(1, microtime(true) - $start);
        fwrite($progFp, sprintf("w%d done=%d already=%d failed=%d missing=%d sizechg=%d %.1f MB %.1f MB/s\n",
            $worker, $stat['done'], $stat['already'], $stat['failed'], $stat['missing'], $stat['sizechg'],
            $stat['bytes'] / 1048576, $stat['bytes'] / $el / 1048576));
        fflush($progFp);
    }
}

fclose($fp);
fclose($doneFp);
fclose($failFp);
$el = max(1, microtime(true) - $start);
fwrite($progFp, sprintf("FINAL w%d scanned=%d done=%d already=%d skipped=%d failed=%d missing=%d sizechg=%d %.1f MB %.1f MB/s elapsed=%.0fs\n",
    $worker, $scanned, $stat['done'], $stat['already'], $stat['skipped'], $stat['failed'], $stat['missing'],
    $stat['sizechg'], $stat['bytes'] / 1048576, $stat['bytes'] / $el / 1048576, $el));
fclose($progFp);

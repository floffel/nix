<?php
# One-off verification for the Nextcloud -> Garage S3 primary-storage switch.
# See README.md ("Nextcloud user files on Garage S3").
/**
 * Prove that NEW writes go to the object store and not to the datadir.
 *
 * Writes a file as a real user through Nextcloud's storage layer, then checks
 * (a) that a bucket object urn:oid:<fileid> appeared with the same bytes and
 * (b) that no file content materialised on the local datadir.  Cleans up.
 */
define('PHPCLI', true);
define('OC_CONSOLE', 1);

$CODE = getenv('NC_CODE') or exit("set NC_CODE\n");
$datadir = rtrim(getenv('NC_DATADIR') ?: '/var/lib/nextcloud-data/data', '/') . '/';
$uid = $argv[1] ?? 'florian@minnecker.com';
$rel = '__s3-cutover-check-' . getmypid() . '.bin';

chdir($CODE);
require $CODE . '/lib/base.php';

$creds = json_decode(file_get_contents('/var/lib/nc-s3-migration/creds.json'), true);
require $CODE . '/3rdparty/autoload.php';
$s3 = new Aws\S3\S3Client([
    'version' => 'latest', 'region' => $creds['region'], 'endpoint' => $creds['endpoint'],
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => $creds['key'], 'secret' => $creds['secret']],
]);

$payload = random_bytes(1024 * 512);
$userFolder = \OC::$server->getUserFolder($uid);
$node = $userFolder->newFile($rel, $payload);
$fileid = $node->getId();
$expected = md5($payload);
printf("wrote %s as %s: fileid=%d size=%d md5=%s\n", $rel, $uid, $fileid, strlen($payload), $expected);

$storage = $userFolder->getStorage();
printf("home storage class = %s\n", get_class($storage));

$key = 'urn:oid:' . $fileid;
$head = $s3->headObject(['Bucket' => $creds['bucket'], 'Key' => $key]);
$tmp = tempnam('/tmp', 's3wt');
$s3->getObject(['Bucket' => $creds['bucket'], 'Key' => $key, 'SaveAs' => $tmp]);
printf("bucket %s size=%d md5=%s  %s\n", $key, (int)$head['ContentLength'], md5_file($tmp),
       md5_file($tmp) === $expected ? 'MATCHES what was written' : 'DIFFERS');
unlink($tmp);

$onDisk = $datadir . $uid . '/files/' . $rel;
printf("local datadir copy : %s\n", file_exists($onDisk) ? "PRESENT at $onDisk (unexpected)" : 'absent (correct: content lives only in the bucket)');

// read it back through Nextcloud
$again = $node->getContent();
printf("read back through Nextcloud: %s\n", md5($again) === $expected ? 'identical' : 'DIFFERS');

$node->delete();
$gone = true;
try {
    $s3->headObject(['Bucket' => $creds['bucket'], 'Key' => $key]);
    $gone = false;
} catch (\Throwable $e) {
    $gone = (int)(method_exists($e, 'getStatusCode') ? $e->getStatusCode() : 0) === 404;
}
printf("cleanup: %s; bucket object gone: %s\n", 'file deleted', $gone ? 'yes' : 'no (Nextcloud keeps objects until the retention job runs)');

-- Switch existing Nextcloud users from local home storage ("home::<uid>") to
-- the primary S3 object store ("object::user:<uid>"), which is what
-- OC\Files\Mount\ObjectHomeMountProvider + HomeObjectStoreStorage::getId()
-- resolve for every user once services.nextcloud.config.objectstore.s3 is on.
--
-- Runs against one database; content itself must already be in the bucket as
-- urn:oid:<oc_filecache.fileid>.  Nothing here deletes rows, so rollback is a
-- plain restore of the pre-migration dump.
\set ON_ERROR_STOP on
BEGIN;

-- 1. Register one objectstore home storage per user (idempotent).
INSERT INTO oc_storages (id)
SELECT 'object::user:' || uid
FROM (VALUES
  ('admin'),
  ('florian@minnecker.com'),
  ('helena@minnecker.com'),
  ('sabine@minnecker.com'),
  ('bodo@minnecker.com'),
  ('carolin@minnecker.com')
) AS u(uid)
ON CONFLICT (id) DO NOTHING;

-- 2. Map old -> new storage ids.  The join on o.id deliberately fails if a
--    numeric id does not belong to the expected user, so a drifted database
--    cannot silently remap the wrong rows.
CREATE TEMP TABLE nc_storage_map (uid text NOT NULL, old_id bigint NOT NULL, new_id bigint NOT NULL) ON COMMIT DROP;

INSERT INTO nc_storage_map (uid, old_id, new_id)
SELECT u.uid, o.numeric_id, n.numeric_id
FROM (VALUES
  ('admin', 1),
  ('florian@minnecker.com', 3),
  ('helena@minnecker.com', 4),
  ('sabine@minnecker.com', 5),
  ('bodo@minnecker.com', 6),
  ('carolin@minnecker.com', 7)
) AS u(uid, old_id)
JOIN oc_storages o ON o.numeric_id = u.old_id AND o.id = 'home::' || u.uid
JOIN oc_storages n ON n.id = 'object::user:' || u.uid;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM nc_storage_map;
  IF n <> 6 THEN
    RAISE EXCEPTION 'storage mapping incomplete: expected 6 users, got %', n;
  END IF;
END
$$;

-- 3. Point the three storage-aware tables at the objectstore ids.
UPDATE oc_filecache f SET storage = m.new_id FROM nc_storage_map m WHERE f.storage = m.old_id;
UPDATE oc_mounts    t SET storage_id = m.new_id FROM nc_storage_map m WHERE t.storage_id = m.old_id;
UPDATE oc_previews  p SET storage_id = m.new_id FROM nc_storage_map m WHERE p.storage_id = m.old_id;

-- 4. Home mounts now come from ObjectHomeMountProvider (Nextcloud would
--    rewrite this itself on each user's next login; doing it here keeps the
--    database consistent immediately).  Share mounts keep their own class.
UPDATE oc_mounts t
   SET mount_provider_class = 'OC\Files\Mount\ObjectHomeMountProvider'
  FROM nc_storage_map m
 WHERE t.user_id = m.uid
   AND t.mount_provider_class = 'OC\Files\Mount\LocalHomeMountProvider';

COMMIT;

\echo '--- resulting storages ---'
SELECT numeric_id, id FROM oc_storages ORDER BY numeric_id;
\echo '--- filecache rows per objectstore storage ---'
SELECT s.numeric_id, s.id, count(*) rows, pg_size_pretty(sum(f.size)) bytes
FROM oc_filecache f JOIN oc_storages s ON s.numeric_id = f.storage
WHERE s.id LIKE 'object::user:%'
GROUP BY s.numeric_id, s.id ORDER BY s.numeric_id;
\echo '--- rows still pointing at local home storages (expect 0) ---'
SELECT count(*) leftover FROM oc_filecache WHERE storage IN (1,3,4,5,6,7);
\echo '--- mounts ---'
SELECT storage_id, root_id, user_id, mount_point, mount_provider_class FROM oc_mounts ORDER BY user_id NULLS LAST, mount_point;
\echo '--- home mounts still on the local provider (expect 0) ---'
SELECT count(*) stale FROM oc_mounts WHERE mount_provider_class = 'OC\Files\Mount\LocalHomeMountProvider';

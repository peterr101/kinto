--
-- Triggers to set last_modified on INSERT/UPDATE
--
DROP TRIGGER IF EXISTS tgr_records_last_modified ON records;
DROP TRIGGER IF EXISTS tgr_deleted_last_modified ON deleted;

CREATE OR REPLACE FUNCTION bump_timestamp()
RETURNS trigger AS $$
DECLARE
    previous TIMESTAMP;
    current TIMESTAMP;
BEGIN
    previous := NULL;
    WITH existing_timestamps AS (
      -- Timestamp of latest record.
      (
        SELECT last_modified
        FROM records
        WHERE parent_id = NEW.parent_id
          AND collection_id = NEW.collection_id
        ORDER BY last_modified DESC
        LIMIT 1
      )
      -- Timestamp of latest tombstone.
      UNION
      (
        SELECT last_modified
        FROM deleted
        WHERE parent_id = NEW.parent_id
          AND collection_id = NEW.collection_id
        ORDER BY last_modified DESC
        LIMIT 1
      )
      -- Timestamp when collection was empty.
      UNION
      (
        SELECT last_modified
        FROM timestamps
        WHERE parent_id = NEW.parent_id
          AND collection_id = NEW.collection_id
      )
    )
    SELECT MAX(last_modified) INTO previous
      FROM existing_timestamps;

    --
    -- This bumps the current timestamp to 1 msec in the future if the previous
    -- timestamp is equal to the current one (or higher if was bumped already).
    --
    -- If a bunch of requests from the same user on the same collection
    -- arrive in the same millisecond, the unicity constraint can raise
    -- an error (operation is cancelled).
    -- See https://github.com/mozilla-services/cliquet/issues/25
    --
    current := clock_timestamp();
    IF previous IS NOT NULL AND previous >= current THEN
        current := previous + INTERVAL '1 milliseconds';
    END IF;

    IF NEW.last_modified IS NULL OR
       (previous IS NOT NULL AND as_epoch(NEW.last_modified) = as_epoch(previous)) THEN
        -- If record does not carry last-modified, or if the one specified
        -- is equal to previous, assign it to current (i.e. bump it).
        NEW.last_modified := current;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tgr_records_last_modified
BEFORE INSERT OR UPDATE OF data ON records
FOR EACH ROW EXECUTE PROCEDURE bump_timestamp();

CREATE TRIGGER tgr_deleted_last_modified
BEFORE INSERT ON deleted
FOR EACH ROW EXECUTE PROCEDURE bump_timestamp();


-- Bump storage schema version.
INSERT INTO metadata (name, value) VALUES ('storage_schema_version', '17');

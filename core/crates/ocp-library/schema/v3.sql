CREATE TABLE source_v3 (
  source_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('localFolder','webdav')),
  display_name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  access_ref TEXT,
  created_at REAL NOT NULL
);
INSERT INTO source_v3 SELECT * FROM source;
DROP TABLE source;
ALTER TABLE source_v3 RENAME TO source;
ALTER TABLE entry ADD COLUMN etag TEXT;

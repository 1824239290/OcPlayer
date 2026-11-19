CREATE TABLE source_v4 (
  source_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('localFolder','webdav','smb')),
  display_name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  access_ref TEXT,
  created_at REAL NOT NULL
);
INSERT INTO source_v4 SELECT * FROM source;
DROP TABLE source;
ALTER TABLE source_v4 RENAME TO source;

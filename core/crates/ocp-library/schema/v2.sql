ALTER TABLE catalog_item ADD COLUMN match_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE item_metadata (
  source_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  language TEXT NOT NULL,
  metadata TEXT NOT NULL,
  parent_revision INTEGER NOT NULL,
  fetched_at REAL NOT NULL,
  PRIMARY KEY(source_id,item_id),
  FOREIGN KEY(source_id,item_id) REFERENCES catalog_item(source_id,item_id)
);
CREATE TABLE scrape_run (
  run_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  status TEXT NOT NULL,
  language TEXT NOT NULL,
  refresh INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL,
  FOREIGN KEY(source_id,library_id) REFERENCES library(source_id,library_id)
);
CREATE INDEX scrape_run_library ON scrape_run(source_id,library_id,created_at);
CREATE TABLE scrape_target (
  run_id TEXT NOT NULL REFERENCES scrape_run(run_id),
  item_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  input_version TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  error_kind TEXT,
  last_error TEXT,
  next_retry_at REAL,
  PRIMARY KEY(run_id,item_id)
);

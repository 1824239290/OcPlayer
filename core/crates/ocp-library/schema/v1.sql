CREATE TABLE source (
  source_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind = 'localFolder'),
  display_name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  access_ref TEXT,
  created_at REAL NOT NULL
);
CREATE TABLE library (
  library_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES source(source_id),
  name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('movies','tvshows')),
  revision INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL,
  draft_id TEXT NOT NULL UNIQUE,
  UNIQUE(source_id,library_id)
);
CREATE INDEX library_source_type ON library(source_id,type,library_id);
CREATE TABLE entry (
  source_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime REAL NOT NULL,
  available INTEGER NOT NULL DEFAULT 1,
  seen_generation INTEGER NOT NULL,
  PRIMARY KEY(source_id,asset_id),
  UNIQUE(source_id,library_id,relative_path),
  UNIQUE(source_id,library_id,asset_id),
  FOREIGN KEY(source_id,library_id) REFERENCES library(source_id,library_id)
);
CREATE TABLE catalog_item (
  source_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  group_key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('movie','series','season','episode','unidentified')),
  title TEXT NOT NULL,
  year INTEGER,
  parent_id TEXT,
  series_id TEXT,
  season_number INTEGER,
  episode_number INTEGER,
  first_seen_at REAL NOT NULL,
  PRIMARY KEY(source_id,item_id),
  UNIQUE(source_id,library_id,item_id),
  UNIQUE(source_id,library_id,group_key),
  FOREIGN KEY(source_id,library_id) REFERENCES library(source_id,library_id),
  FOREIGN KEY(source_id,library_id,parent_id) REFERENCES catalog_item(source_id,library_id,item_id),
  FOREIGN KEY(source_id,library_id,series_id) REFERENCES catalog_item(source_id,library_id,item_id)
);
CREATE INDEX catalog_parent ON catalog_item(source_id,library_id,parent_id,season_number,episode_number,item_id);
CREATE TABLE item_asset (
  source_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  PRIMARY KEY(source_id,item_id,asset_id),
  FOREIGN KEY(source_id,library_id,item_id) REFERENCES catalog_item(source_id,library_id,item_id),
  FOREIGN KEY(source_id,library_id,asset_id) REFERENCES entry(source_id,library_id,asset_id)
);
CREATE TABLE item_match (
  source_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  media_type TEXT NOT NULL CHECK(media_type IN ('movie','tv')),
  tmdb_id INTEGER NOT NULL CHECK(tmdb_id > 0),
  language TEXT NOT NULL,
  metadata TEXT NOT NULL,
  manual_lock INTEGER NOT NULL DEFAULT 0,
  fetched_at REAL NOT NULL,
  PRIMARY KEY(source_id,item_id),
  FOREIGN KEY(source_id,item_id) REFERENCES catalog_item(source_id,item_id)
);
CREATE TABLE watch_state (
  source_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  position_seconds REAL NOT NULL,
  duration_seconds REAL,
  played INTEGER NOT NULL,
  completed INTEGER NOT NULL,
  recorded_at REAL NOT NULL,
  PRIMARY KEY(source_id,item_id),
  FOREIGN KEY(source_id,item_id) REFERENCES catalog_item(source_id,item_id)
);
CREATE TABLE job (
  job_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  status TEXT NOT NULL,
  files_found INTEGER NOT NULL DEFAULT 0,
  directories_done INTEGER NOT NULL DEFAULT 0,
  error_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at REAL NOT NULL,
  UNIQUE(library_id,generation),
  FOREIGN KEY(source_id,library_id) REFERENCES library(source_id,library_id)
);
CREATE TABLE job_directory (
  job_id TEXT NOT NULL REFERENCES job(job_id),
  relative_path TEXT NOT NULL,
  done INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(job_id,relative_path)
);

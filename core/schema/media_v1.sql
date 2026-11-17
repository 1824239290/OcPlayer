CREATE TABLE tenant(
  tenant_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  server_name TEXT,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE TABLE item(
  tenant_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  name TEXT,
  year INTEGER,
  series_id TEXT,
  season_id TEXT,
  season_number INTEGER,
  episode_number INTEGER,
  played INTEGER,
  played_percentage REAL,
  position_seconds REAL,
  fetched_at INTEGER NOT NULL,
  progress_fetched_at INTEGER,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, item_id)
) WITHOUT ROWID;
CREATE INDEX item_series ON item(tenant_id, series_id, season_number, episode_number);
CREATE INDEX item_season ON item(tenant_id, season_id, episode_number);
CREATE INDEX item_fetched ON item(tenant_id, fetched_at);
CREATE INDEX item_progress ON item(tenant_id, progress_fetched_at);
CREATE TABLE library(
  tenant_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, library_id)
);
CREATE TABLE rail(
  tenant_id TEXT NOT NULL,
  rail TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, rail)
);
CREATE TABLE page(
  tenant_id TEXT NOT NULL,
  parent_id TEXT NOT NULL DEFAULT '',
  kinds TEXT NOT NULL DEFAULT '',
  sort_key TEXT NOT NULL DEFAULT '',
  watch_state TEXT NOT NULL DEFAULT '',
  search_term TEXT NOT NULL DEFAULT '',
  start_index INTEGER NOT NULL,
  limit_value INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, parent_id, kinds, sort_key, watch_state, search_term, start_index, limit_value)
);
CREATE TABLE media_file_info(
  tenant_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, item_id)
);

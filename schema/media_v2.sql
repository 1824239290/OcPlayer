CREATE TABLE tmdb_entity(
  entity_key TEXT NOT NULL,
  language TEXT NOT NULL,
  kind TEXT NOT NULL,
  tmdb_id INTEGER NOT NULL,
  season_number INTEGER,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(entity_key, language)
);
CREATE INDEX tmdb_entity_expiry ON tmdb_entity(expires_at);
CREATE TABLE tmdb_link(
  tenant_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  entity_key TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence REAL NOT NULL,
  linked_at INTEGER NOT NULL,
  PRIMARY KEY(tenant_id, item_id)
);
CREATE INDEX tmdb_link_entity ON tmdb_link(tenant_id, entity_key);

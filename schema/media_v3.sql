CREATE TABLE local_progress(
  tenant_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  recorded_at REAL NOT NULL,
  confirmed_at REAL,
  completed INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, item_id),
  FOREIGN KEY(tenant_id, item_id) REFERENCES item(tenant_id, item_id) ON DELETE CASCADE
) WITHOUT ROWID;

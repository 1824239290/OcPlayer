ALTER TABLE local_progress RENAME TO local_progress_v3;
CREATE TABLE local_progress(
  tenant_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  recorded_at REAL NOT NULL,
  confirmed_at REAL,
  completed INTEGER NOT NULL,
  payload_version INTEGER NOT NULL,
  payload BLOB NOT NULL,
  PRIMARY KEY(tenant_id, item_id)
) WITHOUT ROWID;
INSERT INTO local_progress SELECT * FROM local_progress_v3;
DROP TABLE local_progress_v3;

CREATE TABLE library_root (
  root_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  root_path TEXT NOT NULL,
  access_ref TEXT,
  created_at REAL NOT NULL,
  UNIQUE(source_id, library_id, root_path),
  FOREIGN KEY(source_id, library_id) REFERENCES library(source_id, library_id)
);
CREATE INDEX library_root_lookup ON library_root(source_id, library_id, created_at, root_id);

INSERT INTO library_root(root_id, source_id, library_id, root_path, access_ref, created_at)
SELECT l.library_id, l.source_id, l.library_id, l.root_path, s.access_ref, l.created_at
FROM library l
JOIN source s ON s.source_id = l.source_id;

CREATE TABLE entry_v5 (
  source_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  root_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime REAL NOT NULL,
  available INTEGER NOT NULL DEFAULT 1,
  seen_generation INTEGER NOT NULL,
  etag TEXT,
  PRIMARY KEY(source_id, asset_id),
  UNIQUE(source_id, library_id, root_id, relative_path),
  UNIQUE(source_id, library_id, asset_id),
  FOREIGN KEY(source_id, library_id) REFERENCES library(source_id, library_id),
  FOREIGN KEY(root_id) REFERENCES library_root(root_id)
);
INSERT INTO entry_v5(source_id, asset_id, library_id, root_id, relative_path, size, mtime, available, seen_generation, etag)
SELECT source_id, asset_id, library_id, library_id, relative_path, size, mtime, available, seen_generation, etag
FROM entry;
DROP TABLE entry;
ALTER TABLE entry_v5 RENAME TO entry;

CREATE TABLE job_directory_v5 (
  job_id TEXT NOT NULL REFERENCES job(job_id),
  root_id TEXT NOT NULL REFERENCES library_root(root_id),
  relative_path TEXT NOT NULL,
  done INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(job_id, root_id, relative_path)
);
INSERT INTO job_directory_v5(job_id, root_id, relative_path, done)
SELECT jd.job_id, j.library_id, jd.relative_path, jd.done
FROM job_directory jd
JOIN job j ON j.job_id = jd.job_id;
DROP TABLE job_directory;
ALTER TABLE job_directory_v5 RENAME TO job_directory;

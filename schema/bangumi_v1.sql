CREATE TABLE subjects(
 subject_id INTEGER PRIMARY KEY, airtime_data BLOB, collection_data BLOB,
 eps INTEGER, images_data BLOB, infobox_data BLOB, locked INTEGER,
 meta_tags_data BLOB, tags_data BLOB, name TEXT, name_cn TEXT, nsfw INTEGER,
 platform_data BLOB, rating_data BLOB, series INTEGER, summary TEXT,
 type INTEGER, volumes INTEGER, info TEXT, alias TEXT, ctype INTEGER,
 collected_at INTEGER, interest_data BLOB
);
CREATE INDEX subjects_collection_idx ON subjects(type, ctype, collected_at DESC);
CREATE INDEX subjects_ctype_idx ON subjects(ctype);
CREATE INDEX subjects_ctype_collected_idx ON subjects(ctype, collected_at DESC);
CREATE TABLE episodes(
 episode_id INTEGER PRIMARY KEY, subject_id INTEGER, type INTEGER, sort REAL,
 name TEXT, name_cn TEXT, duration TEXT, airdate TEXT, comment INTEGER,
 disc INTEGER, desc TEXT, status INTEGER, collected_at INTEGER
);
CREATE INDEX episodes_subject_idx ON episodes(subject_id, type, sort);
CREATE INDEX episodes_progress_idx ON episodes(subject_id, type, status, sort);

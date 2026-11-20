use ocp_library::{scan, ItemKind, Library, LibraryType, Progress, Query, Store};
use std::{
    path::{Path, PathBuf},
    sync::atomic::AtomicU8,
};

struct Fixture {
    directory: PathBuf,
    root: PathBuf,
    store: Store,
}
impl Fixture {
    fn new() -> Self {
        let directory =
            std::env::temp_dir().join(format!("ocp-library-test-{}", ocp_library::id()));
        let root = directory.join("videos");
        std::fs::create_dir_all(&root).unwrap();
        let store = Store::open(&directory.join("db")).unwrap();
        Self {
            directory,
            root,
            store,
        }
    }
    fn video(&self, name: &str) {
        let path = self.root.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"fixture video").unwrap();
    }
    fn library(&self, typ: LibraryType) -> Library {
        self.store
            .create_local(
                &ocp_library::id(),
                None,
                "Fixture",
                &self.root,
                None,
                "Library",
                &self.root,
                typ,
            )
            .unwrap()
    }
    fn scan(&self, library: &Library) {
        let job = self
            .store
            .start_scan(&library.source_id, &library.library_id)
            .unwrap();
        scan::run(&self.store, &job, &AtomicU8::new(scan::RUN)).unwrap();
        assert_eq!(
            self.store
                .job(&library.source_id, &job.job_id)
                .unwrap()
                .status,
            "completed"
        );
    }
    fn query(&self, library: &Library, parent: Option<&str>) -> Vec<ocp_library::Item> {
        self.store
            .query(&Query {
                source_id: library.source_id.clone(),
                library_id: Some(library.library_id.clone()),
                library_type: None,
                parent_id: parent.map(str::to_owned),
                search: String::new(),
                start_index: 0,
                limit: 50,
                sort_by: None,
                sort_ascending: None,
                watch_state: None,
            })
            .unwrap()
            .0
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn v1_v2_v3_upgrade_preserve_catalog_and_add_durable_online_queue() {
    let f = Fixture::new();
    f.video("Movie (2020).mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let movie = f.query(&library, None).remove(0);
    f.store
        .bind_metadata(
            &library.source_id,
            &movie.item_id,
            11,
            "movie",
            "zh-CN",
            &serde_json::json!({"id":11,"title":"持久标题"}),
            true,
        )
        .unwrap();
    f.store
        .record_progress(&Progress {
            source_id: library.source_id.clone(),
            item_id: movie.item_id.clone(),
            position_seconds: 35.0,
            duration_seconds: None,
            played: false,
            completed: false,
            recorded_at: 20.0,
        })
        .unwrap();
    // Construct real older schemas, including source CHECK rebuilding and FK preservation.
    for version in [1, 2, 3, 4] {
        let old = f.directory.join(format!("old-{version}.sqlite"));
        let db = rusqlite::Connection::open(&old).unwrap();
        db.execute_batch(include_str!("../schema/v1.sql")).unwrap();
        if version >= 2 {
            db.execute_batch(include_str!("../schema/v2.sql")).unwrap();
        }
        if version >= 3 {
            db.execute_batch(include_str!("../schema/v3.sql")).unwrap();
        }
        if version >= 4 {
            db.execute_batch(include_str!("../schema/v4.sql")).unwrap();
        }
        db.pragma_update(None, "user_version", version).unwrap();
        db.execute(
            "ATTACH DATABASE ?1 AS fixture",
            [f.store.path().to_str().unwrap()],
        )
        .unwrap();
        db.execute_batch("INSERT INTO source SELECT * FROM fixture.source; INSERT INTO library SELECT * FROM fixture.library;").unwrap();
        db.execute_batch(if version >= 3 {
            "INSERT INTO entry(source_id,asset_id,library_id,relative_path,size,mtime,available,seen_generation,etag) SELECT source_id,asset_id,library_id,relative_path,size,mtime,available,seen_generation,etag FROM fixture.entry;"
        } else {
            "INSERT INTO entry(source_id,asset_id,library_id,relative_path,size,mtime,available,seen_generation) SELECT source_id,asset_id,library_id,relative_path,size,mtime,available,seen_generation FROM fixture.entry;"
        }).unwrap();
        db.execute_batch("INSERT INTO catalog_item(source_id,library_id,item_id,group_key,kind,title,year,parent_id,series_id,season_number,episode_number,first_seen_at) SELECT source_id,library_id,item_id,group_key,kind,title,year,parent_id,series_id,season_number,episode_number,first_seen_at FROM fixture.catalog_item; INSERT INTO item_asset SELECT * FROM fixture.item_asset; INSERT INTO item_match SELECT * FROM fixture.item_match; INSERT INTO watch_state SELECT * FROM fixture.watch_state;").unwrap();
        drop(db);
        let upgraded = Store::open_path(&old).unwrap();
        assert_eq!(
            upgraded.item(&library.source_id, &movie.item_id).unwrap(),
            f.store.item(&library.source_id, &movie.item_id).unwrap()
        );
        assert_eq!(
            upgraded
                .progress(&library.source_id, &movie.item_id)
                .unwrap()
                .unwrap()
                .position_seconds,
            35.0
        );
        let run = upgraded
            .start_scrape(&library.source_id, &library.library_id, "zh-CN", false)
            .unwrap();
        upgraded.seed_scrape(&run).unwrap();
        assert_eq!(
            upgraded
                .scrape_run(&library.source_id, &run.run_id)
                .unwrap()
                .total,
            1
        );
        upgraded.set_scrape_status(&run.run_id, "running").unwrap();
        upgraded.claim_scrape(&run).unwrap().unwrap();
        upgraded.recover_scrapes().unwrap();
        assert_eq!(
            upgraded
                .scrape_run(&library.source_id, &run.run_id)
                .unwrap()
                .status,
            "interrupted"
        );
        assert!(upgraded.claim_scrape(&run).unwrap().is_some());
    }
}

#[test]
fn smb_roots_categories_and_source_identity_stay_scoped() {
    let f = Fixture::new();
    let movie = f
        .store
        .create_smb(
            "smb-movies",
            None,
            "NAS",
            "smb://nas/Media/",
            Some("credential"),
            "电影",
            "smb://nas/Media/Movies/",
            LibraryType::Movies,
        )
        .unwrap();
    let tv = f
        .store
        .create_smb(
            "smb-tv",
            Some(&movie.source_id),
            "NAS",
            "smb://nas/Media/",
            Some("credential"),
            "电视剧",
            "smb://nas/Media/Shows/",
            LibraryType::Tvshows,
        )
        .unwrap();
    assert_eq!(movie.source_id, tv.source_id);
    assert_eq!(
        f.store.source(&movie.source_id).unwrap().kind,
        ocp_library::SourceKind::Smb
    );
    for root in [
        "smb://nas/Media/movies/",
        "smb://nas/Media/",
        "smb://other/Media/",
        "smb://nas/Other/",
        "smb://nas/Media/Movies/Nested/",
    ] {
        assert!(
            f.store
                .create_smb(
                    "smb-invalid",
                    Some(&movie.source_id),
                    "NAS",
                    "smb://nas/Media/",
                    None,
                    "无效",
                    root,
                    LibraryType::Movies
                )
                .is_err(),
            "{root}"
        );
    }
    assert_eq!(
        f.store
            .create_smb(
                "smb-movies",
                None,
                "NAS",
                "smb://nas/Media/",
                Some("credential"),
                "电影",
                "smb://nas/Media/Movies/",
                LibraryType::Movies
            )
            .unwrap()
            .library_id,
        movie.library_id
    );
    let reopened = Store::open_path(f.store.path()).unwrap();
    assert_eq!(reopened.libraries(&movie.source_id).unwrap().len(), 2);
    let db = rusqlite::Connection::open(f.store.path()).unwrap();
    assert_eq!(
        db.pragma_query_value::<i64, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        5
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r
            .get::<_, i64>(
            0
        ))
        .unwrap(),
        0
    );
}

#[test]
fn late_scrape_and_manual_binding_cannot_overwrite_new_revision() {
    let f = Fixture::new();
    f.video("Movie (2020).mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let movie = f.query(&library, None).remove(0);
    let run = f
        .store
        .start_scrape(&library.source_id, &library.library_id, "zh-CN", false)
        .unwrap();
    f.store.seed_scrape(&run).unwrap();
    f.store.set_scrape_status(&run.run_id, "running").unwrap();
    let old = f.store.claim_scrape(&run).unwrap().unwrap();
    let manual = f
        .store
        .match_target(&library.source_id, &movie.item_id, "zh-CN", true)
        .unwrap();
    let metadata = serde_json::json!({"id":2,"title":"Manual title","release_date":"2021-01-01"});
    f.store
        .bind_match_checked(&manual, "zh-CN", 2, &metadata)
        .unwrap();
    assert!(!f
        .store
        .commit_scrape(&run, &old, &serde_json::json!({"id":1,"title":"Old title"}))
        .unwrap());
    assert!(f
        .store
        .bind_match_checked(&manual, "zh-CN", 1, &serde_json::json!({"id":1}))
        .is_err());
    let current = f.store.item(&library.source_id, &movie.item_id).unwrap();
    assert_eq!(current.title, "Manual title");
    assert_eq!(current.year, Some(2021));
    f.scan(&library);
    assert_eq!(
        f.store
            .item(&library.source_id, &movie.item_id)
            .unwrap()
            .title,
        "Manual title"
    );
    let current = f
        .store
        .match_target(&library.source_id, &movie.item_id, "zh-CN", true)
        .unwrap();
    assert!(current.manual);
    assert_eq!(current.tmdb_id, Some(2));
    assert_eq!(current.item.title, "Movie");
    f.store
        .unbind_match(&library.source_id, &movie.item_id)
        .unwrap();
    assert!(f
        .store
        .bind_match_checked(&current, "zh-CN", 2, &metadata)
        .is_err());
    assert_eq!(
        f.store
            .item(&library.source_id, &movie.item_id)
            .unwrap()
            .title,
        "Movie"
    );
}

#[test]
fn rescan_blocks_old_network_result_and_missing_assets_skip_online_work() {
    let f = Fixture::new();
    f.video("Movie (2020).mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let run = f
        .store
        .start_scrape(&library.source_id, &library.library_id, "zh-CN", false)
        .unwrap();
    f.store.seed_scrape(&run).unwrap();
    f.store.set_scrape_status(&run.run_id, "running").unwrap();
    let old = f.store.claim_scrape(&run).unwrap().unwrap();
    std::fs::remove_file(f.root.join("Movie (2020).mkv")).unwrap();
    f.scan(&library);
    assert!(!f
        .store
        .commit_scrape(&run, &old, &serde_json::json!({"id":1}))
        .unwrap());
    f.store.seed_scrape(&run).unwrap();
    assert!(f.store.claim_scrape(&run).unwrap().is_none());
}

#[test]
fn season_metadata_only_updates_local_episodes_and_preserves_specials_progress() {
    let f = Fixture::new();
    f.video("Show (2024)/Season 0/Show S00E01.mkv");
    let library = f.library(LibraryType::Tvshows);
    f.scan(&library);
    let series = f.query(&library, None).remove(0);
    let season = f.query(&library, Some(&series.item_id)).remove(0);
    let episode = f.query(&library, Some(&season.item_id)).remove(0);
    f.store
        .record_progress(&Progress {
            source_id: library.source_id.clone(),
            item_id: episode.item_id.clone(),
            position_seconds: 123.0,
            duration_seconds: None,
            played: false,
            completed: false,
            recorded_at: 20.0,
        })
        .unwrap();
    let run = f
        .store
        .start_scrape(&library.source_id, &library.library_id, "zh-CN", false)
        .unwrap();
    f.store.seed_scrape(&run).unwrap();
    f.store.set_scrape_status(&run.run_id, "running").unwrap();
    let top = f.store.claim_scrape(&run).unwrap().unwrap();
    assert!(f.store.commit_scrape(&run,&top,&serde_json::json!({"id":10,"title":null,"name":"整剧标题","first_air_date":"2024-01-01"})).unwrap());
    assert_eq!(f.query(&library, None)[0].title, "整剧标题");
    f.store.seed_scrape(&run).unwrap();
    let target = f.store.claim_scrape(&run).unwrap().unwrap();
    assert_eq!(target.item.season_number, Some(0));
    assert!(f
        .store
        .commit_scrape(
            &run,
            &target,
            &serde_json::json!({"season_number":1,"episodes":[]})
        )
        .is_err());
    assert!(f.store.commit_scrape(&run,&target,&serde_json::json!({"season_number":0,"name":"特别篇","episodes":[{"episode_number":1,"name":"已入库特别篇","overview":"简介"},{"episode_number":2,"name":"没有本地文件"}]})).unwrap());
    let episodes = f.query(&library, Some(&season.item_id));
    assert_eq!(episodes.len(), 1);
    assert_eq!(episodes[0].title, "已入库特别篇");
    assert_eq!(
        f.store
            .progress(&library.source_id, &episode.item_id)
            .unwrap()
            .unwrap()
            .position_seconds,
        123.0
    );
    let foreign = f
        .store
        .start_scrape("foreign", &library.library_id, "zh-CN", false);
    assert!(foreign.is_err());
    f.store
        .unbind_match(&library.source_id, &series.item_id)
        .unwrap();
    assert!(f
        .store
        .item(&library.source_id, &episode.item_id)
        .unwrap()
        .metadata
        .is_none());
    assert!(f
        .store
        .progress(&library.source_id, &episode.item_id)
        .unwrap()
        .is_some());
}

#[test]
fn resume_includes_episode_leaves_and_excludes_completed_missing_and_foreign_sources() {
    let f = Fixture::new();
    f.video("Show/Season 1/Show S01E01.mkv");
    f.video("Show/Season 1/Show S01E02.mkv");
    let library = f.library(LibraryType::Tvshows);
    f.scan(&library);
    let series = f.query(&library, None).remove(0);
    let season = f.query(&library, Some(&series.item_id)).remove(0);
    let episodes = f.query(&library, Some(&season.item_id));
    for (index, episode) in episodes.iter().enumerate() {
        f.store
            .record_progress(&Progress {
                source_id: library.source_id.clone(),
                item_id: episode.item_id.clone(),
                position_seconds: 120.0,
                duration_seconds: Some(900.0),
                played: index == 1,
                completed: index == 1,
                recorded_at: 20.0 + index as f64,
            })
            .unwrap();
    }
    let resume = f.store.resume(&library.source_id, 20).unwrap();
    assert_eq!(resume.len(), 1);
    assert_eq!(resume[0].item_id, episodes[0].item_id);
    assert!(f.store.resume("foreign", 20).is_err());
    assert!(f.store.resume(&library.source_id, 0).is_err());
    std::fs::remove_file(f.root.join("Show/Season 1/Show S01E01.mkv")).unwrap();
    f.scan(&library);
    assert!(f.store.resume(&library.source_id, 20).unwrap().is_empty());
    assert!(f
        .store
        .progress(&library.source_id, &episodes[0].item_id)
        .unwrap()
        .is_some());
}

#[test]
fn movie_ids_and_progress_survive_rescan_reopen_and_cache_removal() {
    let f = Fixture::new();
    f.video("1917 (2019).mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let first = f.query(&library, None).remove(0);
    assert_eq!(
        (first.kind, first.title.as_str()),
        (ItemKind::Movie, "1917")
    );
    let progress = Progress {
        source_id: library.source_id.clone(),
        item_id: first.item_id.clone(),
        position_seconds: 300.0,
        duration_seconds: Some(500.0),
        played: false,
        completed: false,
        recorded_at: 20.0,
    };
    assert!(f.store.record_progress(&progress).unwrap());
    let mut old = progress.clone();
    old.recorded_at = 10.0;
    old.position_seconds = 100.0;
    assert!(!f.store.record_progress(&old).unwrap());
    f.scan(&library);
    assert_eq!(f.query(&library, None)[0].item_id, first.item_id);
    let cache = f.directory.join("db/Media.sqlite");
    std::fs::write(&cache, b"throwaway cache").unwrap();
    std::fs::remove_file(cache).unwrap();
    let reopened = Store::open(&f.directory.join("db")).unwrap();
    assert_eq!(
        reopened
            .progress(&library.source_id, &first.item_id)
            .unwrap(),
        Some(progress.clone())
    );
    let mut expected = first;
    expected.progress = Some(progress);
    assert_eq!(
        reopened
            .item(&library.source_id, &expected.item_id)
            .unwrap(),
        expected
    );
}

#[test]
fn series_seasons_episodes_and_same_episode_versions_form_one_tree() {
    let f = Fixture::new();
    for video in [
        "Show (2024)/Season 00/Show.S00E01.mkv",
        "Show (2024)/Season 02/Show.S02E03.1080p.mkv",
        "Show (2024)/Season 02/Show.S02E03.2160p.mkv",
    ] {
        f.video(video);
    }
    let library = f.library(LibraryType::Tvshows);
    f.scan(&library);
    let shows = f.query(&library, None);
    assert_eq!(shows.len(), 1);
    assert_eq!(shows[0].kind, ItemKind::Series);
    let seasons = f.query(&library, Some(&shows[0].item_id));
    assert_eq!(seasons.len(), 2);
    assert_eq!(
        seasons
            .iter()
            .map(|s| s.season_number.unwrap())
            .collect::<Vec<_>>(),
        vec![0, 2]
    );
    let episodes = f.query(&library, Some(&seasons[1].item_id));
    assert_eq!(episodes.len(), 1);
    assert_eq!(episodes[0].episode_number, Some(3));
    assert_eq!(
        f.store
            .assets(&library.source_id, &episodes[0].item_id)
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn scoped_queries_and_playback_reject_foreign_source_and_asset() {
    let f = Fixture::new();
    f.video("Movie (2020).mkv");
    let a = f.library(LibraryType::Movies);
    let b = f.library(LibraryType::Movies);
    f.scan(&a);
    f.scan(&b);
    let item = f.query(&a, None).remove(0);
    let asset = f
        .store
        .assets(&a.source_id, &item.item_id)
        .unwrap()
        .remove(0);
    assert!(f.store.item(&b.source_id, &item.item_id).is_err());
    assert!(f
        .store
        .playback_path(&b.source_id, &item.item_id, &asset.asset_id)
        .is_err());
    assert!(f
        .store
        .query(&Query {
            source_id: b.source_id,
            library_id: Some(a.library_id),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 50,
            sort_by: None,
            sort_ascending: None,
            watch_state: None,
        })
        .is_err());
}

#[test]
fn drafts_are_idempotent_and_overlapping_roots_are_rejected() {
    let f = Fixture::new();
    std::fs::create_dir_all(f.root.join("Movies")).unwrap();
    std::fs::create_dir_all(f.root.join("TV")).unwrap();
    let root = f.root.join("Movies");
    let a = f
        .store
        .create_local(
            "draft",
            None,
            "NAS",
            &f.root,
            None,
            "Movies",
            &root,
            LibraryType::Movies,
        )
        .unwrap();
    assert_eq!(
        f.store
            .create_local(
                "draft",
                None,
                "NAS",
                &f.root,
                None,
                "Movies",
                &root,
                LibraryType::Movies
            )
            .unwrap(),
        a
    );
    assert!(f
        .store
        .create_local(
            "draft",
            None,
            "NAS",
            &f.root,
            None,
            "TV",
            &root,
            LibraryType::Tvshows
        )
        .is_err());
    assert!(f
        .store
        .create_local(
            "other",
            Some(&a.source_id),
            "NAS",
            &f.root,
            None,
            "All",
            &f.root,
            LibraryType::Tvshows
        )
        .is_err());
    let b = f
        .store
        .create_local(
            "tv",
            Some(&a.source_id),
            "NAS",
            &f.root,
            None,
            "TV",
            &f.root.join("TV"),
            LibraryType::Tvshows,
        )
        .unwrap();
    assert_eq!(a.source_id, b.source_id);
    assert_eq!(f.store.libraries(&a.source_id).unwrap().len(), 2);
}

#[test]
fn interrupted_scan_never_marks_unseen_videos_missing() {
    let f = Fixture::new();
    f.video("Movie.mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let item = f.query(&library, None).remove(0);
    std::fs::remove_file(f.root.join("Movie.mkv")).unwrap();
    let job = f
        .store
        .start_scan(&library.source_id, &library.library_id)
        .unwrap();
    scan::run(&f.store, &job, &AtomicU8::new(scan::PAUSE)).unwrap();
    assert!(
        f.store
            .item(&library.source_id, &item.item_id)
            .unwrap()
            .playable
    );
    scan::run(&f.store, &job, &AtomicU8::new(scan::RUN)).unwrap();
    assert!(
        !f.store
            .item(&library.source_id, &item.item_id)
            .unwrap()
            .playable
    );
}

#[test]
fn root_unavailable_keeps_index_and_progress() {
    let f = Fixture::new();
    f.video("Movie.mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let item = f.query(&library, None).remove(0);
    std::fs::rename(&f.root, f.directory.join("disconnected")).unwrap();
    let job = f
        .store
        .start_scan(&library.source_id, &library.library_id)
        .unwrap();
    scan::run(&f.store, &job, &AtomicU8::new(scan::RUN)).unwrap();
    assert_eq!(
        f.store.job(&library.source_id, &job.job_id).unwrap().status,
        "waitingPermission"
    );
    assert!(
        f.store
            .item(&library.source_id, &item.item_id)
            .unwrap()
            .playable
    );
}

#[test]
fn manual_matches_are_locked_and_type_mismatch_is_rejected() {
    let f = Fixture::new();
    f.video("Movie.mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let item = f.query(&library, None).remove(0);
    assert!(f
        .store
        .bind_metadata(
            &library.source_id,
            &item.item_id,
            1,
            "tv",
            "zh-CN",
            &serde_json::json!({"id":1}),
            true
        )
        .is_err());
    assert!(f
        .store
        .bind_metadata(
            &library.source_id,
            &item.item_id,
            1,
            "movie",
            "zh-CN",
            &serde_json::json!({"id":1,"title":"Matched"}),
            true
        )
        .unwrap());
    assert!(!f
        .store
        .bind_metadata(
            &library.source_id,
            &item.item_id,
            2,
            "movie",
            "zh-CN",
            &serde_json::json!({"id":2}),
            false
        )
        .unwrap());
    let reopened = Store::open(&f.directory.join("db")).unwrap();
    assert_eq!(
        reopened
            .item(&library.source_id, &item.item_id)
            .unwrap()
            .metadata
            .unwrap()["id"],
        1
    );
}

#[test]
fn corrupt_permanent_database_is_preserved() {
    let directory = std::env::temp_dir().join(format!("ocp-library-corrupt-{}", ocp_library::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join(ocp_library::FILE_NAME);
    std::fs::write(&path, b"precious corrupt catalog").unwrap();
    assert!(Store::open(&directory).is_err());
    assert_eq!(std::fs::read(path).unwrap(), b"precious corrupt catalog");
    std::fs::remove_dir_all(directory).unwrap();
}

#[cfg(unix)]
#[test]
fn symlink_to_outside_file_is_not_indexed_or_played() {
    let f = Fixture::new();
    let outside = f.directory.join("outside.mkv");
    std::fs::write(&outside, b"outside").unwrap();
    std::os::unix::fs::symlink(&outside, f.root.join("escape.mkv")).unwrap();
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    assert!(f.query(&library, None).is_empty());
    f.video("legit.mkv");
    f.scan(&library);
    let item = f.query(&library, None).remove(0);
    let asset = f
        .store
        .assets(&library.source_id, &item.item_id)
        .unwrap()
        .remove(0);
    std::fs::remove_file(f.root.join("legit.mkv")).unwrap();
    std::os::unix::fs::symlink(&outside, f.root.join("legit.mkv")).unwrap();
    assert!(f
        .store
        .playback_path(&library.source_id, &item.item_id, &asset.asset_id)
        .is_err());
}

#[test]
fn scan_cancellation_and_recovery_preserve_discovered_items() {
    let f = Fixture::new();
    f.video("Movie.mkv");
    let library = f.library(LibraryType::Movies);
    let job = f
        .store
        .start_scan(&library.source_id, &library.library_id)
        .unwrap();
    f.store.set_job_status(&job.job_id, "enumerating").unwrap();
    f.store.recover_jobs().unwrap();
    assert_eq!(
        f.store.job(&library.source_id, &job.job_id).unwrap().status,
        "interrupted"
    );
    scan::run(&f.store, &job, &AtomicU8::new(scan::RUN)).unwrap();
    assert_eq!(f.query(&library, None).len(), 1);
    assert!(Path::new(&library.root_path).is_absolute());
}

#[test]
fn same_title_in_distinct_directories_is_not_merged_before_matching() {
    let f = Fixture::new();
    f.video("A/Show/Season 01/Show.S01E01.mkv");
    f.video("B/Show/Season 01/Show.S01E01.mkv");
    let library = f.library(LibraryType::Tvshows);
    f.scan(&library);
    let shows = f.query(&library, None);
    assert_eq!(shows.len(), 2);
    assert!(shows.iter().all(|show| show.title == "Show"));
}

#[test]
fn old_scan_cannot_publish_or_mark_newer_files_missing() {
    let f = Fixture::new();
    f.video("Movie.mkv");
    let library = f.library(LibraryType::Movies);
    f.scan(&library);
    let old = f.store.jobs(&library.source_id).unwrap().remove(0);
    f.video("New.mkv");
    f.scan(&library);
    assert!(f.store.finish_scan(&old).is_err());
    let parsed = ocp_library::parse::parse(Path::new("Movie.mkv"), LibraryType::Movies);
    assert!(f.store.ingest(&old, "Movie.mkv", 2, 0.0, &parsed).is_err());
    assert!(f.query(&library, None).iter().all(|item| item.playable));
}

#[test]
fn query_sort_watch_state_next_up_and_mark_played_match_home_and_library_needs() {
    let f = Fixture::new();
    f.video("Alpha (2020).mkv");
    f.video("Beta (2024).mkv");
    let movies = f.library(LibraryType::Movies);
    f.scan(&movies);
    let items = f.query(&movies, None);
    let alpha = items.iter().find(|i| i.title == "Alpha").unwrap();
    let beta = items.iter().find(|i| i.title == "Beta").unwrap();
    f.store
        .bind_metadata(
            &movies.source_id,
            &alpha.item_id,
            10,
            "movie",
            "zh-CN",
            &serde_json::json!({"id":10,"title":"Alpha","release_date":"2020-01-01","vote_average":9.1}),
            false,
        )
        .unwrap();
    f.store
        .bind_metadata(
            &movies.source_id,
            &beta.item_id,
            11,
            "movie",
            "zh-CN",
            &serde_json::json!({"id":11,"title":"Beta","release_date":"2024-05-01","vote_average":7.2}),
            false,
        )
        .unwrap();
    let by_rating = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 20,
            sort_by: Some("rating".into()),
            sort_ascending: Some(false),
            watch_state: None,
        })
        .unwrap()
        .0;
    assert_eq!(by_rating[0].item_id, alpha.item_id);
    let by_year = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 20,
            sort_by: Some("year".into()),
            sort_ascending: Some(false),
            watch_state: None,
        })
        .unwrap()
        .0;
    assert_eq!(by_year[0].item_id, beta.item_id);

    f.store
        .record_progress(&Progress {
            source_id: movies.source_id.clone(),
            item_id: alpha.item_id.clone(),
            position_seconds: 120.0,
            duration_seconds: Some(6000.0),
            played: false,
            completed: false,
            recorded_at: 50.0,
        })
        .unwrap();
    let marked = f
        .store
        .mark_played(&movies.source_id, &alpha.item_id, true, 100.0)
        .unwrap();
    assert!(marked.played && marked.completed && marked.duration_seconds == Some(6000.0));
    let played_only = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 20,
            sort_by: None,
            sort_ascending: None,
            watch_state: Some("played".into()),
        })
        .unwrap();
    assert_eq!(played_only.1, 1);
    assert_eq!(played_only.0[0].item_id, alpha.item_id);
    let unplayed_only = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 20,
            sort_by: None,
            sort_ascending: None,
            watch_state: Some("unplayed".into()),
        })
        .unwrap();
    assert_eq!(unplayed_only.1, 1);
    assert_eq!(unplayed_only.0[0].item_id, beta.item_id);

    let tv_fixture = Fixture::new();
    tv_fixture.video("Show (2024)/Season 00/Show.S00E01.mkv");
    tv_fixture.video("Show (2024)/Season 01/Show.S01E01.mkv");
    tv_fixture.video("Show (2024)/Season 01/Show.S01E02.mkv");
    let tv = tv_fixture.library(LibraryType::Tvshows);
    tv_fixture.scan(&tv);
    let show = tv_fixture.query(&tv, None).remove(0);
    assert_eq!(show.child_count, Some(2));
    tv_fixture
        .store
        .bind_metadata(
            &tv.source_id,
            &show.item_id,
            200,
            "tv",
            "zh-CN",
            &serde_json::json!({"id":200,"name":"剧集名称","backdrop_path":"/bg.jpg","poster_path":"/p.jpg"}),
            false,
        )
        .unwrap();
    let seasons = tv_fixture.query(&tv, Some(&show.item_id));
    let s1 = seasons.iter().find(|s| s.season_number == Some(1)).unwrap();
    let eps = tv_fixture.query(&tv, Some(&s1.item_id));
    let e1 = eps.iter().find(|e| e.episode_number == Some(1)).unwrap();
    let e2 = eps.iter().find(|e| e.episode_number == Some(2)).unwrap();
    assert_eq!(e1.series_title.as_deref(), Some("剧集名称"));
    assert_eq!(e1.series_backdrop_path.as_deref(), Some("/bg.jpg"));
    assert_eq!(e1.series_poster_path.as_deref(), Some("/p.jpg"));

    tv_fixture
        .store
        .mark_played(&tv.source_id, &e1.item_id, true, 100.0)
        .unwrap();
    let next_up = tv_fixture.store.next_up(&tv.source_id, 10).unwrap();
    assert_eq!(next_up.len(), 1);
    assert_eq!(next_up[0].item_id, e2.item_id);

    // If e2 is partially watched (in resume), next_up skips the series.
    tv_fixture
        .store
        .record_progress(&Progress {
            source_id: tv.source_id.clone(),
            item_id: e2.item_id.clone(),
            position_seconds: 90.0,
            duration_seconds: Some(1500.0),
            played: false,
            completed: false,
            recorded_at: 200.0,
        })
        .unwrap();
    assert!(tv_fixture
        .store
        .next_up(&tv.source_id, 10)
        .unwrap()
        .is_empty());
}

#[test]
fn local_source_supports_cross_root_categories_and_multi_root_single_category() {
    let f = Fixture::new();
    let disk_a_movies = f.directory.join("diskA/Movies");
    let disk_b_movies = f.directory.join("diskB/4KMovies");
    let disk_c_tv = f.directory.join("diskC/TV");
    std::fs::create_dir_all(&disk_a_movies).unwrap();
    std::fs::create_dir_all(&disk_b_movies).unwrap();
    std::fs::create_dir_all(disk_c_tv.join("Frieren/Season 1")).unwrap();
    std::fs::write(disk_a_movies.join("Arrival (2016).mkv"), b"a").unwrap();
    std::fs::write(disk_b_movies.join("Dune (2021).mkv"), b"b").unwrap();
    // Same relative filename in second root of same category must not collide.
    std::fs::write(disk_b_movies.join("Arrival (2016).mkv"), b"a4k").unwrap();
    std::fs::write(
        disk_c_tv.join("Frieren/Season 1/Frieren S01E01.mkv"),
        b"ep1",
    )
    .unwrap();

    let movies = f
        .store
        .create_local(
            "m-1",
            None,
            "My Media",
            &disk_a_movies,
            Some("ref-a"),
            "Movies",
            &disk_a_movies,
            LibraryType::Movies,
        )
        .unwrap();
    assert_eq!(movies.roots.len(), 1);
    assert_eq!(movies.roots[0].access_ref.as_deref(), Some("ref-a"));

    // Cross-drive category under the SAME local source succeeds.
    let tv = f
        .store
        .create_local(
            "t-1",
            Some(&movies.source_id),
            "My Media",
            &disk_c_tv,
            Some("ref-c"),
            "TV",
            &disk_c_tv,
            LibraryType::Tvshows,
        )
        .unwrap();
    assert_eq!(tv.source_id, movies.source_id);

    // Add a second folder into the EXISTING Movies category.
    let (updated_movies, added_root) = f
        .store
        .add_local_root(
            &movies.source_id,
            &movies.library_id,
            &disk_b_movies,
            Some("ref-b"),
            &disk_b_movies,
        )
        .unwrap();
    assert_eq!(updated_movies.roots.len(), 2);
    assert_eq!(added_root.access_ref.as_deref(), Some("ref-b"));

    // Overlapping root across categories or within the same category is rejected.
    assert!(f
        .store
        .add_local_root(
            &movies.source_id,
            &movies.library_id,
            &disk_c_tv,
            Some("ref-c2"),
            &disk_c_tv,
        )
        .is_err());

    let m_job = f
        .store
        .start_scan(&movies.source_id, &movies.library_id)
        .unwrap();
    scan::run(&f.store, &m_job, &AtomicU8::new(scan::RUN)).unwrap();
    let t_job = f.store.start_scan(&tv.source_id, &tv.library_id).unwrap();
    scan::run(&f.store, &t_job, &AtomicU8::new(scan::RUN)).unwrap();

    let (movie_items, total) = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 50,
            sort_by: Some("name".into()),
            sort_ascending: Some(true),
            watch_state: None,
        })
        .unwrap();
    assert_eq!(total, 3);
    // Arrival exists in both roots with the same relative filename; both stay indexed without colliding
    // and resolve to their respective disk paths.
    let arrivals: Vec<_> = movie_items
        .iter()
        .filter(|i| i.title == "Arrival")
        .collect();
    assert_eq!(arrivals.len(), 2);
    let mut playback_paths: Vec<_> = arrivals
        .iter()
        .map(|item| {
            let assets = f.store.assets(&movies.source_id, &item.item_id).unwrap();
            assert_eq!(assets.len(), 1);
            f.store
                .playback_path(&movies.source_id, &item.item_id, &assets[0].asset_id)
                .unwrap()
        })
        .collect();
    playback_paths.sort();
    assert_eq!(
        playback_paths,
        vec![
            std::fs::canonicalize(disk_a_movies.join("Arrival (2016).mkv")).unwrap(),
            std::fs::canonicalize(disk_b_movies.join("Arrival (2016).mkv")).unwrap(),
        ]
    );
    let dune = movie_items.iter().find(|i| i.title == "Dune").unwrap();
    let dune_assets = f.store.assets(&movies.source_id, &dune.item_id).unwrap();
    assert_eq!(dune_assets.len(), 1);
    assert_eq!(
        f.store
            .playback_path(&movies.source_id, &dune.item_id, &dune_assets[0].asset_id)
            .unwrap(),
        std::fs::canonicalize(disk_b_movies.join("Dune (2021).mkv")).unwrap()
    );

    // Rename category, remove one root from a multi-root category, reject removing the last root, then delete category and source.
    let renamed = f
        .store
        .rename_library(&movies.source_id, &movies.library_id, "4K 电影")
        .unwrap();
    assert_eq!(renamed.name, "4K 电影");
    let after_root_remove = f
        .store
        .remove_library_root(&movies.source_id, &movies.library_id, &added_root.root_id)
        .unwrap();
    assert_eq!(after_root_remove.roots.len(), 1);
    let (_, remaining_movies) = f
        .store
        .query(&Query {
            source_id: movies.source_id.clone(),
            library_id: Some(movies.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 50,
            sort_by: None,
            sort_ascending: None,
            watch_state: None,
        })
        .unwrap();
    assert_eq!(remaining_movies, 1);
    // Cannot remove the only remaining folder of a category.
    assert!(f
        .store
        .remove_library_root(
            &movies.source_id,
            &movies.library_id,
            &after_root_remove.roots[0].root_id
        )
        .is_err());
    // Delete Movies category -> TV category stays intact under the same source.
    f.store
        .delete_library(&movies.source_id, &movies.library_id)
        .unwrap();
    let remaining_libs = f.store.libraries(&movies.source_id).unwrap();
    assert_eq!(remaining_libs.len(), 1);
    assert_eq!(remaining_libs[0].library_id, tv.library_id);
    // Delete source -> everything cleanly removed with zero FK violations.
    f.store.delete_source(&movies.source_id).unwrap();
    assert!(f.store.sources().unwrap().is_empty());
    let db = rusqlite::Connection::open(f.store.path()).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r
            .get::<_, i64>(
            0
        ))
        .unwrap(),
        0
    );
}

#[test]
fn matching_same_tmdb_id_merges_series_seasons_episodes_and_movies_reversibly() {
    let f = Fixture::new();
    f.video("GroupA/Anime/Season 01/Anime.S01E01.1080p.mkv");
    f.video("GroupB/Anime/Season 01/Anime.S01E01.2160p.mkv");
    f.video("GroupB/Anime/Season 02/Anime.S02E01.mkv");
    let tv = f.library(LibraryType::Tvshows);
    f.scan(&tv);

    // Before TMDB matching, distinct folder trees remain separate.
    let before = f.query(&tv, None);
    assert_eq!(before.len(), 2);

    // Bind both series folders to the SAME TMDB TV ID.
    let tv_meta = serde_json::json!({
        "id": 777,
        "name": "恶女不才，请多关照",
        "first_air_date": "2026-04-01",
        "poster_path": "/p777.jpg"
    });
    for show in &before {
        f.store
            .bind_metadata(
                &tv.source_id,
                &show.item_id,
                777,
                "tv",
                "zh-CN",
                &tv_meta,
                true,
            )
            .unwrap();
    }

    // Top-level query merges both into ONE series with 2 seasons!
    let (after, total) = f
        .store
        .query(&Query {
            source_id: tv.source_id.clone(),
            library_id: Some(tv.library_id.clone()),
            library_type: None,
            parent_id: None,
            search: String::new(),
            start_index: 0,
            limit: 50,
            sort_by: None,
            sort_ascending: None,
            watch_state: None,
        })
        .unwrap();
    assert_eq!(total, 1);
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].child_count, Some(2));

    // Seasons merge across both folders (Season 1 + Season 2).
    let seasons = f.query(&tv, Some(&after[0].item_id));
    assert_eq!(seasons.len(), 2);
    assert_eq!(seasons[0].season_number, Some(1));
    assert_eq!(seasons[1].season_number, Some(2));

    // Season 1 Episode 1 merges into 1 episode with 2 playable versions (1080p + 2160p)!
    let s1_eps = f.query(&tv, Some(&seasons[0].item_id));
    assert_eq!(s1_eps.len(), 1);
    let e1_assets = f.store.assets(&tv.source_id, &s1_eps[0].item_id).unwrap();
    assert_eq!(e1_assets.len(), 2);
    for asset in &e1_assets {
        assert!(f
            .store
            .playback_path(&tv.source_id, &s1_eps[0].item_id, &asset.asset_id)
            .is_ok());
    }

    // Marking S01E01 played advances Next Up across folders to S02E01!
    f.store
        .mark_played(&tv.source_id, &s1_eps[0].item_id, true, 100.0)
        .unwrap();
    let next_up = f.store.next_up(&tv.source_id, 10).unwrap();
    assert_eq!(next_up.len(), 1);
    assert_eq!(next_up[0].season_number, Some(2));
    assert_eq!(next_up[0].episode_number, Some(1));

    // Unbinding splits them cleanly back to 2 unmatched entries without losing files.
    f.store
        .unbind_match(&tv.source_id, &after[0].item_id)
        .unwrap();
    assert_eq!(f.query(&tv, None).len(), 2);

    // Same for movies: 1080p + 4K matched to same TMDB ID merge into 1 movie with 2 versions.
    let mf = Fixture::new();
    mf.video("Dune.2021.1080p.mkv");
    mf.video("Dune.2021.2160p.mkv");
    let movies = mf.library(LibraryType::Movies);
    mf.scan(&movies);
    let raw_movies = mf.query(&movies, None);
    assert_eq!(raw_movies.len(), 2);
    let movie_meta = serde_json::json!({"id": 888, "title": "沙丘", "release_date": "2021-09-15"});
    for m in &raw_movies {
        mf.store
            .bind_metadata(
                &movies.source_id,
                &m.item_id,
                888,
                "movie",
                "zh-CN",
                &movie_meta,
                true,
            )
            .unwrap();
    }
    let merged_movies = mf.query(&movies, None);
    assert_eq!(merged_movies.len(), 1);
    let movie_assets = mf
        .store
        .assets(&movies.source_id, &merged_movies[0].item_id)
        .unwrap();
    assert_eq!(movie_assets.len(), 2);
}

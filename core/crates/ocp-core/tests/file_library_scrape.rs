use ocp_core::Core;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::TcpListener,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

struct HttpFixture {
    base: String,
    mode: Arc<AtomicU8>,
    paths: Arc<Mutex<Vec<String>>>,
    detail_started: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}
impl HttpFixture {
    fn new(mode: u8) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}/3", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let mode = Arc::new(AtomicU8::new(mode));
        let paths = Arc::new(Mutex::new(Vec::new()));
        let detail_started = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let (m, p, d, s) = (
            mode.clone(),
            paths.clone(),
            detail_started.clone(),
            stop.clone(),
        );
        let handle = thread::spawn(move || {
            let mut connections = Vec::new();
            while !s.load(Ordering::Acquire) {
                let Ok((mut stream, _)) = listener.accept() else {
                    thread::sleep(Duration::from_millis(5));
                    continue;
                };
                let (mode, paths, started) = (m.clone(), p.clone(), d.clone());
                connections.push(thread::spawn(move || {
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    let mut bytes=Vec::new(); let mut block=[0;4096];
                    while !bytes.windows(4).any(|b|b==b"\r\n\r\n") {
                        let Ok(n)=stream.read(&mut block) else { return; };
                        if n==0 { return; } bytes.extend_from_slice(&block[..n]);
                    }
                    let text=String::from_utf8(bytes).unwrap();
                    let raw=text.split_whitespace().nth(1).unwrap();
                    let url=url::Url::parse(&format!("http://fixture{raw}")).unwrap();
                    let path=url.path().to_owned();
                    paths.lock().unwrap().push(path.clone());
                    let configured=path.ends_with("configuration");
                    let valid=url.query_pairs().any(|(k,v)|k=="api_key" && v=="fixture-key");
                    let mode=mode.load(Ordering::Acquire);
                    let status=if !valid || mode==3 && !configured {401} else if mode==5 && !configured {503} else {200};
                    let movie=json!({"id":17,"title":"1917","original_title":"1917","release_date":"2019-12-01","overview":"电影简介","poster_path":"/movie.jpg"});
                    let show=json!({"id":24,"name":"Show","original_name":"Show","first_air_date":"2024-01-01","overview":"整剧简介","poster_path":"/show.jpg"});
                    let payload=if configured {json!({"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]},"change_keys":["title"]})}
                        else if path.ends_with("search/movie") {if mode==1 {json!({"results":[movie.clone(),{"id":18,"title":"1917","release_date":"2019-01-01"}]})} else {json!({"results":[movie.clone()]})}}
                        else if path.ends_with("search/tv") {json!({"results":[show.clone()]})}
                        else if path.ends_with("movie/17") { started.store(true,Ordering::Release); if mode==2 {thread::sleep(Duration::from_millis(300));} movie }
                        else if path.ends_with("tv/24") {show}
                        else if path.ends_with("tv/24/season/0") {json!({"season_number":if mode==4 {1} else {0},"name":"特别篇","episodes":[{"id":241,"episode_number":1,"name":"第一特别篇","overview":"分集简介","still_path":"/ep.jpg"},{"id":242,"episode_number":2,"name":"未入库集"}]})}
                        else {json!({"id":18,"title":"Manual 1917","overview":"人工选择","release_date":"2019-01-01"})};
                    let body=payload.to_string();
                    let _=write!(stream,"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
                }));
            }
            for connection in connections {
                let _ = connection.join();
            }
        });
        Self {
            base,
            mode,
            paths,
            detail_started,
            stop,
            handle: Some(handle),
        }
    }
}
impl Drop for HttpFixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.handle.take().unwrap().join();
    }
}

struct Fixture {
    core: Option<Core>,
    directory: PathBuf,
    root: PathBuf,
}
impl Fixture {
    fn new(video: &str) -> Self {
        let directory = std::env::temp_dir().join(format!("ocp-scrape-test-{}", ocp_library::id()));
        let root = directory.join("videos");
        let path = root.join(video);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"video").unwrap();
        let core = Core::new(&json!({"dataDirectory":directory.join("db")}).to_string()).unwrap();
        Self {
            core: Some(core),
            directory,
            root,
        }
    }
    fn reply(&self, method: &str, args: Value) -> Value {
        serde_json::from_str(
            &self
                .core
                .as_ref()
                .unwrap()
                .call(method, &args.to_string())
                .unwrap(),
        )
        .unwrap()
    }
    fn call(&self, method: &str, args: Value) -> Value {
        let reply = self.reply(method, args);
        assert_eq!(reply["ok"], true, "{method}: {reply}");
        reply["data"].clone()
    }
    fn create(&self, http: &HttpFixture, typ: &str) -> (String, String) {
        let receipt=self.call("tmdb.access.validate",json!({"apiKey":"fixture-key","apiBase":http.base,"credentialRevision":"r","draftId":"draft"}));
        let access = self.call("library.access.prepare", json!({"rootPath":self.root}));
        let created=self.call("library.create",json!({"draftId":"draft","verificationId":receipt["verificationId"],"credentialRevision":"r","apiBase":http.base,"accessId":access["accessId"],"kind":"localFolder","sourceName":"Files","rootPath":self.root,"name":"Library","type":typ}));
        (
            created["library"]["sourceId"].as_str().unwrap().into(),
            created["library"]["libraryId"].as_str().unwrap().into(),
        )
    }
    fn wait(&self, source: &str, status: &str) -> Value {
        for _ in 0..500 {
            let snapshot = self.call("library.scrape.snapshot", json!({"sourceId":source}));
            if snapshot["runs"][0]["status"] == status {
                return snapshot["runs"][0].clone();
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!(
            "scrape did not reach {status}: {}",
            self.call("library.scrape.snapshot", json!({"sourceId":source}))
        );
    }
    fn top(&self, source: &str, library: &str) -> Value {
        self.call(
            "library.query.page",
            json!({"sourceId":source,"libraryId":library}),
        )["items"][0]
            .clone()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.core.take();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn automatic_movie_and_specials_download_once_per_work_and_keep_offline_facts() {
    let http = HttpFixture::new(0);
    let movie = Fixture::new("1917 (2019).mkv");
    let (source, library) = movie.create(&http, "movies");
    assert_eq!(movie.wait(&source, "completed")["completed"], 1);
    let item = movie.top(&source, &library);
    assert_eq!(item["metadata"]["overview"], "电影简介");
    movie.call("tmdb.access.invalidate", json!({}));
    assert_eq!(movie.top(&source, &library), item);
    assert_eq!(
        movie.reply(
            "library.match.candidates",
            json!({"sourceId":source,"itemId":item["itemId"]})
        )["ok"],
        false
    );
    let tv = Fixture::new("Show (2024)/Season 0/Show S00E01.mkv");
    let (source, library) = tv.create(&http, "tvshows");
    assert_eq!(tv.wait(&source, "completed")["completed"], 2);
    let show = tv.top(&source, &library);
    let season = tv.call(
        "library.query.page",
        json!({"sourceId":source,"parentId":show["itemId"]}),
    )["items"][0]
        .clone();
    assert_eq!(season["seasonNumber"], 0);
    assert_eq!(season["title"], "特别篇");
    let episodes = tv.call(
        "library.query.page",
        json!({"sourceId":source,"parentId":season["itemId"]}),
    );
    assert_eq!(episodes["totalCount"], 1);
    assert_eq!(episodes["items"][0]["title"], "第一特别篇");
    let paths = http.paths.lock().unwrap();
    assert_eq!(paths.iter().filter(|p| p.ends_with("search/tv")).count(), 1);
    assert_eq!(paths.iter().filter(|p| p.ends_with("season/0")).count(), 1);
    assert!(!paths.iter().any(|p| p.contains("episode/")));
}

#[test]
fn ambiguous_candidates_require_manual_choice_and_refresh_keeps_manual_id() {
    let http = HttpFixture::new(1);
    let f = Fixture::new("1917 (2019).mkv");
    let (source, library) = f.create(&http, "movies");
    assert_eq!(f.wait(&source, "needsMatch")["unmatched"], 1);
    let item = f.top(&source, &library);
    assert!(item["metadata"].is_null());
    let candidates = f.call(
        "library.match.candidates",
        json!({"sourceId":source,"itemId":item["itemId"],"query":"1917"}),
    );
    assert_eq!(candidates["candidates"].as_array().unwrap().len(), 2);
    assert!(candidates["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .all(|c| c["mediaType"] == "movie"));
    let args = json!({"sourceId":source,"itemId":item["itemId"],"inputVersion":candidates["inputVersion"],"tmdbId":18});
    f.call("library.match.bind", args.clone());
    assert_eq!(f.reply("library.match.bind", args)["ok"], false);
    assert_eq!(f.top(&source, &library)["title"], "Manual 1917");
    f.call(
        "library.scrape.start",
        json!({"sourceId":source,"libraryId":library,"refresh":true}),
    );
    f.wait(&source, "completed");
    assert_eq!(f.top(&source, &library)["metadata"]["id"], 18);
    f.call(
        "library.match.unbind",
        json!({"sourceId":source,"itemId":item["itemId"]}),
    );
    assert!(f.top(&source, &library)["metadata"].is_null());
    let bytes = std::fs::read(f.directory.join("db/Library.sqlite-wal")).unwrap();
    assert!(!bytes
        .windows(b"fixture-key".len())
        .any(|b| b == b"fixture-key"));
}

#[test]
fn credential_invalidation_cancels_inflight_writes_and_allows_revalidated_resume() {
    let http = HttpFixture::new(2);
    let f = Fixture::new("1917 (2019).mkv");
    let (source, library) = f.create(&http, "movies");
    for _ in 0..300 {
        if http.detail_started.load(Ordering::Acquire) {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    assert!(http.detail_started.load(Ordering::Acquire));
    f.call("tmdb.access.invalidate", json!({}));
    let run = f.wait(&source, "waitingCredentials");
    thread::sleep(Duration::from_millis(350));
    assert!(f.top(&source, &library)["metadata"].is_null());
    http.mode.store(0, Ordering::Release);
    f.call("tmdb.access.validate",json!({"apiKey":"fixture-key","apiBase":http.base,"credentialRevision":"r","draftId":"online"}));
    f.call(
        "library.scrape.resume",
        json!({"sourceId":source,"runId":run["runId"]}),
    );
    f.wait(&source, "completed");
    assert_eq!(f.top(&source, &library)["metadata"]["id"], 17);
}

#[test]
fn revoked_key_pauses_queue_and_wrong_season_becomes_retryable_failure() {
    let http = HttpFixture::new(3);
    let f = Fixture::new("1917 (2019).mkv");
    let (source, library) = f.create(&http, "movies");
    let run = f.wait(&source, "waitingCredentials");
    assert!(f.top(&source, &library)["playable"].as_bool().unwrap());
    assert!(run["lastError"].as_str().unwrap().contains("凭据"));
    assert_eq!(
        f.reply(
            "library.scrape.resume",
            json!({"sourceId":source,"runId":run["runId"]})
        )["ok"],
        false
    );
    http.mode.store(4, Ordering::Release);
    let tv = Fixture::new("Show (2024)/Season 0/Show S00E01.mkv");
    let (source, library) = tv.create(&http, "tvshows");
    let run = tv.wait(&source, "partialFailure");
    assert_eq!(run["failed"], 1);
    let show = tv.top(&source, &library);
    assert!(!show["metadata"].is_null());
    let season = tv.call(
        "library.query.page",
        json!({"sourceId":source,"parentId":show["itemId"]}),
    )["items"][0]
        .clone();
    assert!(season["metadata"].is_null());
    http.mode.store(0, Ordering::Release);
    tv.call(
        "library.scrape.retry",
        json!({"sourceId":source,"runId":run["runId"]}),
    );
    tv.wait(&source, "completed");
    assert_eq!(
        tv.call(
            "library.query.detail",
            json!({"sourceId":source,"itemId":season["itemId"]})
        )["item"]["title"],
        "特别篇"
    );
}

#[test]
fn simultaneous_scan_and_online_queue_do_not_drop_discovered_files() {
    let http = HttpFixture::new(0);
    let f = Fixture::new("1917 (2019).mkv");
    for index in 0..40 {
        std::fs::write(f.root.join(format!("Other {index} (2020).mkv")), b"video").unwrap();
    }
    let (source, library) = f.create(&http, "movies");
    let run = f.wait(&source, "needsMatch");
    assert_eq!(run["total"], 41);
    assert_eq!(run["unmatched"], 40);
    let jobs = f.call("library.jobs.snapshot", json!({"sourceId":source}));
    assert_eq!(jobs["jobs"][0]["filesFound"], 41);
    assert_eq!(jobs["jobs"][0]["errorCount"], 0);
    assert_eq!(
        f.call(
            "library.query.page",
            json!({"sourceId":source,"libraryId":library,"limit":100})
        )["totalCount"],
        41
    );
}

#[test]
fn network_backoff_can_be_paused_and_explicitly_retried() {
    let http = HttpFixture::new(5);
    let f = Fixture::new("1917 (2019).mkv");
    let (source, library) = f.create(&http, "movies");
    let run = f.wait(&source, "waitingNetwork");
    assert!(run["nextRetryAt"].as_f64().unwrap() > ocp_library::now());
    f.call(
        "library.scrape.pause",
        json!({"sourceId":source,"runId":run["runId"]}),
    );
    http.mode.store(0, Ordering::Release);
    for _ in 0..100 {
        if f.reply(
            "library.scrape.retry",
            json!({"sourceId":source,"runId":run["runId"]}),
        )["ok"]
            == true
        {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    f.wait(&source, "completed");
    assert_eq!(f.top(&source, &library)["metadata"]["id"], 17);
}

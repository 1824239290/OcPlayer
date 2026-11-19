use ocp_core::Core;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::Duration,
};
struct Fixture {
    core: Option<Core>,
    child: Child,
    directory: PathBuf,
    base: String,
    size: u64,
}
impl Fixture {
    fn new() -> Self {
        let mut child = Command::new("python3")
            .arg("-u")
            .arg(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures/file_library_webdav.py"),
            )
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let config: Value = serde_json::from_str(&line).unwrap();
        let directory = std::env::temp_dir().join(format!("ocp-dav-{}", ocp_library::id()));
        let core = Core::new(&json!({"dataDirectory":directory}).to_string()).unwrap();
        Self {
            core: Some(core),
            child,
            directory,
            base: config["base"].as_str().unwrap().into(),
            size: config["size"].as_u64().unwrap(),
        }
    }
    fn call(&self, method: &str, args: Value) -> Value {
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
    fn ok(&self, method: &str, args: Value) -> Value {
        let r = self.call(method, args);
        assert_eq!(r["ok"], true, "{method}: {r}");
        r["data"].clone()
    }
    fn connection(&self) -> Value {
        json!({"rootUrl":format!("{}/dav/",self.base),"credential":{"type":"basic","username":"user","password":"fixture-password"},"accessRef":"credential-ref"})
    }
    fn create(
        &self,
        draft: &str,
        access: &Value,
        relative: &str,
        source: Option<&str>,
        typ: &str,
    ) -> Value {
        let category = self.ok(
            "library.webdav.browse",
            json!({"accessId":access["accessId"],"relativePath":relative}),
        );
        let v=self.ok("tmdb.access.validate",json!({"apiKey":"fixture-tmdb","apiBase":format!("{}/3",self.base),"credentialRevision":"v1","draftId":draft}));
        self.ok("library.create",json!({"draftId":draft,"verificationId":v["verificationId"],"credentialRevision":"v1","apiBase":format!("{}/3",self.base),"accessId":access["accessId"],"kind":"webdav","sourceId":source,"sourceName":"DAV","rootPath":category["rootPath"],"name":typ,"type":typ}))
    }
    fn wait(&self, source: &str, job: &str, status: &str) {
        for _ in 0..400 {
            let jobs = self.ok("library.jobs.snapshot", json!({"sourceId":source}));
            if jobs["jobs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|j| j["jobId"] == job && j["status"] == status)
            {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!(
            "job did not reach {status}: {}",
            self.ok("library.jobs.snapshot", json!({"sourceId":source}))
        );
    }
    fn control(&self, value: Value) {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                reqwest::Client::new()
                    .post(format!("{}/__control", self.base))
                    .json(&value)
                    .send()
                    .await
                    .unwrap();
            });
    }
    fn get(&self, url: &str, range: Option<&str>) -> (u16, Vec<u8>) {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let mut r = reqwest::Client::new().get(url);
                if let Some(range) = range {
                    r = r.header("Range", range);
                }
                let r = r.send().await.unwrap();
                (r.status().as_u16(), r.bytes().await.unwrap().to_vec())
            })
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.core.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
#[test]
fn creation_range_resource_and_reopen_without_tmdb() {
    let mut f = Fixture::new();
    let mut bad = f.connection();
    bad["credential"]["password"] = json!("wrong");
    assert_eq!(f.call("library.webdav.access.prepare", bad)["ok"], false);
    let access = f.ok("library.webdav.access.prepare", f.connection());
    let created = f.create("movie", &access, "Movies", None, "movies");
    let source = created["library"]["sourceId"].as_str().unwrap().to_owned();
    f.wait(
        &source,
        created["job"]["jobId"].as_str().unwrap(),
        "completed",
    );
    assert_eq!(
        f.ok("library.sources.list", json!({}))["sources"][0]["kind"],
        "webdav"
    );
    for _ in 0..200 {
        let runs = f.ok("library.scrape.snapshot", json!({"sourceId":source}));
        if runs["runs"][0]["status"] == "completed" {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let page = f.ok("library.query.page", json!({"sourceId":source}));
    assert_eq!(page["items"][0]["title"], "刮削后的中文电影");
    assert_eq!(page["totalCount"], 1);
    let item = page["items"][0]["itemId"].as_str().unwrap().to_owned();
    let detail = f.ok(
        "library.query.detail",
        json!({"sourceId":source,"itemId":item}),
    );
    assert_eq!(
        detail["assets"][0]["relativePath"],
        "中文 100% # & (2020).mkv"
    );
    let args = json!({"sourceId":source,"itemId":item,"assetId":detail["assets"][0]["assetId"]});
    f.ok("tmdb.access.invalidate", json!({}));
    let playback = f.ok("library.playback.prepare", args.clone());
    let uri = playback["uri"].as_str().unwrap();
    assert_eq!(playback["headers"], json!({}));
    assert!(uri.starts_with("http://127.0.0.1:"));
    assert!(!uri.contains("fixture-password"));
    let (status, bytes) = f.get(uri, Some("bytes=4194299-4194312"));
    assert_eq!(status, 206);
    assert_eq!(
        bytes,
        (4194299..=4194312)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<_>>()
    );
    let (status, bytes) = f.get(uri, Some("bytes=-8"));
    assert_eq!(status, 206);
    assert_eq!(
        bytes,
        ((f.size - 8)..f.size)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<_>>()
    );
    assert_eq!(f.get(uri, Some("bytes=0-1,4-5")).0, 416);
    let (status, bytes) = f.get(uri, None);
    assert_eq!(status, 200);
    assert_eq!(bytes.len() as u64, f.size);
    assert_eq!(bytes[4194312], (4194312 % 251) as u8);
    assert_eq!(f.get(&uri.replace("/media", "/other"), None).0, 404);
    f.ok(
        "library.playback.release",
        json!({"leaseId":playback["leaseId"]}),
    );
    assert!(std::net::TcpStream::connect(format!(
        "127.0.0.1:{}",
        url::Url::parse(uri).unwrap().port().unwrap()
    ))
    .is_err());
    f.ok("library.progress.record",json!({"sourceId":source,"itemId":item,"positionSeconds":35,"durationSeconds":120,"played":false,"completed":false,"recordedAt":20}));
    f.control(json!({"rangeMode":"same"}));
    let redirected = f.ok("library.playback.prepare", args.clone());
    assert_eq!(
        f.get(redirected["uri"].as_str().unwrap(), Some("bytes=2-4"))
            .1,
        vec![2, 3, 4]
    );
    f.ok(
        "library.playback.release",
        json!({"leaseId":redirected["leaseId"]}),
    );
    let trap = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    trap.set_nonblocking(true).unwrap();
    f.control(
        json!({"redirectURL":format!("http://{}/credential-trap",trap.local_addr().unwrap())}),
    );
    for mode in ["200", "wrong", "foreign"] {
        f.control(json!({"rangeMode":mode}));
        assert_eq!(
            f.call("library.playback.prepare", args.clone())["ok"],
            false,
            "{mode}"
        );
    }
    assert_eq!(
        trap.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    f.control(json!({"rangeMode":""}));
    f.core.take();
    f.core = Some(Core::new(&json!({"dataDirectory":f.directory}).to_string()).unwrap());
    assert_eq!(
        f.ok(
            "library.query.detail",
            json!({"sourceId":source,"itemId":item})
        )["progress"]["positionSeconds"],
        35.0
    );
    assert_eq!(
        f.call("library.playback.prepare", args.clone())["ok"],
        false
    );
    let mut restore = f.connection();
    restore["sourceId"] = json!(source);
    f.ok("library.webdav.credentials.restore", restore);
    let reopened = f.ok("library.playback.prepare", args);
    assert_eq!(reopened["progress"]["positionSeconds"], 35.0);
    f.ok(
        "library.playback.release",
        json!({"leaseId":reopened["leaseId"]}),
    );
    let records: Value =
        serde_json::from_slice(&f.get(&format!("{}/__requests", f.base), None).1).unwrap();
    assert!(records
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["path"].as_str().unwrap().starts_with("/3/"))
        .all(|r| r["authorization"].is_null()));
}
#[test]
fn same_source_movie_tv_and_failed_directory_resume_preserve_assets() {
    let mut f = Fixture::new();
    let access = f.ok("library.webdav.access.prepare", f.connection());
    let movie = f.create("movie", &access, "Movies", None, "movies");
    let source = movie["library"]["sourceId"].as_str().unwrap();
    f.wait(source, movie["job"]["jobId"].as_str().unwrap(), "completed");
    let tv = f.create("tv", &access, "Shows", Some(source), "tvshows");
    f.wait(source, tv["job"]["jobId"].as_str().unwrap(), "completed");
    assert_eq!(
        f.ok("library.sources.list", json!({}))["sources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let library = tv["library"]["libraryId"].as_str().unwrap();
    let series = f.ok(
        "library.query.page",
        json!({"sourceId":source,"libraryId":library}),
    );
    assert_eq!(series["items"][0]["kind"], "series");
    let seasons = f.ok(
        "library.query.page",
        json!({"sourceId":source,"parentId":series["items"][0]["itemId"]}),
    );
    assert_eq!(seasons["items"].as_array().unwrap().len(), 2);
    assert_eq!(seasons["items"][0]["seasonNumber"], 0);
    f.control(json!({"failDirectory":"/dav/Shows/Show/Season 0/"}));
    let scan = f.ok(
        "library.scan.start",
        json!({"sourceId":source,"libraryId":library}),
    );
    let id = scan["job"]["jobId"].as_str().unwrap();
    f.wait(source, id, "waitingNetwork");
    let before = f.ok(
        "library.query.page",
        json!({"sourceId":source,"parentId":seasons["items"][0]["itemId"]}),
    );
    assert_eq!(before["items"][0]["playable"], true);
    f.core.take();
    f.core = Some(Core::new(&json!({"dataDirectory":f.directory}).to_string()).unwrap());
    let mut restore = f.connection();
    restore["sourceId"] = json!(source);
    f.ok("library.webdav.credentials.restore", restore);
    f.control(json!({"failDirectory":""}));
    f.ok("library.scan.resume", json!({"sourceId":source,"jobId":id}));
    f.wait(source, id, "partialFailure");
    let after = f.ok(
        "library.query.page",
        json!({"sourceId":source,"parentId":seasons["items"][0]["itemId"]}),
    );
    assert_eq!(after["items"][0]["itemId"], before["items"][0]["itemId"]);
}

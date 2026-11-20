#[path = "../../../tests/support/smb_fixture.rs"]
mod fixture;
use ocp_core::Core;
use serde_json::{json, Value};
use std::{path::PathBuf, thread, time::Duration};
struct App {
    core: Option<Core>,
    directory: PathBuf,
    fixture: fixture::SmbFixture,
}
impl App {
    fn new() -> Option<Self> {
        let fixture = fixture::SmbFixture::start()?;
        let directory = std::env::temp_dir().join(format!("ocp-smb-core-{}", ocp_library::id()));
        let core = Some(Core::new(&json!({"dataDirectory":directory}).to_string()).unwrap());
        Some(Self {
            core,
            directory,
            fixture,
        })
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
        let value = self.call(method, args);
        assert_eq!(value["ok"], true, "{method}: {value}");
        value["data"].clone()
    }
    fn connection(&self) -> Value {
        json!({"rootUrl":self.fixture.config["root"],"credential":{"type":"password","username":"user","password":"fixture-password","domain":"FIXTURE","requireSigning":true},"accessRef":"smb-credential"})
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
            "library.smb.browse",
            json!({"accessId":access["accessId"],"relativePath":relative}),
        );
        let api = format!("{}/3", self.fixture.config["base"].as_str().unwrap());
        let validation=self.ok("tmdb.access.validate",json!({"apiKey":"fixture-tmdb","apiBase":api,"credentialRevision":"v1","draftId":draft}));
        self.ok("library.create",json!({"draftId":draft,"verificationId":validation["verificationId"],"credentialRevision":"v1","apiBase":api,"accessId":access["accessId"],"kind":"smb","sourceId":source,"sourceName":"SMB","rootPath":category["rootPath"],"name":typ,"type":typ}))
    }
    fn wait(&self, source: &str, job: &str) {
        self.wait_status(source, job, "completed");
    }
    fn wait_status(&self, source: &str, job: &str, status: &str) {
        for _ in 0..500 {
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
            "scan incomplete: {}",
            self.ok("library.jobs.snapshot", json!({"sourceId":source}))
        );
    }
    fn range(&self, uri: &str, range: &str) -> (u16, Vec<u8>) {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let response = reqwest::Client::new()
                    .get(uri)
                    .header("Range", range)
                    .send()
                    .await
                    .unwrap();
                (
                    response.status().as_u16(),
                    response.bytes().await.unwrap().to_vec(),
                )
            })
    }
}

#[test]
fn smb_failed_directory_restarts_from_checkpoint_without_deleting_assets() {
    let Some(mut app) = App::new() else {
        return;
    };
    let access = app.ok("library.smb.access.prepare", app.connection());
    let created = app.create("movies", &access, "Movies", None, "movies");
    let source = created["library"]["sourceId"].as_str().unwrap().to_owned();
    let library = created["library"]["libraryId"].as_str().unwrap().to_owned();
    app.wait(&source, created["job"]["jobId"].as_str().unwrap());
    let page = app.ok("library.query.page", json!({"sourceId":source}));
    let item = page["items"][0]["itemId"].clone();
    let detail_args = json!({"sourceId":source,"itemId":item});
    let original =
        app.ok("library.query.detail", detail_args.clone())["assets"][0]["assetId"].clone();
    let root = PathBuf::from(app.fixture.config["directory"].as_str().unwrap());
    std::fs::rename(root.join("Movies"), root.join("Offline")).unwrap();
    let job = app.ok(
        "library.scan.start",
        json!({"sourceId":source,"libraryId":library}),
    )["job"]["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    app.wait_status(&source, &job, "waitingNetwork");
    assert_eq!(
        app.ok("library.query.detail", detail_args.clone())["assets"][0]["available"],
        true
    );
    app.core.take();
    app.core = Some(Core::new(&json!({"dataDirectory":app.directory}).to_string()).unwrap());
    let mut connection = app.connection();
    connection["sourceId"] = json!(source);
    app.ok("library.smb.credentials.restore", connection);
    std::fs::rename(root.join("Offline"), root.join("Movies")).unwrap();
    app.ok(
        "library.scan.resume",
        json!({"sourceId":source,"jobId":job}),
    );
    app.wait_status(&source, &job, "partialFailure");
    let retry = app.ok(
        "library.scan.start",
        json!({"sourceId":source,"libraryId":library}),
    );
    app.wait(&source, retry["job"]["jobId"].as_str().unwrap());
    assert_eq!(
        app.ok("library.query.detail", detail_args)["assets"][0]["assetId"],
        original
    );
}
impl Drop for App {
    fn drop(&mut self) {
        self.core.take();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn smb_categories_scrape_large_range_and_reopen_without_tmdb() {
    let Some(mut app) = App::new() else {
        return;
    };
    assert_eq!(
        app.ok("library.capabilities", json!({}))["schemaVersion"],
        5
    );
    let access = app.ok("library.smb.access.prepare", app.connection());
    assert_eq!(
        app.call(
            "library.webdav.browse",
            json!({"accessId":access["accessId"]})
        )["ok"],
        false
    );
    assert_eq!(app.call("library.create",json!({"draftId":"no-key","verificationId":"fake","credentialRevision":"v1","apiBase":"http://fixture/3","accessId":access["accessId"],"kind":"smb","sourceName":"SMB","rootPath":access["rootPath"],"name":"movies","type":"movies"}))["ok"],false);
    let created = app.create("movies", &access, "Movies", None, "movies");
    let source = created["library"]["sourceId"].as_str().unwrap().to_owned();
    app.wait(&source, created["job"]["jobId"].as_str().unwrap());
    let tv = app.create("tv", &access, "Shows", Some(&source), "tvshows");
    app.wait(&source, tv["job"]["jobId"].as_str().unwrap());
    let page = app.ok(
        "library.query.page",
        json!({"sourceId":source,"type":"movies"}),
    );
    assert_eq!(page["totalCount"], 1);
    let item = page["items"][0]["itemId"].as_str().unwrap().to_owned();
    let detail = app.ok(
        "library.query.detail",
        json!({"sourceId":source,"itemId":item}),
    );
    let args = json!({"sourceId":source,"itemId":item,"assetId":detail["assets"][0]["assetId"]});
    let shows = app.ok(
        "library.query.page",
        json!({"sourceId":source,"type":"tvshows"}),
    );
    assert_eq!(shows["totalCount"], 1);
    let seasons = app.ok(
        "library.query.page",
        json!({"sourceId":source,"parentId":shows["items"][0]["itemId"]}),
    );
    assert_eq!(seasons["totalCount"], 2);
    assert!(seasons["items"]
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["seasonNumber"] == 0));
    for _ in 0..300 {
        if app.ok(
            "library.query.detail",
            json!({"sourceId":source,"itemId":item}),
        )["item"]["title"]
            == "SMB 刮削电影"
        {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        app.ok(
            "library.query.detail",
            json!({"sourceId":source,"itemId":item})
        )["item"]["title"],
        "SMB 刮削电影"
    );
    app.ok("tmdb.access.invalidate", json!({}));
    let playback = app.ok("library.playback.prepare", args.clone());
    let uri = playback["uri"].as_str().unwrap();
    assert!(uri.starts_with("http://127.0.0.1:"));
    assert!(!uri.contains("Media"));
    let offset = 4 * 1024_u64.pow(3) - 16;
    let (status, bytes) = app.range(uri, &format!("bytes={offset}-{}", offset + 31));
    assert_eq!(status, 206);
    assert_eq!(
        bytes,
        (offset..offset + 32)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<_>>()
    );
    assert_eq!(app.range(uri, "bytes=0-1,4-5").0, 416);
    let size = app.fixture.config["size"].as_u64().unwrap();
    assert_eq!(
        app.range(uri, "bytes=-8").1,
        (size - 8..size)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<_>>()
    );
    app.ok("library.progress.record",json!({"sourceId":source,"itemId":item,"positionSeconds":35,"durationSeconds":120,"played":false,"completed":false,"recordedAt":20}));
    app.ok(
        "library.playback.release",
        json!({"leaseId":playback["leaseId"]}),
    );
    app.core.take();
    app.core = Some(Core::new(&json!({"dataDirectory":app.directory}).to_string()).unwrap());
    assert_eq!(
        app.ok(
            "library.query.detail",
            json!({"sourceId":source,"itemId":item})
        )["progress"]["positionSeconds"],
        35.0
    );
    assert_eq!(
        app.ok("library.sources.list", json!({}))["sources"][0]["kind"],
        "smb"
    );
    assert_eq!(
        app.call("library.playback.prepare", args.clone())["ok"],
        false
    );
    let mut restore = app.connection();
    restore["sourceId"] = json!(source);
    app.ok("library.smb.credentials.restore", restore);
    let second = app.ok("library.playback.prepare", args);
    assert_eq!(
        app.range(second["uri"].as_str().unwrap(), "bytes=0-7").1,
        (0..8).collect::<Vec<u8>>()
    );
    app.ok(
        "library.playback.release",
        json!({"leaseId":second["leaseId"]}),
    );
}

use ocp_core::Core;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::TcpListener,
    path::PathBuf,
    thread,
    time::Duration,
};

struct Fixture {
    core: Core,
    directory: PathBuf,
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let directory =
            std::env::temp_dir().join(format!("ocp-file-library-{}", ocp_library::id()));
        let root = directory.join("videos");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("1917 (2019).mkv"), b"video").unwrap();
        let core = Core::new(&json!({"dataDirectory":directory.join("db")}).to_string()).unwrap();
        Self {
            core,
            directory,
            root,
        }
    }
    fn call(&self, method: &str, args: Value) -> Value {
        serde_json::from_str(&self.core.call(method, &args.to_string()).unwrap()).unwrap()
    }
    fn access(&self) -> String {
        let reply = self.call("library.access.prepare", json!({"rootPath":self.root}));
        assert!(reply["ok"].as_bool().unwrap(), "{reply}");
        reply["data"]["accessId"].as_str().unwrap().into()
    }
    fn input(&self, base: &str, receipt: &str, access: &str) -> Value {
        json!({"draftId":"draft","verificationId":receipt,"credentialRevision":"revision","apiBase":base,"accessId":access,"kind":"localFolder","sourceName":"Files","rootPath":self.root,"name":"Movies","type":"movies"})
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn endpoint(status: u16, body: &str) -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}/3", listener.local_addr().unwrap());
    let body = body.to_owned();
    let handle = thread::spawn(move || {
        let (mut connection, _) = listener.accept().unwrap();
        connection
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        let mut block = [0; 4096];
        while !request.windows(4).any(|w| w == b"\r\n\r\n") {
            let read = connection.read(&mut block).unwrap();
            if read == 0 {
                break;
            }
            request.extend_from_slice(&block[..read]);
        }
        write!(connection,"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
        String::from_utf8(request).unwrap()
    });
    (base, handle)
}

const CONFIG: &str = r#"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500","original"]},"change_keys":["title"]}"#;

#[test]
fn authenticated_validation_creation_scan_and_playback_cross_public_commands() {
    let f = Fixture::new();
    let access = f.access();
    let rejected = f.call(
        "library.create",
        f.input("http://unused", "invented", &access),
    );
    assert!(!rejected["ok"].as_bool().unwrap());
    let (base, http) = endpoint(200, CONFIG);
    let validation=f.call("tmdb.access.validate",json!({"apiKey":"fixture-secret-key","apiBase":base,"credentialRevision":"revision","draftId":"draft"}));
    assert_eq!(validation["data"]["status"], "valid", "{validation}");
    let request = http.join().unwrap();
    assert!(request.starts_with("GET /3/configuration?"));
    assert!(request.contains("api_key=fixture-secret-key"));
    let receipt = validation["data"]["verificationId"].as_str().unwrap();
    let created = f.call("library.create", f.input(&base, receipt, &access));
    assert!(created["ok"].as_bool().unwrap(), "{created}");
    let source = created["data"]["library"]["sourceId"].as_str().unwrap();
    let library = created["data"]["library"]["libraryId"].as_str().unwrap();
    for _ in 0..200 {
        let jobs = f.call("library.jobs.snapshot", json!({"sourceId":source}));
        if jobs["data"]["jobs"][0]["status"] == "completed" {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    let jobs = f.call("library.jobs.snapshot", json!({"sourceId":source}));
    assert_eq!(jobs["data"]["jobs"][0]["status"], "completed");
    let duplicate = f.call("library.create", f.input(&base, receipt, &access));
    assert_eq!(duplicate["data"]["library"], created["data"]["library"]);
    assert_eq!(
        duplicate["data"]["job"]["jobId"],
        created["data"]["job"]["jobId"]
    );
    let page = f.call(
        "library.query.page",
        json!({"sourceId":source,"libraryId":library}),
    );
    assert_eq!(page["data"]["totalCount"], 1);
    assert_eq!(page["data"]["items"][0]["title"], "1917");
    let item = page["data"]["items"][0]["itemId"].as_str().unwrap();
    let detail = f.call(
        "library.query.detail",
        json!({"sourceId":source,"itemId":item}),
    );
    let asset = detail["data"]["assets"][0]["assetId"].as_str().unwrap();
    let prepared = f.call(
        "library.playback.prepare",
        json!({"sourceId":source,"itemId":item,"assetId":asset}),
    );
    assert!(prepared["data"]["uri"]
        .as_str()
        .unwrap()
        .starts_with("file://"));
    let invalidated = f.call("tmdb.access.invalidate", json!({}));
    assert!(invalidated["ok"].as_bool().unwrap());
    assert!(
        !f.call("library.create", f.input(&base, receipt, &access))["ok"]
            .as_bool()
            .unwrap()
    );
    assert!(
        f.call("library.query.page", json!({"sourceId":source}))["ok"]
            .as_bool()
            .unwrap()
    );
    let secret = b"fixture-secret-key";
    for entry in std::fs::read_dir(f.directory.join("db")).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        assert!(!bytes.windows(secret.len()).any(|w| w == secret));
    }
}

#[test]
fn token_authentication_and_malformed_mirror_responses_are_distinct() {
    let f = Fixture::new();
    let (base, http) = endpoint(200, CONFIG);
    let reply=f.call("tmdb.access.validate",json!({"apiKey":"eyJ.fixture-token","apiBase":base,"credentialRevision":"token","draftId":"draft"}));
    assert!(reply["ok"].as_bool().unwrap());
    let request = http.join().unwrap().to_lowercase();
    assert!(request.contains("authorization: bearer eyj.fixture-token"));
    assert!(!request.contains("api_key="));
    for (status, body) in [
        (200, "<html>mirror login</html>"),
        (200, "{}"),
        (
            401,
            r#"{"status_code":7,"status_message":"Invalid API key"}"#,
        ),
        (
            403,
            r#"{"status_code":10,"status_message":"Access denied"}"#,
        ),
    ] {
        let (base, http) = endpoint(status, body);
        let reply=f.call("tmdb.access.validate",json!({"apiKey":"fixture","apiBase":base,"credentialRevision":"changed","draftId":"draft"}));
        http.join().unwrap();
        assert!(!reply["ok"].as_bool().unwrap(), "{status}");
        assert!(reply["data"].is_null());
    }
}

#[test]
fn capabilities_do_not_advertise_unimplemented_providers_and_queries_require_scope() {
    let f = Fixture::new();
    let capabilities = f.call("library.capabilities", json!({}));
    assert_eq!(
        capabilities["data"]["sourceKinds"],
        json!(["localFolder", "webdav", "smb"])
    );
    assert_eq!(capabilities["data"]["aggregation"], false);
    assert!(!f.call("library.query.page", json!({}))["ok"]
        .as_bool()
        .unwrap());
    assert!(!f.call(
        "tmdb.access.validate",
        json!({"apiKey":" ","apiBase":"http://unused","credentialRevision":"r","draftId":"d"})
    )["ok"]
        .as_bool()
        .unwrap());
    assert_eq!(
        f.call("library.capabilities", json!({"requestId":false}))["code"],
        1002
    );
}

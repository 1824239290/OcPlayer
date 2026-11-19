#[path = "../../../tests/support/smb_fixture.rs"]
mod fixture;
use ocp_smb::{Credential, Error, Provider};
fn credential() -> Credential {
    Credential::Password {
        username: "user".into(),
        password: "fixture-password".into(),
        domain: "FIXTURE".into(),
        require_signing: true,
        require_encryption: false,
    }
}

#[test]
fn parallel_context_creation_and_retirement_remain_independent() {
    let Some(f) = fixture::SmbFixture::start() else {
        return;
    };
    let provider = Provider::new(f.config["root"].as_str().unwrap(), credential()).unwrap();
    let mut threads = Vec::new();
    for _ in 0..8 {
        let provider = provider.clone();
        threads.push(std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                for _ in 0..3 {
                    let entries = provider.list("Movies").await.unwrap();
                    let mut reader = provider
                        .open(&entries[0].relative_path, None)
                        .await
                        .unwrap();
                    assert_eq!(
                        reader.read_at(0, 8).await.unwrap(),
                        (0..8).collect::<Vec<u8>>()
                    );
                }
            });
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }
}

#[tokio::test]
async fn authentication_special_paths_and_independent_large_reads() {
    let Some(f) = fixture::SmbFixture::start() else {
        return;
    };
    let root = f.config["root"].as_str().unwrap();
    let p = Provider::new(&root.replace("127.0.0.1", "localhost"), credential()).unwrap();
    let entries = p.list("Movies").await.unwrap();
    assert_eq!(entries.len(), 1);
    let relative = &entries[0].relative_path;
    assert_eq!(relative, "Movies/中文 100% # & (2020).mkv");
    assert_eq!(entries[0].size, f.config["size"].as_i64().unwrap());
    let snapshot = p.probe(relative).await.unwrap();
    assert_eq!(snapshot.size, entries[0].size as u64);
    let mut readers = Vec::new();
    for _ in 0..4 {
        readers.push(p.open(relative, Some(&snapshot)).await.unwrap());
    }
    let offset = 4 * 1024_u64.pow(3) - 16;
    let mut tasks = tokio::task::JoinSet::new();
    for mut r in readers {
        tasks.spawn(async move { r.read_at(offset, 32).await.unwrap() });
    }
    while let Some(r) = tasks.join_next().await {
        assert_eq!(
            r.unwrap(),
            (offset..offset + 32)
                .map(|i| (i % 251) as u8)
                .collect::<Vec<_>>()
        );
    }
    assert!(
        Provider::new(f.config["guestRoot"].as_str().unwrap(), Credential::Guest)
            .unwrap()
            .list("")
            .await
            .is_ok()
    );
}

#[tokio::test]
async fn errors_and_file_replacement_never_join_different_content() {
    let Some(f) = fixture::SmbFixture::start() else {
        return;
    };
    let root = f.config["root"].as_str().unwrap();
    let mut bad = credential();
    if let Credential::Password { password, .. } = &mut bad {
        *password = "wrong".into();
    }
    assert_eq!(
        Provider::new(root, bad)
            .unwrap()
            .list("")
            .await
            .unwrap_err(),
        Error::Unauthorized
    );
    assert_eq!(
        Provider::new(&root.replace("Media/", "Missing/"), credential())
            .unwrap()
            .list("")
            .await
            .unwrap_err(),
        Error::ShareMissing
    );
    let p = Provider::new(root, credential()).unwrap();
    assert_eq!(p.list("Missing").await.unwrap_err(), Error::NotFound);
    assert_eq!(p.list("Denied").await.unwrap_err(), Error::Permission);
    let mut encrypted = credential();
    if let Credential::Password {
        require_encryption, ..
    } = &mut encrypted
    {
        *require_encryption = true;
    }
    assert!(
        Provider::new(root, encrypted)
            .unwrap()
            .list("")
            .await
            .is_err(),
        "SMB2 fixture must not silently satisfy required SMB3 encryption"
    );
    let path = "Movies/中文 100% # & (2020).mkv";
    let mut reader = p.open(path, None).await.unwrap();
    let snapshot = reader.snapshot.clone();
    let file = std::fs::OpenOptions::new()
        .write(true)
        .open(std::path::Path::new(f.config["directory"].as_str().unwrap()).join(path))
        .unwrap();
    file.set_len(snapshot.size + 1).unwrap();
    assert_eq!(reader.read_at(0, 1).await.unwrap_err(), Error::Changed);
    assert!(matches!(
        p.open(path, Some(&snapshot)).await,
        Err(Error::Changed)
    ));
}

#[tokio::test]
async fn cancellation_closes_pending_protocol_socket() {
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let p = Provider::new(
        &format!("smb://{}/Media/", listener.local_addr().unwrap()),
        Credential::Guest,
    )
    .unwrap();
    let reading = async {
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), p.list(""))
                .await
                .is_err()
        );
    };
    let accepted = async {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            socket.read_to_end(&mut bytes),
        )
        .await
        .unwrap();
        assert!(
            result.is_ok() || result.unwrap_err().kind() == std::io::ErrorKind::ConnectionReset
        );
        assert!(!bytes.is_empty());
    };
    tokio::join!(reading, accepted);
}

use ocp_webdav::{parse_listing, root_url, within, Credential, Provider};
fn response(href: &str, props: &str) -> String {
    format!("<x:response><x:href>{href}</x:href><x:propstat><x:prop><x:getcontentlength>invalid</x:getcontentlength></x:prop><x:status>HTTP/1.1 404 Missing</x:status></x:propstat><x:propstat><x:prop>{props}</x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response>")
}
fn xml(child: &str) -> String {
    format!(
        "<x:multistatus xmlns:x='DAV:'>{}{child}</x:multistatus>",
        response(
            "/dav/Movies/",
            "<x:resourcetype><x:collection/></x:resourcetype>"
        )
    )
}
#[test]
fn segment_identity_and_directory_boundaries() {
    let p = Provider::new("https://nas.example/dav/中文%20库/", Credential::None).unwrap();
    let u = p.url("100% # &/file.mkv", false).unwrap();
    assert!(u.as_str().contains("100%25%20%23%20&"));
    assert!(within(p.root(), p.url("Movies", true).unwrap().as_str()));
    assert!(!within(
        "https://nas.example/dav/Movies/",
        "https://nas.example/dav/Movies2/"
    ));
    assert!(!within(p.root(), "https://foreign.example/dav/"));
    for root in [
        "https://nas/dav/%2e%2e/",
        "https://nas/dav/%2f/",
        "https://u:p@nas/dav/",
        "https://nas/dav/?token=secret",
        "file:///tmp/",
    ] {
        assert!(root_url(root).is_err(), "{root}");
    }
    for path in ["/Movies", "../Movies", "a//b", "a\\b", "a/./b"] {
        assert!(p.url(path, true).is_err(), "{path}");
    }
}
#[test]
fn dav_namespace_propstat_and_64bit_size() {
    let root = root_url("https://nas/dav/").unwrap();
    let directory = root_url("https://nas/dav/Movies/").unwrap();
    let child = response("/dav/Movies/%E4%B8%AD%E6%96%87%20100%25%20%23.mkv", "<x:resourcetype/><x:getcontentlength>9223372036854775807</x:getcontentlength><x:getetag>&quot;v1&quot;</x:getetag>");
    let entries = parse_listing(&root, &directory, &xml(&child)).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].relative_path, "Movies/中文 100% #.mkv");
    assert_eq!(entries[0].size, i64::MAX);
    assert_eq!(entries[0].etag.as_deref(), Some("\"v1\""));
}
#[test]
fn invalid_or_partial_listing_cannot_prove_missing_entries() {
    let root = root_url("https://nas/dav/").unwrap();
    let directory = root_url("https://nas/dav/Movies/").unwrap();
    for href in [
        "https://foreign/dav/Movies/a.mkv",
        "/dav/Movies/%2e%2e/a.mkv",
        "/dav/Movies/a%2fb.mkv",
        "/dav/Movies/a/b.mkv",
        "/outside/a.mkv",
        "/dav/Movies/a.mkv?key=x",
    ] {
        assert!(
            parse_listing(
                &root,
                &directory,
                &xml(&response(
                    href,
                    "<x:resourcetype/><x:getcontentlength>1</x:getcontentlength>"
                ))
            )
            .is_err(),
            "{href}"
        );
    }
    for props in [
        "<x:resourcetype/><x:getcontentlength>-1</x:getcontentlength>",
        "<x:resourcetype/><x:getcontentlength>9223372036854775808</x:getcontentlength>",
        "<x:getcontentlength>1</x:getcontentlength>",
    ] {
        assert!(parse_listing(
            &root,
            &directory,
            &xml(&response("/dav/Movies/a.mkv", props))
        )
        .is_err());
    }
    let failed = "<x:response><x:href>/dav/Movies/a.mkv</x:href><x:status>HTTP/1.1 403 Forbidden</x:status></x:response>";
    assert!(parse_listing(&root, &directory, &xml(failed)).is_err());
    assert!(parse_listing(&root, &directory, "<multistatus xmlns='DAV:' />").is_err());
    assert!(parse_listing(
        &root,
        &directory,
        "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x>&secret;</x>"
    )
    .is_err());
}

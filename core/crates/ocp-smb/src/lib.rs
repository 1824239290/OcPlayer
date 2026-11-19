//! Credential-scoped SMB2/3. Each async reader owns a C context and offset-based
//! handle; dropping its future closes the socket and aborts outstanding PDUs.
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_int, c_void, CStr, CString},
    ptr::NonNull,
    sync::Mutex,
    time::Duration,
};
// libsmb2's active_contexts list is process-global and unsynchronized. Only
// creation/destruction touches it in this client; network reads remain parallel.
static CONTEXT_LIFECYCLE: Mutex<()> = Mutex::new(());
use url::Url;

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("SMB 地址或路径无效，请填写 smb://主机/共享名/")]
    Path,
    #[error("SMB 用户名、密码或域无效")]
    Unauthorized,
    #[error("SMB 账户没有目录或文件权限")]
    Permission,
    #[error("SMB 共享不存在")]
    ShareMissing,
    #[error("SMB 文件或目录不存在")]
    NotFound,
    #[error("SMB 连接失败或超时，请检查服务器后重试")]
    Network,
    #[error("SMB 目录响应无效或超出大小限制")]
    Listing,
    #[error("SMB 文件在读取期间发生变化，请重新打开")]
    Changed,
    #[error("SMB 服务器未完成所需的读取或安全协商")]
    Read,
}
fn yes() -> bool {
    true
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(
    tag = "type",
    rename_all = "lowercase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Credential {
    Guest,
    Password {
        username: String,
        password: String,
        #[serde(default)]
        domain: String,
        #[serde(default = "yes")]
        require_signing: bool,
        #[serde(default)]
        require_encryption: bool,
    },
}
#[derive(Clone)]
pub struct Provider {
    root: Url,
    credential: Credential,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub relative_path: String,
    pub is_directory: bool,
    pub size: i64,
    pub modified_at: f64,
    pub etag: Option<String>,
}

#[repr(C)]
#[derive(Default, Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub size: u64,
    ino: u64,
    mtime: u64,
    mtime_ns: u64,
    ctime: u64,
    ctime_ns: u64,
    btime: u64,
    btime_ns: u64,
    typ: u32,
}
impl Snapshot {
    fn version(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}:{}:{}:{}",
            self.ino,
            self.size,
            self.mtime,
            self.mtime_ns,
            self.ctime,
            self.ctime_ns,
            self.btime,
            self.btime_ns
        )
    }
}
unsafe extern "C" {
    fn ocp_smb_new(
        user: *const c_char,
        password: *const c_char,
        domain: *const c_char,
        sign: c_int,
        seal: c_int,
    ) -> *mut c_void;
    fn ocp_smb_destroy(s: *mut c_void);
    fn ocp_smb_connect(
        s: *mut c_void,
        server: *const c_char,
        share: *const c_char,
        user: *const c_char,
    ) -> c_int;
    fn ocp_smb_list(s: *mut c_void, path: *const c_char) -> c_int;
    fn ocp_smb_open(s: *mut c_void, path: *const c_char) -> c_int;
    fn ocp_smb_stat(s: *mut c_void) -> c_int;
    fn ocp_smb_read(s: *mut c_void, buf: *mut u8, count: u32, offset: u64) -> c_int;
    fn ocp_smb_step(s: *mut c_void) -> c_int;
    fn ocp_smb_status(s: *mut c_void) -> c_int;
    fn ocp_smb_ntstatus(s: *mut c_void) -> u32;
    fn ocp_smb_get_stat(s: *mut c_void, st: *mut Snapshot);
    fn ocp_smb_next(s: *mut c_void, st: *mut Snapshot) -> *const c_char;
}
struct Session {
    raw: NonNull<c_void>,
    buffer: Vec<u8>,
    busy: bool,
}
// The context and read buffer have exactly one owner. All C calls and callbacks
// run on the polling future; no other thread accesses the context concurrently.
unsafe impl Send for Session {}
impl Drop for Session {
    fn drop(&mut self) {
        let _guard = CONTEXT_LIFECYCLE.lock().unwrap_or_else(|e| e.into_inner());
        unsafe { ocp_smb_destroy(self.raw.as_ptr()) };
    }
}
fn text(s: &str) -> Result<CString, Error> {
    CString::new(s).map_err(|_| Error::Path)
}
fn segments(url: &Url) -> Result<Vec<String>, Error> {
    if url.path().contains("//") {
        return Err(Error::Path);
    }
    url.path_segments()
        .ok_or(Error::Path)?
        .filter(|s| !s.is_empty())
        .map(|s| {
            let decoded = percent_encoding::percent_decode_str(s)
                .decode_utf8()
                .map_err(|_| Error::Path)?
                .into_owned();
            valid_segment(&decoded)?;
            Ok(decoded)
        })
        .collect()
}
fn valid_segment(s: &str) -> Result<(), Error> {
    if s.is_empty()
        || matches!(s, "." | "..")
        || s.ends_with([' ', '.'])
        || s.contains([
            '/', '\\', '\0', '\r', '\n', ':', '*', '?', '<', '>', '|', '"',
        ])
    {
        Err(Error::Path)
    } else {
        Ok(())
    }
}
pub fn root_url(raw: &str) -> Result<Url, Error> {
    if raw.contains(['\\', '\0', '\r', '\n']) {
        return Err(Error::Path);
    }
    for s in raw.split(['/', '?', '#']) {
        let decoded = percent_encoding::percent_decode_str(s)
            .decode_utf8()
            .map_err(|_| Error::Path)?;
        if matches!(decoded.as_ref(), "." | "..") || decoded.contains(['/', '\\', '\0', '\r', '\n'])
        {
            return Err(Error::Path);
        }
    }
    let mut url = Url::parse(raw).map_err(|_| Error::Path)?;
    if url.scheme() != "smb"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.port() == Some(0)
    {
        return Err(Error::Path);
    }
    let path = segments(&url)?;
    if path.is_empty() {
        return Err(Error::Path);
    }
    let host = url.host_str().unwrap().to_ascii_lowercase();
    url.set_host(Some(&host)).map_err(|_| Error::Path)?;
    if url.port() == Some(445) {
        url.set_port(None).map_err(|_| Error::Path)?;
    }
    url.set_path("/");
    let mut parts = url.path_segments_mut().map_err(|_| Error::Path)?;
    parts.clear();
    for part in path {
        parts.push(&part);
    }
    parts.push("");
    drop(parts);
    Ok(url)
}
pub fn within(root: &str, candidate: &str) -> bool {
    let (Ok(root), Ok(candidate)) = (root_url(root), root_url(candidate)) else {
        return false;
    };
    let (Ok(root_parts), Ok(candidate_parts)) = (segments(&root), segments(&candidate)) else {
        return false;
    };
    root.host() == candidate.host()
        && root.port() == candidate.port()
        && candidate_parts.len() >= root_parts.len()
        && root_parts
            .iter()
            .zip(candidate_parts.iter())
            .all(|(a, b)| a.to_lowercase() == b.to_lowercase())
}
impl Provider {
    pub fn new(root: &str, credential: Credential) -> Result<Self, Error> {
        if let Credential::Password {
            username,
            password,
            domain,
            ..
        } = &credential
        {
            if username.trim().is_empty()
                || [username, password, domain]
                    .iter()
                    .any(|s| s.contains(['\0', '\r', '\n']))
            {
                return Err(Error::Unauthorized);
            }
        }
        Ok(Self {
            root: root_url(root)?,
            credential,
        })
    }
    pub fn root(&self) -> &str {
        self.root.as_str()
    }
    pub fn same_access(&self, other: &Self) -> bool {
        self.root == other.root && self.credential == other.credential
    }
    pub fn scoped(&self, root: &str) -> Result<Self, Error> {
        if !within(self.root(), root) {
            return Err(Error::Path);
        }
        Ok(Self {
            root: root_url(root)?,
            credential: self.credential.clone(),
        })
    }
    pub fn url(&self, relative: &str) -> Result<Url, Error> {
        let mut url = self.root.clone();
        let mut parts = url.path_segments_mut().map_err(|_| Error::Path)?;
        parts.pop_if_empty();
        if !relative.is_empty() {
            for part in relative.split('/') {
                valid_segment(part)?;
                parts.push(part);
            }
        }
        parts.push("");
        drop(parts);
        Ok(url)
    }
    fn path(&self, relative: &str) -> Result<CString, Error> {
        self.url(relative)?;
        let mut parts = segments(&self.root)?;
        parts.remove(0);
        if !relative.is_empty() {
            parts.extend(relative.split('/').map(str::to_owned));
        }
        text(&parts.join("/"))
    }
    async fn connect(&self) -> Result<Session, Error> {
        let host = self
            .root
            .host_str()
            .ok_or(Error::Path)?
            .trim_matches(['[', ']']);
        let port = self.root.port().unwrap_or(445);
        // Resolve before entering C. libsmb2 receives a numeric address, so its
        // asynchronous connect never does blocking hostname discovery.
        let addresses = tokio::time::timeout(
            Duration::from_secs(10),
            tokio::net::lookup_host((host, port)),
        )
        .await
        .map_err(|_| Error::Network)?
        .map_err(|_| Error::Network)?;
        let share = text(&segments(&self.root)?[0])?;
        let (user, password, domain, sign, seal) = match &self.credential {
            Credential::Guest => ("guest", "", "", false, false),
            Credential::Password {
                username,
                password,
                domain,
                require_signing,
                require_encryption,
            } => (
                username.as_str(),
                password.as_str(),
                domain.as_str(),
                *require_signing,
                *require_encryption,
            ),
        };
        let (user, password, domain) = (text(user)?, text(password)?, text(domain)?);
        for address in addresses.take(2) {
            let server = text(&address.to_string())?;
            let raw = {
                let _guard = CONTEXT_LIFECYCLE.lock().unwrap_or_else(|e| e.into_inner());
                NonNull::new(unsafe {
                    ocp_smb_new(
                        user.as_ptr(),
                        password.as_ptr(),
                        domain.as_ptr(),
                        sign.into(),
                        seal.into(),
                    )
                })
                .ok_or(Error::Network)?
            };
            let mut session = Session {
                raw,
                buffer: Vec::new(),
                busy: false,
            };
            let result = unsafe {
                ocp_smb_connect(
                    session.raw.as_ptr(),
                    server.as_ptr(),
                    share.as_ptr(),
                    user.as_ptr(),
                )
            };
            match tokio::time::timeout(Duration::from_secs(10), session.wait(result)).await {
                Ok(Ok(_)) => return Ok(session),
                Ok(Err(Error::NotFound)) => return Err(Error::ShareMissing),
                Ok(Err(Error::Network)) | Err(_) => continue,
                Ok(Err(error)) => return Err(error),
            }
        }
        Err(Error::Network)
    }
    pub async fn list(&self, relative: &str) -> Result<Vec<Entry>, Error> {
        let path = self.path(relative)?;
        let mut s = self.connect().await?;
        let result = unsafe { ocp_smb_list(s.raw.as_ptr(), path.as_ptr()) };
        s.wait(result).await?;
        let mut entries = Vec::new();
        let mut names = std::collections::HashSet::new();
        loop {
            let mut st = Snapshot::default();
            let name = unsafe { ocp_smb_next(s.raw.as_ptr(), &mut st) };
            if name.is_null() {
                break;
            }
            let name = unsafe { CStr::from_ptr(name) }
                .to_str()
                .map_err(|_| Error::Listing)?;
            if matches!(name, "." | "..") {
                continue;
            }
            valid_segment(name).map_err(|_| Error::Listing)?;
            if !names.insert(name.to_owned()) || entries.len() >= 50000 || st.size > i64::MAX as u64
            {
                return Err(Error::Listing);
            }
            // Reparse points are never followed, including directory symlinks.
            if st.typ == 2 {
                continue;
            }
            if st.typ > 2 {
                return Err(Error::Listing);
            }
            entries.push(Entry {
                relative_path: if relative.is_empty() {
                    name.to_owned()
                } else {
                    format!("{relative}/{name}")
                },
                is_directory: st.typ == 1,
                size: st.size as i64,
                modified_at: st.mtime as f64 + st.mtime_ns as f64 / 1e9,
                etag: Some(st.version()),
            });
        }
        entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        Ok(entries)
    }
    pub async fn open(&self, relative: &str, expected: Option<&Snapshot>) -> Result<Reader, Error> {
        let path = self.path(relative)?;
        let mut session = self.connect().await?;
        let result = unsafe { ocp_smb_open(session.raw.as_ptr(), path.as_ptr()) };
        session.wait(result).await?;
        let snapshot = session.stat().await?;
        if snapshot.typ != 0 || snapshot.size == 0 || snapshot.size > i64::MAX as u64 {
            return Err(Error::Read);
        }
        if expected.is_some_and(|e| e != &snapshot) {
            return Err(Error::Changed);
        }
        Ok(Reader { session, snapshot })
    }
    pub async fn probe(&self, relative: &str) -> Result<Snapshot, Error> {
        let mut reader = self.open(relative, None).await?;
        reader.read_at(0, 1).await?;
        Ok(reader.snapshot)
    }
}
impl Session {
    fn error(&self) -> Error {
        match unsafe { ocp_smb_ntstatus(self.raw.as_ptr()) } {
            0xc000006d | 0xc000006a | 0xc0000064 | 0xc0000072 | 0xc0000234 => Error::Unauthorized,
            0xc0000022 => Error::Permission,
            0xc00000cc => Error::ShareMissing,
            0xc0000034 | 0xc000003a | 0xc000000f => Error::NotFound,
            _ => Error::Network,
        }
    }
    async fn wait(&mut self, start: i32) -> Result<i32, Error> {
        if start < 0 {
            return Err(self.error());
        }
        self.busy = true;
        let result = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                match self.step()? {
                    Some(status) => return Ok(status),
                    None => tokio::time::sleep(Duration::from_millis(2)).await,
                }
            }
        })
        .await
        .map_err(|_| self.error())?;
        if result.is_ok() {
            self.busy = false;
        }
        result
    }
    fn step(&mut self) -> Result<Option<i32>, Error> {
        match unsafe { ocp_smb_step(self.raw.as_ptr()) } {
            1 => {
                let status = unsafe { ocp_smb_status(self.raw.as_ptr()) };
                if status < 0 {
                    Err(self.error())
                } else {
                    Ok(Some(status))
                }
            }
            0 => Ok(None),
            _ => Err(self.error()),
        }
    }
    async fn stat(&mut self) -> Result<Snapshot, Error> {
        if self.busy {
            return Err(Error::Network);
        }
        let result = unsafe { ocp_smb_stat(self.raw.as_ptr()) };
        self.wait(result).await?;
        let mut st = Snapshot::default();
        unsafe { ocp_smb_get_stat(self.raw.as_ptr(), &mut st) };
        Ok(st)
    }
}
pub struct Reader {
    session: Session,
    pub snapshot: Snapshot,
}
impl Reader {
    /// Bounded readAt with independent handle and explicit offset. On failure the
    /// caller closes this reader; it never joins bytes from a replacement file.
    pub async fn read_at(&mut self, offset: u64, count: u32) -> Result<Vec<u8>, Error> {
        if count == 0
            || count > 4 * 1024 * 1024
            || offset
                .checked_add(count as u64)
                .is_none_or(|end| end > self.snapshot.size)
        {
            return Err(Error::Read);
        }
        if self.session.stat().await? != self.snapshot {
            return Err(Error::Changed);
        }
        self.session.buffer.resize(count as usize, 0);
        let mut received = 0;
        while received < count as usize {
            let start = unsafe {
                ocp_smb_read(
                    self.session.raw.as_ptr(),
                    self.session.buffer.as_mut_ptr().add(received),
                    (count as usize - received).min(256 * 1024) as u32,
                    offset + received as u64,
                )
            };
            let n = self.session.wait(start).await? as usize;
            if n == 0 || n > count as usize - received {
                return Err(Error::Read);
            }
            received += n;
        }
        if self.session.stat().await? != self.snapshot {
            return Err(Error::Changed);
        }
        Ok(std::mem::take(&mut self.session.buffer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_preserve_special_names_and_reject_escape() {
        let p = Provider::new("smb://NAS:445/Media/", Credential::Guest).unwrap();
        assert_eq!(p.root(), "smb://nas/Media/");
        assert_eq!(
            p.url("中文 100%/Film #1").unwrap().as_str(),
            "smb://nas/Media/%E4%B8%AD%E6%96%87%20100%25/Film%20%231/"
        );
        for root in [
            "smb://nas/",
            "smb://u:p@nas/share/",
            "smb://nas/share/../other/",
            "smb://nas/share/%2f/",
            "smb://nas/share/?token=x",
            "smb://nas/share//",
        ] {
            assert!(root_url(root).is_err(), "{root}");
        }
        assert!(within(p.root(), "smb://nas/media/Movies/"));
        assert!(!within(p.root(), "smb://nas/Media2/"));
        assert!(!within(p.root(), "smb://other/Media/"));
    }
}

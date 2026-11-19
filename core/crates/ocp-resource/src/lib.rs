//! Shared remote enumeration and leased loopback playback, independent of the
//! media catalog and decoding engine.
pub mod bridge;
use serde::Serialize;
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Webdav(#[from] ocp_webdav::Error),
    #[error(transparent)]
    Smb(#[from] ocp_smb::Error),
    #[error("本机播放资源不可用")]
    Bridge,
    #[error("远程文件未正确完成 Range 读取")]
    Range,
    #[error("远程文件读取中断")]
    Network,
}
impl Error {
    pub fn credentials(&self) -> bool {
        matches!(
            self,
            Self::Webdav(ocp_webdav::Error::Unauthorized)
                | Self::Smb(ocp_smb::Error::Unauthorized | ocp_smb::Error::Permission)
        )
    }
}
#[derive(Clone)]
pub enum Provider {
    Webdav(ocp_webdav::Provider),
    Smb(ocp_smb::Provider),
}
pub enum Snapshot {
    Webdav(u64),
    Smb(ocp_smb::Snapshot),
}
impl Snapshot {
    pub fn size(&self) -> u64 {
        match self {
            Self::Webdav(size) => *size,
            Self::Smb(st) => st.size,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub relative_path: String,
    pub is_directory: bool,
    pub size: i64,
    pub modified_at: f64,
    pub etag: Option<String>,
}
impl Provider {
    pub fn same_access(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Webdav(a), Self::Webdav(b)) => a.same_access(b),
            (Self::Smb(a), Self::Smb(b)) => a.same_access(b),
            _ => false,
        }
    }
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Webdav(_) => "webdav",
            Self::Smb(_) => "smb",
        }
    }
    pub fn root(&self) -> &str {
        match self {
            Self::Webdav(p) => p.root(),
            Self::Smb(p) => p.root(),
        }
    }
    pub fn scoped(&self, root: &str) -> Result<Self, Error> {
        Ok(match self {
            Self::Webdav(p) => Self::Webdav(p.scoped(root)?),
            Self::Smb(p) => Self::Smb(p.scoped(root)?),
        })
    }
    pub fn directory_url(&self, relative: &str) -> Result<String, Error> {
        Ok(match self {
            Self::Webdav(p) => p.url(relative, true)?.to_string(),
            Self::Smb(p) => p.url(relative)?.to_string(),
        })
    }
    pub async fn list(&self, relative: &str) -> Result<Vec<Entry>, Error> {
        Ok(match self {
            Self::Webdav(p) => p
                .list(relative)
                .await?
                .into_iter()
                .map(|e| Entry {
                    relative_path: e.relative_path,
                    is_directory: e.is_directory,
                    size: e.size,
                    modified_at: e.modified_at,
                    etag: e.etag,
                })
                .collect(),
            Self::Smb(p) => p
                .list(relative)
                .await?
                .into_iter()
                .map(|e| Entry {
                    relative_path: e.relative_path,
                    is_directory: e.is_directory,
                    size: e.size,
                    modified_at: e.modified_at,
                    etag: e.etag,
                })
                .collect(),
        })
    }
    pub async fn probe(&self, relative: &str) -> Result<Snapshot, Error> {
        Ok(match self {
            Self::Webdav(p) => Snapshot::Webdav(p.probe(relative).await?),
            Self::Smb(p) => Snapshot::Smb(p.probe(relative).await?),
        })
    }
    pub(crate) async fn reader(
        &self,
        relative: &str,
        snapshot: &Snapshot,
    ) -> Result<Reader, Error> {
        Ok(match (self, snapshot) {
            (Self::Webdav(p), Snapshot::Webdav(size)) => {
                Reader::Webdav(p.clone(), relative.to_owned(), *size)
            }
            (Self::Smb(p), Snapshot::Smb(st)) => Reader::Smb(p.open(relative, Some(st)).await?),
            _ => return Err(Error::Range),
        })
    }
}
pub(crate) enum Reader {
    Webdav(ocp_webdav::Provider, String, u64),
    Smb(ocp_smb::Reader),
}
pub(crate) enum Body {
    Webdav(reqwest::Response),
    Smb(Option<Vec<u8>>),
}
impl Reader {
    pub async fn range(&mut self, start: u64, end: u64) -> Result<Body, Error> {
        Ok(match self {
            Self::Webdav(p, path, size) => {
                Body::Webdav(p.range(path, start, end, Some(*size)).await?)
            }
            Self::Smb(reader) => Body::Smb(Some(
                reader
                    .read_at(
                        start,
                        (end - start + 1).try_into().map_err(|_| Error::Range)?,
                    )
                    .await?,
            )),
        })
    }
}
impl Body {
    pub async fn chunk(&mut self) -> Result<Option<Vec<u8>>, Error> {
        match self {
            Self::Webdav(r) => r
                .chunk()
                .await
                .map(|c| c.map(|c| c.to_vec()))
                .map_err(|_| Error::Network),
            Self::Smb(bytes) => Ok(bytes.take()),
        }
    }
}

use serde_json::Value;
use std::{
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Child, Command, Stdio},
};
pub struct SmbFixture {
    pub child: Child,
    pub config: Value,
}
impl SmbFixture {
    pub fn start() -> Option<Self> {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let python = std::env::var_os("OCP_SMB_TEST_PYTHON")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                root.join("../artifacts/verification/smb-dependency/venv/bin/python")
            });
        if !python.is_file() {
            eprintln!("SMB protocol fixture skipped: set OCP_SMB_TEST_PYTHON to Python with impacket==0.13.0");
            return None;
        }
        let mut child = Command::new(python)
            .arg("-u")
            .arg(root.join("tests/fixtures/file_library_smb.py"))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let config = serde_json::from_str(&line).unwrap();
        Some(Self { child, config })
    }
}
impl Drop for SmbFixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(self.config["directory"].as_str().unwrap());
    }
}

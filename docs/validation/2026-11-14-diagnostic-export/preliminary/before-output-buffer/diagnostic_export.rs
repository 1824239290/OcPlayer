//! Diagnostic export preserves native archive/tail semantics and writes a file,
//! keeping large bodies outside JSON envelopes and the global Core state lock.
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Input {
    log_directory: PathBuf,
    output_path: PathBuf,
    header_lines: Vec<String>,
    body_byte_budget: Option<i64>,
    traces: Vec<Trace>,
    username: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Trace {
    path: PathBuf,
    name: String,
    max_bytes: i64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Report {
    path: PathBuf,
    bytes: u64,
    skipped_log_files: Vec<String>,
    traces: Vec<TraceReport>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TraceReport {
    name: String,
    bytes: usize,
    truncated: bool,
}
pub(super) enum Error {
    Invalid(String),
    Io(std::io::Error),
}
impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}
impl Error {
    pub(super) fn parts(self) -> (i32, bool, String) {
        match self {
            Self::Invalid(message) => (1002, false, message),
            Self::Io(error) => (1502, false, format!("diagnostic export: {error}")),
        }
    }
}
struct LogFile {
    path: PathBuf,
    name: String,
    size: u64,
    modified: Option<SystemTime>,
}
fn log_files(directory: &Path) -> Vec<LogFile> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut files: Vec<_> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let is_log = name == "diagnostics.jsonl"
                || (name.starts_with("diagnostics-") && name.ends_with(".jsonl"))
                || (name.starts_with("diagnostics.jsonl.") && !name.ends_with(".lock"));
            if !is_log {
                return None;
            }
            let metadata = entry.metadata().ok();
            Some(LogFile {
                path: entry.path(),
                name,
                size: metadata.as_ref().map_or(0, |m| m.len()),
                modified: metadata.and_then(|m| m.modified().ok()),
            })
        })
        .collect();
    files.sort_by(|a, b| {
        a.modified
            .cmp(&b.modified)
            .then_with(|| a.name.cmp(&b.name))
    });
    files
}
/// A streaming equivalent of String(decoding: joinedBytes, as: UTF8.self).
/// Preserve incomplete code points across file/chunk boundaries.
struct Utf8Writer<W: Write> {
    output: W,
    pending: Vec<u8>,
}
impl<W: Write> Utf8Writer<W> {
    fn new(output: W) -> Self {
        Self {
            output,
            pending: Vec::new(),
        }
    }
    fn append(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.pending.extend_from_slice(bytes);
        let mut offset = 0;
        loop {
            match std::str::from_utf8(&self.pending[offset..]) {
                Ok(_) => {
                    self.output.write_all(&self.pending[offset..])?;
                    self.pending.clear();
                    return Ok(());
                }
                Err(error) => {
                    let valid = offset + error.valid_up_to();
                    self.output.write_all(&self.pending[offset..valid])?;
                    let Some(length) = error.error_len() else {
                        self.pending.drain(..valid);
                        return Ok(());
                    };
                    self.output.write_all("\u{fffd}".as_bytes())?;
                    offset = valid + length;
                }
            }
        }
    }
    fn finish(mut self) -> std::io::Result<W> {
        if !self.pending.is_empty() {
            self.output
                .write_all(String::from_utf8_lossy(&self.pending).as_bytes())?;
        }
        Ok(self.output)
    }
}
fn copy_utf8(file: &mut File, output: &mut Utf8Writer<&mut File>) -> std::io::Result<()> {
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            return Ok(());
        }
        output.append(&buffer[..n])?;
    }
}
fn read_log_tail(file: &LogFile, remaining: u64) -> std::io::Result<Option<Vec<u8>>> {
    let skip = file.size.saturating_sub(remaining);
    if skip == 0 {
        return fs::read(&file.path).map(Some);
    }
    let Ok(mut handle) = File::open(&file.path) else {
        return Ok(None);
    };
    if handle.seek(SeekFrom::Start(skip)).is_err() {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    if handle.read_to_end(&mut bytes).is_err() {
        return Ok(None);
    }
    let Some(newline) = bytes.iter().position(|b| *b == b'\n') else {
        return Ok(Some(Vec::new()));
    };
    bytes.drain(..=newline);
    Ok(Some(bytes))
}
fn read_trace_tail(trace: &Trace) -> Option<(String, bool)> {
    let mut file = File::open(&trace.path).ok()?;
    let size = file.seek(SeekFrom::End(0)).ok()?;
    let limit = trace.max_bytes.max(0) as u64;
    let truncated = size > limit;
    file.seek(SeekFrom::Start(if truncated { size - limit } else { 0 }))
        .ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let mut text = String::from_utf8_lossy(&bytes).into_owned();
    if truncated {
        // Unlike a log body, a trace with no newline keeps its available suffix.
        if let Some(newline) = text.find('\n') {
            text.drain(..=newline);
        }
    }
    Some((text, truncated))
}
struct Redactor {
    home: Regex,
    container: Regex,
    url: Regex,
    auth: Regex,
    assignment: Regex,
    jwt: Regex,
}
impl Redactor {
    fn new(username: &str) -> Result<Self, Error> {
        let name = regex::escape(username);
        Ok(Self {
            home:Regex::new(&format!(r#"(?i)(?:file://)?(?:/Users/{name}|/home/{name})(?:/[^\s"'<>]*)?"#)).map_err(|_| Error::Invalid("diagnostic username pattern is too large".into()))?,
            container:Regex::new(r#"(?i)/(?:var/mobile|private/var/mobile)/Containers/[^\s"'<>]+"#).unwrap(),
            url:Regex::new(r#"(?i)https?://[^\s"'<>]+"#).unwrap(),
            auth:Regex::new(r"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+").unwrap(),
            assignment:Regex::new(r#"(?i)("|')?\b(access[_-]?token|refresh[_-]?token|accesstoken|token|authorization|password|passwd|secret|api[_-]?key|apikey|api-key|x-emby-token|x-api-key|client[_-]?secret|cookie|set-cookie)\b("|')?(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,\s;&}\]]+)"#).unwrap(),
            jwt:Regex::new(r"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b").unwrap(),
        })
    }
    fn redact(&self, input: &str) -> String {
        let value = self.home.replace_all(input, "<user-path>");
        let value = self.container.replace_all(&value, "<app-container-path>");
        let value = self
            .url
            .replace_all(&value, |captures: &regex::Captures<'_>| {
                let raw = captures.get(0).unwrap().as_str();
                let token = raw.trim_end_matches(['.', ',', ';', ':', ')', ']', '}']);
                let trailing = &raw[token.len()..];
                let scheme = token.find("://").unwrap() + 3;
                let authority_end = token[scheme..]
                    .find('/')
                    .map_or(token.len(), |i| scheme + i);
                let authority = &token[scheme..authority_end];
                let authority = if let Some((_, host)) = authority.rsplit_once('@') {
                    format!("<redacted>@{host}")
                } else {
                    authority.into()
                };
                let suffix = &token[authority_end..];
                let suffix = if let Some(query) = suffix.find('?') {
                    format!("{}?<redacted>", &suffix[..query])
                } else if let Some(fragment) = suffix.find('#') {
                    format!("{}#<redacted>", &suffix[..fragment])
                } else {
                    suffix.into()
                };
                format!("{}{authority}{suffix}{trailing}", &token[..scheme])
            });
        let value = self.auth.replace_all(&value, "${1} <redacted>");
        let value = self
            .assignment
            .replace_all(&value, "${1}${2}${3}${4}<redacted>");
        self.jwt
            .replace_all(&value, "<redacted-token>")
            .into_owned()
    }
}
fn export_into(input: &Input, output: &mut File) -> Result<(Vec<String>, Vec<TraceReport>), Error> {
    output.write_all((input.header_lines.join("\n") + "\n\n").as_bytes())?;
    let files = log_files(&input.log_directory);
    let mut skipped = Vec::new();
    let mut writer = Utf8Writer::new(&mut *output);
    if let Some(budget) = input.body_byte_budget {
        let mut remaining = budget.max(0) as u64;
        let mut chunks = Vec::new();
        for file in files.iter().rev() {
            if remaining == 0 {
                break;
            }
            let Some(chunk) = read_log_tail(file, remaining)? else {
                skipped.push(file.name.clone());
                continue;
            };
            if chunk.is_empty() {
                skipped.push(file.name.clone());
                continue;
            }
            remaining = remaining.saturating_sub(chunk.len() as u64);
            chunks.push(chunk);
        }
        for chunk in chunks.iter().rev() {
            writer.append(chunk)?;
        }
    } else {
        for file in &files {
            copy_utf8(&mut File::open(&file.path)?, &mut writer)?;
        }
    }
    writer.finish()?;
    let redactor = Redactor::new(&input.username)?;
    let mut reports = Vec::new();
    for trace in &input.traces {
        let Some((text, truncated)) = read_trace_tail(trace) else {
            continue;
        };
        if text.is_empty() {
            continue;
        }
        let heading = format!(
            "\n\n# 内核 trace：{}{}\n",
            trace.name,
            if truncated {
                format!(
                    "（只保留尾部 {} MiB，已截断）",
                    trace.max_bytes / 1024 / 1024
                )
            } else {
                String::new()
            }
        );
        output.write_all(heading.as_bytes())?;
        let text = redactor.redact(&text);
        output.write_all(text.as_bytes())?;
        reports.push(TraceReport {
            name: trace.name.clone(),
            bytes: text.len(),
            truncated,
        });
    }
    Ok((skipped, reports))
}
pub(super) fn export(input: Input) -> Result<Report, Error> {
    if !input.log_directory.is_absolute()
        || !input.output_path.is_absolute()
        || input.traces.iter().any(|t| !t.path.is_absolute())
    {
        return Err(Error::Invalid("diagnostic paths must be absolute".into()));
    }
    if input.output_path.exists() {
        return Err(Error::Invalid("diagnostic output already exists".into()));
    }
    // Never let a diagnostic destination become a candidate input log/trace.
    if input.traces.iter().any(|t| t.path == input.output_path)
        || input.output_path.parent() == Some(input.log_directory.as_path())
    {
        return Err(Error::Invalid(
            "diagnostic output must be separate from input files".into(),
        ));
    }
    if let (Ok(source), Some(parent)) = (
        fs::canonicalize(&input.log_directory),
        input.output_path.parent(),
    ) {
        if fs::canonicalize(parent).ok().as_ref() == Some(&source) {
            return Err(Error::Invalid(
                "diagnostic output must be separate from input files".into(),
            ));
        }
    }
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&input.output_path)?;
    let result = export_into(&input, &mut output).and_then(|(skipped_log_files, traces)| {
        output.flush()?;
        let bytes = output.metadata()?.len();
        Ok(Report {
            path: input.output_path.clone(),
            bytes,
            skipped_log_files,
            traces,
        })
    });
    drop(output);
    if result.is_err() {
        let _ = fs::remove_file(&input.output_path);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "ocp-diag-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(path.join("logs")).unwrap();
            Self(path)
        }
        fn input(&self) -> Input {
            Input {
                log_directory: self.0.join("logs"),
                output_path: self.0.join("export.txt"),
                header_lines: vec!["# 诊断".into()],
                body_byte_budget: Some(8),
                traces: vec![],
                username: "fixture".into(),
            }
        }
        fn log(&self, name: &str, bytes: &[u8]) {
            fs::write(self.0.join("logs").join(name), bytes).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn utf8_repair_preserves_chunk_boundaries_and_invalid_sequences() {
        let mut writer = Utf8Writer::new(Vec::new());
        for bytes in [b"a\xe4".as_slice(), b"\xb8", b"\xad\xff\xe2\x82"] {
            writer.append(bytes).unwrap();
        }
        assert_eq!(writer.finish().unwrap(), "a中\u{fffd}\u{fffd}".as_bytes());
        let mut writer = Utf8Writer::new(Vec::new());
        writer.append(&vec![255; 100_000]).unwrap();
        assert_eq!(writer.finish().unwrap().len(), 300_000);
        let input: Vec<u8> = (0..70_000).map(|i| (i % 256) as u8).collect();
        let mut writer = Utf8Writer::new(Vec::new());
        for chunk in input.chunks(101) {
            writer.append(chunk).unwrap();
        }
        assert_eq!(
            writer.finish().unwrap(),
            String::from_utf8_lossy(&input).as_bytes()
        );
    }
    #[test]
    fn budget_reclaims_empty_latest_tail_and_preserves_archive_order() {
        let f = Fixture::new();
        f.log("diagnostics-old.jsonl", b"old\n");
        f.log("diagnostics.jsonl", b"xxxxxxxxxxxxxxxx");
        let report = export(f.input()).ok().unwrap();
        assert_eq!(
            fs::read(&report.path).unwrap(),
            "# 诊断\n\nold\n".as_bytes()
        );
        assert_eq!(report.skipped_log_files, vec!["diagnostics.jsonl"]);
    }
    #[test]
    fn unlimited_logs_join_before_decoding_and_ignore_lock_files() {
        let f = Fixture::new();
        f.log("diagnostics-a.jsonl", b"\xe4\xb8");
        f.log("diagnostics.jsonl", b"\xad\xff");
        f.log("diagnostics.jsonl.1.lock", b"hidden");
        let mut input = f.input();
        input.body_byte_budget = None;
        let report = export(input).ok().unwrap();
        assert_eq!(
            fs::read(&report.path).unwrap(),
            "# 诊断\n\n中\u{fffd}".as_bytes()
        );
    }
    #[test]
    fn traces_keep_no_newline_suffix_and_negative_budgets_are_empty() {
        let f = Fixture::new();
        let path = f.0.join("trace");
        fs::write(&path, b"abcdefgh").unwrap();
        let trace = Trace {
            path: path.clone(),
            name: "trace".into(),
            max_bytes: 3,
        };
        assert_eq!(read_trace_tail(&trace), Some(("fgh".into(), true)));
        assert_eq!(
            read_trace_tail(&Trace {
                max_bytes: -1,
                ..trace
            }),
            Some((String::new(), true))
        );
        let mut input = f.input();
        input.body_byte_budget = Some(-1);
        input.traces = vec![Trace {
            path,
            name: "trace".into(),
            max_bytes: 3,
        }];
        let report = export(input).ok().unwrap();
        assert_eq!(report.traces[0].bytes, 3);
        assert!(report.traces[0].truncated);
    }
    #[test]
    fn redaction_preserves_server_routes_and_native_placeholders() {
        let r = Redactor::new("fixture").ok().unwrap();
        assert_eq!(r.redact("file:///Users/fixture/private /Users/server/Items /private/var/mobile/Containers/Data/App"),"<user-path> /Users/server/Items <app-container-path>");
        assert_eq!(
            r.redact("https://u:p@example.test/a?token=secret). Bearer abc password='hidden'"),
            "https://<redacted>@example.test/a?<redacted>). Bearer <redacted> password=<redacted>"
        );
        assert_eq!(
            r.redact("ſecret=hidden eyJabcdefghijklmnop.a.b"),
            "ſecret=<redacted> <redacted-token>"
        );
    }
    #[test]
    fn output_is_exclusive_and_failed_unlimited_export_is_removed() {
        let f = Fixture::new();
        fs::write(f.0.join("export.txt"), b"existing").unwrap();
        assert!(matches!(export(f.input()), Err(Error::Invalid(_))));
        assert_eq!(fs::read(f.0.join("export.txt")).unwrap(), b"existing");
        fs::remove_file(f.0.join("export.txt")).unwrap();
        fs::create_dir(f.0.join("logs/diagnostics-bad.jsonl")).unwrap();
        let mut input = f.input();
        input.body_byte_budget = None;
        assert!(matches!(export(input), Err(Error::Io(_))));
        assert!(!f.0.join("export.txt").exists());
    }
    #[test]
    fn output_cannot_alias_input_directory() {
        let f = Fixture::new();
        let mut input = f.input();
        input.output_path = input.log_directory.join("diagnostics-new.jsonl");
        assert!(matches!(export(input), Err(Error::Invalid(_))));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(f.0.join("logs"), f.0.join("alias")).unwrap();
            let mut input = f.input();
            input.output_path = f.0.join("alias/diagnostics-new.jsonl");
            assert!(matches!(export(input), Err(Error::Invalid(_))));
        }
    }
    #[test]
    fn missing_logs_and_trace_produce_header_only_with_exact_report_size() {
        let f = Fixture::new();
        let mut input = f.input();
        input.log_directory = f.0.join("missing");
        input.traces.push(Trace {
            path: f.0.join("absent"),
            name: "absent".into(),
            max_bytes: 1024,
        });
        let report = export(input).ok().unwrap();
        assert_eq!(report.bytes, "# 诊断\n\n".len() as u64);
        assert!(report.traces.is_empty());
    }
}

from pathlib import Path
p=Path('/Volumes/Backup/软件/OcPlayer-Core/crates/ocp-core/src/diagnostic_export.rs');s=p.read_text()
s=s.replace('use std::io::{Read, Seek, SeekFrom, Write};','use std::io::{BufWriter, Read, Seek, SeekFrom, Write};')
s=s.replace('fn copy_utf8(file: &mut File, output: &mut Utf8Writer<&mut File>)', 'fn copy_utf8<W: Write>(file: &mut File, output: &mut Utf8Writer<W>)')
s=s.replace('fn export_into(input: &Input, output: &mut File)', 'fn export_into<W: Write>(input: &Input, output: &mut W)')
needle='    let result = export_into(&input, &mut output).and_then(|(skipped_log_files, traces)| {'
assert needle in s
s=s.replace(needle,'''    // Repairing invalid UTF-8 may emit individual replacement characters.
    // Buffer those writes so adversarial bytes do not cause one syscall each.
    let exported = {
        let mut buffered = BufWriter::with_capacity(64 * 1024, &mut output);
        export_into(&input, &mut buffered).and_then(|report| {
            buffered.flush()?;
            Ok(report)
        })
    };
    let result = exported.and_then(|(skipped_log_files, traces)| {''')
p.write_text(s)
print('buffered output applied')

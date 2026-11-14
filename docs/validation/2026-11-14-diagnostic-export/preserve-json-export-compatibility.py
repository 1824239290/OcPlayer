from pathlib import Path
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer')
p=core/'crates/ocp-core/src/lib.rs';s=p.read_text();s=s.replace('if method == "diag.export.capabilities"','if method == "diag.exportFile.capabilities"').replace('if method == "diag.export"','if method == "diag.exportFile"');p.write_text(s)
p=core/'bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpDiagnosticExport.swift';s=p.read_text().replace('"diag.export.capabilities"','"diag.exportFile.capabilities"').replace('"diag.export"','"diag.exportFile"');p.write_text(s);(native/'Packages/OcPlayerCore/Sources/OcPlayerCore/OcpDiagnosticExport.swift').write_text(s)
p=core/'tests/diagnostic_export_contract.py';s=p.read_text().replace("'diag.export.capabilities'","'diag.exportFile.capabilities'").replace("'diag.export'","'diag.exportFile'");needle='    def test_concurrent_exports_keep_file_ownership_and_small_reports(self):';s=s.replace(needle,'''    def test_legacy_json_export_keeps_snapshot_and_redaction_options(self):
        for include in (True,False):
            snapshot=self.success('diag.export',includeConfig=include,redact=True)
            self.assertEqual(snapshot['schemaVersion'],1)
            self.assertGreater(snapshot['generatedAt'],0)
            self.assertEqual(snapshot['config'] is not None,include)
            self.assertNotIn('path',snapshot)
        reply=self.call('diag.exportFile')
        self.assertFalse(reply['ok']);self.assertEqual(reply['code'],1002)
'''+needle);p.write_text(s)
p=core/'docs/diagnostic-export-contract.md';s=p.read_text().replace('`diag.export.capabilities`','`diag.exportFile.capabilities`').replace('`diag.export`','`diag.exportFile`');s=s.replace('runs outside the shared state mutex', 'preserves the existing `diag.export` JSON snapshot alias and runs outside the shared state mutex');p.write_text(s);(native/'Docs/SHARED-DIAGNOSTIC-EXPORT.md').write_text(s)
print('preserved legacy JSON export; added file-specific command')

"""File-backed diagnostic exports through the public C ABI."""
import concurrent.futures
import os
from pathlib import Path
import tempfile
import unittest
import bangumi_account_contract as fixture
import network_contract as network

class DiagnosticExportContract(unittest.TestCase):
    setUpClass = classmethod(fixture.AccountContract.setUpClass.__func__)
    call = network.NetworkContract.call
    success = network.NetworkContract.success
    def setUp(self):
        fixture.AccountContract.setUp(self)
        self.temp = tempfile.TemporaryDirectory(prefix='ocp-diagnostic-abi-')
        self.root=Path(self.temp.name);self.logs=self.root/'logs';self.logs.mkdir()
    def tearDown(self):
        self.temp.cleanup();fixture.AccountContract.tearDown(self)
    def log(self,name,data,mtime=1):
        path=self.logs/name;path.write_bytes(data);os.utime(path,(mtime,mtime));return path
    def arguments(self,**changes):
        result=dict(logDirectory=str(self.logs),outputPath=str(self.root/'export.txt'),headerLines=['# 诊断','版本: fixture'],bodyByteBudget=8,traces=[],username='fixture')
        result.update(changes);return result
    def export(self,**changes):
        report=self.success('diag.exportFile',**self.arguments(**changes));data=Path(report['path']).read_bytes()
        self.assertEqual(report['bytes'],len(data));self.assertNotIn('text',report);return report,data
    def test_chronology_tie_names_and_log_name_filters(self):
        self.log('diagnostics-b.jsonl',b'b\n',1);self.log('diagnostics-a.jsonl',b'a\n',1)
        self.log('diagnostics.jsonl',b'current\n',2);self.log('diagnostics.jsonl.1.lock',b'hidden\n',3)
        self.log('other.jsonl',b'hidden\n',4);self.log('diagnostics.jsonl.1',b'rotated\n',0)
        _,data=self.export(bodyByteBudget=None)
        self.assertEqual(data,'# 诊断\n版本: fixture\n\nrotated\na\nb\ncurrent\n'.encode())
    def test_budget_charges_actual_bytes_after_line_alignment(self):
        self.log('diagnostics-a.jsonl',b'old\n',1);self.log('diagnostics.jsonl',b'xxxxxx\nn\n',2)
        _,data=self.export(bodyByteBudget=6);self.assertTrue(data.endswith(b'old\nn\n'))
        self.assertLessEqual(len(data.split(b'\n\n')[1]),6)
    def test_latest_no_newline_reclaims_budget_and_zero_negative_are_empty(self):
        self.log('diagnostics-a.jsonl',b'old\n',1);self.log('diagnostics.jsonl',b'xxxxxxxxxxxxxxxx',2)
        report,data=self.export();self.assertTrue(data.endswith(b'old\n'));self.assertEqual(report['skippedLogFiles'],['diagnostics.jsonl'])
        for budget in (0,-1):
            _,data=self.export(outputPath=str(self.root/f'export{budget}'),bodyByteBudget=budget)
            self.assertTrue(data.endswith(b'\n\n'))
    def test_utf8_join_and_repair_are_outside_the_json_envelope(self):
        self.log('diagnostics-a.jsonl',b'\xe4\xb8',1);self.log('diagnostics.jsonl',b'\xad\xff',2)
        for budget in (None,100):
            _,data=self.export(outputPath=str(self.root/f'export-{budget}'),bodyByteBudget=budget)
            self.assertTrue(data.endswith('中�'.encode()))
    def test_trace_tail_and_redaction_preserve_native_order(self):
        t=self.root/'trace';t.write_text('old\npassword=hidden https://u:p@host/a?token=hidden). /Users/fixture/home /Users/server/Items\n')
        text=t.read_bytes();report,data=self.export(traces=[dict(path=str(t),name='trace.jsonl',maxBytes=len(text)-2),dict(path=str(self.root/'missing'),name='missing',maxBytes=100)])
        decoded=data.decode();self.assertNotIn('hidden',decoded);self.assertIn('https://<redacted>@host/a?<redacted>).',decoded)
        self.assertIn('<user-path> /Users/server/Items',decoded);self.assertIn('（只保留尾部 0 MiB，已截断）',decoded)
        self.assertEqual(len(report['traces']),1);self.assertTrue(report['traces'][0]['truncated'])
    def test_strict_inputs_and_exclusive_output_preserve_existing_files(self):
        for changes in [dict(logDirectory='relative'),dict(bodyByteBudget='8'),dict(headerLines=[1]),dict(extra=True),dict(traces=[dict(path=str(self.root/'trace'),name='a',maxBytes=1,extra=1)])]:
            reply=self.call('diag.exportFile',**self.arguments(**changes));self.assertFalse(reply['ok']);self.assertEqual(reply['code'],1002);self.assertFalse(reply['retryable'])
        output=self.root/'export.txt';output.write_bytes(b'original')
        reply=self.call('diag.exportFile',**self.arguments());self.assertFalse(reply['ok']);self.assertEqual(output.read_bytes(),b'original')
    def test_alias_and_failed_unlimited_read_clean_up_only_new_destination(self):
        alias=self.root/'alias'
        if os.name=='nt':
            # Junctions exercise the directory-alias guard without symlink privileges.
            import _winapi
            _winapi.CreateJunction(str(self.logs),str(alias))
        else:alias.symlink_to(self.logs,target_is_directory=True)
        reply=self.call('diag.exportFile',**self.arguments(outputPath=str(alias/'diagnostics-export.jsonl')));self.assertEqual(reply['code'],1002)
        (self.logs/'diagnostics-bad.jsonl').mkdir()
        reply=self.call('diag.exportFile',**self.arguments(bodyByteBudget=None));self.assertEqual(reply['code'],1502);self.assertFalse((self.root/'export.txt').exists())
    def test_legacy_json_export_keeps_snapshot_and_redaction_options(self):
        for include in (True,False):
            snapshot=self.success('diag.export',includeConfig=include,redact=True)
            self.assertEqual(snapshot['schemaVersion'],1)
            self.assertGreater(snapshot['generatedAt'],0)
            self.assertEqual(snapshot['config'] is not None,include)
            self.assertNotIn('path',snapshot)
        reply=self.call('diag.exportFile')
        self.assertFalse(reply['ok']);self.assertEqual(reply['code'],1002)
    def test_concurrent_exports_keep_file_ownership_and_small_reports(self):
        self.log('diagnostics.jsonl',b'{"event":"fixture"}\n',1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            replies=list(pool.map(lambda i:self.success('diag.exportFile',**self.arguments(outputPath=str(self.root/f'export-{i}'),bodyByteBudget=None)),range(12)))
        self.assertEqual(len({r['path'] for r in replies}),12)
        for r in replies:self.assertTrue(Path(r['path']).read_bytes().endswith(b'{"event":"fixture"}\n'))
        self.assertEqual(self.success('diag.exportFile.capabilities')['output'],'file')

if __name__=='__main__':unittest.main()

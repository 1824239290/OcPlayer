"""Shared AniList resolver and native ID-file behavior through the exported ABI."""
import base64
import concurrent.futures
import hashlib
import json
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from intro_provider_server import Handler
from network_contract import NetworkContract


class IntroIdentityContract(NetworkContract):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.records = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)
        self.success('introIDs.open', directory=str(self.path))

    def tearDown(self):
        super().tearDown()
        self.directory.cleanup()

    def value(self, response):
        self.assertTrue(response['ok'], response)
        return json.loads(response['data']['payloadJSON'])

    def policy(self, method, value, **args):
        return self.value(self.call('introIdentity.' + method, payloadJSON=json.dumps(value), **args))

    def record(self, key):
        return self.value(self.call('introIDs.record', key=key))

    def write(self, key, record):
        return self.value(self.call('introIDs.write', key=key, payloadJSON=json.dumps(record)))

    def resolve(self, identity, **args):
        return self.call('introIDs.resolve', payloadJSON=json.dumps(identity),
                         baseURL=args.pop('baseURL', self.base), **args)

    def test_policy_key_titles_and_exact_expiry_direct_zero_io(self):
        identity = {'anilistID': 9223372036854775807, 'title': '\nＡＢＣ\u0085',
                    'alternativeTitles': ['abc', '！？', '作品名称'], 'seasonNumber': 2, 'year': 2026}
        self.assertEqual(self.policy('searchTitles', identity), ['ＡＢＣ', '作品名称'])
        raw = 'v2|9223372036854775807|ａｂｃ|2|2026'
        self.assertEqual(self.policy('cacheKey', identity), hashlib.sha256(raw.encode()).hexdigest())
        empty = {'malID': None, 'anilistID': None, 'resolvedAt': 0}
        self.assertIsNotNone(self.policy('plan', identity, recordJSON=json.dumps(empty), now=604799)['ready'])
        self.assertIsNone(self.policy('plan', identity, recordJSON=json.dumps(empty), now=604800)['ready'])
        self.assertIsNone(self.policy('plan', identity, recordJSON=json.dumps(empty), now=0, forceRefresh=True)['ready'])
        self.assertEqual(self.value(self.resolve({'malID': 1, 'anilistID': -1}, forceRefresh=True))['ids'], {'malID': 1, 'anilistID': -1})
        self.assertEqual(self.value(self.resolve({}))['ids'], {'malID': None, 'anilistID': None})
        self.assertFalse(self.value(self.call('introIDs.stats'))['loaded'])
        self.assertEqual(self.server.records, [])

    def test_file_interop_cached_empty_and_write_through_failure(self):
        file = self.path / 'aniskip-ids.json'
        file.write_text('{"legacy":{"malID":42.0,"resolvedAt":777.5},"large":{"malID":9223372036854775807,"anilistID":9223372036854775806,"resolvedAt":0.125}}')
        self.assertEqual(self.record('legacy'), {'malID': 42, 'anilistID': None, 'resolvedAt': 777.5})
        self.assertEqual(self.record('large')['malID'], 9223372036854775807)
        self.write('new', {'malID': 7, 'anilistID': 8, 'resolvedAt': 888.25})
        self.assertEqual(json.loads(file.read_text())['new']['resolvedAt'], 888.25)
        self.success('introIDs.open', directory=str(self.path))
        self.assertEqual(self.record('new')['anilistID'], 8)
        file.write_text('{')
        self.success('introIDs.open', directory=str(self.path))
        self.assertIsNone(self.record('new'))
        file.write_text('{"new":{"malID":7,"resolvedAt":0}}')
        self.assertIsNone(self.record('new'))
        self.write('repair', {'malID': 9, 'resolvedAt': 0})
        self.assertEqual(set(json.loads(file.read_text())), {'repair'})
        file.unlink()
        file.mkdir()
        self.success('introIDs.open', directory=str(self.path))
        self.write('memory', {'malID': 10, 'resolvedAt': 1})
        self.assertEqual(self.record('memory')['malID'], 10)
        self.assertTrue(file.is_dir())
        self.assertEqual(self.call('introIDs.write', key='bad', payloadJSON='{"resolvedAt":null}')['code'], 1002)
        self.assertEqual(self.value(self.call('introIDs.stats'))['records'], 1)

    def test_lookup_positive_cache_force_refresh_and_negative_ttl(self):
        identity = {'anilistID': 42, 'title': 'primary'}
        key = self.policy('cacheKey', identity)
        resolved = self.value(self.resolve(identity, now=1, resolvedAt=50))
        self.assertEqual(resolved['ids'], {'malID': 100000, 'anilistID': 42})
        self.assertFalse(resolved['needsCommit'])
        self.assertEqual(self.record(key)['resolvedAt'], 50)
        self.assertEqual(self.value(self.resolve(identity, now=10000000))['ids']['malID'], 100000)
        self.assertEqual(len(self.server.records), 1)
        self.value(self.resolve(identity, forceRefresh=True, resolvedAt=60))
        self.assertEqual(len(self.server.records), 2)
        missing = {'title': 'empty'}
        self.assertIsNone(self.value(self.resolve(missing, now=0, resolvedAt=0))['ids']['malID'])
        self.value(self.resolve(missing, now=604799))
        self.assertEqual(len(self.server.records), 3)
        self.value(self.resolve(missing, now=604800, resolvedAt=604800))
        self.assertEqual(len(self.server.records), 4)
        only = self.value(self.resolve({'anilistID': 404}, resolvedAt=0))
        self.assertEqual(only['ids'], {'malID': None, 'anilistID': 404})

    def test_complete_ordered_search_failures_fallback_and_no_retries(self):
        cases = [(['first', 'later'], 78, 'exact', 2),
                 (['bad', 'http503', 'later'], 78, 'exact', 3),
                 (['contained-one', 'later'], 14, 'contained', 1),
                 (['exact-last'], 22, 'exact', 1),
                 (['short'], 33, 'firstWithID', 1),
                 (['no-mal', 'empty'], None, None, 2)]
        for titles, mal, rule, requests in cases:
            before = len(self.server.records)
            result = self.value(self.call('introProvider.resolveIDs', baseURL=self.base, searchTitles=titles))
            self.assertEqual(result['ids']['malID'], mal)
            self.assertEqual(result['rule'], rule)
            self.assertEqual(len(self.server.records) - before, requests)
            self.assertEqual(len(result['attempts']), requests)
        failed = self.value(self.call('introProvider.resolveIDs', baseURL=self.base, anilistID=503))
        self.assertEqual(failed['ids'], {'malID': None, 'anilistID': None})
        self.assertEqual(failed['attempts'][0]['status'], 503)
        large = self.value(self.call('introProvider.resolveIDs', baseURL=self.base, anilistID=9223372036854775807))
        self.assertEqual(large['ids']['anilistID'], 9223372036854775807)
        self.assertEqual(json.loads(self.server.records[-1]['body'])['variables']['id'], '9223372036854775807')
        self.assertEqual(len({r['port'] for r in self.server.records}), 1)

    def test_deferred_native_clock_commit_reads_the_same_store(self):
        identity = {'title': 'later'}
        result = self.value(self.resolve(identity, commit=False))
        self.assertTrue(result['needsCommit'])
        self.assertIsNone(self.record(result['cacheKey']))
        self.write(result['cacheKey'], dict(result['ids'], resolvedAt=123.75))
        cached = self.value(self.resolve(identity, now=123.75))
        self.assertEqual(cached['ids'], result['ids'])
        self.assertFalse(cached['needsCommit'])
        self.assertEqual(len(self.server.records), 1)

    def test_cancellation_stops_titles_and_does_not_poison_cache(self):
        identity = {'title': 'first', 'alternativeTitles': ['later']}
        key = self.policy('cacheKey', identity)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.resolve, identity, baseURL=self.base + '/slow', requestId='identity-cancel')
            deadline = time.monotonic() + 2
            while not self.server.records and time.monotonic() < deadline:
                time.sleep(.005)
            self.success('request.cancel', requestId='identity-cancel')
            self.assertEqual(future.result(timeout=.3)['code'], 1003)
        self.assertEqual(len(self.server.records), 1)
        self.assertIsNone(self.record(key))
        self.assertFalse((self.path / 'aniskip-ids.json').exists())
        self.assertEqual(self.value(self.resolve(identity))['ids']['malID'], 78)


for name in list(vars(NetworkContract)):
    if name.startswith('test_'):
        setattr(IntroIdentityContract, name, None)
del NetworkContract
if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)

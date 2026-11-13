"""Complete standalone loading through the public ABI, including live cancellation."""
import concurrent.futures
import hashlib
import json
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from network_contract import NetworkContract
from standalone_danmaku_server import Handler

class StandaloneContract(NetworkContract):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.records = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.core = self.ffi.ocp_core_create(b'{}')
        self.temp = tempfile.TemporaryDirectory(prefix='ocp-standalone-')
        self.directory = Path(self.temp.name)
    def tearDown(self):
        super().tearDown()
        self.temp.cleanup()
    def value(self, method, **args):
        result = self.success(method, **args)
        return json.loads(result['payloadJSON'])
    def args(self, scenario='first', **overrides):
        args = {'gateway': {'base_url': self.base + '/' + scenario, 'api_key': 'fixture', 'user_agent': 'OcPlayer/fixture'},
                'matchRequest': {'fileName': 'Clean - 02.mkv', 'fileHash': 'a' * 32}, 'retryAttempts': 1}
        args.update(overrides)
        return args
    def load(self, scenario='first', **overrides): return self.value('danmaku.load', **self.args(scenario, **overrides))
    def open(self):
        for method in ['danmakuCache.open', 'introLearning.open', 'introIDs.open']:
            self.success(method, directory=str(self.directory))
    def seed_match(self, media, episode, anime=5):
        self.value('danmakuCache.setEpisodeMatch', mediaID=media, payloadJSON={'episodeID': episode, 'animeID': anime, 'shiftSeconds': 0, 'animeTitle': 'Local'})
    def hint(self, episode, end, source='danmaku'):
        self.value('danmakuCache.setIntroHint', episodeID=episode, payloadJSON={'endSeconds': end, 'evidenceCount': 2, 'source': source})
    def test_first_authoritative_candidate_only_one_fetch_and_shared_payload(self):
        result = self.load()
        self.assertEqual(result['outcome']['kind'], 'loaded')
        self.assertEqual(result['episodes'][0]['candidate']['episodeId'], 9223372036854775807)
        self.assertEqual(result['episodes'][0]['candidate']['shift'], -5)
        self.assertEqual(len(result['episodes']), 1)
        self.assertEqual(result['episodes'][0]['count'], 3)
        self.assertEqual(result['episodes'][0]['rawCommentCount'], 6)
        self.assertEqual([c['time'] for c in result['episodes'][0]['comments']], [10, 11, 132])
        self.assertEqual([c['time'] for c in json.loads(result['episodes'][0]['json'])['comments']], [11, 10, 132])
        self.assertEqual(result['outcome']['introHint']['endSeconds'], 131)
        self.assertEqual(len(self.server.records), 2)
        self.assertEqual(len({r['port'] for r in self.server.records}), 1)
        self.assertEqual(self.server.records[1]['query'], {'chConvert': ['0'], 'withRelated': ['true']})
        self.assertEqual(self.value('danmakuFlow.stats')['active'], 0)
    def test_ranked_match_and_complete_eight_query_waterfall(self):
        config = {'context': {'animeTitle': 'Local', 'episodeNumber': 2, 'tmdbId': 42}}
        providers = {name: {'enabled': False} for name in ['aniList', 'aniSkip', 'animeSkip', 'theIntroDB']}
        ranked = self.load('ranked', configuration=config, providers=providers)
        self.assertEqual(ranked['outcome']['episodeID'], 9223372036854775807)
        self.server.records.clear()
        result = self.load('fallback', configuration=json.dumps(config), providers=providers)
        self.assertEqual(result['outcome']['episodeID'], 50002)
        records = self.server.records
        self.assertEqual(len(records), 9)
        self.assertEqual([r['query'].get('tmdbIdType') for r in records[1:4]], [['0'], ['0'], ['1']])
        self.assertEqual([r['query'].get('episode') for r in records[1:8]], [['2'], None, None, ['2'], None, ['2'], None])
        self.assertTrue(all('tmdbIdType' not in r['query'] for r in records[4:8]))
        self.assertFalse(result['diagnostics']['budgetDidCut'])
    def test_business_and_decode_fall_through_credentials_stop_and_retry_once_owner(self):
        config = {'context': {'animeTitle': 'Local'}}
        for scenario in ['business', 'malformed']:
            result = self.load(scenario, configuration=config)
            self.assertEqual(result['outcome']['episodeID'], 50002)
        before = len(self.server.records)
        error = self.call('danmaku.load', **self.args('unauthorized', configuration=config))
        self.assertFalse(error['ok'])
        self.assertEqual(len(self.server.records) - before, 1)
        before = len(self.server.records)
        self.load('retry', retryAttempts=3)
        self.assertEqual(len(self.server.records) - before, 4)
        self.assertEqual(self.value('danmakuFlow.stats')['active'], 0)
    def test_cache_reuse_and_force_forget_keep_native_files_and_exact_revision(self):
        self.open()
        result = self.load(cacheKey='media', revision=18446744073709551615)
        self.assertEqual(self.value('danmakuCache.episodeMatch', mediaID='media')['episodeID'], 9223372036854775807)
        before = len(self.server.records)
        reused = self.load(cacheKey='media', revision=18446744073709551615,
                           configuration={'context': {'allowsCachedMatchReuse': True}})
        self.assertEqual(reused['episodes'], result['episodes'])
        self.assertEqual(len(self.server.records), before)
        empty = self.load('empty', cacheKey='media', revision=18446744073709551615,
                          configuration={'forceRematch': True, 'context': {'fileName': ''}})
        self.assertEqual(empty['outcome']['kind'], 'noMatch')
        self.assertIsNone(self.value('danmakuCache.episodeMatch', mediaID='media'))
        self.assertTrue((self.directory / 'comments-9223372036854775807.json').exists())
    def test_community_alias_identity_cache_and_priority(self):
        self.open()
        config = {'context': {'animeTitle': 'Local', 'originalTitle': 'Other', 'episodeNumber': 2, 'seasonNumber': 1, 'seriesTmdbId': 42}}
        providers = {name: {'baseURL': self.base + '/intro', 'clientID': 'client'} for name in ['aniList', 'aniSkip', 'animeSkip', 'theIntroDB']}
        result = self.load(configuration=config, providers=providers, aliases=['Alias'], cacheKey='media')
        hint = result['outcome']['introHint']
        self.assertEqual(hint['source'], 'aniskip')
        self.assertEqual(hint['evidenceCount'], 2)
        self.assertEqual(hint['endSeconds'], 99)
        self.assertTrue((self.directory / 'aniskip-ids.json').exists())
        searches = [r['body']['variables']['search'] for r in self.server.records if r['path'] == '/intro/' and 'search' in r['body']['variables']]
        self.assertIn('Alias', searches)
        self.assertTrue(any(r['client'] == 'client' for r in self.server.records))
        saved = self.value('danmakuCache.introHint', episodeID=9223372036854775807)
        self.assertEqual(saved, hint)
        before = len(self.server.records)
        self.load(configuration={'context': {'allowsCachedMatchReuse': True}}, cacheKey='media', providers=providers)
        self.assertEqual(len(self.server.records), before)
    def test_promoted_then_sibling_then_detected_and_manual_force(self):
        self.open()
        promoted = {'endSeconds': 90, 'evidenceCount': 4, 'source': 'learned'}
        self.value('introLearning.promote', animeID=5, payloadJSON=promoted)
        automatic = self.load()
        self.assertEqual(automatic['outcome']['introHint'], promoted)
        for episode, end in [(50001, 120), (50002, 124)]:
            self.seed_match(str(episode), episode)
            self.hint(episode, end)
        manual = self.load(configuration={'mode': 'manual', 'matchValue': {'episodeID': 9223372036854775807, 'animeID': 5, 'shiftSeconds': 2}})
        self.assertEqual(manual['outcome']['introHint']['endSeconds'], 122)
        self.assertEqual(manual['outcome']['introHint']['source'], 'danmaku')
        self.assertEqual(manual['episodes'][0]['candidate']['shift'], 2)
    def test_empty_invalid_payload_and_local_fingerprint(self):
        empty = self.load('invalid')
        self.assertEqual(empty['outcome']['kind'], 'empty')
        self.assertEqual(empty['episodes'][0]['comments'], [])
        self.assertIsNone(empty['episodes'][0]['json'])
        path = self.directory / 'media.bin'
        path.write_bytes(b'fixture media')
        self.load(filePath=str(path), matchRequest={'fileName': 'Clean - 02.mkv'})
        record = next(r for r in reversed(self.server.records) if r['path'].endswith('/match'))
        self.assertEqual(record['body']['fileHash'], hashlib.md5(path.read_bytes()).hexdigest())
    def test_native_integral_float_decoding_and_consumed_optional_field_validation(self):
        numeric = self.load('numeric')
        self.assertEqual(numeric['outcome']['episodeID'], 50002)
        self.assertEqual(numeric['episodes'][0]['candidate']['shift'], -5)
        self.assertEqual(numeric['episodes'][0]['count'], 1)
        self.server.records.clear()
        valid = self.load('badoptional', configuration={'context': {'animeTitle': 'Local'}})
        self.assertEqual(valid['outcome']['episodeID'], 50002)
        self.assertEqual(len(self.server.records), 3)
        self.assertTrue(self.server.records[1]['path'].endswith('/search/episodes'))
    def test_live_cancel_and_revision_change_leave_no_continuations_or_late_writes(self):
        self.open()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending = pool.submit(self.call, 'danmaku.load', **self.args('slow', requestId='cancel', cacheKey='media', revision=1))
            deadline = time.monotonic() + 3
            while len(self.server.records) < 2 and time.monotonic() < deadline: time.sleep(.005)
            self.success('request.cancel', requestId='cancel')
            self.assertEqual(pending.result(timeout=.5)['code'], 1003)
        self.assertEqual(self.value('danmakuFlow.stats')['active'], 0)
        self.assertIsNone(self.value('danmakuCache.comments', episodeID=9223372036854775807))
        self.server.records.clear()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending = pool.submit(self.call, 'danmaku.load', **self.args('slow', cacheKey='media', revision=2))
            deadline = time.monotonic() + 3
            while len(self.server.records) < 2 and time.monotonic() < deadline: time.sleep(.005)
            self.value('danmakuCache.claimRevision', mediaID='media', revision=3)
            self.seed_match('media', 50003)
            response = pending.result(timeout=2)
            self.assertEqual(response['code'], 1003)
        self.assertIsNone(self.value('danmakuCache.comments', episodeID=9223372036854775807))
        self.assertEqual(self.value('danmakuCache.episodeMatch', mediaID='media')['episodeID'], 50003)
        self.assertEqual(self.value('danmakuFlow.stats')['active'], 0)

    def test_preflight_and_budget_cut_are_failures_not_false_no_match(self):
        for invalid in [{'configuration': []}, {'revision': 1}, {'cacheKey': 'unconfigured'},
                        {'timeoutSeconds': 0}, {'retryAttempts': 0}, {'format': 'unknown'}]:
            response = self.call('danmaku.load', **self.args(**invalid))
            self.assertFalse(response['ok'])
            self.assertIn(response['code'], [1002, 1401])
        self.assertEqual(self.server.records, [])
        context = {'animeTitle': 'Local', 'episodeNumber': 2, 'tmdbId': 42}
        response = self.call('danmaku.load', **self.args('delayed', configuration={'context': context, 'budgetSeconds': .05}))
        self.assertEqual(response['code'], 1503)
        self.assertTrue(response['retryable'])
        self.assertEqual(len(self.server.records), 1)
        self.assertEqual(self.value('danmakuFlow.stats')['active'], 0)
        self.server.records.clear()
        providers = {name: {'enabled': False} for name in ['aniList', 'aniSkip', 'animeSkip', 'theIntroDB']}
        result = self.load('delayed', configuration={'context': context, 'budgetSeconds': 0}, providers=providers)
        self.assertEqual(result['outcome']['kind'], 'loaded')
        self.assertEqual(len(self.server.records), 9)

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(StandaloneContract, name, None)
del NetworkContract
if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)

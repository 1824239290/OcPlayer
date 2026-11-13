"""Intro policy and native-compatible learning storage through the C ABI."""
import ctypes
import json
import os
import tempfile
import unittest
from pathlib import Path


class IntroContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffi = ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
        cls.ffi.ocp_core_create.argtypes = [ctypes.c_char_p]
        cls.ffi.ocp_core_create.restype = ctypes.c_void_p
        cls.ffi.ocp_core_destroy.argtypes = [ctypes.c_void_p]
        cls.ffi.ocp_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        cls.ffi.ocp_call.restype = ctypes.c_void_p
        cls.ffi.ocp_string_free.argtypes = [ctypes.c_void_p]

    def setUp(self):
        self.cores = []
        self.core = self.new_core()
        self.temp = tempfile.TemporaryDirectory(prefix='ocp-intro-')
        self.directory = Path(self.temp.name)

    def tearDown(self):
        for core in self.cores:
            self.ffi.ocp_core_destroy(core)
        self.temp.cleanup()

    def new_core(self):
        core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(core)
        self.cores.append(core)
        return core

    def call(self, method, core=None, **args):
        ptr = self.ffi.ocp_call(core or self.core, method.encode(), json.dumps(args).encode())
        self.assertTrue(ptr)
        try:
            return json.loads(ctypes.string_at(ptr))
        finally:
            self.ffi.ocp_string_free(ptr)

    def value(self, method, core=None, **args):
        result = self.call(method, core, **args)
        self.assertTrue(result['ok'], result)
        return json.loads(result['data']['payloadJSON'])

    def policy(self, method, **args):
        return self.value('danmakuIntro.' + method, **args)

    def open_store(self, core=None):
        result = self.call('introLearning.open', core, directory=str(self.directory))
        self.assertTrue(result['ok'], result)

    def event(self, episode=9007199254740993, position=140, at=100):
        return {'episodeID': episode, 'position': position, 'at': at}

    def hint(self, source='learned', end=140):
        return {'endSeconds': end, 'evidenceCount': 3, 'source': source}

    def test_detector_strong_signals_and_single_user_rejection(self):
        comments = [{'cid': 9223372036854775807, 'p': f'{time},1,255,{uid}', 'm': text}
                    for time, uid, text in [(10, 'a', '跳伞2:10'), (11, 'b', '空降2:12'),
                                            (132, 'a', '空降成功')]]
        hint = self.policy('detect', payloadJSON=json.dumps(comments))
        self.assertEqual(hint, {'startSeconds': 8.0, 'endSeconds': 131.0,
                                'evidenceCount': 3, 'source': 'danmaku'})
        landing = [{'p': f'{time},1,255,a', 'm': '空降成功'} for time in [129, 130, 131]]
        self.assertIsNone(self.policy('detect', payloadJSON=landing))
        landing[-1]['p'] = '131,1,255,b'
        self.assertEqual(self.policy('detect', payloadJSON=landing)['endSeconds'], 130)
        self.assertIsNone(self.policy('detect', payloadJSON=[]))

    def test_timestamp_keyword_priority_and_grapheme_fields(self):
        self.assertEqual(self.policy('timestamp', text='1:23:45'), 162083)
        self.assertEqual(self.policy('timestamp', text='一:30'), 30)
        self.assertEqual(self.policy('timestamp', text='１２:３４'), 0)
        self.assertIsNone(self.policy('timestamp', text='123:45 1:23'))
        self.assertIsNone(self.policy('timestamp', text='1.5倍'))
        self.assertEqual(self.policy('jumpTarget', text='空降2:15跳伞2:12'), 132)
        self.assertIsNone(self.policy('jumpTarget', text='跳伞\u03012:12'))
        fields = self.policy('commentFields', p='0x1.8p+1,,1,,2,,\u00a0uid\u200b')
        self.assertEqual(fields, {'time': 3.0, 'uid': 'uid'})
        raw = '0x1.000000000000081p0'
        self.assertEqual(self.policy('commentFields', p=raw + ',1,2,u')['time'], float.fromhex(raw))
        self.assertEqual(self.policy('commentFields', p='1,\u03012,3,4,5')['uid'], '5')

    def test_cross_episode_consensus_boundaries_chain_and_source_upgrade(self):
        events = [self.event(position=120), self.event(9007199254740994, 130),
                  self.event(9223372036854775807, 140)]
        self.assertEqual(self.policy('consensus', payloadJSON=events), {'end': 130, 'episodeCount': 3})
        same = [self.event(position=p) for p in [120, 121, 122]]
        self.assertIsNone(self.policy('consensus', payloadJSON=same))
        for to, expected in [(30, True), (360, True), (29, False), (361, False)]:
            self.assertEqual(self.policy('eligibleSeek', **{'from': 0, 'to': to}), expected)
        self.assertFalse(self.policy('eligibleSeek', **{'from': 95, 'to': 100}))
        upgraded = self.policy('confirmedHint', to=150, payloadJSON=self.hint('danmaku'))
        self.assertEqual(upgraded['source'], 'learned')
        self.assertEqual(upgraded['evidenceCount'], 4)
        self.assertIsNone(self.policy('confirmedHint', to=140, payloadJSON=self.hint('aniskip')))

    def test_source_cluster_representative_tie_and_sibling_start_consensus(self):
        intervals = [{'source': s, 'start': a, 'end': b} for s, a, b in
                     [('danmaku', 10, 100), ('aniskip', 12, 102),
                      ('animeSkip', 20, 300), ('theIntroDB', 22, 301)]]
        self.assertEqual(self.policy('selectIntervals', payloadJSON=intervals),
                         {'start': 21, 'end': 300.5, 'votes': 2, 'source': 'animeSkip'})
        hints = [dict(self.hint('danmaku', end), startSeconds=start)
                 for start, end in [(10, 140), (12, 142), (99, 300)]]
        hint = self.policy('siblingHint', payloadJSON=hints)
        self.assertEqual(hint['startSeconds'], 11)
        self.assertEqual(hint['endSeconds'], 141)
        hints[1]['startSeconds'] = 50
        self.assertNotIn('startSeconds', self.policy('siblingHint', payloadJSON=hints))

    def test_learning_persistence_exact_ids_reference_dates_and_cap(self):
        self.open_store()
        anime = 9223372036854775807
        for i in range(205):
            self.assertTrue(self.value('introLearning.record', animeID=anime,
                                       payloadJSON=self.event(9007199254740993 + i, 140 + i % 2, i)))
        self.value('introLearning.promote', animeID=anime, payloadJSON=self.hint())
        saved = json.loads((self.directory / 'learned-intros.json').read_text())[str(anime)]
        self.assertEqual(len(saved['events']), 200)
        self.assertEqual(saved['events'][0], self.event(9007199254740998, 141, 5))
        reopened = self.new_core()
        self.open_store(reopened)
        self.assertEqual(self.value('introLearning.promotedHint', reopened, animeID=anime), self.hint())
        self.assertEqual(self.value('introLearning.consensusHint', reopened, animeID=anime)['source'], 'learned')
        self.assertIsNone(self.value('introLearning.promotedHint', reopened, animeID=1))

    def test_corruption_cached_empty_failed_write_memory_and_validation(self):
        path = self.directory / 'learned-intros.json'
        path.write_bytes(b'bad')
        self.open_store()
        self.assertEqual(self.value('introLearning.events', animeID=1), [])
        path.write_text(json.dumps({'1': {'events': [self.event()]}}))
        self.assertEqual(self.value('introLearning.events', animeID=1), [])
        path.unlink()
        path.mkdir()
        self.assertFalse(self.value('introLearning.record', animeID=1, payloadJSON=self.event()))
        self.assertEqual(self.value('introLearning.events', animeID=1), [self.event()])
        self.assertEqual(self.value('introLearning.stats')['writeFailures'], 1)
        self.assertFalse(any(p.name.startswith('.ocp-cache-') for p in self.directory.iterdir()))
        unconfigured = self.new_core()
        self.assertEqual(self.call('introLearning.events', unconfigured, animeID=1)['code'], 1401)
        for method, args in [('danmakuIntro.detect', {'payloadJSON': 'bad'}),
                             ('danmakuIntro.consensus', {'payloadJSON': [], 'minimumEpisodes': 1.5}),
                             ('introLearning.record', {'animeID': 1, 'payloadJSON': {'episodeID': 1}}),
                             ('introLearning.open', {'directory': 'relative'})]:
            self.assertEqual(self.call(method, **args)['code'], 1002)


if __name__ == '__main__':
    unittest.main(verbosity=2)

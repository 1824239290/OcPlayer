"""Complete resumable Danmaku workflow over the exported C ABI."""
import json
from network_contract import NetworkContract


class DanmakuFlowContract(NetworkContract):
    def value(self, result):
        self.assertTrue(result['ok'], result)
        return json.loads(result['data']['payloadJSON'])

    def begin(self, config, id='flow'):
        return self.value(self.call('danmakuFlow.begin', flowID=id, payloadJSON=json.dumps(config)))

    def advance(self, state, value=None, **reply):
        return self.value(self.call('danmakuFlow.advance', flowID=state['flowID'], step=state['step'],
                         payloadJSON=json.dumps({'current': True, 'value': value, 'nowSeconds': 0, **reply})))

    @staticmethod
    def kind(state):
        return state['effect']['kind']

    @staticmethod
    def automatic(**context):
        return {'mode': 'automatic', 'budgetSeconds': 30, 'context': {'fileName': 'Clean - 01.mkv',
                'animeTitle': 'Local', 'episodeNumber': 1, 'tmdbId': 42, **context}}

    def manual(self, **config):
        return self.begin({'mode': 'manual',
            'matchValue': {'episodeID': 84190003, 'shiftSeconds': 7, 'animeTitle': 'Show'}, **config})

    def through_injection(self, state):
        for kind, value in [('remember', None), ('detectIntro', None), ('cachedComments', {'hit': True}),
                            ('render', {'hasEntries': True, 'hasJSON': False, 'commentCount': 3}),
                            ('waitReady', True), ('inject', True)]:
            self.assertEqual(self.kind(state), kind)
            state = self.advance(state, value)
        return state

    def test_full_eight_requests_budget_origin_and_tier_errors(self):
        state = self.begin(self.automatic())
        state = self.advance(state)
        state = self.advance(state, 'hash', nowSeconds=100)
        requests = []
        while state['outcome'] is None:
            requests.append(state['effect'])
            state = self.advance(state, {'candidates': []}, nowSeconds=101)
        self.assertEqual(len(requests), 8)
        self.assertEqual(requests[3]['arguments']['tmdbIdType'], 1)
        self.assertEqual(requests[4]['arguments']['anime'], 'Local')
        self.assertEqual(requests[6]['arguments']['anime'], 'Clean')
        self.assertEqual(state['outcome'], {'kind': 'noMatch'})
        self.assertFalse(state['diagnostics']['budgetDidCut'])
        config = self.automatic()
        del config['budgetSeconds']
        state = self.begin(config)
        state = self.advance(self.advance(state), 'hash', nowSeconds=100)
        state = self.advance(state, {'candidates': []}, nowSeconds=131)
        self.assertEqual(state['outcome']['message'], '弹幕匹配超时，请重试')
        for error, expected in [({'kind': 'httpStatus', 'status': 404}, 'search'),
                                ({'kind': 'decodingFailed'}, 'search'),
                                ({'kind': 'network'}, None)]:
            state = self.begin(self.automatic())
            state = self.advance(self.advance(state), 'hash')
            state = self.advance(state, error=error)
            if expected:
                self.assertEqual(self.kind(state), expected)
                self.value(self.call('danmakuFlow.close', flowID='flow'))
            else:
                self.assertEqual(state['outcome']['message'], '弹幕网络请求失败')

    def test_match_ranking_direct_first_and_int64_payloads(self):
        candidates = [{'episodeId': 9223372036854775807, 'animeId': 9223372036854775806,
                       'animeTitle': 'Wrong', 'episodeTitle': '第02话', 'shift': -7},
                      {'episodeId': 2, 'animeTitle': 'Local', 'episodeTitle': '第01话'}]
        for matched, expected in [(True, 9223372036854775807), (False, 2)]:
            state = self.begin(self.automatic())
            state = self.advance(self.advance(state), 'hash')
            state = self.advance(state, {'candidates': candidates, 'isMatched': matched})
            self.assertEqual(self.kind(state), 'remember')
            self.assertEqual(state['match']['episodeID'], expected)
            if matched:
                self.assertEqual(state['match']['animeID'], 9223372036854775806)
                self.assertEqual(state['match']['shiftSeconds'], -7)
            self.value(self.call('danmakuFlow.close', flowID='flow'))

    def test_cache_fast_path_no_hash_budget_and_empty_render(self):
        state = self.begin({**self.automatic(allowsCachedMatchReuse=True), 'budgetSeconds': 1e-9})
        state = self.advance(state)
        self.assertEqual(self.kind(state), 'cachedMatch')
        state = self.advance(state, {'episodeID': 1, 'shiftSeconds': 0})
        self.assertEqual(self.kind(state), 'detectIntro')
        state = self.advance(state)
        state = self.advance(state, {'hit': True})
        state = self.advance(state, {'hasEntries': False, 'hasJSON': False, 'commentCount': 99})
        state = self.advance(state, True)
        self.assertFalse(state['effect']['arguments']['replace'])
        state = self.advance(state, True)
        self.assertEqual(self.kind(state), 'cachedIntro')
        state = self.advance(state, {'endSeconds': 90, 'evidenceCount': 1, 'source': 'danmaku'})
        self.assertEqual(state['outcome']['kind'], 'empty')
        self.assertEqual(state['outcome']['title'], '弹弹play')

    def test_manual_parallel_source_plan_aliases_priority_and_persist(self):
        state = self.manual(context={'episodeNumber': 3, 'malID': 42, 'seriesTmdbId': 9,
                                     'originalTitle': 'Original'}, hasAliases=True, hasLearning=True)
        state = self.through_injection(state)
        self.assertEqual(self.kind(state), 'aliases')
        state = self.advance(state, ['Alias'])
        identity = state['effect']['arguments']['identity']
        self.assertEqual(identity['alternativeTitles'], ['Original', 'Alias'])
        state = self.advance(state, {'malID': 42, 'anilistID': 43})
        self.assertEqual([s['provider'] for s in state['effect']['arguments']['sources']], ['aniSkip', 'animeSkip', 'theIntroDB'])
        state = self.advance(state, [{'source': 'aniskip', 'start': 0, 'end': 90},
                                    {'source': 'theIntroDB', 'start': 2, 'end': 92}])
        self.assertEqual(self.kind(state), 'persistIntro')
        self.assertEqual(state['effect']['arguments']['hint']['endSeconds'], 91)
        state = self.advance(state)
        self.assertEqual(state['outcome']['introHint']['source'], 'aniskip')

    def test_cancel_stale_step_invalid_reply_and_bounded_lifetimes(self):
        state = self.begin(self.automatic())
        failed = self.call('danmakuFlow.advance', flowID='flow', step=state['step']+1,
                           payloadJSON=json.dumps({'current': True}))
        self.assertEqual(failed['code'], 1002)
        state = self.advance(state, cancelled=True)
        self.assertEqual(state['outcome']['message'], '已取消')
        self.assertEqual(self.value(self.call('danmakuFlow.stats'))['active'], 0)
        state = self.begin(self.automatic())
        state = self.advance(state, current=False)
        self.assertEqual(state['outcome']['message'], '播放已切换')
        for i in range(64): self.begin(self.automatic(), id=str(i))
        self.assertEqual(self.call('danmakuFlow.begin', flowID='overflow', payloadJSON=json.dumps(self.automatic()))['code'], 1002)
        self.value(self.call('danmakuFlow.close', flowID='1'))
        self.begin(self.automatic(), id='overflow')

    def test_render_native_shapes_unicode_whitespace_modes_and_sorted_overlay(self):
        comments = [{'p': '3,5,16777215', 'm': 'third'}, {'p': '1,4,0', 'm': 'first'},
                    {'p': '2,1,1,\u0301suffix', 'm': 'second'}, {'p': '1,1,1', 'm': '\u200b'},
                    {'p': '1,1,1', 'm': ' \u0301'}, {'p': 'NaN,1,1', 'm': 'bad'},
                    {'p': '1,2,1', 'm': 'bad'}, {'p': '1,1,16777216', 'm': 'bad'}]
        result = self.value(self.call('danmaku.renderPayload', payloadJSON=json.dumps(comments), format='both', detectingIntro=False))
        self.assertEqual([e['time'] for e in result['entries']], [1, 1, 2, 3])
        self.assertEqual([e['time'] for e in json.loads(result['json'])['comments']], [3, 1, 2, 1])
        self.assertEqual(result['commentCount'], 8)
        self.assertIsNone(result['detectedIntroHint'])
        self.assertEqual([e['mode'] for e in result['entries']], ['bottom', 'scroll', 'scroll', 'top'])


for name in list(vars(NetworkContract)):
    if name.startswith('test_'):
        setattr(DanmakuFlowContract, name, None)
del NetworkContract
if __name__ == '__main__':
    import unittest
    unittest.main()

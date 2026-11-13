"""Native TMDB identity and matching policy through the real shared C ABI."""
import json
from danmaku_contract import DanmakuContract

class TmdbMatcherContract(DanmakuContract):
    def policy(self, operation='initial', **args):
        return json.loads(self.success('tmdb.matcher', operation=operation, **args)['payloadJSON'])
    def item(self, name='作品', kind='series', **fields):
        return dict(name=name, kind=kind, **fields)
    def candidate(self, id=9223372036854775807, title='作品', **fields):
        return dict(id=id, mediaType='tv', title=title, **fields)

    def test_authoritative_and_parent_identity_boundary(self):
        for kind, prefix in [('movie','movie'),('series','tv')]:
            result=self.policy(item=self.item(kind=kind,tmdbID='\u0085+9223372036854775807\u2000'),allowSearch=False)
            self.assertEqual(result['match']['entityKey'],prefix+'/9223372036854775807')
            self.assertEqual(result['match']['confidence'],1)
            self.assertIsNone(result['search'])
        parent=dict(entityKey='tv/153217',source='manual',confidence=.8)
        for kind in ['season','episode']:
            result=self.policy(item=self.item(kind=kind,tmdbID='3384539',seasonNumber=0,seriesName='父剧'),seriesLink=parent)
            self.assertEqual(result['match']['entityKey'],'tv/153217/season/0')
            self.assertFalse(result['match']['shouldApplyAutomatically'])
            self.assertEqual(result['match']['source'],'manual')
            self.assertEqual(result['match']['matchedTitle'],'父剧')
            self.assertIsNone(self.policy(item=self.item(kind=kind,tmdbID='3384539',seasonNumber=0))['match'])
        for raw in ['', '0', '-1', '６０３', '9223372036854775808', '12.5']:
            self.assertIsNone(self.policy('providerID',item=self.item(tmdbID=raw))['id'])
        for kind in ['boxSet','musicAlbum','folder','other']:
            self.assertEqual(self.policy(item=self.item(kind=kind,tmdbID='603')),dict(match=None,search=None))
        self.assertEqual(self.server.records,[])

    def test_search_year_is_separate_from_score_and_original_fallback(self):
        item=self.item(name='作品 (2024)',originalTitle='Original')
        result=self.policy(item=item)
        self.assertEqual(result['search'],dict(query='作品 (2024)',mediaType='tv',year=2024))
        result=self.policy('rank',item=item,candidates=[self.candidate(title='作品 (2024)',year=2024)])
        self.assertEqual(result['scores'],[.7])
        self.assertTrue(result['needsOriginalSearch'])
        item=self.item(year=2024,originalTitle='Original')
        results=[self.candidate(id=i,year=year) for i,year in enumerate([2024,2023,None,2021])]
        result=self.policy('rank',item=item,candidates=results)
        self.assertEqual(result['scores'],[.95,.8,.7,.4])
        self.assertFalse(result['needsOriginalSearch'])
        self.assertEqual(result['match']['entityKey'],'tv/0')
        result=self.policy('rank',item=self.item(name='Cafe\u0301',originalTitle='Café'),candidates=[])
        self.assertFalse(result['needsOriginalSearch'])
        self.assertIsNone(result['match'])

    def test_unicode_canonical_matching_and_stable_manual_candidates(self):
        titles=['ＡＢＣ 第十一季','ガ season12','① Ⅳ ﬃ','Cafe\u0301','Show 1st season','Show 2']
        result=self.policy('normalize',titles=titles)
        self.assertEqual(result['normalized'],['abc','ｶﾞ','①ⅳﬃ','cafe\u0301','show1stseason','show2'])
        result=self.policy('rank',item=self.item(name='Café',year=2024),candidates=[self.candidate(title='Cafe\u0301',year=2024)])
        self.assertEqual(result['scores'],[.95])
        candidates=[self.candidate(id=9223372036854775807-i,title='无关',overview='text',posterPath='/x',popularity=.25,future={'raw':i}) for i in range(10)]
        result=self.policy('rank',item=self.item(year=2024),candidates=candidates)
        self.assertEqual(result['match']['entityKey'],'tv/9223372036854775807')
        self.assertEqual(result['scores'],[.1]*10)
        self.assertEqual([v['id'] for v in result['match']['alternatives']],[9223372036854775806-i for i in range(5)])
        self.assertEqual(result['match']['alternatives'][0]['future'],{'raw':1})
        self.assertFalse(result['match']['shouldApplyAutomatically'])
        result=self.policy('normalize',titles=['Show 第2\u0301季','Show season2\ufe0f','(2\u0301019) (2024)'])
        self.assertEqual(result['normalized'][:2],['show','show'])
        self.assertIsNone(result['years'][2])

    def test_preflight_rejects_wrong_types_and_overflow(self):
        invalid=[{}, {'operation':True,'item':self.item()}, {'operation':'unknown','item':self.item()},
                 {'item':self.item(kind='invalid')}, {'item':self.item(year=1.5)},
                 {'item':self.item(seasonNumber=9223372036854775808)}, {'item':self.item(),'allowSearch':1},
                 {'item':self.item(),'seriesLink':dict(entityKey='tv/not-number',source='manual',confidence=1)},
                 {'operation':'normalize','titles':['name',1]},
                 {'operation':'rank','item':self.item(),'candidates':[self.candidate(id=9223372036854775808)]},
                 {'operation':'rank','item':self.item(),'candidates':[self.candidate(popularity=True)]},
                 {'operation':'rank','item':self.item(),'candidates':[self.candidate(overview=False)]},
                 {'operation':'rank','item':self.item(),'candidates':[dict(id=1,mediaType='invalid')]}]
        for args in invalid:
            self.assertEqual(self.call('tmdb.matcher',**args)['code'],1002,args)
        self.assertEqual(self.server.records,[])

for name in list(vars(DanmakuContract)):
    if name.startswith('test_'): setattr(TmdbMatcherContract,name,None)
del DanmakuContract
if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

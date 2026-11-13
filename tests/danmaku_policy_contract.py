"""Shared matching policy through the public C ABI, without native scoring."""
from danmaku_contract import DanmakuContract

class DanmakuPolicyContract(DanmakuContract):
    def candidate(self,title='作品',episode='第1话',**fields):
        return dict(episodeId=9007199254740993,animeTitle=title,episodeTitle=episode,**fields)
    def test_identity_gates_and_special_namespace_order(self):
        target={'animeTitle':'作品','episodeNumber':1,'seasonNumber':1}
        c=[self.candidate(),self.candidate(episode='第2话'),self.candidate(type='movie')]
        result=self.success('danmaku.scoreCandidates',target=target,candidates=c)
        self.assertEqual(result['scores'],[4050,-951,-5952])
        self.assertEqual(result['selection'],{'index':0,'score':4050})
        target.update(seasonNumber=0,special={'index':1,'kinds':['extra','special']})
        c=[self.candidate(episode='S1'),self.candidate(episode='C1'),self.candidate(episode='O1'),self.candidate()]
        result=self.success('danmaku.scoreCandidates',target=target,candidates=c)
        self.assertEqual(result['scores'],[3050,3549,1848,2147])
        self.assertEqual(result['selection'],{'index':1,'score':3549})
        c=[self.candidate(type='movie')]
        self.assertIsNone(self.success('danmaku.scoreCandidates',target=target,candidates=c)['selection'])
        self.assertEqual(self.server.records,[])
    def test_order_threshold_and_rank_offset(self):
        target={'animeTitle':'作品','episodeNumber':1,'seasonNumber':1}
        result=self.success('danmaku.scoreCandidates',target=target,candidates=[self.candidate()]*2000,rankIndex=100)
        self.assertEqual(set(result['scores']),{4000})
        self.assertEqual(result['selection'],{'index':0,'score':4000})
        self.assertIsNone(self.success('danmaku.scoreCandidates',target=target,candidates=[])['selection'])
    def test_parser_canonical_unicode_and_large_tokens(self):
        value=self.success('danmaku.parseFilename',fileName='[标题] 02.mp4')
        self.assertEqual(value['title'],'标题')
        self.assertEqual(value['episode_number'],2)
        for title,expected in [('Ｓ２','S2'),('s2',None),('SP1 特番',None),('第9223372036854775807话','9223372036854775807')]:
            self.assertEqual(self.success('danmaku.parseEpisode',title=title)['searchValue'],expected)
        self.assertEqual(self.success('danmaku.canonicalMatchName',seriesTitle='作品',season=0,episode={'tokenType':'special','kind':'extra','index':1},rawFileName='NCOP.mkv')['fileName'],'作品 C1')
        self.assertEqual(self.success('danmaku.comparableTitle',title='Cafe\u0301！')['title'],'Café'.lower())
        self.assertEqual(self.success('danmaku.specialKind',text='Show NCOP 01.mkv')['kind'],'extra')
    def test_invalid_inputs_are_rejected(self):
        for args in [{'target':{},'candidates':'bad'},{'target':{'kind':'bad'},'candidates':[]},{'target':{'episodeNumber':1.5},'candidates':[]},{'target':{},'candidates':[],'rankIndex':1.5}]:
            self.assertEqual(self.call('danmaku.scoreCandidates',**args)['code'],1002)
        for args in [{'rawFileName':'x','episode':{'tokenType':'number','value':1.5}},{'rawFileName':'x','season':4294967296.5}]:
            self.assertEqual(self.call('danmaku.canonicalMatchName',**args)['code'],1002)

for name in list(vars(DanmakuContract)):
    if name.startswith('test_'): setattr(DanmakuPolicyContract,name,None)
del DanmakuContract
if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

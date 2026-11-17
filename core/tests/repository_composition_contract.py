"""Actual ABI repository composition, without native request replay."""
import json
from network_contract import NetworkContract

class RepositoryCompositionContract(NetworkContract):
    def compose(self, method, **args):
        return self.success('mediaRepository.compose.' + method,payloadJSON=json.dumps(args,ensure_ascii=False))
    def item(self,id):
        return dict(id=id,name='作品',year=9223372036854775807)
    def test_pagination_restores_gaps_and_retains_native_duplicate_rules(self):
        rows=[dict(items=[self.item('e\u0301'),self.item('last')],startIndex=2,limit=2),dict(items=[self.item('é'),self.item('é')],startIndex=0,limit=2,totalRecordCount=9223372036854775807),dict(items=[self.item('gap')],startIndex=5,limit=1)]
        previous=self.compose('diskPage',rows=rows)
        self.assertEqual([i['id'] for i in previous['items']],['é','last'])
        self.assertEqual(previous['nextStartIndex'],4); self.assertNotIn('totalCount',previous)
        page=self.compose('page',items=[self.item('e\u0301'),self.item('new')],previous=previous,startIndex=7,limit=2,requestStartedAt=-100.125,totalRecordCount=9223372036854775807)
        self.assertEqual([i['id'] for i in page['items']],['é','last','new'])
        self.assertEqual(page['totalCount'],9223372036854775807);self.assertEqual(page['nextStartIndex'],9)
        first=self.compose('page',items=[self.item('é'),self.item('é')],startIndex=0,limit=-1,requestStartedAt=1)
        self.assertEqual(len(first['items']),2);self.assertTrue(first['lastPageWasFull'])
    def test_home_dates_empty_cache_and_default_season_match_native(self):
        content=dict(libraries=[],resume=[self.item('é')],nextUp=[self.item('e\u0301'),self.item('n'),self.item('n')],latest=[])
        result=self.compose('diskHome',content=content,railDates=[-10.125,5],libraryDates=[-20],now=10)
        self.assertEqual(result['fetchedAt'],-10.125);self.assertEqual(len(result['value']['nextUp']),2)
        self.assertEqual(result['value']['resume'][0]['year'],9223372036854775807)
        empty=dict(libraries=[],resume=[],nextUp=[],latest=[])
        self.assertIsNone(self.compose('diskHome',content=empty,railDates=[],libraryDates=[],now=1))
        self.assertEqual(self.compose('defaultSeason',seasons=[dict(id='zero',seasonNumber=0),dict(id='missing')]),'missing')
        self.assertEqual(self.compose('detailPlan',kindHint='series',item=dict(kind='boxSet')),'series')
        self.assertEqual(self.compose('detailPlan',item=dict(kind='series')),'retrySeries')
    def test_session_progress_is_shared_and_bad_payloads_are_atomic(self):
        self.success('mediaRepository.progress.beginFinal',payloadJSON=json.dumps(dict(item=self.item('é'),positionSeconds=42,recordedAt=5)))
        page=self.compose('page',items=[self.item('e\u0301')],startIndex=0,limit=1,requestStartedAt=4)
        self.assertEqual(page['items'][0]['playState']['positionSeconds'],42)
        before=self.success('mediaRepository.progress.stats');memory=self.success('mediaRepository.stats')
        for operation,args in [('page',dict(items=[self.item('id')],startIndex=9223372036854775807,limit=1,requestStartedAt=4)),('diskPage',dict(rows=[dict(items=[{}],startIndex=0,limit=1)])),('defaultSeason',dict(seasons=[dict(id='id',seasonNumber=9223372036854775808)]))]:
            result=self.call('mediaRepository.compose.'+operation,payloadJSON=json.dumps(args))
            self.assertFalse(result['ok']);self.assertEqual(result['code'],1002)
            self.assertEqual(self.success('mediaRepository.progress.stats'),before);self.assertEqual(self.success('mediaRepository.stats'),memory)
        self.assertEqual(self.server.records,[])

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(RepositoryCompositionContract,name,None)
if __name__=='__main__':
    import unittest
    unittest.main(defaultTest='RepositoryCompositionContract',verbosity=2)

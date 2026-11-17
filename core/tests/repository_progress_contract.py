"""Actual C ABI retained repository progress and async revision boundaries."""
import json
from network_contract import NetworkContract

class RepositoryProgressContract(NetworkContract):
    def progress(self, operation, **args):
        return self.success('mediaRepository.progress.' + operation, payloadJSON=json.dumps(args,ensure_ascii=False))
    def put(self, bucket, key, value):
        return self.success('mediaRepository.put',bucket=bucket,payloadJSON=json.dumps(dict(key=key,entry=dict(value=value,fetchedAt=1)),ensure_ascii=False))
    def get(self,bucket,key):
        return self.success('mediaRepository.get',bucket=bucket,payloadJSON=json.dumps(dict(key=key),ensure_ascii=False))
    def item(self,id='movie',position=0,played=False):
        return dict(id=id,name='作品',kind='movie',year=9223372036854775807,extra={'keep':True},playState=dict(played=played,percentage=0.25,positionSeconds=position,unplayedCount=9223372036854775807))
    def begin(self,at=10,position=42):
        return self.progress('beginFinal',item=self.item(),recordedAt=at,positionSeconds=position,durationSeconds=100)
    def finish(self,receipt,**args):
        return self.progress('finishFinal',itemID='movie',revision=receipt['revision'],state=receipt['state'],now=30,**args)

    def test_apply_updates_all_typed_projections_and_first_duplicate(self):
        item=self.item('e\u0301'); state=dict(played=True,percentage=1,positionSeconds=0,unplayedCount=9223372036854775807)
        self.put('items',item['id'],item)
        self.put('details',item['id'],dict(item=item,episodes=[item,item]))
        self.put('episodes',dict(seriesID='s',seasonID='é'),[item,item])
        self.put('home','home',dict(libraries=[],resume=[item,item],nextUp=[item],latest=[item]))
        self.put('pages',dict(parentID='lib'),dict(items=[item,item],totalCount=9223372036854775807))
        result=self.progress('apply',itemID='é',state=state,now=20,persistToStore=True)
        self.assertTrue(result['applied']); self.assertEqual(result['fallbackItem']['id'],item['id'])
        for bucket,key in [('items','é'),('details','é'),('episodes',dict(seriesID='s',seasonID='e\u0301')),('home','home'),('pages',dict(parentID='lib'))]:
            self.assertEqual(self.get(bucket,key)['fetchedAt'],20)
        detail=self.get('details','é')['value']
        self.assertEqual(detail['episodes'][0]['playState'],state); self.assertEqual(detail['episodes'][1]['playState'],item['playState'])
        self.assertEqual(detail['item']['year'],9223372036854775807)
        fallback=self.progress('apply',itemID='a\u0301',state=state,now=21,persistToStore=True)
        self.assertEqual(fallback['fallbackItem']['id'],'a\u0301')
        self.assertEqual(self.server.records,[])

    def test_final_receipts_are_retired_by_newer_progress_and_shutdown_preserves_owned_record(self):
        first=self.begin(); newer=self.begin(at=11,position=60)
        self.assertFalse(self.finish(first)['applied'])
        self.progress('invalidate',discardLocalProgress=False)
        self.assertTrue(self.finish(newer)['applied']); self.assertFalse(self.finish(newer)['applied'])
        old=self.begin(at=9); self.assertFalse(old['accepted'])
        final=self.begin(at=40,position=70)
        self.progress('shutdown')
        self.assertFalse(self.finish(final)['applied'])
        stats=self.progress('stats'); self.assertTrue(stats['shutdown'])
        self.assertEqual(stats['records'][0]['item']['playState']['positionSeconds'],70)
        self.assertIsNone(self.get('items','movie'))
        self.progress('invalidate',discardLocalProgress=True)
        self.assertEqual(self.progress('stats')['records'],[])

    def test_confirmation_signed_dates_completion_and_foreign_disk_boundaries(self):
        receipt=self.begin(at=-2000000000.125,position=99)
        finished=self.item(played=True)
        old=self.progress('incoming',incoming=[finished],merged=[finished],rail='resume',requestStartedAt=-2000000001,now=-1999999998)
        self.assertEqual(old[0]['playState']['positionSeconds'],99)
        complete=self.progress('incoming',incoming=[finished],merged=[finished],rail='resume',requestStartedAt=-2000000000.125,now=-1999999998)
        self.assertEqual(complete,[])
        self.assertFalse(self.finish(receipt)['applied'])
        receipt=self.begin(at=10)
        state=self.item(played=True)['playState']
        accepted=self.progress('finishFinal',itemID='movie',revision=receipt['revision'],state=state,now=30,
            newerRecord=dict(item=self.item(),recordedAt=20,confirmedAt=20,completed=False))
        self.assertTrue(accepted['applied'])
        self.assertEqual(self.progress('merge',items=[self.item(position=4)],requestStartedAt=20)[0]['playState'],state)
        self.assertEqual(self.progress('merge',items=[self.item(position=4)],requestStartedAt=21)[0]['playState']['positionSeconds'],4)

    def test_bad_arguments_and_untyped_projection_do_not_mutate_progress_or_lru(self):
        self.begin()
        self.put('items','bad','not a media projection')
        before=self.progress('stats'); memory=self.success('mediaRepository.stats')
        state=self.item()['playState']
        invalid=[dict(itemID='movie',state={},now=20,persistToStore=True),dict(itemID='movie',state=state,now='20',persistToStore=True),dict(itemID='movie',state=state,now=20,persistToStore=True)]
        for args in invalid:
            result=self.call('mediaRepository.progress.apply',payloadJSON=json.dumps(args))
            self.assertFalse(result['ok']); self.assertEqual(result['code'],1002)
            self.assertEqual(self.progress('stats'),before); self.assertEqual(self.success('mediaRepository.stats'),memory)
        self.success('mediaRepository.clear')
        self.put('items','movie',self.item())
        for duration in (None,-1,0,100):
            result=self.progress('playbackState',itemID='movie',positionSeconds=50,durationSeconds=duration,played=False)
            self.assertEqual(result['percentage'],0.5 if duration==100 else 0.25)
            self.assertEqual(result['unplayedCount'],9223372036854775807)

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(RepositoryProgressContract,name,None)
if __name__=='__main__':
    import unittest
    unittest.main(defaultTest='RepositoryProgressContract',verbosity=2)

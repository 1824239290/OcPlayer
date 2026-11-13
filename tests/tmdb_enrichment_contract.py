"""Complete enrichment continuations and concurrent scheduling via the C ABI."""
import concurrent.futures
import json
from network_contract import NetworkContract

MAX=9223372036854775807
class TmdbEnrichmentContract(NetworkContract):
    def invoke(self,command,**args): return self.success('tmdbEnrichment.'+command,**args)
    def item(self,kind='movie',provider='1'): return dict(name='作品',kind=kind,tmdbID=provider)
    def link(self,key='movie/1',source='providerID',confidence=1): return dict(entityKey=key,source=source,confidence=confidence)
    def begin(self,mode='refresh',**fields):
        return self.invoke('begin',flowID='flow',payloadJSON=json.dumps(dict(mode=mode,configured=True,item=self.item(),**fields)))
    def advance(self,state,value,cancelled=False):
        return self.invoke('advance',flowID='flow',step=state['step'],payloadJSON=json.dumps(dict(value=value,cancelled=cancelled)))
    def cache(self,**fields): return dict(present=True,fetchedAt=1000,expiresAt=2000,now=1500,startOfToday=0,**fields)

    def test_complete_authoritative_rematch_and_cached_failure_flow(self):
        state=self.begin()
        state=self.advance(state,self.link('movie/2','search'))
        state=self.advance(state,dict(present=True,fetchedAt=0,expiresAt=1,now=1000,startOfToday=0))
        state=self.advance(state,self.link('movie/2','search'))
        self.assertEqual(state['effect']['kind'],'match')
        state=self.advance(state,self.link(f'movie/{MAX}'))
        self.assertEqual(state['effect']['arguments']['entityKey'],f'movie/{MAX}')
        state=self.advance(state,None)
        self.assertEqual(state['effect']['kind'],'hasPayload')
        state=self.advance(state,True)
        state=self.advance(state,False)
        self.assertEqual(state['outcome']['kind'],'skipped')
        self.assertEqual(self.invoke('stats')['active'],0)
        self.assertEqual(self.server.records,[])

    def test_collections_keep_member_filter_budget_and_transient_failure_distinction(self):
        members=[self.item('series'),self.item(provider='0'),self.item(provider=str(MAX))]+[self.item(provider=str(i)) for i in (2,3,4)]
        for successes,expected in [([False]*3,'failed'),([False,True,False],'noMatch')]:
            state=self.begin('collection',members=members)
            state=self.advance(state,None)
            for ident,success in zip([MAX,2,3],successes):
                self.assertEqual(state['effect']['arguments']['id'],ident)
                state=self.advance(state,dict(success=success))
            self.assertEqual(state['outcome']['kind'],expected)
        state=self.begin('collection',members=members)
        state=self.advance(state,None)
        state=self.advance(state,dict(success=True,collectionID=MAX-1))
        self.assertEqual(state['effect']['kind'],'saveLink')
        self.assertEqual(state['effect']['arguments']['entityKey'],f'collection/{MAX-1}')
        state=self.advance(state,None); state=self.advance(state,True)
        self.assertEqual(state['outcome']['kind'],'fetched')

    def test_airing_freshness_and_season_flow_preserve_daily_refresh_and_parent_id(self):
        base=dict(present=True,fetchedAt=1000000-86400,expiresAt=9000000,now=1000000,startOfToday=950400,airDates=[None])
        self.assertFalse(self.invoke('policy',operation='fresh',cache=base)['value'])
        base['fetchedAt']+=1
        self.assertTrue(self.invoke('policy',operation='fresh',cache=base)['value'])
        state=self.begin('season',seriesLink=self.link(f'tv/{MAX}'),seasonNumber=MAX-1)
        self.assertEqual(state['effect']['arguments']['entityKey'],f'tv/{MAX}/season/{MAX-1}')
        base['fetchedAt']-=2
        state=self.advance(state,base)
        self.assertEqual(state['effect']['kind'],'fetch')
        state=self.advance(state,True)
        self.assertTrue(state['outcome']['didFetch'])

    def test_manual_binding_survives_unconfigured_fetch_and_search_trimming(self):
        config=dict(mode='bind',configured=False,entityKey=f'movie/{MAX}')
        state=self.invoke('begin',flowID='flow',payloadJSON=json.dumps(config))
        self.assertEqual(state['effect']['arguments']['source'],'manual')
        state=self.advance(state,None); state=self.advance(state,False)
        self.assertFalse(state['outcome']['didFetch'])
        self.assertEqual(self.invoke('policy',operation='searchQuery',query='\u0085 作品\u2000')['query'],'作品')
        self.assertIsNone(self.invoke('policy',operation='searchQuery',query=' \u2000')['query'])

    def test_concurrent_single_flight_claims_and_completion_retirement(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            futures=[pool.submit(self.invoke,'fetch.claim',key=f'movie/{MAX}',language='zh-CN') for _ in range(12)]
            claims=[future.result() for future in futures]
        self.assertEqual(sum(row['owner'] for row in claims),1)
        self.assertEqual(len({row['ticket'] for row in claims}),1)
        ticket=claims[0]['ticket']
        other=self.invoke('fetch.claim',key=f'movie/{MAX}',language='en-US')
        self.assertNotEqual(ticket,other['ticket'])
        self.invoke('fetch.record',ticket=ticket,error=dict(kind='unauthorized'))
        self.assertEqual(self.invoke('failure')['failure']['kind'],'unauthorized')
        self.assertEqual(self.invoke('fetch.claim',key=f'movie/{MAX}',language='zh-CN')['ticket'],ticket)
        self.invoke('fetch.record',ticket=other['ticket'])
        self.invoke('fetch.finish',ticket=ticket)
        self.assertIsNone(self.invoke('failure')['failure'],'Retirement must not overwrite a newer completion')
        self.assertTrue(self.invoke('fetch.claim',key=f'movie/{MAX}',language='zh-CN')['owner'])

    def test_batch_window_out_of_order_completion_classification_and_progress(self):
        items=[self.item() for _ in range(25)]+[self.item('folder'),self.item('boxSet')]
        state=self.invoke('batch.begin',batchID='batch',configured=True,items=items)
        active=list(state['dispatch']); dispatched=list(active)
        self.assertEqual(active,[0,1,2,3])
        while active:
            index=active.pop()
            state=self.invoke('batch.complete',batchID='batch',index=index,outcome='fetched' if index<25 else 'unsupported',seasons=0)
            self.assertEqual(state['progress']['completed'],len(dispatched)-len(active))
            self.assertEqual(state['active'],len(active))
            state=self.invoke('batch.refill',batchID='batch',cancelled=False)
            active+=state['dispatch']; dispatched+=state['dispatch']
            self.assertLessEqual(len(active),4)
        self.assertEqual(sorted(dispatched),list(range(27)))
        self.assertEqual(state['progress']['completed'],27)
        self.assertEqual(state['progress']['enriched'],25)
        self.assertTrue(state['finished'])
        self.assertEqual(self.invoke('stats')['batches'],0)

    def test_batch_pre_cancelled_receipts_stop_refill_and_never_count_unentered_workers(self):
        state=self.invoke('batch.begin',batchID='batch',configured=True,items=[self.item()]*20)
        for index in state['dispatch']:
            self.invoke('batch.complete',batchID='batch',index=index,outcome='notEntered',seasons=0)
            state=self.invoke('batch.refill',batchID='batch',cancelled=True)
            self.assertEqual(state['dispatch'],[])
        self.assertEqual(state['progress']['completed'],0)
        self.assertTrue(state['wasCancelled'])
        self.assertTrue(state['finished'])

    def test_preflight_step_and_receipt_errors_do_not_consume_live_state(self):
        state=self.begin()
        for step,value in [(1,None),(0,self.link('tv/not-number')),(0,self.link('movie/1',confidence=True))]:
            response=self.call('tmdbEnrichment.advance',flowID='flow',step=step,payloadJSON=json.dumps(dict(value=value,cancelled=False)))
            self.assertEqual(response['code'],1002,response)
        state=self.advance(state,None)
        self.assertEqual(state['effect']['kind'],'link')
        self.invoke('close',flowID='flow')
        self.invoke('batch.begin',batchID='batch',configured=True,items=[self.item()])
        for args in [dict(index=2,outcome='fetched',seasons=0),dict(index=0,outcome='fetched',seasons=1),dict(index=0,outcome='fetched',seasons=True)]:
            self.assertEqual(self.call('tmdbEnrichment.batch.complete',batchID='batch',**args)['code'],1002)
        self.invoke('batch.complete',batchID='batch',index=0,outcome='fetched',seasons=0)
        self.assertTrue(self.invoke('batch.refill',batchID='batch',cancelled=False)['finished'])
        self.assertEqual(self.server.records,[])

for name in list(vars(NetworkContract)):
    if name.startswith('test_'): setattr(TmdbEnrichmentContract,name,None)
del NetworkContract
if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)

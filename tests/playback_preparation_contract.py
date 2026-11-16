"""Complete preparation effects and non-consuming/stale receipts through C ABI."""
import ctypes,json,unittest,subprocess,sys
from pathlib import Path
import bangumi_account_contract as fixture

class PreparationContract(unittest.TestCase):
    setUpClass=classmethod(fixture.AccountContract.setUpClass.__func__)
    setUp=fixture.AccountContract.setUp
    tearDown=fixture.AccountContract.tearDown
    success=fixture.AccountContract.success
    def call(self,method,**args):
        pointer=self.ffi.ocp_call(self.core,('playbackPreparation.'+method).encode(),json.dumps(args).encode())
        self.assertTrue(pointer)
        try:return json.loads(ctypes.string_at(pointer))
        finally:self.ffi.ocp_string_free(pointer)
    def item(self,key='leaf',kind='movie',**args):return dict(key=key,id=key,kind=kind,name='原始条目',**args)
    def start(self,item=None,mode='open',resume=12.5):return self.success('start',item=item or self.item(),mode=mode,resumeSeconds=resume)
    def resume(self,step,response=True):return self.success('resume',token=step['token'],sequence=step['sequence'],response=response)
    def fail(self,step,message='原错误',cancelled=False):return self.success('fail',token=step['token'],sequence=step['sequence'],message=message,cancelled=cancelled)
    def test_complete_main_and_alternate_negotiation_keeps_order_and_id_exclusion(self):
        step=self.resume(self.start())
        sources=[dict(key='a',id='a',supportsDirectStream=True),dict(key='b',id='b',supportsDirectPlay=True),dict(key='duplicate',id='b'),dict(key='c',id='c')]
        step=self.resume(step,dict(playSessionId='session',sources=sources));self.assertEqual(step['arguments']['sourceKey'],'b')
        step=self.resume(step,'main');self.assertEqual(step['arguments']['sourceKey'],'a')
        step=self.fail(step);self.assertEqual(step['arguments']['sourceKey'],'c')
        step=self.resume(step,'other');self.assertEqual(step['effect'],'ready');self.assertEqual(step['arguments']['alternates'],[dict(key='c',id='c',uri='other')])
        self.assertEqual(step['arguments']['resumeSeconds'],12.5)
        self.assertEqual(self.success('stats')['active'],1)
        self.assertTrue(self.resume(step)['done']);self.assertEqual(self.success('stats')['active'],0)
    def test_collection_reads_home_after_members_with_full_signed_episode_title(self):
        step=self.start(self.item('box','boxSet'));self.assertFalse(step['arguments']['recursive'])
        step=self.resume(step,[self.item('series','series')]);self.assertEqual(step['effect'],'home')
        episode=self.item('episode','episode',seriesId='series',seriesName='剧名',seasonNumber=9223372036854775807,episodeNumber=9223372036854775807,positionSeconds=1.25)
        step=self.resume(step,dict(nextUp=[episode],resume=[]));self.assertEqual(step['arguments']['title'],'剧名 S9223372036854775807E9223372036854775807');self.assertEqual(step['arguments']['resumeSeconds'],1.25)
    def test_series_prefers_nextup_then_resume_and_filters_specials_in_server_order(self):
        step=self.start(self.item('series','series'),mode='resolve')
        step=self.resume(step,dict(nextUp=[],resume=[]));self.assertEqual(step['effect'],'episodes');self.assertIsNone(step['arguments']['seasonId'])
        step=self.resume(step,[self.item('special','episode',seasonNumber=0),self.item('watched','episode',played=True),self.item('first','episode'),self.item('later','episode')])
        self.assertEqual(step['arguments']['itemKey'],'first')
        self.resume(step)
        step=self.start(self.item('series','series'),mode='resolve')
        step=self.resume(step,dict(nextUp=[self.item('next','episode',seriesId='series')],resume=[self.item('resume','episode',seriesId='series')]))
        self.assertEqual(step['arguments']['itemKey'],'next')
    def test_info_and_primary_failures_use_fallback_and_preserve_original_failure(self):
        for primary in (False,True):
            step=self.resume(self.start())
            if primary:step=self.resume(step,dict(playSessionId='old',sources=[]))
            step=self.fail(step,'最初错误');self.assertEqual(step['effect'],'fallback')
            step=self.resume(step);self.assertIsNone(step['arguments']['playSessionId']);self.assertIsNone(step['arguments']['mediaSourceId'])
            done=self.fail(step,'直连错误');self.assertEqual(done['result']['error'],'播放信息获取失败：最初错误')
            self.assertEqual(self.success('stats')['active'],0)
    def test_invalid_payloads_receipts_and_late_ready_are_nonconsuming_or_retired(self):
        step=self.start();self.assertEqual(self.call('resume',token=step['token'],sequence=step['sequence'],response=False)['code'],1002)
        self.success('validate',token=step['token'],sequence=step['sequence'])
        next=self.resume(step);self.assertEqual(self.call('resume',token=step['token'],sequence=step['sequence'],response=True)['code'],1003)
        for response in [dict(sources='bad'),dict(sources=[dict(key='x',id='a'),dict(key='x',id='b')]),dict(sources=[dict(key='x',id='a',supportsDirectPlay=1)])]:
            self.assertEqual(self.call('resume',token=next['token'],sequence=next['sequence'],response=response)['code'],1002)
            self.success('validate',token=next['token'],sequence=next['sequence'])
        self.success('invalidate');new=self.start(mode='resolve');self.assertGreater(new['token'],step['token'])
        self.assertEqual(self.call('resume',token=next['token'],sequence=next['sequence'],response={})['code'],1003)
        self.assertFalse(self.success('cancel',token=step['token'])['cancelled']);self.assertEqual(self.success('stats')['active'],1)
        self.assertEqual(self.fail(new,cancelled=True)['result']['status'],'cancelled')
    def test_empty_resolution_and_capacity_cleanup_do_not_change_current_flows(self):
        step=self.start(self.item('box','boxSet'));self.assertEqual(self.resume(step,[])['result']['error'],'这个合集里还没有可播放的内容')
        for _ in range(128):self.start(mode='resolve')
        self.assertEqual(self.call('start',item=self.item(),mode='open',resumeSeconds=None)['code'],1002)
        self.assertEqual(self.success('stats')['active'],128);self.success('invalidate');self.assertEqual(self.success('stats')['active'],0)
        for args in [dict(item=self.item(),mode='bad',resumeSeconds=None),dict(item=self.item(),mode='open',resumeSeconds='bad'),dict(item=self.item(kind='episode',episodeNumber=9223372036854775808),mode='open',resumeSeconds=None)]:
            self.assertEqual(self.call('start',**args)['code'],1002)
        self.assertEqual(self.success('stats')['active'],0)
    def test_native_episode_endpoint_full_sort_window_order_and_parameters(self):
        process=subprocess.Popen([sys.executable,'-u',str(Path(__file__).with_name('playback_preparation_server.py'))],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        try:
            port=int(process.stdout.readline());base='http://127.0.0.1:'+str(port)+'/emby'
            for kind in ['jellyfin','emby']:
                profile=dict(id='fixture:u1',kind=kind,baseURL=base,userID='u1',token='fixture-token')
                def call(**args):
                    pointer=self.ffi.ocp_call(self.core,b'browse.episodes',json.dumps(dict(profile=profile,**args)).encode())
                    try:reply=json.loads(ctypes.string_at(pointer))
                    finally:self.ffi.ocp_string_free(pointer)
                    self.assertTrue(reply['ok'],reply);return reply['data']
                self.assertEqual([i['id'] for i in call(seriesId='order',seasonId='season-one')],['special','first','second','maximum','unknown'])
                self.assertEqual([i['id'] for i in call(seriesId='order',startItemId='current',limit=2)],['current','interstitial'])
            from urllib.request import urlopen
            records=json.load(urlopen('http://127.0.0.1:'+str(port)+'/stats'))
            self.assertTrue(all(r['path'].endswith('/Shows/order/Episodes') for r in records))
            self.assertEqual(records[0]['query']['seasonId'],['season-one']);self.assertNotIn('limit',records[0]['query'])
            self.assertEqual(records[1]['query']['startItemId'],['current']);self.assertEqual(records[1]['query']['limit'],['2'])
            self.assertEqual(records[1]['query']['enableImageTypes'],['Primary,Thumb,Logo'])
        finally:
            process.terminate();process.wait();process.stdout.close()
    def test_preferred_source_retains_first_direct_play_stream_and_default(self):
        for sources,index in [([],None),([dict(key='a',id='a')],0),([dict(key='a',id='a',supportsDirectStream=True),dict(key='b',id='b',supportsDirectPlay=True)],1)]:
            self.assertEqual(self.success('preferredSource',sources=sources)['index'],index)

    def test_continuation_window_and_ready_receipts_preserve_server_order(self):
        current=self.item('current','episode',seriesId='series',seasonNumber=1)
        window=self.start(current,mode='next');self.assertEqual(window['effect'],'episodeWindow');self.assertEqual(window['arguments']['limit'],6)
        self.assertEqual(window['arguments']['startItemId'],'current')
        bad=self.call('resume',token=window['token'],sequence=window['sequence'],response=[{'key':'bad'}]);self.assertEqual(bad['code'],1002)
        ready=self.resume(window,[self.item('before','episode'),current,self.item('special','episode',seasonNumber=0),self.item('next','episode',played=True,seasonNumber=9223372036854775807)])
        self.assertEqual(ready['effect'],'ready');self.assertEqual(ready['arguments']['itemKey'],'next')
        self.success('validate',token=ready['token'],sequence=ready['sequence'])
        self.assertTrue(self.resume(ready)['done']);self.assertEqual(self.success('stats')['active'],0)
    def test_continuation_noops_missing_anchor_and_old_cancellation(self):
        for item in [self.item(),self.item('current','episode'),self.item('special','episode',seriesId='series',seasonNumber=0)]:
            self.assertTrue(self.start(item,mode='next')['done']);self.assertEqual(self.success('stats')['active'],0)
        current=self.item('current','episode',seriesId='series')
        for response in [[],[self.item('missing','episode')],[current]]:
            self.assertTrue(self.resume(self.start(current,mode='next'),response)['done'])
        old=self.start(current,mode='next');self.success('invalidate');fresh=self.start(current,mode='next')
        self.assertEqual(self.call('resume',token=old['token'],sequence=old['sequence'],response=[])['code'],1003)
        self.success('cancel',token=old['token']);self.success('validate',token=fresh['token'],sequence=fresh['sequence'])
        self.success('invalidate')
        for index in range(128):self.start(self.item(str(index)),mode='resolve')
        self.assertTrue(self.start(self.item('noop'),mode='next')['done']);self.assertEqual(self.success('stats')['active'],128)
    def test_recovery_plan_matrix_and_invalid_argument_types(self):
        def call(args):
            pointer=self.ffi.ocp_call(self.core,b'playbackFlow.recoveryPlan',json.dumps(args).encode())
            try:return json.loads(ctypes.string_at(pointer))
            finally:self.ffi.ocp_string_free(pointer)
        import itertools
        for mode,loading,playback,request,item,loaded,current,fallback in itertools.product(['manual','background'],[False,True],[False,True],[False,True],[False,True],[False,True],[None,0,1.25,29.999999,30,120.5],[None,80.5]):
            args=dict(mode=mode,loading=loading,hasPlayback=playback,hasRequest=request,hasMediaItem=item,hasLoadedSource=loaded,currentPositionSeconds=current,requestResumeSeconds=fallback)
            if mode=='manual':
                action='none' if loading else 'reprepare' if item else 'retryLast'
                resume=(current if current is not None and current>=30 else fallback) if action=='reprepare' else None
            else:
                action='none' if not(playback and request) else 'reprepare' if item else 'reopen'
                resume=(current if loaded else fallback) if action!='none' else None
            response=call(args);self.assertTrue(response['ok']);self.assertEqual(response['data'],dict(action=action,resumeSeconds=resume))
        valid_args = dict(args)
        for changes in [dict(mode='wrong'),dict(loading='true'),dict(currentPositionSeconds='1'),dict(unknown=1)]:
            args = dict(valid_args, **changes);self.assertEqual(call(args)['code'],1002)

if __name__=='__main__':unittest.main(verbosity=2)

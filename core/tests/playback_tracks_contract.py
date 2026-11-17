"""Track effects, exact IDs and failed/stale receipts through the public ABI."""
import ctypes
import json
import unittest
import bangumi_account_contract as fixture

class TrackContract(unittest.TestCase):
    setUpClass = classmethod(fixture.AccountContract.setUpClass.__func__)
    setUp = fixture.AccountContract.setUp
    tearDown = fixture.AccountContract.tearDown
    def call(self, method, **args):
        pointer = self.ffi.ocp_call(self.core, ('playbackTracks.' + method).encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try: return json.loads(ctypes.string_at(pointer))
        finally: self.ffi.ocp_string_free(pointer)
    success = fixture.AccountContract.success
    def begin(self, operation, **args): return self.success('begin', request=dict(operation=operation, **args))
    def complete(self, step, success=True, **args): return self.success('complete', operationId=step['operationId'], success=success, **args)
    def track(self, id=1, **args): return dict(id=id, kind='subtitle', source='external', selected=False, title='简体', language=None, displayName=None, canRemove=True, **args)
    def test_import_uses_unique_effect_receipts_and_records_name_before_selected_failure(self):
        add=self.begin('importSubtitle', path='/字幕.srt', name='简体')
        self.assertEqual(add['effect'],dict(action='addSubtitle', path='/字幕.srt'))
        self.assertEqual(self.call('complete',operationId=add['operationId'],success=True)['code'],1002)
        selected=self.complete(add,trackId=9223372036854775807)
        self.assertGreater(selected['operationId'],add['operationId'])
        self.assertEqual(selected['effect'],dict(action='selectSubtitle',id=9223372036854775807))
        self.assertEqual(selected['snapshot']['externalNames'],{'9223372036854775807':'简体'})
        self.assertEqual(self.call('complete',operationId=add['operationId'],success=False)['code'],1003)
        self.assertEqual(self.call('complete',operationId=selected['operationId'],success=True,trackId=1)['code'],1002)
        done=self.complete(selected,False)
        self.assertFalse(done['snapshot']['manualChoice']);self.assertIsNone(done['effect'])
        automatic=self.begin('automatic',tracks=[self.track(9223372036854775807)],preference='zh-Hans',current=None)
        self.assertEqual(automatic['effect']['id'],9223372036854775807)
        self.complete(automatic)
    def test_manual_and_removal_commit_only_after_engine_success(self):
        manual=self.begin('selectSubtitle',id=None);self.complete(manual,False)
        self.assertFalse(self.success('snapshot')['manualChoice'])
        self.complete(self.begin('selectSubtitle',id=-9223372036854775808))
        self.success('registerName',id=-9223372036854775808,name='繁體')
        track=self.track(-9223372036854775808);track['selected']=True
        failed=self.begin('removeSubtitle',track=track);self.complete(failed,False)
        self.assertTrue(self.success('snapshot')['manualChoice'])
        self.assertEqual(self.success('snapshot')['externalNames'],{'-9223372036854775808':'繁體'})
        self.complete(self.begin('removeSubtitle',track=track))
        self.assertFalse(self.success('snapshot')['manualChoice']);self.assertEqual(self.success('snapshot')['externalNames'],{})
    def test_reset_retires_old_receipt_and_pending_refresh_does_not_replace_effect(self):
        old=self.begin('selectAudio',id=4);self.success('reset');new=self.begin('selectAudio',id=5)
        self.assertGreater(new['operationId'],old['operationId'])
        ignored=self.begin('automatic',tracks=[self.track()],preference='zh-Hans',current=None)
        self.assertIsNone(ignored['effect']);self.assertEqual(ignored['operationId'],new['operationId'])
        self.assertEqual(self.call('complete',operationId=old['operationId'],success=True)['code'],1003)
        self.complete(new);self.assertIsNone(self.success('snapshot')['pendingOperationId'])
    def test_batches_reject_stale_end_and_suppress_only_automatic_work(self):
        self.success('beginBatch',batchId='old');self.success('beginBatch',batchId='new')
        self.assertEqual(self.call('endBatch',batchId='old')['code'],1003)
        self.assertEqual(self.success('snapshot')['batchId'],'new')
        self.assertIsNone(self.begin('automatic',tracks=[self.track()],preference='zh-Hans',current=None)['effect'])
        self.complete(self.begin('attachSubtitle',path='/sidecar',name='繁體'),trackId=8)
        self.success('endBatch',batchId='new')
        self.assertIsNotNone(self.begin('automatic',tracks=[self.track()],preference='zh-Hans',current=None)['effect'])
    def test_invalid_payloads_and_unremovable_tracks_leave_state_unchanged(self):
        for request in [dict(operation='selectSubtitle',id=1.5),dict(operation='selectAudio',id=9223372036854775808),dict(operation='importSubtitle',path='',name='简体'),dict(operation='automatic',tracks=[self.track(),self.track()],preference='off',current=1),dict(operation='automatic',tracks=[],preference='bad',current=None)]:
            self.assertEqual(self.call('begin',request=request)['code'],1002)
        self.assertIsNone(self.success('snapshot')['pendingOperationId'])
        track=self.track();track['canRemove']=False
        self.assertIsNone(self.begin('removeSubtitle',track=track)['effect'])
        self.assertEqual(self.call('beginBatch',batchId=' ')['code'],1002)
        self.assertIsNone(self.success('snapshot')['batchId'])
    def test_same_numeric_id_in_different_track_kinds_is_valid(self):
        audio=self.track();audio.update(kind='audio',language='eng',title='English')
        tracks=[audio,self.track()]
        self.assertEqual(self.success('selection',tracks=tracks,preference='zh-Hans',current=None),dict(action='select',id=1))
    def test_selection_field_trust_external_default_and_unknown_language(self):
        tracks=[self.track(),self.track(2)];tracks[0].update(source='embedded',title='',language='sc');tracks[1].update(source='embedded',title='中文',language=None)
        self.assertEqual(self.success('selection',tracks=tracks,preference='zh-Hans',current=None),dict(action='select',id=2))
        self.assertEqual(self.success('selection',tracks=[self.track()],preference='followSource',current=None),dict(action='select',id=1))
        self.assertEqual(self.success('selection',tracks=[self.track()],preference='off',current=1),dict(action='disable'))

if __name__=='__main__': unittest.main(verbosity=2)

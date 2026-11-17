"""Retained sync receipts and transactional writes through the exported ABI."""
import ctypes
import json
import os
import unittest


def subject(identifier=1):
    return {'id': identifier, 'name': 'Subject', 'type': 2, 'eps': 3,
            'interest': {'comment': '', 'epStatus': 0, 'volStatus': 0, 'private': False,
                         'rate': 0, 'tags': [], 'type': 3, 'updatedAt': 1}}


def episode(identifier=1, owner=1):
    return {'id': identifier, 'subjectID': owner, 'type': 0, 'sort': 1.0, 'name': 'Episode',
            'nameCN': '', 'duration': '', 'airdate': '', 'comment': 0, 'disc': 0}


class SyncContract(unittest.TestCase):
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
        self.core = self.ffi.ocp_core_create(b'{"bangumiDatabasePath":":memory:"}')
        self.assertTrue(self.core)

    def tearDown(self):
        self.ffi.ocp_core_destroy(self.core)

    def call(self, method, **args):
        pointer = self.ffi.ocp_call(self.core, method.encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try: return json.loads(ctypes.string_at(pointer))
        finally: self.ffi.ocp_string_free(pointer)

    def success(self, method, **args):
        reply = self.call(method, **args)
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def resume(self, step, response):
        return self.success('bangumiSync.resume', token=step['token'], sequence=step['sequence'], response=response)

    def apply(self, step, now=1000):
        return self.success('bangumiSync.apply', token=step['token'], sequence=step['sequence'], now=now)

    def test_collection_writes_are_transactional_and_receipts_cannot_replay(self):
        start = self.success('bangumiSync.start', operation='collections', since=5)
        write = self.resume(start, {'data': [subject()], 'total': 101})
        self.assertEqual(self.call('bangumiSync.resume', token=write['token'], sequence=write['sequence'], response=None)['code'], 1002)
        next_page = self.apply(write)
        self.assertEqual(next_page['arguments']['offset'], 100)
        self.assertEqual(self.call('bangumiSync.apply', token=write['token'], sequence=write['sequence'], now=1000)['code'], 1002)
        done = self.resume(next_page, {'data': [], 'total': 101})
        self.assertEqual(done['result'], 1)
        self.assertEqual(self.success('bangumiStore.subject', subjectId=1)['interest']['type'], 3)
        self.assertEqual(self.success('bangumiSync.stats')['active'], 0)

    def test_complete_episode_pages_preserve_large_identifiers_and_empty_tail(self):
        self.success('bangumiStore.saveSubject', item=subject())
        start = self.success('bangumiSync.start', operation='episodes', subjectId=1, authoritativeCollection=True)
        next_page = self.resume(start, {'data': [episode(2**63-1)], 'total': 2000})
        self.assertEqual(next_page['arguments']['offset'], 1000)
        write = self.resume(next_page, {'data': [], 'total': 2000})
        self.assertTrue(self.apply(write, now=-1)['result'])
        rows = self.success('bangumiStore.episodes', subjectId=1)
        self.assertEqual(rows[0]['id'], 2**63-1)
        start = self.success('bangumiSync.start', operation='episodes', subjectId=1)
        write = self.resume(start, {'data': [], 'total': 0})
        self.apply(write)
        self.assertEqual(self.success('bangumiStore.episodes', subjectId=1), [])

    def test_account_clear_retires_pending_sql_and_does_not_reuse_tokens(self):
        start = self.success('bangumiSync.start', operation='collections')
        write = self.resume(start, {'data': [subject()], 'total': 1})
        before = self.success('bangumiSync.stats')
        self.success('bangumiStore.clearAccountLocalState')
        self.assertEqual(self.call('bangumiSync.apply', token=write['token'], sequence=write['sequence'], now=1000)['code'], 1002)
        self.assertIsNone(self.success('bangumiStore.subject', subjectId=1))
        after = self.success('bangumiSync.stats')
        self.assertEqual(after['epoch'], before['epoch']+1)
        new = self.success('bangumiSync.start', operation='collections')
        self.assertGreater(new['token'], start['token'])
        self.success('bangumiAccount.operation.begin')
        self.assertEqual(self.call('bangumiSync.resume', token=new['token'], sequence=new['sequence'], response={'data': [], 'total': 0})['code'], 1002)
        refreshed = self.success('bangumiSync.start', operation='collections')
        self.success('bangumiAccount.refresh.claim')
        self.success('bangumiAccount.commit', kind='refresh', generation=0)
        self.resume(refreshed, {'data': [], 'total': 0})
        self.success('bangumiSync.start', operation='collections')
        self.success('bangumiAccount.invalidate')
        self.assertEqual(self.success('bangumiSync.stats')['active'], 0)

    def test_batch_slots_slide_and_parent_cancellation_retires_child_writes(self):
        start = self.success('bangumiSync.start', operation='reconcile', maxConcurrent=2)
        batch = self.resume(start, [1, 2, 3])
        self.assertEqual([j['subjectId'] for j in batch['arguments']['jobs']], [1, 2])
        child = self.success('bangumiSync.start', operation='episodes', subjectId=1, parentToken=batch['token'], parentJob=1)
        write = self.resume(child, {'data': [episode()], 'total': 1})
        self.assertEqual(self.call('bangumiSync.batchComplete', token=batch['token'], jobId=1, succeeded=True)['code'], 1002)
        self.apply(write)
        next_step = self.success('bangumiSync.batchComplete', token=batch['token'], jobId=1, succeeded=True)
        self.assertEqual(next_step['arguments']['jobs'][0]['subjectId'], 3)
        self.assertEqual(self.call('bangumiSync.batchComplete', token=batch['token'], jobId=1, succeeded=True)['code'], 1002)
        child = self.success('bangumiSync.start', operation='episodes', subjectId=2, parentToken=batch['token'], parentJob=2)
        write = self.resume(child, {'data': [episode(2, 2)], 'total': 1})
        self.success('bangumiSync.cancel', token=batch['token'])
        self.assertEqual(self.call('bangumiSync.apply', token=write['token'], sequence=write['sequence'], now=1000)['code'], 1002)
        self.assertEqual(self.success('bangumiSync.stats')['active'], 0)

    def test_full_sync_overlap_start_timestamp_and_partial_batch_count(self):
        start = self.success('bangumiSync.start', operation='allCollections', since=500, startedAt=800, maxConcurrent=0)
        self.assertEqual(start['arguments']['since'], 200)
        stamp = self.resume(start, {'data': [], 'total': 0})
        self.assertEqual(stamp['arguments']['value'], 800)
        targets = self.resume(stamp, True)
        batch = self.resume(targets, [1, 2])
        self.assertEqual(len(batch['arguments']['jobs']), 1)
        next_step = self.success('bangumiSync.batchComplete', token=batch['token'], jobId=1, succeeded=False)
        done = self.success('bangumiSync.batchComplete', token=batch['token'], jobId=2, succeeded=True)
        self.assertEqual(done['result'], 0, 'full sync returns collection count, regardless of episode failures')
        self.assertFalse(next_step['done'])
        standalone = self.success('bangumiSync.start', operation='reconcile', maxConcurrent=2)
        batch = self.resume(standalone, [1, 2])
        self.success('bangumiSync.batchComplete', token=batch['token'], jobId=2, succeeded=True)
        done = self.success('bangumiSync.batchComplete', token=batch['token'], jobId=1, succeeded=False)
        self.assertEqual(done['result'], 1, 'standalone reconciliation returns successful subject count')

    def test_invalid_responses_and_failed_sql_leave_the_same_receipt_retryable(self):
        start = self.success('bangumiSync.start', operation='collections')
        bad = self.call('bangumiSync.resume', token=start['token'], sequence=start['sequence'], response={'data': [], 'total': None})
        self.assertEqual(bad['code'], 1002)
        write = self.resume(start, {'data': [{'id': 1}, {'id': 'invalid'}], 'total': 1})
        for _ in range(2):
            reply = self.call('bangumiSync.apply', token=write['token'], sequence=write['sequence'], now=1000)
            self.assertFalse(reply['ok'])
            self.assertIsNone(self.success('bangumiStore.subject', subjectId=1), 'entire page rolled back')
        self.success('bangumiSync.cancel', token=write['token'])


if __name__ == '__main__': unittest.main(verbosity=2)

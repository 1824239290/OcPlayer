"""Retained account state through the exported ABI, including concurrent owners."""
import ctypes
import json
import os
import unittest
from concurrent.futures import ThreadPoolExecutor


class AccountContract(unittest.TestCase):
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
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)

    def tearDown(self):
        self.ffi.ocp_core_destroy(self.core)

    def call(self, method, **args):
        pointer = self.ffi.ocp_call(self.core, ('bangumiAccount.' + method).encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.ffi.ocp_string_free(pointer)

    def success(self, method, **args):
        reply = self.call(method, **args)
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def test_parallel_refresh_has_one_owner_and_old_release_cannot_touch_new_owner(self):
        with ThreadPoolExecutor(max_workers=16) as workers:
            claims = list(workers.map(lambda _: self.success('refresh.claim'), range(64)))
        self.assertEqual(sum(not c['joined'] for c in claims), 1)
        self.assertEqual(len({c['id'] for c in claims}), 1)
        old = claims[0]
        self.success('invalidate')
        new = self.success('refresh.claim')
        self.assertFalse(self.success('refresh.finish', generation=old['id']))
        self.assertTrue(self.success('snapshot')['refreshActive'])
        self.assertFalse(self.success('commit', kind='refresh', generation=old['generation'])['accepted'])
        self.assertEqual(self.success('refresh.failure', kind='cancelled', generation=old['id']), 'stale')
        self.assertEqual(self.success('refresh.failure', kind='cancelled', generation=new['id']), 'timeout')
        self.assertTrue(self.success('refresh.finish', generation=new['id']))

    def test_oauth_latest_exchange_wins_and_callback_is_single_use(self):
        self.success('oauth.prepare', state='first')
        first = self.success('oauth.consume', state='first')
        self.assertTrue(first['accepted'])
        self.assertFalse(self.success('oauth.consume', state='first')['accepted'])
        self.success('oauth.prepare', state='second')
        second = self.success('oauth.consume', state='second')
        self.assertFalse(self.success('commit', kind='oauth', generation=first['generation'])['accepted'])
        self.assertTrue(self.success('commit', kind='oauth', generation=second['generation'])['accepted'])
        self.assertFalse(self.success('commit', kind='oauth', generation=second['generation'])['accepted'])
        self.success('oauth.prepare', state='logout')
        self.success('invalidate')
        self.assertFalse(self.success('oauth.consume', state='logout')['accepted'])

    def test_invalid_arguments_leave_state_unchanged_and_unsigned_values_remain_exact(self):
        before = self.success('snapshot')
        for method, args in [
            ('invalidate', {'generation': -1}), ('invalidate', {'generation': None}),
            ('commit', {'kind': 'oauth', 'generation': 2**64}),
            ('refresh.finish', {'generation': 0.1}), ('oauth.prepare', {'state': ''}),
            ('refresh.failure', {'kind': 'unknown', 'generation': 0}),
        ]:
            self.assertEqual(self.call(method, **args)['code'], 1002)
            self.assertEqual(self.success('snapshot'), before)
        self.assertFalse(self.success('current', generation=2**64-1))
        self.assertFalse(self.success('invalidate', generation=2**64-1)['accepted'])
        self.assertEqual(self.success('snapshot'), before)

    def test_clock_boundary_session_and_profile_adoption(self):
        self.assertEqual(self.success('access', present=False, now=100)['action'], 'missing')
        self.assertEqual(self.success('access', present=True, expiresAt=160, now=100)['action'], 'reuse')
        self.assertEqual(self.success('access', present=True, expiresAt=159.99, now=100)['action'], 'refresh')
        self.assertTrue(self.success('session', present=True, expiresAt=200, now=100, sessionGeneration=0))
        revision = self.success('operation.begin')
        self.success('operation.begin')
        self.assertFalse(self.success('operation.current', generation=revision))
        self.success('invalidate')
        self.assertFalse(self.success('session', present=True, expiresAt=200, now=100, sessionGeneration=0))
        self.assertEqual(self.success('refresh.failure', kind='unauthorized', generation=0), 'stale')

    def test_credential_commit_preserves_refresh_owner_but_oauth_retires_it(self):
        claim = self.success('refresh.claim')
        result = self.success('commit', kind='refresh', generation=claim['generation'])
        self.assertTrue(result['accepted'])
        self.assertFalse(result['cancelRefresh'])
        self.assertTrue(result['cancelRequests'])
        self.assertTrue(result['invalidateSession'])
        self.assertTrue(self.success('snapshot')['refreshActive'])
        self.success('oauth.prepare', state='new-login')
        exchange = self.success('oauth.consume', state='new-login')
        self.assertTrue(self.success('commit', kind='oauth', generation=exchange['generation'])['cancelRefresh'])
        self.assertFalse(self.success('snapshot')['refreshActive'])
        self.assertFalse(self.success('refresh.finish', generation=claim['id']))


if __name__ == '__main__':
    unittest.main(verbosity=2)

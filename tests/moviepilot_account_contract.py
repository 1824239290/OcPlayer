"""Retained MoviePilot account policy through the public C ABI."""
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
        pointer = self.ffi.ocp_call(self.core, ('moviepilotAccount.' + method).encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.ffi.ocp_string_free(pointer)

    def success(self, method, **args):
        reply = self.call(method, **args)
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def claim(self, revision=0, token=True, credentials=True):
        return self.success('refresh.claim', revision=revision, tokenPresent=token, credentialsPresent=credentials)

    def test_concurrent_refresh_has_one_owner_and_late_finish_preserves_new_owner(self):
        with ThreadPoolExecutor(max_workers=16) as workers:
            claims = list(workers.map(lambda _: self.claim(), range(64)))
        self.assertEqual(sum(c['action'] == 'start' for c in claims), 1)
        self.assertEqual(len({c['id'] for c in claims}), 1)
        old = claims[0]
        self.success('invalidate', revision=1)
        new = self.claim(revision=1)
        self.assertFalse(self.success('refresh.finish', id=old['id']))
        self.assertFalse(self.success('refresh.commit', id=old['id'], revision=0)['accepted'])
        self.assertTrue(self.success('refresh.authorize', id=new['id'], revision=1))

    def test_login_requires_exact_committed_revision_and_latest_attempt(self):
        old = self.success('login.begin', revision=1)
        self.assertTrue(self.success('login.authorize', id=old['id'], revision=1))
        self.success('invalidate', revision=3)  # platform commit then sign out
        self.assertFalse(self.success('login.commit', id=old['id'], revision=2, tokenMatches=True)['accepted'])
        new = self.success('login.begin', revision=4)
        self.assertFalse(self.success('login.finish', id=old['id']))
        for revision, matches in [(4, True), (6, True), (5, False)]:
            self.assertFalse(self.success('login.commit', id=new['id'], revision=revision, tokenMatches=matches)['accepted'])
        self.assertTrue(self.success('login.commit', id=new['id'], revision=5, tokenMatches=True)['accepted'])
        self.assertFalse(self.success('login.commit', id=new['id'], revision=5, tokenMatches=True)['accepted'])

    def test_transient_and_cancelled_failures_preserve_token_but_rejection_fuses(self):
        claim = self.claim()
        for kind in ['transient', 'cancelled']:
            reply = self.success('refresh.failure', id=claim['id'], revision=0, kind=kind)
            self.assertTrue(reply['accepted'])
            self.assertFalse(reply['clearToken'])
            self.assertFalse(reply['notify'])
        rejection = self.success('refresh.failure', id=claim['id'], revision=0, kind='rejected')
        self.assertTrue(rejection['clearToken'])
        self.assertTrue(rejection['notify'])
        self.success('refresh.finish', id=claim['id'])
        self.assertEqual(self.claim()['action'], 'fused')
        self.assertTrue(self.claim()['notify'])
        self.assertFalse(self.claim(token=False)['notify'])

    def test_missing_credentials_configuration_changes_and_success_fuse(self):
        missing = self.claim(credentials=False)
        self.assertEqual(missing['action'], 'missing')
        self.assertTrue(missing['clearToken'])
        self.assertFalse(missing['notify'])
        old = self.claim()
        new = self.claim(revision=1)
        self.assertNotEqual(old['id'], new['id'])
        self.assertFalse(self.success('refresh.authorize', id=old['id'], revision=0))
        commit = self.success('refresh.commit', id=new['id'], revision=1)
        self.assertTrue(commit['accepted'])
        self.assertEqual(self.claim(revision=1)['action'], 'join')  # owner cleanup not complete
        self.success('refresh.finish', id=new['id'])
        self.assertEqual(self.claim(revision=1)['action'], 'fused')
        self.assertFalse(self.success('clear.allowed', generation=commit['generation'], revision=0))
        self.assertTrue(self.success('clear.allowed', generation=commit['generation'], revision=1))

    def test_invalid_arguments_and_unsigned_precision_are_transactional(self):
        generation = 2**53 + 7
        self.success('seed', generation=generation, configurationRevision=2**64-1, refreshId=2**64-2)
        self.assertTrue(self.success('current', generation=generation))
        before = self.success('snapshot')
        for method, args in [
            ('invalidate', {'revision': -1}), ('login.begin', {'revision': None}),
            ('refresh.commit', {'id': 0.5, 'revision': 0}),
            ('refresh.failure', {'id': 0, 'revision': 0, 'kind': 'unknown'}),
            ('seed', {'generation': 0, 'configurationRevision': 0, 'refreshId': 0}),
        ]:
            self.assertEqual(self.call(method, **args)['code'], 1002)
            self.assertEqual(self.success('snapshot'), before)
        self.success('invalidate', revision=0)  # refreshID can reach u64::MAX exactly
        before = self.success('snapshot')
        self.assertEqual(self.call('login.begin', revision=1)['code'], 1002)
        self.assertEqual(self.success('snapshot'), before)


if __name__ == '__main__':
    unittest.main()

"""Retained request sequencing and account retirement through the public C ABI."""
import ctypes
import json
import os
import unittest
from concurrent.futures import ThreadPoolExecutor


class FlowContract(unittest.TestCase):
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

    def call(self, command, **args):
        pointer = self.ffi.ocp_call(self.core, command.encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.ffi.ocp_string_free(pointer)

    def success(self, command, **args):
        reply = self.call(command, **args)
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def start(self, kind='raw', method='GET', authorized=True, revision=0, **extra):
        return self.success('moviepilotFlow.start', kind=kind, method=method,
                            authorized=authorized, revision=revision, **extra)

    def resume(self, step, outcome, revision=0, **extra):
        return self.success('moviepilotFlow.resume', token=step['token'], sequence=step['sequence'],
                            revision=revision, outcome=outcome, **extra)

    def test_method_and_override_policy_authentication_replay_and_unauthorized_guard(self):
        for method in ['GET', 'head', 'PUT', 'DELETE', 'OPTIONS', 'TRACE']:
            step = self.start(method=method)
            self.assertEqual(step['effect']['maxAttempts'], 3)
        for method in ['POST', 'PATCH']:
            step = self.start(method=method)
            self.assertEqual(step['effect']['maxAttempts'], 1)
            step = self.resume(step, 'unauthorized')
            step = self.resume(step, 'ready', tokenChanged=True)
            self.assertTrue(step['effect']['replay'])
            self.assertTrue(self.resume(step, 'unauthorized')['done'])
        self.assertEqual(self.start(method='POST', idempotent=True)['effect']['maxAttempts'], 3)
        self.assertEqual(self.start(idempotent=False)['effect']['maxAttempts'], 1)
        step = self.start(authorized=False)
        self.assertFalse(self.resume(step, 'unauthorized')['success'])

    def test_retry_backoff_sequence_and_one_auth_replay_per_attempt(self):
        step = self.start()
        for attempt, base in [(1, 1), (2, 2)]:
            step = self.resume(step, 'unauthorized')
            step = self.resume(step, 'ready', tokenChanged=True)
            self.assertTrue(step['effect']['replay'])
            step = self.resume(step, 'retryable')
            self.assertEqual(step['effect'], {'kind': 'sleep', 'baseSeconds': base,
                                            'minimumSeconds': base * 0.5, 'maximumSeconds': base * 1.5,
                                            'attempt': attempt, 'maxAttempts': 3})
            step = self.resume(step, 'ready')
            self.assertFalse(step['effect']['replay'])
        self.assertFalse(self.resume(step, 'retryable')['success'])
        self.assertEqual(self.success('moviepilotFlow.stats')['active'], 0)

    def test_failed_refresh_is_terminal_even_when_raw_read_has_retry_budget(self):
        for outcome in ['unauthorized', 'retryable', 'fatal']:
            step = self.start()
            step = self.resume(step, 'unauthorized')
            step = self.resume(step, 'ready', tokenChanged=False)
            self.assertEqual(step['effect']['kind'], 'refresh')
            self.assertFalse(self.resume(step, outcome)['success'])
        step = self.start()
        step = self.resume(step, 'unauthorized')
        step = self.resume(step, 'ready', tokenChanged=False)
        step = self.resume(step, 'success')
        self.assertTrue(step['effect']['replay'])
        self.assertFalse(self.resume(step, 'unauthorized')['success'])

    def test_named_transport_keeps_its_own_transient_retry_owner(self):
        step = self.start(kind='named')
        self.assertFalse(self.resume(step, 'retryable')['success'])
        step = self.start(kind='named')
        step = self.resume(step, 'unauthorized')
        step = self.resume(step, 'ready', tokenChanged=True)
        self.assertTrue(self.resume(step, 'success')['success'])

    def test_receipt_validation_and_cancellation_do_not_advance_other_flows(self):
        step = self.start(revision=2**64-1)
        for changes in [{'sequence': 1}, {'outcome': 'ready'}, {'sequence': -1}, {'token': 2**64}, {'outcome': 'unknown'}]:
            args = dict(token=step['token'], sequence=0, revision=2**64-1, outcome='success') | changes
            self.assertEqual(self.call('moviepilotFlow.resume', **args)['code'], 1002)
        self.assertTrue(self.resume(step, 'success', revision=2**64-1)['success'])
        self.assertEqual(self.call('moviepilotFlow.resume', token=step['token'], sequence=1,
                                   revision=2**64-1, outcome='success')['code'], 1003)
        old = self.start()
        new = self.start()
        self.success('moviepilotFlow.cancel', token=old['token'])
        self.assertFalse(self.success('moviepilotFlow.cancel', token=old['token'])['cancelled'])
        self.assertTrue(self.resume(new, 'success')['success'])
        changed = self.start()
        self.assertEqual(self.call('moviepilotFlow.resume', token=changed['token'], sequence=0,
                                   revision=1, outcome='success')['code'], 1003)
        self.assertEqual(self.success('moviepilotFlow.stats')['active'], 0)

    def test_account_begin_logout_commit_and_transparent_refresh_retire_correct_revisions(self):
        old = self.start()
        claim = self.success('moviepilotAccount.login.begin', revision=1)
        self.assertEqual(self.call('moviepilotFlow.resume', token=old['token'], sequence=0, revision=0, outcome='success')['code'], 1003)
        old_config = self.start(revision=1)
        new_config = self.start(revision=2)
        self.assertTrue(self.success('moviepilotAccount.login.commit', id=claim['id'], revision=2, tokenMatches=True)['accepted'])
        self.assertEqual(self.call('moviepilotFlow.resume', token=old_config['token'], sequence=0, revision=1, outcome='success')['code'], 1003)
        refresh = self.success('moviepilotAccount.refresh.claim', revision=2, tokenPresent=True, credentialsPresent=True)
        self.assertTrue(self.success('moviepilotAccount.refresh.commit', id=refresh['id'], revision=2)['accepted'])
        self.assertTrue(self.resume(new_config, 'success', revision=2)['success'])
        pending = self.start(revision=2)
        self.success('moviepilotAccount.invalidate', revision=3)
        self.assertEqual(self.call('moviepilotFlow.resume', token=pending['token'], sequence=0, revision=2, outcome='success')['code'], 1003)

    def test_concurrent_identifiers_and_directory_bound_are_retained(self):
        with ThreadPoolExecutor(max_workers=16) as workers:
            steps = list(workers.map(lambda _: self.start(), range(64)))
        self.assertEqual(len({step['token'] for step in steps}), 64)
        for _ in range(960):
            self.start()
        self.assertEqual(self.success('moviepilotFlow.stats')['active'], 1024)
        self.assertEqual(self.call('moviepilotFlow.start', kind='raw', method='GET', authorized=True, revision=0)['code'], 1002)
        self.success('moviepilotAccount.invalidate', revision=1)
        self.assertEqual(self.success('moviepilotFlow.stats')['active'], 0)
        self.assertGreater(self.start()['token'], max(step['token'] for step in steps))


if __name__ == '__main__':
    unittest.main()

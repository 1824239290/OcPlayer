"""Direct public C ABI authentication and Quick Connect acceptance fixtures."""
import concurrent.futures
import json
import threading
import time
import unittest
from fixtures.media_login_server import Server
import network_contract as network

class MediaLoginContract(unittest.TestCase):
    setUpClass = classmethod(network.NetworkContract.setUpClass.__func__)
    call = network.NetworkContract.call
    success = network.NetworkContract.success

    def setUp(self):
        self.server = Server()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)
    def tearDown(self):
        self.ffi.ocp_core_destroy(self.core)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
    def profile(self, scenario='jellyfin', kind='jellyfin'):
        return {'id':'login','kind':kind,'baseURL':self.base+'/'+scenario,
            'authorizationHeader':('Emby' if kind == 'emby' else 'MediaBrowser')+' Client="OcPlayer", Device="fixture", DeviceId="stable", Version="1"',
            'userAgent':'custom/1'}
    def login(self, name='fixture', **args):
        return self.call('server.login', profile=args.pop('profile', self.profile()), username=name, password='p &中', **args)
    def wait(self, secret, **args):
        return self.call('server.quickConnect.wait', profile=self.profile(), secret=secret,
                         pollInterval=0.01, **args)

    def test_login_both_products_identity_prefix_and_pool(self):
        for kind, scenario in [('jellyfin','proxy/jellyfin'),('emby','proxy/emby')]:
            profile = self.profile(scenario, kind)
            self.success('server.probe', profile=profile)
            value = self.login('中 &', profile=profile)
            self.assertTrue(value['ok'], value)
            self.assertEqual(value['data'], {'token':'token','userId':'u1','userName':'fixture','primaryImageTag':'avatar'})
        records = self.server.records
        self.assertEqual(len(set(r['port'] for r in records)), 1)
        for record in records:
            self.assertEqual(record['authorization'], record['embyAuthorization'])
            self.assertIn('DeviceId="stable"', record['authorization'])
            self.assertEqual(record['agent'], 'custom/1')
            self.assertEqual(record['accept'], 'application/json')
        self.assertEqual(records[-1]['path'], '/proxy/emby/Users/AuthenticateByName')
        self.assertEqual(records[-1]['body'], {'Username':'中 &', 'Pw':'p &中'})

    def test_probe_preserves_native_transient_retry(self):
        info = self.success('server.probe', profile=self.profile('retryprobe'))
        self.assertEqual(info['id'], 'server-1')
        self.assertEqual(len(self.server.records), 3)

    def test_login_tolerates_optional_types_but_requires_credentials(self):
        good = self.login('optionalTypes')
        self.assertTrue(good['ok'], good)
        self.assertIsNone(good['data']['userName'])
        self.assertIsNone(good['data']['primaryImageTag'])
        for name in ['invalidJSON','missingToken','wrongToken','missingID']:
            response = self.login(name)
            self.assertFalse(response['ok'], response)
            self.assertEqual(response['code'], 2001)
            self.assertFalse(response['retryable'])

    def test_auth_status_and_mutation_non_replay(self):
        for status, code in [(400,2001),(401,2001),(403,2003),(410,2010),(411,2011),(503,2103)]:
            before = len(self.server.records)
            response = self.login('status'+str(status))
            self.assertFalse(response['ok'])
            self.assertEqual(response['code'], code, response)
            self.assertEqual(len(self.server.records)-before, 1)

    def test_quick_connect_round_trip_and_query_escaping(self):
        profile = self.profile('qc')
        initial = self.success('server.quickConnect.initiate', profile=profile)
        self.assertEqual(initial['code'], '123456')
        self.assertEqual(initial['secret'], 'qc ?&中')
        value = self.wait(initial['secret'])
        self.assertTrue(value['ok'], value)
        secret = value['data']['secret']
        self.assertEqual(secret, 'authorized qc ?&中')
        login = self.success('server.loginQuickConnect', profile=profile, secret=secret)
        self.assertEqual(login['token'], 'token')
        self.assertEqual(self.server.records[-1]['body'], {'Secret':secret})
        self.assertEqual(self.server.polls[initial['secret']], 3)
        self.assertIn('secret=qc+%3F%26%E4%B8%AD', self.server.records[1]['path'])

    def test_quick_connect_failure_budget_resets_on_success(self):
        result = self.wait('reset', failureTolerance=1, maxPolls=4)
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.server.polls['reset'], 4)
        failed = self.wait('exhaust', failureTolerance=1)
        self.assertEqual(failed['code'], 2103)
        self.assertEqual(self.server.polls['exhaust'], 2, 'each poll must send exactly one request')
        recovered = self.wait('retry', failureTolerance=2)
        self.assertTrue(recovered['ok'], recovered)
        self.assertEqual(self.server.polls['retry'], 3)

    def test_quick_connect_disabled_missing_and_timeout(self):
        for method, args in [('server.quickConnect.initiate', {}), ('server.quickConnect.state', {'secret':'disabled'}),
                             ('server.quickConnect.wait', {'secret':'disabled'})]:
            response = self.call(method, profile=self.profile('disabled'), **args)
            self.assertEqual(response['code'], 2401, response)
        missing = self.call('server.quickConnect.initiate', profile=self.profile('missing'))
        self.assertFalse(missing['ok'])
        timeout = self.wait('timeout', maxPolls=2)
        self.assertEqual(timeout['code'], 2402)
        self.assertEqual(self.server.polls['timeout'], 2)
        before = len(self.server.records)
        for method in ['server.quickConnect.initiate','server.quickConnect.state','server.quickConnect.wait','server.loginQuickConnect']:
            response = self.call(method, profile=self.profile('emby','emby'), secret='x')
            self.assertEqual(response['code'], 2401, response)
        self.assertEqual(len(self.server.records), before)

    def test_invalid_arguments_fail_before_network(self):
        for args in [{'secret':''},{'secret':5},{'secret':'x','pollInterval':0},{'secret':'x','pollInterval':61},
                     {'secret':'x','maxPolls':0},{'secret':'x','maxPolls':1.5},{'secret':'x','maxPolls':1001},
                     {'secret':'x','failureTolerance':-1},{'secret':'x','failureTolerance':101}]:
            response = self.call('server.quickConnect.wait', profile=self.profile(), **args)
            self.assertEqual(response['code'], 1002, response)
        self.assertEqual(self.server.records, [])

    def test_cancel_interrupts_poll_sleep_and_inflight_login(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            f = pool.submit(self.wait, 'timeout-cancel', requestId='qc-cancel')
            deadline = time.monotonic()+2
            while not self.server.polls and time.monotonic()<deadline: time.sleep(0.005)
            self.success('request.cancel', requestId='qc-cancel')
            self.assertEqual(f.result(timeout=0.3)['code'], 1003)
            n = len(self.server.records)
            time.sleep(0.04)
            self.assertEqual(len(self.server.records), n)
            f = pool.submit(self.login, 'slow', requestId='login-cancel')
            deadline = time.monotonic()+2
            while len(self.server.records)==n and time.monotonic()<deadline: time.sleep(0.005)
            self.success('request.cancel', requestId='login-cancel')
            self.assertEqual(f.result(timeout=0.3)['code'], 1003)

    def test_concurrent_pairings_cancel_independently(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            a = pool.submit(self.wait, 'timeout-a', requestId='a')
            b = pool.submit(self.wait, 'good-b', requestId='b')
            deadline = time.monotonic()+2
            while 'timeout-a' not in self.server.polls and time.monotonic()<deadline: time.sleep(0.005)
            self.success('request.cancel', requestId='a')
            self.assertEqual(a.result(timeout=1)['code'], 1003)
            self.assertTrue(b.result(timeout=1)['ok'])

if __name__ == '__main__':
    unittest.main()

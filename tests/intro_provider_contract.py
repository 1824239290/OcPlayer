"""Real HTTP tests through the exported Core ABI, including cancellation."""
import base64
import concurrent.futures
import json
import threading
import time
from http.server import ThreadingHTTPServer
from intro_provider_server import Handler
from network_contract import NetworkContract


class IntroProviderContract(NetworkContract):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.records = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)

    def raw(self, provider='aniSkip', prefix='', **args):
        path = {'aniSkip': '/v2/skip-times/42/1', 'animeSkip': '/graphql',
                'theIntroDB': '/v3/media', 'aniList': '/'}[provider]
        return self.call('introProvider.exchange', provider=provider,
            baseURL=self.base + prefix, url=self.base + prefix + path,
            httpMethod=args.pop('httpMethod', 'POST' if provider in ('animeSkip', 'aniList') else 'GET'),
            headers={'Accept': 'application/json', 'User-Agent': 'fixture'}, **args)

    def typed(self, method, **args):
        return self.call('introProvider.' + method, baseURL=self.base, **args)

    def value(self, response):
        self.assertTrue(response['ok'], response)
        return json.loads(response['data']['payloadJSON'])

    def test_typed_requests_intervals_and_full_int64_variables(self):
        result = self.typed('aniskip', malID=42, episodeNumber=1, episodeLengthSeconds=-10)
        self.assertEqual(self.value(result)[0], dict(type='op', startSeconds=638.0, endSeconds=728.0))
        query = self.server.records[-1]['path']
        self.assertIn('types=op&types=ed&types=mixed-op&types=mixed-ed&episodeLength=0', query)
        result = self.typed('animeSkip', anilistID=9223372036854775807, seasonNumber=2, episodeNumber=1, clientID='fixture-key')
        self.assertEqual(self.value(result), dict(startSeconds=30.0, endSeconds=100.0))
        record = self.server.records[-1]
        self.assertEqual(record['clientID'], 'fixture-key')
        self.assertEqual(json.loads(record['body'])['variables'], {'id': '9223372036854775807', 'service': 'ANILIST'})
        self.assertEqual(self.value(self.typed('theIntroDB', tmdbID=42, episodeNumber=1)), dict(startSeconds=0.0, endSeconds=90.0))
        self.assertIsNone(self.value(self.typed('theIntroDB', tmdbID=99, episodeNumber=1)))
        self.assertEqual(len({r['port'] for r in self.server.records}), 1)

    def test_native_status_semantics_and_no_http_retries(self):
        self.assertIsNone(self.value(self.typed('aniskip', malID=404, episodeNumber=1)))
        for method, args in [('aniskip', dict(malID=503)), ('animeSkip', dict(anilistID=503)),
                             ('theIntroDB', dict(tmdbID=404)), ('theIntroDB', dict(tmdbID=503))]:
            status = next(iter(args.values()))
            result = self.typed(method, episodeNumber=1, **args)
            self.assertEqual(result['code'], 1600 + status, result)
            self.assertFalse(result['retryable'])
        self.assertEqual(len(self.server.records), 5)

    def test_raw_status_binary_and_anilist_pool(self):
        for status in (401, 403, 404, 429, 500, 502, 503, 504):
            response = self.raw(prefix=f'/status{status}')
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['data']['status'], status)
            self.assertEqual(response['data']['headers']['retry-after'], '0.01')
        response = self.raw(prefix='/binary')
        self.assertEqual(base64.b64decode(response['data']['bodyBase64']), bytes([0, 255, 128, 10]))
        body = base64.b64encode(b'{"query":"query ($id: Int) { Media(id: $id) { id idMal } }","variables":{"id":"42"}}').decode()
        response = self.raw('aniList', bodyBase64=body)
        self.assertTrue(response['ok'], response)
        self.assertEqual(json.loads(base64.b64decode(response['data']['bodyBase64']))['data']['Media']['idMal'], 100000)
        self.assertEqual(len({r['port'] for r in self.server.records}), 1)
        self.assertEqual(len(self.server.records), 10)

    def test_invalid_requests_never_issue_io(self):
        for args in [dict(timeoutSeconds=0), dict(timeoutSeconds=301), dict(timeoutSeconds='1'),
                     dict(bodyBase64='!'), dict(bodyBase64='AA=='), dict(httpMethod='DELETE')]:
            self.assertEqual(self.raw(**args)['code'], 1002)
        for url in [self.base + '/v2/skip-times/0/1', self.base + '/v2/skip-times/42/1#frag',
                    'http://localhost:1/v2/skip-times/42/1', self.base + '/v1/match']:
            r = self.call('introProvider.exchange', provider='aniSkip', baseURL=self.base,
                          url=url, httpMethod='GET')
            self.assertEqual(r['code'], 1002, r)
        self.assertEqual(self.typed('aniskip', malID=0, episodeNumber=1)['code'], 1002)
        self.assertEqual(self.server.records, [])

    def test_decode_unicode_duplicates_bad_bytes_and_whole_array(self):
        raw = '{"found":true,"found":false,"results":[{"skipType":"op","interval":{"startTime":0,"endTime":90}}]}'
        for encoding in ('utf-8', 'utf-8-sig', 'utf-16', 'utf-16-le', 'utf-16-be', 'utf-32-le', 'utf-32-be'):
            r = self.call('introProvider.decodeAniSkip', responseBase64=base64.b64encode(raw.encode(encoding)).decode())
            self.assertEqual(self.value(r)[0]['endSeconds'], 90)
        for raw in [b'{', b'{"found":false,"results":[{}]}', b'{"found":true,"results":[{"skipType":"\xff","interval":{"startTime":0,"endTime":90}}]}']:
            r = self.call('introProvider.decodeAniSkip', responseBase64=base64.b64encode(raw).decode())
            self.assertEqual(r['code'], 1502, r)
        r = self.call('introProvider.decodeAniSkip', responseBase64=base64.b64encode(b'{"found":true,"bad":"\xff"}').decode())
        self.assertEqual(self.value(r), [])
        r = self.call('introProvider.decodeAniSkip', responseBase64=base64.b64encode('{"found":true}'.encode('utf-32')).decode())
        self.assertEqual(r['code'], 1502, r)
        r = self.call('introProvider.decodeTheIntroDB', responseJSON='{"intro":[{"start_ms":0.0,"end_ms":90000.0}]}')
        self.assertEqual(self.value(r)['endSeconds'], 90)

    def test_timeout_and_cancel_interrupt_once(self):
        self.assertEqual(self.raw(prefix='/slow', timeoutSeconds=.05)['code'], 1503)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.raw, prefix='/slow', requestId='intro-cancel')
            deadline = time.monotonic() + 2
            while len(self.server.records) < 2 and time.monotonic() < deadline:
                time.sleep(.005)
            self.success('request.cancel', requestId='intro-cancel')
            self.assertEqual(future.result(timeout=.3)['code'], 1003)
        self.assertEqual(len(self.server.records), 2)


for name in list(vars(NetworkContract)):
    if name.startswith('test_'):
        setattr(IntroProviderContract, name, None)
del NetworkContract
if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)

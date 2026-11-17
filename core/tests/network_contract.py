"""Public ABI fixtures proving connection lifetime, cookie isolation and SSE.

The HTTP/1.1 server records the actual client TCP port, not constructor counts.
Every test has its own server and Core. No remote service or credentials needed.
"""
import concurrent.futures
import ctypes
import json
import os
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def record(self):
        self.server.records.append({'path': self.path, 'port': self.client_address[1],
            'authorization': self.headers.get('Authorization', ''),
            'cookie': self.headers.get('Cookie', ''), 'agent': self.headers.get('User-Agent', '')})

    def respond(self, value, status=200, headers=None):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for key, val in (headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.record()
        path = urlsplit(self.path).path
        query = parse_qs(urlsplit(self.path).query)
        if path.endswith('/System/Info/Public'):
            return self.respond({'Id': 'fixture', 'ServerName': 'fixture', 'ProductName': 'Jellyfin', 'Version': '1'})
        if path.endswith('/search/movie'):
            return self.respond({'page': 1, 'results': [], 'total_pages': 0, 'total_results': 0})
        if path.endswith('/user/current'):
            token = self.headers.get('Authorization', '').removeprefix('Bearer ') or 'anonymous'
            return self.respond({'name': token}, headers={'Set-Cookie': f'MoviePilot={token}; Path=/'})
        if path.endswith('/media/search'):
            return self.respond([{'title': query.get('title', [''])[0]}])
        if path.endswith('/search/title/stream'):
            token = self.headers.get('Authorization', '').removeprefix('Bearer ')
            if f'MoviePilot={token}' not in self.headers.get('Cookie', ''):
                return self.respond({'message': 'account cookie missing'}, 401)
            keyword = query['keyword'][0]
            events = [b'data: ' + json.dumps({'type': 'append', 'text': keyword,
                'items': [{'torrent_info': {'enclosure': keyword}}]}).encode() + b'\n\n']
            if keyword == 'long':
                events += [b': heartbeat\n\n'] * 32
            events += [b'data: {"type":"done","text":"done"}\n\n']
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(sum(map(len, events))))
            self.end_headers()
            try:
                for i, frame in enumerate(events):
                    self.wfile.write(frame)
                    self.wfile.flush()
                    if i + 1 < len(events):
                        time.sleep(1 if keyword == 'long' else 0.4)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == '/slow':
            time.sleep(2)
        return self.respond({'unknown': [0, False]})

    def do_POST(self):
        self.record()
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path.endswith('/login/access-token'):
            return self.respond({'access_token': 'issued'}, headers={'Set-Cookie': 'Login=issued; Path=/'})
        if self.path.endswith('/v1/match'):
            return self.respond({'success': True, 'matches': []})
        return self.respond({'message': 'applied but failed response'}, 503)


class NetworkContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffi = ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
        cls.ffi.ocp_core_create.argtypes = [ctypes.c_char_p]
        cls.ffi.ocp_core_create.restype = ctypes.c_void_p
        cls.ffi.ocp_core_destroy.argtypes = [ctypes.c_void_p]
        cls.ffi.ocp_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        cls.ffi.ocp_call.restype = ctypes.c_void_p
        cls.ffi.ocp_string_free.argtypes = [ctypes.c_void_p]
        cls.ffi.ocp_poll_event.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        cls.ffi.ocp_poll_event.restype = ctypes.c_int

    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.records = []
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

    def call(self, method, **args):
        pointer = self.ffi.ocp_call(self.core, method.encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.ffi.ocp_string_free(pointer)

    def success(self, method, **args):
        result = self.call(method, **args)
        self.assertTrue(result['ok'], result)
        return result['data']

    def media(self, token='a', base=None):
        return self.success('moviepilot.mediaSearch', baseURL=base or self.base, accessToken=token, title='fixture')

    def poll(self):
        events = []
        while True:
            pointer = ctypes.c_void_p()
            status = self.ffi.ocp_poll_event(self.core, ctypes.byref(pointer))
            self.assertGreaterEqual(status, 0)
            if status == 0:
                return events
            try:
                events.append(json.loads(ctypes.string_at(pointer)))
            finally:
                self.ffi.ocp_string_free(pointer)

    def test_standard_domains_and_probe_share_connection_without_header_leaks(self):
        self.success('endpoint.probe', url=self.base)
        self.success('bangumi.request', url=self.base + '/raw', headers={'Authorization': 'Bearer bangumi', 'User-Agent': 'bgm-fixture'})
        self.success('tmdb.search', apiBase=self.base, apiKey='tmdb-fixture', query='fixture')
        self.success('danmaku.load', gateway={'base_url': self.base, 'api_key': 'danmaku', 'user_agent': 'danmaku-fixture'},
                     matchRequest={'fileHash': 'a' * 32, 'matchMode': 'hashOnly'})
        self.success('server.probe', profile={'id': 'fixture', 'kind': 'jellyfin', 'baseURL': self.base,
                                              'authorizationHeader': 'server-fixture', 'userAgent': 'jf-fixture'})
        records = self.server.records
        self.assertEqual(len(records), 5)
        self.assertEqual(len({r['port'] for r in records}), 1, records)
        self.assertEqual(records[0]['authorization'], '')
        self.assertEqual(records[1]['authorization'], 'Bearer bangumi')
        self.assertEqual(records[2]['authorization'], '')
        self.assertEqual(records[3]['agent'], 'danmaku-fixture')
        self.assertEqual(records[4]['authorization'], 'server-fixture')
        self.assertTrue(all(r['cookie'] == '' for r in records))

    def test_moviepilot_reuses_connections_and_isolates_tokens_hosts_and_domains(self):
        self.success('moviepilot.currentUser', baseURL=self.base, accessToken='a')
        self.media('a', self.base + '/')
        self.media('a')
        self.media('b')
        self.media('a', self.base + '/other')
        self.success('bangumi.request', url=self.base + '/raw')
        records = self.server.records
        self.assertEqual(len({r['port'] for r in records[:3]}), 1)
        self.assertTrue(all(r['agent'] == 'OcPlayer/0.1 (MoviePilotKit)' for r in records[:3]))
        self.assertEqual(records[1]['cookie'], 'MoviePilot=a')
        self.assertTrue(all(r['cookie'] == '' for r in records[3:]), records)
        self.assertEqual(len({r['port'] for r in records[2:]}), 4)

    def test_login_publishes_cookie_only_under_issued_token_and_clear_retires_it(self):
        result = self.success('moviepilot.login', baseURL=self.base, username='fixture', password='fixture')
        self.assertEqual(result['accessToken'], 'issued')
        self.media('issued')
        self.media(None)
        records = list(self.server.records)
        self.assertEqual(len({r['port'] for r in records[:3]}), 1)
        self.assertIn('Login=issued', records[2]['cookie'])
        self.assertIn('MoviePilot=issued', records[2]['cookie'])
        self.assertEqual(records[3]['cookie'], '')
        self.success('moviepilot.clearSessions')
        self.media('issued')
        self.assertEqual(self.server.records[-1]['cookie'], '')
        self.assertNotEqual(self.server.records[-1]['port'], records[2]['port'])

    def test_cookie_cache_is_bounded_and_eviction_never_reuses_old_cookie(self):
        self.success('moviepilot.currentUser', baseURL=self.base, accessToken='first-secret')
        first = self.server.records[-1]['port']
        for i in range(16):
            self.media(f'secret-{i}')
        diagnostics = self.success('diag.snapshot')
        self.assertEqual(diagnostics['core']['network']['moviepilotSessions'], 16)
        self.assertNotIn('secret', json.dumps(diagnostics))
        self.media('first-secret')
        self.assertEqual(self.server.records[-1]['cookie'], '')
        self.assertNotEqual(self.server.records[-1]['port'], first)

    def test_cancelled_request_does_not_block_shared_executor_or_other_requests(self):
        self.success('request.prepare', requestId='slow')
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending = pool.submit(self.call, 'bangumi.request', url=self.base + '/slow', requestId='slow')
            deadline = time.monotonic() + 1
            while not self.server.records and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertTrue(self.server.records)
            self.success('endpoint.probe', url=self.base)
            start = time.monotonic()
            self.success('request.cancel', requestId='slow')
            self.assertEqual(pending.result(timeout=1)['code'], 1003)
            self.assertLess(time.monotonic() - start, 0.5)
        self.success('bangumi.request', url=self.base + '/raw', requestId='slow')

    def test_concurrent_search_events_keep_request_identity_and_account_cookie(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            a = pool.submit(self.success, 'moviepilot.torrentSearch', baseURL=self.base, accessToken='a', keyword='first', requestId='a')
            b = pool.submit(self.success, 'moviepilot.torrentSearch', baseURL=self.base, accessToken='b', keyword='second', requestId='b')
            observed = {}
            while not a.done() or not b.done():
                for event in self.poll():
                    if event['kind'] == 'moviepilot.searchProgress' and event['data']['progress']['text'] in ('first', 'second'):
                        observed[event['data']['requestId']] = event['data']['progress']['text']
                time.sleep(0.01)
            self.assertEqual(observed, {'a': 'first', 'b': 'second'})
            self.assertEqual(a.result()['items'][0]['torrent']['enclosure'], 'first')
            self.assertEqual(b.result()['items'][0]['torrent']['enclosure'], 'second')
        streams = [r for r in self.server.records if '/stream' in r['path']]
        self.assertEqual({r['cookie'] for r in streams}, {'MoviePilot=a', 'MoviePilot=b'})

    def test_sse_heartbeats_keep_search_alive_beyond_normal_request_deadline(self):
        start = time.monotonic()
        result = self.success('moviepilot.torrentSearch', baseURL=self.base, accessToken='long-token', keyword='long')
        self.assertGreater(time.monotonic() - start, 30)
        self.assertEqual(result['items'][0]['torrent']['enclosure'], 'long')


if __name__ == '__main__':
    unittest.main()

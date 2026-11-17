"""MoviePilot authentication/raw and mutation wire coverage through the C ABI."""
import base64
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
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.server.records.append({'method': self.command, 'path': self.path, 'body': body,
            'authorization': self.headers.get('Authorization'), 'cookie': self.headers.get('Cookie', ''),
            'contentType': self.headers.get('Content-Type'), 'port': self.client_address[1]})
        return body

    def respond(self, value=None, status=200, headers=None, raw=None):
        body = raw if raw is not None else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.record()
        path = urlsplit(self.path).path
        if path.endswith('/user/current'):
            if self.headers.get('Authorization') == 'Bearer bad-user':
                return self.respond({'id': 1})
            return self.respond({'name': 'fixture', 'is_superuser': True})
        if path.endswith('/raw/slow'):
            time.sleep(0.4)
        if '/raw/' in path:
            status = int(parse_qs(urlsplit(self.path).query).get('status', ['200'])[0])
            return self.respond(status=status, raw=bytes(range(256)) * 100,
                                headers={'Content-Type': 'application/octet-stream', 'X-Result': 'fixture'})
        if path.endswith('/site/'):
            return self.respond([{'id': 1, 'enabled': False, 'unknown': {'zero': 0}}])
        if path.endswith('/download/') or path.endswith('/subscribe/'):
            return self.respond({'success': True, 'data': [{'id': 1, 'state': False, 'raw': [0, False]}]})
        if path.endswith('/media/search'):
            return self.respond([{'title': 'fixture', 'tmdb_id': 1}])
        return self.respond({'success': True, 'data': None})

    def do_POST(self):
        body = self.record()
        if self.path.endswith('/login/access-token'):
            form = parse_qs(body.decode())
            if form['username'] == ['malformed']:
                return self.respond({'access_token': False})
            if form['username'] == ['reject']:
                return self.respond({'detail': 'wrong password'}, 400)
            if form['username'] == ['retry']:
                attempts = sum(r['path'] == self.path for r in self.server.records)
                if attempts < 3:
                    return self.respond({'detail': 'gateway busy'}, 503)
            return self.respond({'access_token': 'bad-user' if form['username'] == ['baduser'] else 'issued'}, headers={'Set-Cookie': 'Login=issued; Path=/'})
        if '/raw/' in self.path:
            return self.respond(status=503, raw=body, headers={'X-Result': 'creation-not-replayed'})
        return self.respond({'success': True, 'data': None})

    def do_PUT(self):
        self.record()
        self.respond({'success': True})

    def do_DELETE(self):
        self.record()
        self.respond(status=204, raw=b'')


class MoviePilotContract(unittest.TestCase):
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
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.records = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}/mirror'
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)

    def tearDown(self):
        self.ffi.ocp_core_destroy(self.core)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def call(self, method, **args):
        args.setdefault('baseURL', self.base)
        args.setdefault('accessToken', 'fixture')
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

    def raw(self, **args):
        args.setdefault('url', self.base + '/raw/binary')
        args.setdefault('httpMethod', 'GET')
        return self.success('moviepilot.request', **args)

    def test_raw_binary_error_status_and_headers_are_preserved_without_truncation(self):
        for status in [200, 400, 403, 503]:
            response = self.raw(url=f'{self.base}/raw/binary?status={status}')
            self.assertEqual(response['status'], status)
            self.assertEqual(base64.b64decode(response['bodyBase64']), bytes(range(256)) * 100)
            self.assertEqual(response['headers']['x-result'], 'fixture')
        self.assertEqual(len(self.server.records), 4)

    def test_raw_creation_is_sent_once_with_exact_request_bytes(self):
        payload = bytes(range(256))
        response = self.raw(httpMethod='POST', bodyBase64=base64.b64encode(payload).decode(), headers={'Content-Type': 'application/octet-stream'})
        self.assertEqual(response['status'], 503)
        self.assertEqual(base64.b64decode(response['bodyBase64']), payload)
        self.assertEqual(len(self.server.records), 1)
        self.assertEqual(self.server.records[0]['body'], payload)

    def test_invalid_raw_arguments_and_escaping_urls_never_dispatch(self):
        valid = {'url': self.base + '/raw/binary', 'httpMethod': 'GET'}
        invalid = [
            {'timeout': 0}, {'timeout': -1}, {'timeout': 'slow'}, {'timeout': 1e300},
            {'bodyBase64': 'not base64!'}, {'bodyBase64': 1}, {'headers': []},
            {'headers': {'X-Test': '\n'}}, {'httpMethod': 'bad method'},
            {'headers': {'Authorization': 'Bearer wrong'}}, {'headers': {'Cookie': 'wrong'}}, {'headers': {'Host': 'wrong'}},
            {'url': self.base.replace('127.0.0.1', 'localhost') + '/raw/binary'},
            {'url': self.base.replace('/mirror', '/outside')},
            {'url': self.base + '/../outside'}, {'url': self.base + '/raw/binary#fragment'},
            {'url': self.base.replace('http://', 'http://user:secret@') + '/raw/binary'},
        ]
        for changes in invalid:
            result = self.call('moviepilot.request', **(valid | changes))
            self.assertEqual(result['code'], 1002, (changes, result))
        for args in [{'username': 'fixture', 'password': 'fixture', 'validateUser': 'yes'},
                     {'username': '', 'password': 'fixture'}]:
            self.assertEqual(self.call('moviepilot.login', **args)['code'], 1002)
        self.assertEqual(self.server.records, [])

    def test_malformed_token_is_a_protocol_error_and_never_publishes_cookie(self):
        result = self.call('moviepilot.login', username='malformed', password='fixture', validateUser=False)
        self.assertEqual(result['code'], 1514)
        self.assertEqual(self.success('diag.snapshot')['core']['network']['moviepilotSessions'], 0)

    def test_missing_user_name_does_not_publish_an_authenticated_session(self):
        result = self.call('moviepilot.login', username='baduser', password='fixture')
        self.assertFalse(result['ok'])
        diagnostics = self.success('diag.snapshot')
        self.assertEqual(diagnostics['core']['network']['moviepilotSessions'], 0)

    def test_token_only_login_retains_cookie_without_requesting_user(self):
        result = self.success('moviepilot.login', username='fixture', password='密 码+&/%', validateUser=False)
        self.assertEqual(result, {'accessToken': 'issued', 'user': None})
        self.raw(accessToken='issued')
        records = self.server.records
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]['authorization'], None)
        self.assertEqual(parse_qs(records[0]['body'].decode()), {'username': ['fixture'], 'password': ['密 码+&/%']})
        self.assertEqual(records[1]['cookie'], 'Login=issued')
        self.assertEqual(records[0]['port'], records[1]['port'])

    def test_login_validation_and_safe_token_retries_use_same_wire_contract(self):
        result = self.success('moviepilot.login', username='retry', password='fixture')
        self.assertEqual(result['user']['name'], 'fixture')
        records = self.server.records
        self.assertEqual([r['method'] for r in records], ['POST', 'POST', 'POST', 'GET'])
        self.assertEqual(len({r['port'] for r in records}), 1)
        self.assertEqual(records[-1]['authorization'], 'Bearer issued')
        self.assertEqual(records[-1]['cookie'], 'Login=issued')
        rejected = self.call('moviepilot.login', username='reject', password='fixture')
        self.assertEqual(rejected['code'], 2000)

    def test_raw_timeout_uses_transport_category_and_does_not_retry(self):
        result = self.call('moviepilot.request', url=self.base + '/raw/slow', httpMethod='GET', timeout=0.05)
        self.assertEqual(result['code'], 1521)
        self.assertEqual(len(self.server.records), 1)

    def test_named_download_and_subscription_mutations_keep_wire_paths_and_fields(self):
        self.success('moviepilot.download.add', media={'zero': 0, 'enabled': False}, torrent={'unknown': {'x': None}})
        self.success('moviepilot.download.start', hash='a/b?c#d')
        self.success('moviepilot.download.stop', hash='hash')
        self.success('moviepilot.download.remove', hash='a/b?c#d')
        self.success('moviepilot.subscription.add', subscription={'id': 1, 'unknown': [0, False]})
        self.success('moviepilot.subscription.update', subscription={'id': 1, 'unknown': [0, False]})
        self.success('moviepilot.subscription.delete', id=1)
        self.success('moviepilot.subscription.deleteByMedia', mediaId='tmdb:1/2?x#f')
        self.success('moviepilot.subscription.refresh')
        self.success('moviepilot.subscription.search')
        records = self.server.records
        self.assertEqual([(r['method'], r['path']) for r in records], [
            ('POST', '/mirror/api/v1/download/'), ('GET', '/mirror/api/v1/download/start/a%2Fb%3Fc%23d'),
            ('GET', '/mirror/api/v1/download/stop/hash'), ('DELETE', '/mirror/api/v1/download/a%2Fb%3Fc%23d'),
            ('POST', '/mirror/api/v1/subscribe/'), ('PUT', '/mirror/api/v1/subscribe/'),
            ('DELETE', '/mirror/api/v1/subscribe/1'), ('DELETE', '/mirror/api/v1/subscribe/media/tmdb%3A1%2F2%3Fx%23f'),
            ('GET', '/mirror/api/v1/subscribe/refresh'), ('GET', '/mirror/api/v1/subscribe/search')])
        self.assertEqual(json.loads(records[0]['body']), {'media_in': {'zero': 0, 'enabled': False}, 'torrent_in': {'unknown': {'x': None}}})
        self.assertEqual(json.loads(records[4]['body']), {'id': 1, 'unknown': [0, False]})
        self.assertEqual(records[4]['body'], records[5]['body'])
        self.assertTrue(all(r['authorization'] == 'Bearer fixture' for r in records))

    def test_named_lists_and_search_preserve_raw_entries_and_query_shape(self):
        self.assertEqual(self.success('moviepilot.sites')['items'][0]['unknown'], {'zero': 0})
        for method in ['moviepilot.download.list', 'moviepilot.subscription.list']:
            self.assertEqual(self.success(method)['items'][0]['raw'], [0, False])
        self.assertEqual(self.success('moviepilot.mediaSearch', title='Anime & 中文')['items'][0]['tmdb_id'], 1)
        query = parse_qs(urlsplit(self.server.records[-1]['path']).query)
        self.assertEqual(query, {'title': ['Anime & 中文'], 'type': ['media'], 'page': ['1'], 'count': ['24']})


if __name__ == '__main__':
    unittest.main()

"""Exercise the public C ABI against the actual Bangumi command HTTP protocol."""
import ctypes
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs


class Handler(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *args): pass
    def send_json(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def record(self):
        self.requests.append((self.command, self.path, self.headers.get('Authorization')))
    def do_GET(self):
        self.record()
        path = urlsplit(self.path).path
        if path == '/mirror/p1/subjects/1':
            self.send_json({'id': 1, 'name': 'subject', 'type': 2, 'interest': {'type': 3}, 'unknown': [0, False]})
        elif path == '/mirror/v0/users/a%2Fb/collections/1':
            self.send_json({'type': 2, 'updated_at': '2026-11-13T01:00:00Z', 'ep_status': 5})
        elif path.endswith('/episodes'):
            self.send_json({'data': [{'id': 1, 'sort': 1, 'type': 0, 'unknown': 'retained'}], 'total': 1})
        else: self.send_json({'message': 'unexpected route'}, 404)
    def do_POST(self):
        self.record()
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        path = urlsplit(self.path).path
        if path == '/mirror/p1/search/subjects':
            assert body == {'keyword': 'Anime & title', 'sort': 'match', 'filter': {'type': [2]}}, body
            assert parse_qs(urlsplit(self.path).query) == {'limit': ['7'], 'offset': ['5']}
            self.send_json({'data': [{'id': 1, 'name_cn': 'translated'}], 'total': 1})
        elif path == '/mirror/v0/users/-/collections/1':
            assert body == {'type': 3, 'rate': 8}
            self.send_response(204)
            self.end_headers()
        else: self.send_json({'message': 'unexpected route'}, 404)
    def do_PATCH(self):
        self.record()
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert urlsplit(self.path).path == '/mirror/p1/collections/episodes/1'
        assert body == {'type': 2, 'batch': True}, body
        self.send_response(204)
        self.end_headers()


class BangumiContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffi = ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
        cls.ffi.ocp_core_create.argtypes = [ctypes.c_char_p]
        cls.ffi.ocp_core_create.restype = ctypes.c_void_p
        cls.ffi.ocp_core_destroy.argtypes = [ctypes.c_void_p]
        cls.ffi.ocp_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        cls.ffi.ocp_call.restype = ctypes.c_void_p
        cls.ffi.ocp_string_free.argtypes = [ctypes.c_void_p]
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
    def setUp(self):
        self.core = self.ffi.ocp_core_create(b'{}')
        self.assertTrue(self.core)
        Handler.requests.clear()
    def tearDown(self): self.ffi.ocp_core_destroy(self.core)
    def call(self, method, **args):
        args.update(baseURL=f'http://127.0.0.1:{self.server.server_port}/mirror', accessToken='fixture')
        pointer = self.ffi.ocp_call(self.core, method.encode(), json.dumps(args).encode())
        self.assertTrue(pointer)
        try: return json.loads(ctypes.string_at(pointer))
        finally: self.ffi.ocp_string_free(pointer)
    def success(self, method, **args):
        result = self.call(method, **args)
        self.assertTrue(result['ok'], result)
        return result['data']
    def test_subject_and_episode_extra_fields_are_preserved(self):
        subject = self.success('bangumi.subject', subjectId=1)
        self.assertEqual(subject['unknown'], [0, False])
        episodes = self.success('bangumi.episodes', subjectId=1, limit=7, offset=5)
        self.assertEqual(episodes['data'][0]['unknown'], 'retained')
        self.assertTrue(all(request[2] == 'Bearer fixture' for request in Handler.requests))
    def test_search_post_filter_and_pagination(self):
        result = self.success('bangumi.search', keyword='Anime & title', subjectType=2, limit=7, offset=5)
        self.assertEqual(result['total'], 1)
        self.assertEqual(Handler.requests[0][0], 'POST')
    def test_collection_username_encoding_and_empty_mutation_responses(self):
        result = self.success('bangumi.subjectCollection', subjectId=1, username='a/b')
        self.assertEqual(result['ep_status'], 5)
        self.assertTrue(self.success('bangumi.updateSubject', subjectId=1, body={'type': 3, 'rate': 8})['updated'])
        self.assertTrue(self.success('bangumi.updateEpisode', episodeId=1, collectionType=2, batch=True)['updated'])
        self.assertEqual([request[0] for request in Handler.requests], ['GET', 'POST', 'PATCH'])
    def test_bad_pagination_never_reaches_server(self):
        for args in [{'limit': 4294967297}, {'offset': 4294967296}, {'limit': -1}, {'limit': 0}]:
            result = self.call('bangumi.episodes', subjectId=1, **args)
            self.assertEqual(result['code'], 1002, result)
        self.assertEqual(Handler.requests, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

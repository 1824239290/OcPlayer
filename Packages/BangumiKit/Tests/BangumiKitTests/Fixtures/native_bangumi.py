import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

requests = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, body, status=200, headers=None):
        data = body.encode() if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', 'application/json')
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def handle_request(self):
        url = urlsplit(self.path)
        if url.path == '/stats': return self.reply(requests)
        body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        requests.append({'path': self.path, 'method': self.command, 'body': body,
                         'authorization': self.headers.get('Authorization'), 'apiKey': self.headers.get('X-API-Key'),
                         'userAgent': self.headers.get('User-Agent')})
        if url.path.endswith('/oauth/authorize'):
            if self.headers.get('X-API-Key') == 'scope': return self.reply({'success': False, 'error': {'code': 'SCOPE_REQUIRED'}}, 403)
            if self.headers.get('X-API-Key') != 'gateway': return self.reply({}, 401)
            if not self.headers.get('User-Agent', '').startswith('OcPlay/'): return self.reply({}, 403)
            state = parse_qs(url.query)['state'][0]
            return self.reply({'authorize_url': 'https://bgm.tv/oauth/authorize?state=' + state})
        if url.path.endswith('/oauth/token'):
            assert json.loads(body) == {'code': 'fixture-code'}
            return self.reply({'access_token': 'fresh', 'expires_in': 3600, 'refresh_token': 'refresh'})
        if url.path.endswith('/oauth/refresh'):
            assert json.loads(body) == {'refresh_token': 'refresh'}
            time.sleep(0.15)
            return self.reply({'access_token': 'fresh', 'expires_in': 3600})
        if url.path.endswith('/slow'):
            time.sleep(2)
            return self.reply({'private': 'retired account'})
        if url.path.endswith('/unauthorized'): return self.reply({}, 401)
        if url.path.endswith('/missing'): return self.reply({'message': 'subject is not collected by user'}, 404)
        if url.path.endswith('/wrong-user'): return self.reply({'message': "user doesn't exist or has been removed"}, 404)
        if url.path.endswith('/forbidden'): return self.reply({'success': False, 'error': {'code': 'SCOPE_REQUIRED'}}, 403)
        if url.path.endswith('/server-error'): return self.reply('<html>upstream failed</html>', 503, {'X-Request-ID': 'fixture-request'})
        if url.path.endswith('/limited'): return self.reply({}, 429, {'Retry-After': '0'})
        if self.command == 'PATCH': return self.reply({'message': 'mutation applied'}, 503)
        if url.path.endswith('/p1/search/subjects'):
            assert json.loads(body) == {'keyword': 'Anime & title', 'sort': 'match', 'filter': {'type': [2]}}
            return self.reply({'data': [{'id': 1}], 'total': 1})
        if url.path.endswith('/empty'): return self.reply('', 204)
        return self.reply({'name_cn': '中文', 'unknown': {'zero': 0, 'enabled': False}, 'data': [1, 2]})
    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

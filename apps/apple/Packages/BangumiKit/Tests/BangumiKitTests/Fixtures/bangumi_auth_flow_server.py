"""Local OAuth/profile fixture with original fields and observable wire order."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

with open(sys.argv[1]) as source: profiles = json.load(source)
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, body, status=200):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def handle_request(self):
        url = urlsplit(self.path)
        if url.path == '/stats': return self.reply(requests)
        body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        requests.append({'method': self.command, 'path': self.path, 'body': body,
                         'authorization': self.headers.get('Authorization')})
        if url.path.endswith('/oauth/authorize'):
            state = parse_qs(url.query)['state'][0]
            return self.reply({'authorize_url': 'https://bgm.tv/oauth/authorize?state=' + state})
        if url.path.endswith('/oauth/token'):
            code = json.loads(body)['code']
            return self.reply({'access_token': 'token-' + code, 'refresh_token': 'refresh', 'expires_in': 3600})
        if url.path == '/profile':
            index = int(parse_qs(url.query).get('index', ['0'])[0])
            return self.reply(profiles[min(index, len(profiles)-1)])
        if url.path == '/profile-fail': return self.reply({'message': 'profile failed'}, 400)
        if url.path == '/profile-malformed': return self.reply({'unexpected': True})
        self.reply({}, 404)
    do_GET = handle_request
    do_POST = handle_request


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

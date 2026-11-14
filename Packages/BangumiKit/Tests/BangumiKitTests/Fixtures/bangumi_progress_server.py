"""Local subject/progress wire fixture; preserves request ordering and bodies."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

with open(sys.argv[1]) as source:
    fixture = json.load(source)
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/stats': return self.reply(requests)
        requests.append({'method': 'GET', 'path': self.path})
        if url.path == '/subject-fail': return self.reply({'message': 'read failed'}, 400)
        if url.path == '/subject': return self.reply(fixture['subject'])
        if url.path == '/lookup': return self.reply(fixture['subject']['interest'])
        if url.path == '/episodes':
            offset = int(parse_qs(url.query).get('offset', ['0'])[0])
            # Two pages exercise the production page size without a thousand redundant DTOs.
            return self.reply({'data': fixture['episodes'][:1] if not offset else fixture['episodes'][1:], 'total': 1001})
        self.reply({}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
        requests.append({'method': 'POST', 'path': self.path, 'body': body})
        if self.path == '/mutation-fail': return self.reply({'message': 'write failed'}, 400)
        self.reply({})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

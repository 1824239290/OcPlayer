import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

fixture = json.load(open(sys.argv[1]))
requests = []
active = peak = 0
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        global active, peak
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/stats':
            with lock: state = {'requests': list(requests), 'peak': peak}
            return self.reply(state)
        with lock: requests.append(self.path)
        offset = int(query.get('offset', [0])[0])
        if url.path in ['/collections', '/collections-fail']:
            if url.path.endswith('fail') and offset: return self.reply({'message': 'page rejected'}, 400)
            data = fixture['subjects'][:2] if offset == 0 else fixture['subjects'][2:]
            return self.reply({'data': data, 'total': 101})
        if url.path.startswith('/episodes/'):
            subject = url.path.rsplit('/', 1)[1]
            with lock:
                active += 1
                peak = max(active, peak)
            try:
                time.sleep(0.35 if query.get('slow') else (0.2 if subject == '2' else 0.05))
                if subject == '2': return self.reply({'message': 'episode rejected'}, 400)
                data = fixture['episodes'].get(subject, [])
                if subject == '1': return self.reply({'data': data[:1] if offset == 0 else data[1:], 'total': 1001})
                return self.reply({'data': data, 'total': len(data)})
            finally:
                with lock: active -= 1
        self.reply({}, 404)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

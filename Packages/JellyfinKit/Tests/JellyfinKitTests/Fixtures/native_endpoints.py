import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

lock = threading.Lock()
stats = {'aReads': 0, 'bReads': 0, 'aProbes': 0, 'bProbes': 0, 'bMutations': 0, 'bProbePeerPorts': []}
mode = 'good'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        global mode
        path = urlsplit(self.path).path
        side = self.server.side
        if path == '/stats':
            with lock:
                snapshot = dict(stats)
            self.respond(200, snapshot)
            return
        if path == '/control':
            mode = parse_qs(urlsplit(self.path).query)['mode'][0]
            self.respond(200, {})
            return
        if path.endswith('/System/Info/Public'):
            with lock:
                stats[side + 'Probes'] += 1
                count = stats[side + 'Probes']
                if side == 'b':
                    stats['bProbePeerPorts'].append(self.client_address[1])
            if side == 'b':
                time.sleep(0.05)
            if path.startswith('/slow/'):
                time.sleep(0.5)
            if path.startswith('/empty/'):
                self.respond(200, {})
                return
            if path.startswith('/foreign/'):
                self.respond(200, {'Id': 'other'})
                return
            if path.startswith('/missing/'):
                self.respond(200, {'ServerName': 'fixture'})
                return
            if path.startswith('/html/'):
                self.respond(200, '<html>not a server</html>')
                return
            self.respond(503 if side == 'a' and count > 1 else 200, {'Id': 'srv-1', 'ServerName': 'fixture'})
            return
        if path.endswith('/UserViews') or path.endswith('/Users/u1/Views'):
            with lock:
                stats[side + 'Reads'] += 1
                stats['lastAuthorization'] = self.headers.get('Authorization')
                stats['lastUserAgent'] = self.headers.get('User-Agent')
                stats['lastPath'] = path
            if side == 'a':
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            status = int(mode) if mode in ('401', '503') else 200
            self.respond(status, {'Items': [{'Id': 'lib-1', 'Name': 'Movies', 'CollectionType': 'movies'}]})
            return
        self.respond(404, {})

    def do_POST(self):
        with lock:
            stats[self.server.side + 'Mutations'] = stats.get(self.server.side + 'Mutations', 0) + 1
        self.respond(500, {'message': 'accepted or failed; never replay'})


servers = [ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
for side, server in zip(('a', 'b'), servers):
    server.side = side
    threading.Thread(target=server.serve_forever, daemon=True).start()
print(json.dumps([server.server_port for server in servers]), flush=True)
threading.Event().wait()

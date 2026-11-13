"""Deterministic real HTTP login/Quick Connect fixture shared with Swift tests."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.records = []
        self.polls = {}
        self.lock = threading.Lock()
    def handle_error(self, request, client_address):
        pass

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def respond(self, value, status=200):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def record(self, body=None):
        with self.server.lock:
            self.server.records.append({'path':self.path, 'method':self.command,
                'authorization':self.headers.get('Authorization'), 'embyAuthorization':self.headers.get('X-Emby-Authorization'),
                'agent':self.headers.get('User-Agent'), 'accept':self.headers.get('Accept'), 'port':self.client_address[1], 'body':body})
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/stats':
            with self.server.lock:
                records = list(self.server.records)
            return self.respond(records)
        self.record()
        if path.endswith('/System/Info/Public'):
            if '/retryprobe/' in path:
                with self.server.lock:
                    n = self.server.polls.get(path, 0)+1
                    self.server.polls[path] = n
                if n <= 2: return self.respond({}, 503)
            if '/slowprobe/' in path: time.sleep(1)
            return self.respond({'Id':'server-1', 'ServerName':'fixture',
                'ProductName':'Emby Server' if '/emby' in path else 'Jellyfin Server',
                'Version':'4.9' if '/emby' in path else '10.9'})
        if path.endswith('/QuickConnect/Connect'):
            secret = parse_qs(urlsplit(self.path).query).get('secret', [''])[0]
            with self.server.lock:
                n = self.server.polls.get(secret, 0) + 1
                self.server.polls[secret] = n
            if 'slow' in secret: time.sleep(1)
            if 'disabled' in secret: return self.respond({}, 404)
            if 'exhaust' in secret: return self.respond({}, 503)
            if 'reset' in secret and n in (1, 3): return self.respond({}, 503)
            if 'retry' in secret and n <= 2: return self.respond({}, 503)
            authenticated = 'timeout' not in secret and n >= (4 if 'reset' in secret else 3)
            return self.respond({'Authenticated':authenticated, 'Secret':'authorized '+secret if authenticated else secret})
        return self.respond({}, 404)
    def do_POST(self):
        path = urlsplit(self.path).path
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw) if raw else None
        self.record(body)
        if path.endswith('/QuickConnect/Initiate'):
            if '/disabled/' in path: return self.respond({}, 404)
            if '/missing/' in path: return self.respond({'Code':'123456'})
            return self.respond({'Code':'123456', 'Secret':path.split('/')[1]+' ?&中'})
        if path.endswith('/Users/AuthenticateByName') or path.endswith('/Users/AuthenticateWithQuickConnect'):
            name = (body or {}).get('Username', 'quick')
            if name.startswith('status'): return self.respond({}, int(name[6:]))
            if name == 'slow': time.sleep(1)
            if name == 'invalidJSON': return self.respond(b'not json')
            if name == 'missingToken': return self.respond({'User':{'Id':'u1'}})
            if name == 'wrongToken': return self.respond({'AccessToken':3,'User':{'Id':'u1'}})
            if name == 'missingID': return self.respond({'AccessToken':'token','User':{'Name':'fixture'}})
            return self.respond({'AccessToken':'token', 'User':{'Id':'u1',
                'Name':5 if name == 'optionalTypes' else 'fixture',
                'PrimaryImageTag':[] if name == 'optionalTypes' else 'avatar',
                'Policy':{'UnknownFutureEnum':['not SDK']}}})
        return self.respond({}, 404)

if __name__ == '__main__':
    server = Server()
    print(server.server_port, flush=True)
    server.serve_forever()

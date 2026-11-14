import base64
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    requests = []
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

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

    def record(self, body=None):
        entry = {'method': self.command, 'path': self.path, 'port': self.client_address[1],
                 'cookie': self.headers.get('Cookie', ''), 'authorization': self.headers.get('Authorization', ''),
                 'contentType': self.headers.get('Content-Type', '')}
        if body is not None:
            entry.update(body=body.decode('utf-8', errors='replace'), bodyBase64=base64.b64encode(body).decode())
        self.requests.append(entry)

    def do_GET(self):
        if self.path == '/stats':
            return self.respond(self.requests)
        self.record()
        path = urlsplit(self.path).path
        if self.headers.get('Authorization') == 'Bearer expired':
            if path.endswith('/late-expired'):
                time.sleep(0.4)
            return self.respond({'success': False, 'message': 'token expired'}, 403)
        if path.endswith('/user/current'):
            token = self.headers.get('Authorization', '').removeprefix('Bearer ')
            if token == 'user:baduser':
                return self.respond({'id': 1})
            if token == 'user:cookie' and 'Login=issued' not in self.headers.get('Cookie', ''):
                return self.respond({'message': 'login cookie missing'}, 401)
            name = token.removeprefix('user:') if token.startswith('user:') else 'native'
            user = {'name': name, 'is_superuser': True, 'is_active': True}
            if name == 'large-id':
                user['id'] = 9007199254741007
                user.update(email='native@example.invalid', avatar='/avatars/large.png', is_superuser=False, is_active=False)
            return self.respond(user, headers={'Set-Cookie': 'MoviePilot=fixture; Path=/'})
        if '/raw/' in path:
            query = parse_qs(urlsplit(self.path).query)
            if path.endswith('/slow'):
                time.sleep(2)
            if path.endswith('/late-expired') and self.headers.get('Authorization') == 'Bearer expired':
                time.sleep(0.4)
                return self.respond({'message': 'token expired'}, 401)
            if path.endswith('/binary'):
                body = bytes([0, 255, 128, 10, 13, 65])
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            status = int(query.get('status', ['200'])[0])
            if path.endswith('/flaky'):
                seen = sum(r['path'] == self.path for r in self.requests)
                status = 503 if seen < 3 else 200
            if path.endswith('/auth-flaky'):
                seen = sum(r['path'] == self.path and r['authorization'] == 'Bearer fresh' for r in self.requests)
                status = 503 if seen < 3 else 200
            return self.respond({'success': status < 400, 'message': query.get('message', ['wire message'])[0], 'data': {'zero': 0, 'flag': False}}, status)
        if path.endswith('/media/search'):
            title = parse_qs(urlsplit(self.path).query).get('title', [''])[0]
            if title == 'slow':
                time.sleep(0.6)
            if title == 'cancel':
                time.sleep(2)
            if title == 'malformed':
                return self.respond({'success': True, 'data': [True]})
            if title == 'named-flaky':
                seen = sum(r['path'] == self.path and r['authorization'] == 'Bearer fresh' for r in self.requests)
                if seen < 3:
                    return self.respond({'message': 'gateway busy'}, 503)
            return self.respond({'success': True, 'data': [{'title': title, 'tmdb_id': 1, 'enabled': False, 'unknown_field': {'zero': 0}}]})
        if path.endswith('/search/title/stream'):
            if 'MoviePilot=fixture' not in self.headers.get('Cookie', ''):
                return self.respond({'message': 'cookie required'}, 401)
            events = [
                {'type': 'append', 'text': 'partial', 'items': [{'torrent_info': {'enclosure': 'old'}}]},
                {'type': 'replace', 'text': 'replace', 'items': [{'torrent_info': {'enclosure': 'new', 'seeders': 0}}]},
                {'type': 'done', 'text': 'finished', 'finished': 2, 'total': 2, 'total_items': 2, 'items': [{'torrent_info': {'enclosure': 'last', 'seeders': 1}}]},
            ]
            keyword = parse_qs(urlsplit(self.path).query).get('keyword', [''])[0]
            if keyword in ('concurrent-a', 'concurrent-b'):
                for event in events:
                    event['text'] = keyword + ':' + event['text']
                    for item in event.get('items', []):
                        item['torrent_info']['enclosure'] = keyword + ':' + item['torrent_info']['enclosure']
            frames = [('data: ' + json.dumps(event) + '\n\n').encode() for event in events]
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(sum(map(len, frames))))
            self.end_headers()
            try:
                for frame in frames:
                    self.wfile.write(frame)
                    self.wfile.flush()
                    time.sleep(0.25)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        return self.respond({'success': True})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.record(raw)
        if self.path.endswith('/login/access-token'):
            user = parse_qs(raw.decode()).get('username', [''])[0]
            if user in ('slow', 'older'):
                time.sleep(1.2)
            if user == 'reject':
                return self.respond({'detail': 'wrong password'}, 400)
            if user == 'offline':
                return self.respond({'message': 'login gateway busy'}, 503)
            if user == 'retry':
                count = sum(r.get('body') == raw.decode() for r in self.requests)
                if count < 3:
                    return self.respond({'message': 'gateway busy'}, 503)
            if user == 'malformed':
                return self.respond({'access_token': False})
            if user == 'empty':
                return self.respond({'access_token': ''})
            token = 'fresh' if user in ('fixture', 'retry') else 'user:' + user
            if user == 'stale':
                token = 'expired'
            return self.respond({'access_token': token, 'token_type': 'bearer'}, headers={'Set-Cookie': 'Login=issued; Path=/'})
        if self.path.endswith('/raw/echo'):
            self.send_response(200)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        return self.respond({'success': False, 'message': 'creation applied but response failed'}, 503)

    def do_DELETE(self):
        self.requests.append({'method': 'DELETE', 'path': self.path})
        self.send_response(204)
        self.end_headers()


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

"""Intro provider wire fixture shared with native Swift; no external credentials."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # Timeout/cancel fixtures deliberately close a live connection.
            pass

    def log_message(self, *args):
        pass

    def respond(self, value=None, status=200, raw=None):
        body = raw if raw is not None else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Provider-Fixture', 'HIT')
        self.send_header('Retry-After', '0.01')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_provider(self):
        parsed = urlsplit(self.path)
        if parsed.path == '/stats':
            return self.respond(self.server.records)
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.server.records.append(dict(path=self.path, method=self.command, body=body.decode(),
            agent=self.headers.get('User-Agent', ''), clientID=self.headers.get('X-Client-ID', ''),
            accept=self.headers.get('Accept', ''), contentType=self.headers.get('Content-Type', ''),
            port=self.client_address[1]))
        parts = parsed.path.strip('/').split('/')
        if parts[0] == 'slow':
            time.sleep(1)
        if parts[0].startswith('status'):
            return self.respond({'message': 'unavailable'}, int(parts[0][6:]))
        if parts[0] == 'binary':
            return self.respond(raw=bytes([0, 255, 128, 10]))
        if parts[0] == 'malformed':
            return self.respond(raw=b'{')
        query = parse_qs(parsed.query)
        if 'skip-times' in parts:
            mal = int(parts[-2])
            if mal in (404, 503):
                return self.respond({'found': False}, mal)
            return self.respond({'found': True, 'results': [
                {'interval': {'startTime': 638, 'endTime': 728}, 'skipType': 'op'},
                {'interval': {'startTime': 1000, 'endTime': 1090}, 'skipType': 'ed'}]})
        if parts[-2:] == ['v3', 'media']:
            tmdb = int(query['tmdb_id'][0])
            if tmdb in (404, 503):
                return self.respond({'message': 'missing'}, tmdb)
            return self.respond({'intro': ([{}, {'start_ms': 0, 'end_ms': 90000}] if tmdb == 99
                else [{'start_ms': -10, 'end_ms': 90000}])})
        payload = json.loads(body)
        if parts[-1] == 'graphql':
            anime = int(payload['variables']['id'])
            if anime in (404, 503):
                return self.respond({'errors': [{'message': 'missing'}]}, anime)
            return self.respond({'data': {'findShowsByExternalId': [{'episodes': [
                {'season': '1', 'number': '01', 'timestamps': [
                    {'at': 0, 'type': {'name': 'Intro'}}, {'at': 90}]},
                {'season': '2', 'number': '+1', 'timestamps': [
                    {'at': 100, 'type': {'name': 'Canon'}},
                    {'at': 30, 'type': {'name': 'New Intro'}}]}]}]}})
        variables = payload['variables']
        if 'id' in variables:
            anime = int(variables['id'])
            if anime == 503:
                return self.respond({'errors': []}, 503)
            if anime == 404:
                return self.respond({'data': {}})
            if anime == 99:
                return self.respond({'data': {'Media': {'id': 'bad', 'idMal': 100000}}})
            return self.respond({'data': {'Media': {'id': 999, 'idMal': 100000}}})
        title = variables.get('search', '')
        media = [{'id': 12, 'idMal': 34, 'title': {'native': '其他番剧'}}]
        if title in ('empty', 'no-mal'):
            media = [] if title == 'empty' else [{'id': 12, 'title': {'native': title}}]
        elif title == 'http503':
            return self.respond({'data': {}}, 503)
        elif title == 'bad':
            return self.respond({'data': {'Page': {'media': [{'idMal': 'bad'}]}}})
        elif title == 'contained-one':
            media = [{'id': 24, 'idMal': 14, 'title': {'native': 'contained-one extra'}}]
        elif title == 'exact-last':
            media = [{'id': 1, 'idMal': 11, 'title': {'native': 'exact-last extra'}},
                     {'id': 2, 'idMal': 22, 'title': {'native': title}}]
        elif title == 'short':
            media = [{'id': 3, 'idMal': 33, 'title': {'native': 'short extra'}}]
        elif title in ('作品名稱', 'later'):
            media = [{'id': 56, 'idMal': 78, 'title': {'native': title}}]
        return self.respond({'data': {'Page': {'media': media}}})

    do_GET = handle_provider
    do_POST = handle_provider


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.records = []
    print(server.server_port, flush=True)
    server.serve_forever()

"""Shared standalone-loader fixture, used by C ABI and Apple binding tests."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def respond(self, value=None, status=200, raw=None):
        body = raw if raw is not None else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'application/json')
        self.send_header('Retry-After', '0.01')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def handle_request(self):
        path = urlsplit(self.path).path
        if path == '/stats': return self.respond(self.server.records)
        query = parse_qs(urlsplit(self.path).query)
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        value = json.loads(body) if body else None
        self.server.records.append({'path': path, 'query': query, 'body': value,
            'agent': self.headers.get('User-Agent'), 'key': self.headers.get('X-API-Key'),
            'client': self.headers.get('X-Client-ID'), 'port': self.client_address[1]})
        scenario = path.split('/')[1]
        if scenario == 'intro':
            if '/v2/skip-times/' in path:
                time.sleep(0.04)
                return self.respond({'found': True, 'results': [{'skipType': 'op',
                    'interval': {'startTime': 2, 'endTime': 100}}]})
            if path.endswith('/graphql'):
                time.sleep(0.01)
                return self.respond({'data': {'findShowsByExternalId': [{'episodes': [{'season': '1', 'number': '2',
                    'timestamps': [{'at': 1, 'type': {'name': 'Intro'}},
                                   {'at': 98, 'type': {'name': 'Content'}}]}]}]}})
            if path.endswith('/v3/media'):
                return self.respond({'intro': [{'start_ms': 0, 'end_ms': 300000}]})
            if 'Media(id:' in value['query']:
                return self.respond({'data': {'Media': {'id': 6, 'idMal': 5}}})
            title = value['variables'].get('search')
            media = [{'id': 6, 'idMal': 5, 'title': {'native': 'Alias'}, 'synonyms': []}] if title == 'Alias' else []
            return self.respond({'data': {'Page': {'media': media}}})
        if path.endswith('/v1/match'):
            if scenario == 'delayed': time.sleep(.15)
            attempts = sum(r['path'] == path for r in self.server.records)
            if scenario == 'unauthorized': return self.respond({'error': 'key'}, 401)
            if scenario == 'retry' and attempts < 3: return self.respond({'error': 'retry'}, 429)
            if scenario == 'business': return self.respond({'success': False, 'errorCode': 4321, 'errorMessage': 'bad fingerprint'})
            if scenario == 'malformed': return self.respond(raw=b'{')
            if scenario in ['fallback', 'empty', 'delayed']: return self.respond({'success': True, 'matches': []})
            if scenario == 'numeric':
                return self.respond({'success': True, 'isMatched': True, 'resultCount': 1.0, 'matches': [
                    {'episodeId': 50002.0, 'animeId': 5.0, 'shift': -5.0, 'fileSize': 10.0}]})
            if scenario == 'badoptional':
                return self.respond({'success': True, 'isMatched': True, 'matches': [
                    {'episodeId': 50002, 'fileName': False}]})
            candidates = [{'episodeId': 9223372036854775807, 'animeId': 5,
                           'animeTitle': 'Local', 'episodeTitle': '第2话', 'shift': -5},
                          {'episodeId': 50003, 'animeId': 5, 'animeTitle': 'Wrong', 'episodeTitle': '第3话'}]
            if scenario == 'ranked':
                candidates = [candidates[1], candidates[0]]
            return self.respond({'success': True, 'isMatched': scenario != 'ranked', 'matches': candidates})
        if path.endswith('/v1/search/episodes'):
            found = scenario in ['business', 'malformed', 'badoptional'] or (scenario in ['fallback', 'delayed']
                and query.get('anime') == ['Clean'] and 'episode' not in query)
            animes = [{'animeId': 5, 'animeTitle': 'Local', 'episodes': [{'episodeId': 50002, 'episodeTitle': '第2话'}]}] if found else []
            return self.respond({'success': True, 'animes': animes})
        if '/v1/comments/' in path:
            if scenario == 'slow': time.sleep(1)
            if scenario == 'invalid':
                return self.respond({'comments': [{'p': '-1,1,1', 'm': 'bad'}, {'p': '1,2,1', 'm': 'bad'}]})
            if scenario == 'numeric':
                return self.respond({'count': 1.0, 'comments': [{'cid': 1.0, 'p': '1,1,255', 'm': 'numeric'}]})
            comments = [{'cid': 9223372036854775807, 'p': '11,1,255,b', 'm': '空降2:12'},
                        {'p': '10,5,16777215,a', 'm': '跳伞2:10'},
                        {'p': '132,4,123,a', 'm': '空降成功'},
                        {'p': '1,2,1', 'm': 'invalid'}, {'p': '-1,1,1', 'm': 'invalid'},
                        {'p': '0,1,1', 'm': '\u200b'}]
            return self.respond({'count': 6, 'comments': comments})
        return self.respond({'error': 'route'}, 404)
    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()

if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.records = []
    print(server.server_port, flush=True)
    server.serve_forever()

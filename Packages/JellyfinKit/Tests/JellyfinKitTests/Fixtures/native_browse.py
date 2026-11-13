import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        query = parse_qs(urlsplit(self.path).query)
        expected = {'userId': 'native-user'}
        if query.get('parentId') == ['failure']:
            self.send_response(400)
            self.end_headers()
            return
        if query.get('parentId') == ['library']:
            expected.update({
                'recursive': 'false', 'includeItemTypes': 'Movie,Episode',
                'sortBy': 'CommunityRating,SortName', 'sortOrder': 'Descending,Ascending',
                'filters': 'IsUnplayed', 'searchTerm': 'native', 'startIndex': '50',
                'limit': '25', 'enableTotalRecordCount': 'true',
            })
        else:
            expected.update({'limit': '7', 'sortBy': 'DateCreated', 'recursive': 'true'})
        valid = urlsplit(self.path).path == '/base/Items'
        valid = valid and 'Token="fixture"' in self.headers.get('Authorization', '')
        valid = valid and all(query.get(key) == [value] for key, value in expected.items())
        body = json.dumps({'Items': [{'Id': 'native-item', 'Name': 'Native item', 'Type': 'Movie',
                                      'RunTimeTicks': 1000000000,
                                      'UserData': {'PlaybackPositionTicks': 420000000, 'Played': False}}],
                           'TotalRecordCount': 80}).encode()
        self.send_response(200 if valid else 400)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

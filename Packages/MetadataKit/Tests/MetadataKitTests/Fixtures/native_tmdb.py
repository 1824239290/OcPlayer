import json
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

counts = Counter()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        counts[url.path] += 1
        status, body = 200, {}
        if url.path == '/counts': body = dict(counts)
        elif query.get('api_key') != ['fixture'] and self.headers.get('Authorization') != 'Bearer eyJ.fixture': status = 401
        elif url.path.endswith('/movie/401'): status = 401
        elif url.path.endswith('/movie/404'): status = 404
        elif url.path.endswith('/movie/429'): status = 429
        elif url.path.endswith('/movie/500'): status = 500
        elif url.path.endswith('/tv/7/season/0'):
            body = {'name': 'Specials', 'episodes': [{'episode_number': 1, 'name': 'Special', 'runtime': 25}, {'name': 'invalid'}]}
        elif url.path.endswith('/search/tv'):
            if query.get('first_air_date_year') != ['2023'] or query.get('query') != ['Anime & title'] or 'year' in query: status = 400
            body = {'results': [{'id': 7, 'name': 'Anime', 'first_air_date': '2023-09-29', 'poster_path': '/poster.jpg'}, {'id': 'invalid'}]}
        elif url.path.endswith('/search/collection'):
            if 'year' in query: status = 400
            body = {'results': [{'id': 10, 'name': 'Collection'}]}
        elif url.path.endswith('/movie/1'):
            body = {'id': 1, 'title': '中文标题', 'overview': 'English overview' if query.get('language') == ['en-US'] else '',
                    'poster_path': None, 'backdrop_path': '/backdrop.jpg', 'genres': [{'name': 'Drama'}, {'bad': 1}],
                    'credits': {'cast': [{'id': 1, 'name': 'Actor', 'profile_path': '/actor.jpg'}]},
                    'external_ids': {'imdb_id': 'tt123'}, 'belongs_to_collection': {'id': 10},
                    'content_ratings': {'results': [{'iso_3166_1': 'US', 'rating': 'PG'}]}}
            if query.get('language') == ['en-US']: body.update(title='English title', poster_path='/poster.jpg')
        elif url.path.endswith('/collection/10'): body = {'id': 10, 'name': 'Collection', 'overview': 'Complete', 'credits': None, 'genres': None}
        elif url.path.endswith('/movie/2'): body = {'id': 2, 'title': 'Complete', 'overview': 'Complete'}
        elif url.path.endswith('/movie/3'):
            if query.get('language') == ['en-US']: status = 404
            body = {'id': 3, 'title': '主语言'}
        else: status = 404
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

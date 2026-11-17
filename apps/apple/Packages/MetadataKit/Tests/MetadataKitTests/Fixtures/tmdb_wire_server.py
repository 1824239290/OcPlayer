"""Shared TMDB wire fixture for C ABI, exported SDK and native metadata tests."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

MAX = 9223372036854775807
records = []
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        url = urlsplit(self.path); query = parse_qs(url.query)
        if url.path == '/stats':
            body = records
            scenario = 'stats'
        else:
            records.append(dict(path=url.path, query=query))
            scenario = url.path.split('/')[1]
            entity = dict(id=MAX, title='作品', name='作品', original_title='Original', original_name='Original',
                          overview='完整简介😀', poster_path='/poster', backdrop_path='/back', vote_average=8.25,
                          popularity=3.5, genres=[{'name':'Drama'}],
                          credits={'cast':[{'id':MAX-1,'name':'Actor','character':'Character','profile_path':'/actor'}]},
                          seasons=[{'season_number':MAX-2,'name':'Season','episode_count':MAX-3}],
                          belongs_to_collection={'id':MAX-4}, external_ids={'imdb_id':'tt123'},
                          content_ratings={'results':[{'iso_3166_1':'JP','rating':'G'},{'iso_3166_1':'US','rating':'PG'}]})
            search = {'results':[{'id':MAX,'title':'作品','name':'作品','original_title':'Original','original_name':'Original','release_date':'2024-01-01','first_air_date':'2024-01-01','popularity':3.5},
                                 {'id':MAX-1,'title':'Short date','name':'Short date','release_date':'202','first_air_date':'202'}]}
            season = {'season_number':MAX-2,'name':'Season','overview':'完整季简介😀',
                      'episodes':[{'id':MAX-3,'episode_number':MAX-4,'name':'Episode','runtime':MAX-5,'vote_average':9.5}]}
            if scenario == 'numeric':
                entity.update(id=7.9, vote_average=True, popularity=False, belongs_to_collection={'id':8.9},
                              credits={'cast':[{'id':True,'name':'Actor'},{'id':-7.9,'name':'Negative'}]},
                              seasons=[{'season_number':3.8,'episode_count':19.9}])
                search={'results':[{'id':True,'title':'作品','name':'作品','popularity':False},
                                   {'id':7.9,'title':'Fraction','name':'Fraction','popularity':True},
                                   {'id':'bad'}]}
                season={'season_number':3.8,'episodes':[{'episode_number':-2.8,'runtime':4.8,'vote_average':True},{'episode_number':False}]}
            elif scenario == 'mixed':
                entity.update(genres=[{'name':'Drama'},'invalid'], credits={'cast':[{'id':1,'name':'Actor'},False]},
                              seasons=[{'season_number':1},None])
                search={'results':[{'id':1,'title':'valid','name':'valid'},'invalid']}
                season={'episodes':[{'episode_number':1},False]}
            elif scenario == 'prefix':
                entity['credits']={'cast':[{},{}]+[{'id':i,'name':str(i)} for i in range(30)]}
            elif scenario == 'preferred':
                entity.update(__language='CN',content_ratings={'results':[{'iso_3166_1':'JP','rating':'G'},{'iso_3166_1':'CN','rating':'12'}]})
            elif scenario == 'overflow':
                entity.update(id=7,vote_average=18446744073709551615,popularity=18446744073709551615)
                search={'results':[{'id':18446744073709551615},{'id':7,'popularity':18446744073709551615}]}
            body = search if '/search/' in url.path else season if '/season/' in url.path else entity
        data=json.dumps(body,ensure_ascii=False).encode('utf-8')
        if scenario == 'utf8bom': data=b'\xef\xbb\xbf'+data
        elif scenario in ('utf16le','utf16be','utf16lebom','utf16bebom','utf32le','utf32be','utf32lebom','utf32bebom'):
            little='le' in scenario; width=16 if scenario.startswith('utf16') else 32
            data=json.dumps(body,ensure_ascii=False).encode(f'utf-{width}-{ "le" if little else "be" }')
            if scenario.endswith('bom'):
                marker=b'\xff\xfe' if little else b'\xfe\xff'
                if width==32: marker=marker+b'\0\0' if little else b'\0\0'+marker
                data=marker+data
        elif scenario == 'invalid': data=b'{"id":7,"ignored":"\xff"}'
        elif scenario == 'array': data=b'[{}]'
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()

"""Real HTTP fixture for native/shared TMDB enrichment differential tests."""
import json,time,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs

MAX=9223372036854775807
records=[]
lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        url=urlsplit(self.path); query=parse_qs(url.query)
        if url.path=='/stats':
            with lock: body=list(records)
            status=200
        else:
            with lock: records.append({'path':url.path,'query':query})
            parts=url.path.split('/')[2:]
            status=200
            ident=int(parts[1]) if len(parts)>1 and parts[0]!='search' else 0
            if parts[0]=='movie' and ident==401: status=401; body={}
            elif parts[0]=='movie' and ident==500: status=500; body={}
            elif parts[0]=='search':
                q=query.get('query',[''])[0]
                body={'results':[] if q=='Unknown' else [{'id':1,'title':q,'name':q,'release_date':'2024-01-01','first_air_date':'2024-01-01'}]}
            elif '/season/' in url.path:
                number=int(parts[-1]); date=None if number==0 else '2000-01-01'
                body={'season_number':number,'name':'Season','overview':'Complete',
                      'episodes':[{'episode_number':1,'name':'Episode','air_date':date,'runtime':25}]}
            else:
                if parts[0]=='movie' and 200<=ident<300: time.sleep(.15)
                body={'id':ident,'title':'作品','name':'作品','overview':'Complete','poster_path':'/poster'}
                if parts[0]=='movie' and ident in (1,MAX): body['belongs_to_collection']={'id':10 if ident==1 else MAX-1}
                if parts[0]=='tv': body['seasons']=[{'season_number':0},{'season_number':MAX-2 if ident==MAX else 1}]
        data=json.dumps(body,ensure_ascii=False).encode()
        self.send_response(status); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()

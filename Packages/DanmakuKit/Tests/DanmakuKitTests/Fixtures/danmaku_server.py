"""Local wire fixture; used by native Swift and exported C ABI checks."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def respond(self, value, status=200, raw=None, headers=None):
        body = raw if raw is not None else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'application/json')
        for k,v in (headers or {}).items(): self.send_header(k,v)
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def handle_gateway(self):
        parsed=urlsplit(self.path)
        q=parse_qs(parsed.query)
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        self.server.records.append(dict(path=self.path, method=self.command, body=body.decode(),
            key=self.headers.get('X-API-Key'), agent=self.headers.get('User-Agent'), port=self.client_address[1]))
        scenario=q.get('scenario',[''])[0]
        if scenario=='slow': time.sleep(1)
        if scenario=='binary': return self.respond(None,raw=bytes([0,255,128,10]))
        if scenario=='malformed': return self.respond(None,raw=b'{')
        if scenario=='business': return self.respond({'success':False,'errorCode':4321,'errorMessage':'missing'})
        if scenario.startswith('status'): return self.respond({'message':'error'},status=int(scenario[6:]),headers={'Retry-After':'0.01'})
        if parsed.path.endswith('/match'):
            result={'success':True,'isMatched':True,'matches':[{'episodeId':42000001,'animeTitle':'作品','episodeTitle':'第1话','shift':-2,'unknown':{'x':[1,2]}}]}
        elif parsed.path.endswith('/search/anime'):
            result={'success':True,'animes':[{'animeId':42000,'animeTitle':q.get('keyword',['作品'])[0]}]}
        elif parsed.path.endswith('/search/episodes'):
            result={'success':True,'animes':[{'animeId':42000,'animeTitle':'作品','episodes':[{'episodeId':42000001,'episodeTitle':'第1话'}]}]}
        else: result={'count':3,'comments':[{'cid':1,'p':'1,1,16777215,0','m':'scroll'},{'cid':2,'p':'2,5,255,0','m':'top'},{'cid':3,'p':'3,4,123,0','m':'bottom'}]}
        self.respond(result,headers={'X-Gateway-Cache':'HIT'})
    def do_GET(self):
        if self.path=='/stats': return self.respond(self.server.records)
        self.handle_gateway()
    def do_POST(self): self.handle_gateway()

if __name__=='__main__':
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads=True
    server.records=[]
    print(server.server_port,flush=True)
    server.serve_forever()

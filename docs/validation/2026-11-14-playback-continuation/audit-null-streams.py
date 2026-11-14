import ctypes,json,sys,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
sys.path.insert(0,'/Volumes/Backup/软件/OcPlayer-Core/tests')
import bangumi_account_contract as fixture
nullable=False
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  payload={'PlaySessionId':'session','MediaSources':[{'Id':'source','Size':9223372036854775807,'SupportsDirectPlay':True,'MediaStreams':None if nullable else []}]}
  body=json.dumps(payload).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
fixture.AccountContract.setUpClass();case=fixture.AccountContract();case.setUp()
try:
 results=[]
 for kind in ['jellyfin','emby']:
  for nullable in [False,True]:
   args={'profile':{'id':'probe','kind':kind,'baseURL':'http://127.0.0.1:'+str(server.server_port),'userID':'user','token':'fixture-token'},'itemId':'item'}
   pointer=case.ffi.ocp_call(case.core,b'playback.info',json.dumps(args).encode())
   try:response=json.loads(ctypes.string_at(pointer))
   finally:case.ffi.ocp_string_free(pointer)
   results.append({'kind':kind,'streams':None if nullable else [],'ok':response['ok'],'message':response['message']})
   assert response['ok'] is (not nullable),response
 print(json.dumps(results,ensure_ascii=False))
finally:case.tearDown();server.shutdown();server.server_close()

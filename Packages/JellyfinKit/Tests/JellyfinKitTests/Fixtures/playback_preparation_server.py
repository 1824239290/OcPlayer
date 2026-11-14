import json,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs
records=[];lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def reply(self,body,status=200):
  data=json.dumps(body,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers()
  try:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
 def record(self,body=None):
  with lock:records.append(dict(method=self.command,path=urlsplit(self.path).path,query=parse_qs(urlsplit(self.path).query),authorization=self.headers.get('Authorization'),body=body))
 def do_GET(self):
  path=urlsplit(self.path).path
  if path=='/stats':
   with lock:body=list(records)
   self.reply(body);return
  self.record()
  if path.endswith('/System/Info/Public'):self.reply({'Id':'fixture','ServerName':'fixture','Version':'10.10.7'});return
  if path.endswith('/Shows/order/Episodes'):
   query=parse_qs(urlsplit(self.path).query)
   if 'startItemId' in query:
    items=[{'Id':'current','Name':'current','Type':'Episode','ParentIndexNumber':2,'IndexNumber':10},{'Id':'interstitial','Name':'interstitial','Type':'Episode','ParentIndexNumber':0,'IndexNumber':1}]
   else:
    items=[{'Id':'second','Name':'second','Type':'Episode','ParentIndexNumber':2,'IndexNumber':1},{'Id':'unknown','Name':'unknown','Type':'Episode','IndexNumber':1},{'Id':'maximum','Name':'maximum','Type':'Episode','ParentIndexNumber':2147483647,'IndexNumber':9},{'Id':'special','Name':'special','Type':'Episode','ParentIndexNumber':0,'IndexNumber':4},{'Id':'first','Name':'first','Type':'Episode','ParentIndexNumber':1,'IndexNumber':3}]
   self.reply({'Items':items,'TotalRecordCount':len(items)});return
  if path.endswith('/Episodes'):
   self.reply({'Items':[{'Id':'episode','Name':'本集','Type':'Episode','SeriesId':'series','SeriesName':'完整剧名','ParentIndexNumber':1,'IndexNumber':2,'RunTimeTicks':72000000000,'Overview':'原始完整简介','UserData':{'Key':'episode','Played':False,'PlaybackPositionTicks':12500000}}],'TotalRecordCount':1});return
  self.reply({},404)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}');self.record(body)
  if urlsplit(self.path).path.endswith('/PlaybackInfo'):
   self.reply({'PlaySessionId':'native-session','MediaSources':[
    {'Id':'stream','Name':'直推','Path':'/media/stream.mkv','Size':123,'SupportsDirectPlay':False,'SupportsDirectStream':True,'RunTimeTicks':71000000000},
    {'Id':'direct','Name':'直连原盘','Path':'/原盘/片.mkv','Size':9223372036854775807,'Container':'mkv','SupportsDirectPlay':True,'SupportsDirectStream':True,'RunTimeTicks':72002500000,'MediaStreams':[{'Type':'Video','VideoRangeType':'HDR10'}]}
   ]});return
  self.reply({},404)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()

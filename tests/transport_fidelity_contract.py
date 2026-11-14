#!/usr/bin/env python3
"""Compressed bodies, native headers, redirects, streaming and schema extensions."""
import base64,concurrent.futures,ctypes,gzip,json,os,subprocess,threading,time,unittest,zlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
BODY=b'{"page":1,"results":[],"total_pages":1,"total_results":0}'
BROTLI=base64.b64decode('GzgAUJwHto1s+0YQlr9qrVCLdH3tDZ1i6WsRmJgt4JADx0P2eWBRsAEHEfU87flEOYct+1UQNQ==')
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  path=urlsplit(self.path).path;coding=path.strip('/').split('/')[0]
  self.server.paths.append(path)
  if path=='/redirect':
   self.send_response(302);self.send_header('Location','/gzip');self.send_header('Content-Length','0');self.end_headers();return
  if path.endswith('/search/title/stream'):
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Encoding','gzip');self.send_header('Transfer-Encoding','chunked');self.end_headers()
   encoder=zlib.compressobj(wbits=31)
   try:
    for index,data in enumerate([b'data: {"type":"progress","text":"first"}\n\n',b'data: {"type":"done","text":"done"}\n\n']):
     payload=encoder.compress(data)+encoder.flush(zlib.Z_SYNC_FLUSH if index==0 else zlib.Z_FINISH)
     self.wfile.write(f'{len(payload):X}\r\n'.encode()+payload+b'\r\n');self.wfile.flush()
     if index==0:time.sleep(1)
    self.wfile.write(b'0\r\n\r\n');self.wfile.flush()
   except (BrokenPipeError,ConnectionResetError):pass
   return
  data=BODY
  if path.endswith('/System/Info/Public'):data=b'{"Id":"compressed","ServerName":"fixture","ProductName":"Emby"}'
  elif path.endswith('/user/current'):data=b'{"id":9007199254740993,"name":"fixture","permissions":{"search":true},"is_active":true}'
  if coding=='gzip':data=gzip.compress(data)
  elif coding=='deflate':data=zlib.compress(data)
  elif coding=='br':data=BROTLI
  elif coding=='stacked':data=zlib.compress(gzip.compress(data));coding='gzip, deflate'
  elif coding=='multi':data=gzip.compress(data[:20])+gzip.compress(data[20:]);coding='gzip'
  elif coding=='invalid':data=b'invalid compressed bytes';coding='gzip'
  else:coding='identity'
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Encoding',coding);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
class TransportFidelity(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.ffi=ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH']);f=cls.ffi
  f.ocp_core_create.argtypes=[ctypes.c_char_p];f.ocp_core_create.restype=ctypes.c_void_p
  f.ocp_core_destroy.argtypes=[ctypes.c_void_p]
  f.ocp_call.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];f.ocp_call.restype=ctypes.c_void_p
  f.ocp_poll_event.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)];f.ocp_poll_event.restype=ctypes.c_int
  f.ocp_string_free.argtypes=[ctypes.c_void_p]
 def setUp(self):
  self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.server.daemon_threads=True;self.server.paths=[]
  self.thread=threading.Thread(target=self.server.serve_forever);self.thread.start()
  self.base=f'http://127.0.0.1:{self.server.server_port}';self.core=self.ffi.ocp_core_create(b'{}')
 def tearDown(self):
  self.ffi.ocp_core_destroy(self.core);self.server.shutdown();self.server.server_close();self.thread.join()
 def call(self,method,**args):
  p=self.ffi.ocp_call(self.core,method.encode(),json.dumps(args).encode());self.assertTrue(p)
  try:return json.loads(ctypes.string_at(p))
  finally:self.ffi.ocp_string_free(p)
 def success(self,method,**args):
  reply=self.call(method,**args);self.assertTrue(reply['ok'],reply);return reply['data']
 def test_all_codings_decode_as_native_and_keep_raw_headers(self):
  probe=os.environ['OCP_NATIVE_HTTP_PROBE_PATH']
  for coding in ['gzip','deflate','br','multi']:
   with self.subTest(coding=coding):
    url=self.base+'/'+coding
    native=json.loads(subprocess.check_output([probe,url],text=True));self.assertFalse(native['error'])
    core=self.success('bangumi.request',url=url)
    self.assertEqual(core['status'],native['status'])
    self.assertEqual(core['body'].encode(),base64.b64decode(native['bodyBase64']))
    self.assertEqual(core['body'].encode(),BODY[:20] if coding=='multi' else BODY)
    self.assertEqual(core['headers']['content-encoding'],native['encoding'])
    self.assertEqual(core['headers']['content-length'],native['length'])
 def test_native_rejected_encoding_chains_fail_without_replay(self):
  url=self.base+'/stacked'
  native=json.loads(subprocess.check_output([os.environ['OCP_NATIVE_HTTP_PROBE_PATH'],url],text=True))
  self.assertTrue(native['error'])
  self.assertFalse(self.call('bangumi.request',url=url)['ok'])
  self.assertEqual(self.server.paths.count('/stacked'),2)
 def test_json_domain_decoding_and_probe_share_the_decompressor(self):
  for coding in ['gzip','deflate','br']:
   self.success('tmdb.search',apiBase=self.base+'/'+coding,apiKey='fixture',query='fixture')
  result=self.success('endpoint.probe',url=self.base+'/gzip')
  self.assertEqual(result['serverID'],'compressed')
 def test_same_origin_redirect_preserves_decoded_reply(self):
  value=self.success('bangumi.request',url=self.base+'/redirect',headers={'Authorization':'Bearer fixture'})
  self.assertEqual(value['body'].encode(),BODY)
  self.assertIn('/gzip',self.server.paths)
 def test_bad_compressed_body_is_not_replayed(self):
  reply=self.call('bangumi.request',url=self.base+'/invalid');self.assertFalse(reply['ok'])
  self.assertEqual(self.server.paths.count('/invalid'),1)
  self.assertTrue(self.call('ping')['ok'])
 def test_moviepilot_permission_map_is_an_ignored_native_extension(self):
  data=self.success('moviepilot.currentUser',baseURL=self.base+'/gzip',accessToken='fixture')
  self.assertEqual(data['user']['id'],9007199254740993)
  self.assertEqual(data['user']['name'],'fixture')
  self.assertIsNone(data['user']['permissions'])
 def test_compressed_sse_delivers_events_before_the_body_finishes(self):
  with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
   pending=pool.submit(self.success,'moviepilot.torrentSearch',baseURL=self.base+'/gzip',accessToken='fixture',keyword='fixture',requestId='compressed-stream')
   deadline=time.monotonic()+0.8;observed=False
   while time.monotonic()<deadline and not observed:
    p=ctypes.c_void_p();status=self.ffi.ocp_poll_event(self.core,ctypes.byref(p))
    if status==1:
     try:event=json.loads(ctypes.string_at(p))
     finally:self.ffi.ocp_string_free(p)
     observed=event['kind']=='moviepilot.searchProgress' and event['data']['requestId']=='compressed-stream'
    else:time.sleep(.01)
   self.assertTrue(observed,'decoder buffered the complete SSE body')
   self.assertFalse(pending.done());pending.result(timeout=3)
if __name__=='__main__':unittest.main(verbosity=2)

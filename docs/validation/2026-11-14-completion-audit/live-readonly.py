"""Read-only server checks; credentials and raw server payloads are never logged."""
import base64,ctypes,json,os,plistlib,threading,time
from pathlib import Path
f=ctypes.CDLL(os.environ['OCP_CORE_LIBRARY_PATH'])
f.ocp_core_create.argtypes=[ctypes.c_char_p];f.ocp_core_create.restype=ctypes.c_void_p
f.ocp_core_destroy.argtypes=[ctypes.c_void_p]
f.ocp_call.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];f.ocp_call.restype=ctypes.c_void_p
f.ocp_string_free.argtypes=[ctypes.c_void_p]
core=f.ocp_core_create(b'{}');report=[]
def call(method,args):
 p=f.ocp_call(core,method.encode(),json.dumps(args).encode())
 if not p:return dict(ok=False,code=-1,data=None)
 try:return json.loads(ctypes.string_at(p))
 finally:f.ocp_string_free(p)
def bounded(method,args,label):
 request='live-'+str(len(report));args=dict(args,requestId=request)
 timer=threading.Timer(8,lambda:call('request.cancel',dict(requestId=request)))
 start=time.monotonic();timer.start()
 try:reply=call(method,args)
 finally:timer.cancel();timer.join()
 report.append(dict(label=label,method=method,ok=reply['ok'],code=reply['code'],seconds=round(time.monotonic()-start,3)))
 return reply.get('data') if reply['ok'] else None
prefs=plistlib.loads(Path('/Users/jumusu/Library/Preferences/dev.jumusu.OcPlayer.plist').read_bytes())
profiles=json.loads(prefs['dev.jumusu.ocplayer.servers'])
creds=json.loads(Path('/Users/jumusu/Library/Application Support/OcPlayer/credentials.json').read_text())
try:
 for index,p in enumerate(profiles):
  encoded=creds.get('jellyfin.token.'+p['id'])
  token=base64.b64decode(encoded).decode() if encoded else None
  profile=dict(id=p['id'],kind=p['kind'],baseURL=p['baseURL'],userID=p.get('userID'),token=token,userAgent='OcPlayer-Core parity audit')
  label=f'saved-server-{index+1}-{p["kind"]}'
  public=bounded('server.probe',dict(profile=profile),label)
  if public is None:
   for address_index,address in enumerate(p.get('addresses',[])):
    url=address if isinstance(address,str) else address.get('url') or address.get('baseURL') or address.get('baseUrl')
    if not url or url==profile['baseURL']:continue
    profile['baseURL']=url
    public=bounded('server.probe',dict(profile=profile),label+'-alternate-'+str(address_index+1))
    if public is not None:break
   if public is None:continue
  libraries=bounded('server.libraries',dict(profile=profile),label)
  recent=bounded('browse.latest',dict(profile=profile,limit=2),label)
  bounded('browse.resume',dict(profile=profile,limit=2),label)
  if recent:
   item=(recent.get('items',[]) if isinstance(recent,dict) else recent)[0]
   item_id=item.get('id') or item.get('Id')
   if item_id:
    for method in ['browse.detail','media.fileInfo','media.segments','media.subtitles']:
     bounded(method,dict(profile=profile,itemId=item_id),label)
 tmdbkey=prefs.get('dev.jumusu.ocplayer.tmdb.apiKey')
 if tmdbkey:
  bounded('tmdb.search',dict(apiKey=tmdbkey,query='Spirited Away',kind='movie',language='zh-CN'),'configured-tmdb-public-search')
 bounded('bangumi.calendar',{},'bangumi-public-calendar')
 mpbase=prefs.get('dev.jumusu.ocplayer.moviepilot.serverURL')
 mptoken=creds.get('moviepilot.token')
 if mpbase and mptoken:
  if "://" not in mpbase:mpbase="http://"+mpbase
  mptoken=base64.b64decode(mptoken).decode()
  for method,args in [('moviepilot.currentUser',{}),('moviepilot.mediaSearch',{'title':'Spirited Away'}),('moviepilot.subscription.list',{})]:
   bounded(method,dict(baseURL=mpbase,accessToken=mptoken,**args),'configured-moviepilot-readonly')
  raw=bounded('moviepilot.request',dict(baseURL=mpbase,accessToken=mptoken,url=mpbase.rstrip('/')+'/api/v1/user/current',httpMethod='GET'),'moviepilot-user-wire-inspection')
  if raw and raw.get('bodyBase64'):
   body=json.loads(base64.b64decode(raw['bodyBase64']))
   if isinstance(body,dict) and isinstance(body.get('data'),dict):body=body['data']
   shape={k:type(v).__name__ for k,v in body.items()} if isinstance(body,dict) else type(body).__name__
   Path(__file__).with_name('moviepilot-user-field-types.json').write_text(json.dumps(shape,indent=2)+'\n')
finally:f.ocp_core_destroy(core)
Path(__file__).with_name('live-readonly-results.json').write_text(json.dumps(dict(readOnly=True,credentialsLogged=False,checks=report),indent=2)+'\n')
print(json.dumps(report))

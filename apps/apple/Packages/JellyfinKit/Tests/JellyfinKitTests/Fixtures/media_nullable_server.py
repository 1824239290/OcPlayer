from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs
import json,threading
records=[];lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,data,status=200):
  body=json.dumps(data,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def case(self):return urlsplit(self.path).path.split('/')[2]
 def item(self):
  case=self.case();item={'Id':'item','Name':'原生片名','Type':'Movie','Overview':'完整简介','OriginalTitle':'原題','ProductionYear':2026,'Genres':None,'People':None,'ImageTags':None,'BackdropImageTags':None,'ProviderIds':None,'UserData':{'Key':'item','Played':None,'PlaybackPositionTicks':None,'PlayedPercentage':None,'UnplayedItemCount':None},'RunTimeTicks':72002500000}
  if case=='full_movie' or case=='full_episode' or case=='full_season':
   item.update(Genres=['科幻'],ImageTags={'Thumb':'thumb'},BackdropImageTags=['backdrop','second'],AlbumPrimaryImageTag='album-primary',SeriesPrimaryImageTag='series-primary',ParentLogoImageTag='parent-logo',ParentLogoItemId='logo-parent',SeriesThumbImageTag='series-thumb',ParentThumbItemId='thumb-parent',ParentThumbImageTag='parent-thumb',ParentBackdropItemId='backdrop-parent',ParentBackdropImageTags=['parent-backdrop','later'],ParentPrimaryImageItemId='primary-parent',ParentPrimaryImageTag='parent-primary',ProviderIds={'Tmdb':'123','Mal':'456','AniList':'789'},SeriesId='series',SeriesName='剧名',SeasonId='wrong-parent-season',SeasonName='错误季名',ParentIndexNumber=99,IndexNumber=3)
   if case=='full_episode':item['Type']='Episode'
   if case=='full_season':item['Type']='Season'
  if case in ('emby_markers','emby_marker_fallback','emby_marker_unknown'):
   item['Chapters']=[{'StartPositionTicks':100000000,'MarkerType':1},{'StartPositionTicks':200000000,'MarkerType':'IntroEnd'},{'StartPositionTicks':70000000000,'MarkerType':'CREDITSSTART'}]
   if case=='emby_marker_fallback':item['Chapters'][1]['MarkerType']=0
   if case=='emby_marker_unknown':item['Chapters']=[{'StartPositionTicks':1,'MarkerType':{'bad':True}},{'StartPositionTicks':2,'MarkerType':99},{'MarkerType':'IntroStart'}]
  if case=='containers_null':item['Chapters']=None
  if case=='containers_empty':item['Chapters']=[]
  if case=='wrong_chapters':item['Chapters']=1
  if case=='missing_identity':item.update(Id=None,Name=None)
  if case=='null_name':item['Name']=None
  if case=='null_kind':item['Type']=None
  if case=='partial_people':item['People']=[{'Id':None,'Name':'跳过'},{'Id':'skip','Name':None},{'Id':'person','Name':'演员','Role':'角色','Type':None}]
  if case=='wrong_genres':item['Genres']=1
  if case=='wrong_people':item['People']='bad'
  if case=='wrong_images':item['ImageTags']={'Primary':1}
  if case=='wrong_ticks':item['UserData']['PlaybackPositionTicks']='bad'
  return item
 def list(self,items):
  case=self.case()
  if case=='containers_missing':return {}
  if case=='containers_null':return {'Items':None,'TotalRecordCount':None,'StartIndex':None}
  if case=='containers_empty':return {'Items':[],'TotalRecordCount':0,'StartIndex':0}
  if case=='wrong_list':return {'Items':1}
  return {'Items':items,'TotalRecordCount':len(items),'StartIndex':0}
 def do_GET(self):
  path=urlsplit(self.path).path;query=parse_qs(urlsplit(self.path).query)
  if path=='/stats':
   with lock:data=list(records)
   self.send(data);return
  with lock:records.append({'method':'GET','path':path,'query':query})
  if path.endswith('/System/Info/Public'):self.send({'Id':'fixture','ServerName':'fixture','Version':'10.10.7'});return
  if path.endswith('/UserViews') or path.endswith('/Views'):
   views=[{'Id':'movies','Name':None,'CollectionType':'Movies','ImageTags':None},{'Id':'boxes','Name':'合集','CollectionType':'BoxSets'},{'Id':'mixed','CollectionType':'mixed'},{'Id':'folders','CollectionType':'folders'}]
   if self.case()=='library_missing_identity':views[0]['Id']=None
   if not self.headers.get('Authorization','').startswith('Emby '):
    for view in views:view['CollectionType']=view['CollectionType'].lower() if view['CollectionType']!='mixed' else None
   self.send(self.list(views));return
  if path.endswith('/Items/Latest'):
   self.send([] if self.case().startswith('containers_') else [self.item()]);return
  if path.endswith('/MediaSegments/item'):self.send(self.list([]));return
  if path.endswith('/Items/item'):
   if self.headers.get('Authorization','').startswith('Emby ') and not path.endswith('/Users/user/Items/item'):
    self.send({'error':'Emby requires legacy user detail path'},404);return
   fields=query.get('fields',[''])[0].split(',')
   if fields!=['Chapters'] and 'People' not in fields:
    self.send({'error':'detail must explicitly request People'},400);return
   self.send(self.item());return
  if 'ids' in query:
   source={'Id':'source','Name':'原盘','Size':9223372036854775807,'Path':'/原盘/片.mkv','SupportsDirectPlay':True,'RunTimeTicks':72002500000,'MediaStreams':None}
   case=self.case()
   if case=='no_streams':source.pop('MediaStreams')
   if case=='empty_streams':source['MediaStreams']=[]
   if case=='wrong_streams':source['MediaStreams']='bad'
   item={'Id':'item','MediaSources':[source]}
   if case=='null_sources':item['MediaSources']=None
   if case=='missing_sources':item.pop('MediaSources')
   if case=='wrong_sources':item['MediaSources']=1
   self.send(self.list([item]));return
  self.send(self.list([self.item()]))
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  with lock:records.append({'method':'POST','path':urlsplit(self.path).path})
  case=self.case();source={'Id':'source','Name':'原盘','Size':9223372036854775807,'Path':'/原盘/片.mkv','SupportsDirectPlay':True,'RunTimeTicks':72002500000,'MediaStreams':None}
  if case=='no_streams':source.pop('MediaStreams')
  if case=='empty_streams':source['MediaStreams']=[]
  if case=='wrong_streams':source['MediaStreams']='bad'
  info={'PlaySessionId':'session','MediaSources':[source]}
  if case=='null_sources':info['MediaSources']=None
  if case=='missing_sources':info.pop('MediaSources')
  if case=='wrong_sources':info['MediaSources']=1
  self.send(info)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);print(server.server_port,flush=True);server.serve_forever()

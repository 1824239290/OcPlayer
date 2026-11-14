"""Native media-source and track projection fixture with observable HTTP requests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
import json
import threading

records = []
lock = threading.Lock()


def streams():
    return [
        {'Index':0,'Type':'Video','Codec':'hevc','Width':3840,'Height':2160,'BitRate':24500000,'AverageFrameRate':23.976,'RealFrameRate':24,'BitDepth':10,'ColorPrimaries':'bt2020','ColorTransfer':'smpte2084','ColorSpace':'bt2020nc','ColorRange':'tv','VideoRangeType':'DOVIWithHDR10','Profile':'Main 10','IsInterlaced':False},
        {'Index':1,'Type':'Audio','Codec':'truehd','Channels':8,'ChannelLayout':'7.1','SampleRate':48000,'BitRate':4200000,'Language':'jpn','Title':'日语原声','IsDefault':True},
        {'Index':2,'Type':'Audio','Codec':'aac','Channels':2,'Title':None,'DisplayTitle':'显示音轨'},
        {'Index':3,'Type':'Subtitle','Codec':'ASS','Language':'chi','Title':None,'DisplayTitle':'简中外挂','IsExternal':True,'IsDefault':True,'IsForced':False},
        {'Index':4,'Type':'Subtitle','Codec':'subrip','Title':'内封','IsExternal':False,'IsForced':True},
        {'Index':5,'Type':'Subtitle','Codec':'pgssub','IsExternal':True,'DisplayTitle':'图像字幕'},
        {'Index':6,'Type':'Subtitle','Codec':'WEBVTT','IsExternal':True,'Title':'英语外挂','Language':'eng'},
        {'Index':7,'Type':'Subtitle','Codec':'SSA','IsExternal':True,'Title':'旧字幕'},
        {'Index':None,'Type':'Subtitle','Codec':'srt','IsExternal':True},
        {'Index':8,'Type':'Subtitle','Codec':None,'IsExternal':True},
    ]


def sources(case):
    rows = [
        {'Id':'stream','SupportsDirectPlay':False,'SupportsDirectStream':True,'MediaStreams':[{'Index':3,'Type':'Subtitle','Codec':'srt','Title':'直推资源','IsExternal':True}],'Path':'/stream.mkv'},
        {'Id':'play','SupportsDirectPlay':True,'SupportsDirectStream':False,'Container':'mkv','Size':9223372036854775807,'RunTimeTicks':72002500000,'Path':'/原盘/剧名 第1集.mkv','MediaStreams':streams(),'PluginData':{'keep':'unknown'}},
        {'Id':'other','SupportsDirectPlay':False,'MediaStreams':[{'Index':3,'Type':'Subtitle','Codec':'ass','Title':'另一资源','IsExternal':True}]},
    ]
    if case=='stream_only':rows[1]['SupportsDirectPlay']=False
    if case=='none_playable':
        for row in rows:row['SupportsDirectPlay']=False;row['SupportsDirectStream']=False
    if case=='empty':return []
    if case=='missing_ids':
        for row in rows:row.pop('Id')
    video=rows[1]['MediaStreams'][0]
    if case=='fps_zero':video.update(AverageFrameRate=0,RealFrameRate=29.97)
    if case=='fps_high':video.update(AverageFrameRate=1000,RealFrameRate=25)
    if case=='fps_negative':video.update(AverageFrameRate=-1,RealFrameRate=24)
    if case=='fps_invalid':video.update(AverageFrameRate=1001,RealFrameRate=0)
    if case=='fps_round':video.update(AverageFrameRate=999.99999,RealFrameRate=25)
    if case=='fps_small':video.update(AverageFrameRate=1e-50,RealFrameRate=24)
    if case=='fps_overflow':video['AverageFrameRate']=1e100
    if case=='fps_missing':video.pop('AverageFrameRate');video['RealFrameRate']=60
    if case=='null_fields':
        rows[1].update(Size=None,RunTimeTicks=None,Path=None,Container=None)
        for stream in rows[1]['MediaStreams']:
            for key in list(stream):
                if key not in ('Index','Type','Codec','IsExternal'):stream[key]=None
    paths={'path_root':'/','path_trailing':'/folder/','path_empty':'','path_windows':'C:\\folder\\file.mkv'}
    if case in paths:rows[1]['Path']=paths[case]
    if case=='wrong_size':rows[1]['Size']='huge'
    if case=='wrong_ticks':rows[1]['RunTimeTicks']='ticks'
    if case=='wrong_supports':rows[1]['SupportsDirectPlay']=1
    if case=='wrong_width':video['Width']='wide'
    if case=='wrong_rate':video['AverageFrameRate']='23.976'
    if case=='wrong_sample':rows[1]['MediaStreams'][1]['SampleRate']='48000'
    if case=='wrong_flag':rows[1]['MediaStreams'][3]['IsExternal']='true'
    if case=='unknown_stream':rows[1]['MediaStreams'].append({'Type':'Attachment','Codec':'ttf'})
    if case=='lower_stream':rows[1]['MediaStreams'].append({'Type':'subtitle','Index':9,'IsExternal':True,'Codec':'srt'})
    if case=='unknown_range':video['VideoRangeType']='FutureHDR'
    return rows


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def reply(self,value,status=200):
        body=json.dumps(value,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_GET(self):
        path=urlsplit(self.path).path;query=parse_qs(urlsplit(self.path).query,keep_blank_values=True)
        if path=='/stats':
            with lock:value=list(records)
            self.reply(value);return
        with lock:records.append({'method':'GET','path':path,'query':query})
        if path.endswith('/System/Info/Public'):
            self.reply({'Id':'fixture','ServerName':'fixture','Version':'10.10.7'});return
        if path.endswith('/Items') and query.get('ids')==['item'] and query.get('fields')==['MediaSources']:
            case=path.split('/')[2]
            self.reply({'Items':[{'Id':'item','MediaSources':sources(case),'PluginField':'preserved'}],'PluginEnvelope':{'unknown':[1,2,3]}});return
        self.reply({'error':'unexpected request'},400)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        with lock:records.append({'method':'POST','path':urlsplit(self.path).path})
        self.reply({'error':'media metadata must not create a playback session'},400)


server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()

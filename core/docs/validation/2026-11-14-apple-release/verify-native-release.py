from pathlib import Path
import hashlib,json,os,re,struct,subprocess
root=Path('/tmp/ocp-apple-delivery');core=Path('/Volumes/Backup/软件/OcPlayer-Core')
out=root/'native-verification';out.mkdir(exist_ok=False)
app=root/'NativeRelease/Build/Products/Release/OcPlayer.app'
library=root/'universal-macos/libocp_ffi.dylib'
def run(args,name,env=None,timeout=120):
 with (out/name).open('w') as log:
  r=subprocess.run(args,cwd=core,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=timeout)
  log.write('\nEXIT_STATUS='+str(r.returncode)+'\n')
 assert r.returncode==0,name
run(['Scripts/embed-macos-core.sh',str(app),str(library)],'embed.log')
run(['codesign','--verify','--deep','--strict','--verbose=2',str(app)],'signature.log')
def sections(path):
 data=path.read_bytes()
 def thin(data):
  assert struct.unpack_from('<I',data)[0]==0xfeedfacf
  cursor=32;result={}
  for _ in range(struct.unpack_from('<I',data,16)[0]):
   command,length=struct.unpack_from('<II',data,cursor)
   if command==0x19:
    for i in range(struct.unpack_from('<I',data,cursor+64)[0]):
     section=struct.unpack_from('<16s16sQQIIIIIIII',data,cursor+72+80*i)
     name,segment,_,size,offset,_,_,_,flags,*_=section
     if offset and size and (flags&255) not in (1,12,18):
      key=segment.rstrip(b'\0').decode()+'/'+name.rstrip(b'\0').decode()
      result[key]=hashlib.sha256(data[offset:offset+size]).hexdigest()
   cursor+=length
  return result
 magic=struct.unpack_from('>I',data)[0]
 if magic==0xcafebabe:
  result={}
  for i in range(struct.unpack_from('>I',data,4)[0]):
   cpu,_,offset,size,_=struct.unpack_from('>IIIII',data,8+20*i)
   name={0x100000c:'arm64',0x1000007:'x86_64'}[cpu]
   result[name]=thin(data[offset:offset+size])
  assert set(result)=={'arm64','x86_64'}
  return result
 raise AssertionError('Expected universal macOS dylib')
runtime=sections(library);assert runtime==sections(app/'Contents/Frameworks/libocp_ffi.dylib')
media=[]
for name,file,seconds,controls in [('playback','/tmp/ocplayer-core-playback.mp4',10,1),('eof','/tmp/ocp-repository-flow-eof.mp4',8,0)]:
 env=dict(os.environ);env.pop('OCP_CORE_ENABLED',None);env.pop('OCP_CORE_LIBRARY_PATH',None)
 env.update(OCPLAYER_SELFTEST_TOKEN='ocp-selftest-v1',OCPLAYER_SELFTEST_FILE=file,OCPLAYER_SELFTEST_SECONDS=str(seconds),OCPLAYER_SELFTEST_CONTROLS=str(controls),OCPLAYER_SELFTEST_LOG=str(out/(name+'.log')))
 run([str(app/'Contents/MacOS/OcPlayer')],name+'-process.log',env,60)
 text=(out/(name+'.log')).read_text()
 assert not re.search(r'(?:渲染失败|音频失败) [1-9]',text),name
 assert 'done' in text and '渲染失败 0' in text and '音频失败 0' in text,name
 if name=='eof':assert 'core=ended' in text
 media.append({'name':name,'seconds':seconds,'controls':bool(controls),'fileSHA256':hashlib.sha256(Path(file).read_bytes()).hexdigest(),'exitStatus':0,'renderFailures':0,'audioFailures':0})
summary={'configuration':'Release','deepStrictAdHocSignature':True,'runtimeSections':runtime,'playback':media,'app':str(app),'library':str(library)}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'configuration':'Release','signature':True,'matchingRuntimeSections':{key:len(value) for key,value in runtime.items()},'media':media}))

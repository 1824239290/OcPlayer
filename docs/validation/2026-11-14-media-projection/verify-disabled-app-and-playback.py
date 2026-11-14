from pathlib import Path
import subprocess,os,json,plistlib
out=Path('/tmp/ocp-media-projection-macos');native=Path('/Users/jumusu/Documents/project/OcPlayer');core=Path('/Volumes/Backup/软件/OcPlayer-Core')
base=['xcodebuild','-project',str(native/'OcPlayer.xcodeproj'),'-scheme','OcPlayer-macOS','-configuration','Debug','-destination','platform=macOS,arch=arm64','-derivedDataPath',str(out/'DerivedData'),'-disableAutomaticPackageResolution','CODE_SIGNING_ALLOWED=NO']
def run(args,name,env=None,timeout=None):
 with (out/name).open('w') as log:
  r=subprocess.run(args,cwd=core,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=timeout)
  log.write('\nEXIT_STATUS='+str(r.returncode)+'\n')
 if r.returncode:raise SystemExit(str(args[0])+' failed: '+name)
run(base+['build-for-testing'],'build-for-testing.log')
products=out/'DerivedData/Build/Products'
original=max(products.glob('OcPlayer-macOS_*.xctestrun'),key=lambda p:p.stat().st_mtime)
data=plistlib.loads(original.read_bytes());targets=[]
def update(value):
 if isinstance(value,dict):
  if value.get('BlueprintName')=='OcPlayerTests' or value.get('TestTargetName')=='OcPlayerTests':
   for key in ['EnvironmentVariables','TestingEnvironmentVariables']:
    env=value.setdefault(key,{});env['OCP_CORE_ENABLED']='0';env.pop('OCP_CORE_LIBRARY_PATH',None)
   targets.append({'target':'OcPlayerTests','OCP_CORE_ENABLED':'0'})
  for child in value.values():update(child)
 elif isinstance(value,list):
  for child in value:update(child)
update(data);assert targets
disabled=products/'OcPlayer-media-projection-disabled.xctestrun';disabled.write_bytes(plistlib.dumps(data))
args=['xcodebuild','test-without-building','-xctestrun',str(disabled),'-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO','-only-testing:OcPlayerTests/CollectionPlaybackTests','-only-testing:OcPlayerTests/PlaybackSourceFailoverTests','-only-testing:OcPlayerTests/AppPlaybackContinuationTests']
(out/'disabled-app-environment.json').write_text(json.dumps(dict(originalXctestrun=str(original),disabledXctestrun=str(disabled),targets=targets,command=args),indent=2)+'\n')
run(args,'disabled-app-preparation.log')
app=out/'DerivedData/Build/Products/Debug/OcPlayer.app'
run(['Scripts/embed-macos-core.sh',str(app),str(out/'libocp_ffi.dylib')],'macos-embed-final.log')
run(['codesign','--verify','--deep','--strict','--verbose=2',str(app)],'signature.log')
for name,file,seconds,controls in [('playback','/tmp/ocplayer-core-playback.mp4',10,1),('eof','/tmp/ocp-repository-flow-eof.mp4',8,0)]:
 env=dict(os.environ);env.pop('OCP_CORE_ENABLED',None);env.pop('OCP_CORE_LIBRARY_PATH',None)
 env.update(OCPLAYER_SELFTEST_TOKEN='ocp-selftest-v1',OCPLAYER_SELFTEST_FILE=file,OCPLAYER_SELFTEST_SECONDS=str(seconds),OCPLAYER_SELFTEST_CONTROLS=str(controls),OCPLAYER_SELFTEST_LOG=str(out/(name+'.log')))
 run([str(app/'Contents/MacOS/OcPlayer')],name+'-process.log',env,60)
print('disabled app, signature and bundled controls/EOF passed')

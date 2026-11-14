import hashlib,json,os,re,subprocess
from pathlib import Path
report=Path(__file__).resolve().parent
app=Path('/tmp/ocp-completion-final-gate/DerivedData/Build/Products/Debug/OcPlayer.app')
lib=app/'Contents/Frameworks/libocp_ffi.dylib'
rows=[]
cases=[('hevc-main10',Path('/tmp/ocp-completion-audit-media/hevc-main10.mkv'),False,8),('vp9-opus',Path('/tmp/ocp-completion-audit-media/vp9-opus.webm'),False,8),('av1-opus',Path('/tmp/ocp-completion-audit-media/av1-opus.mkv'),False,8),('h264-controls',Path('/tmp/ocplayer-core-playback.mp4'),True,10),('h264-eof',Path('/tmp/ocp-repository-flow-eof.mp4'),False,8)]
for name,clip,controls,seconds in cases:
 log=report/(name+'.final.selftest.log')
 env=dict(os.environ)
 for key in ['OCP_CORE_ENABLED','OCP_CORE_LIBRARY_PATH']:env.pop(key,None)
 env.update(OCPLAYER_SELFTEST_TOKEN='ocp-selftest-v1',OCPLAYER_SELFTEST_FILE=str(clip),OCPLAYER_SELFTEST_SECONDS=str(seconds),OCPLAYER_SELFTEST_CONTROLS=str(int(controls)),OCPLAYER_SELFTEST_LOG=str(log),OCPLAYER_ISOLATED_STORAGE='1')
 with (report/(name+'.final.process.log')).open('w') as output:
  process=subprocess.Popen([str(app/'Contents/MacOS/OcPlayer')],env=env,stdout=output,stderr=subprocess.STDOUT)
  try:code=process.wait(timeout=seconds+25)
  except subprocess.TimeoutExpired:
   process.terminate()
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:process.kill();process.wait()
   raise AssertionError(name+' did not exit')
 text=log.read_text(); core=[s for s in text.splitlines() if '[selftest] core=' in s]; native=[s for s in text.splitlines() if '渲染失败' in s]
 assert code==0 and core and native,(name,code)
 last=native[-1]; counts=dict((key,int(value)) for key,value in re.findall(r'(解码|渲染|音频|渲染失败|音频失败) (\d+)',last))
 assert counts['渲染失败']==counts['音频失败']==0 and counts['解码']>0 and counts['渲染']>0 and counts['音频']>0,(name,last)
 assert 'surface=true' in last,(name,last)
 if controls:
  processText=(report/(name+'.final.process.log')).read_text()
  assert len([s for s in processText.splitlines() if '[selftest] >>>' in s])>=6,(name,'missing controls')
  assert 'core=paused' in text and 'rate=2.0' in text and 'rate=1.0' in text,(name,'missing control snapshot')
 else:assert 'core=ended' in core[-1],(name,core[-1])
 rows.append(dict(name=name,exitCode=code,mediaSha256=hashlib.sha256(clip.read_bytes()).hexdigest(),bundledCoreSha256=hashlib.sha256(lib.read_bytes()).hexdigest(),controls=controls,ended='core=ended' in core[-1],lastCore=core[-1],lastNative=last,counts=counts))
 (report/'final-bundled-playback-results.json').write_text(json.dumps(rows,indent=2,ensure_ascii=False)+'\n')
 print(name,'passed',flush=True)

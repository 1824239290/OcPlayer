from pathlib import Path
import hashlib,json,os,stat,subprocess,zipfile
root=Path('/tmp/ocp-apple-delivery');app=root/'NativeRelease/Build/Products/Release/OcPlayer.app'
output=Path('/Volumes/Backup/软件/OcPlayer-Core/artifacts/apple-2026-11-14/OcPlayer-macOS.zip')
assert not output.exists()
exe=app/'Contents/MacOS/OcPlayer'
assert b'ocp-selftest-v1' not in exe.read_bytes()
archive_entries=0
with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for path in sorted(app.rglob('*')):
  relative=str(path.relative_to(app.parent))
  mode=path.lstat().st_mode
  if path.is_symlink():
   entry=zipfile.ZipInfo(relative);entry.create_system=3;entry.external_attr=mode<<16
   archive.writestr(entry,os.readlink(path).encode());archive_entries+=1
  elif path.is_file():
   archive.write(path,relative);archive_entries+=1
extracted=root/'ProductionArchiveCheck';extracted.mkdir(exist_ok=False)
with zipfile.ZipFile(output) as archive:
 for entry in archive.infolist():
  destination=extracted/entry.filename;destination.parent.mkdir(parents=True,exist_ok=True)
  mode=entry.external_attr>>16
  if stat.S_ISLNK(mode):destination.symlink_to(archive.read(entry).decode())
  else:
   with archive.open(entry) as source,destination.open('wb') as target:
    while data:=source.read(1024*1024):target.write(data)
   os.chmod(destination,stat.S_IMODE(mode))
verified=extracted/'OcPlayer.app'
with (root/'production-archive-signature.log').open('w') as log:
 result=subprocess.run(['codesign','--verify','--deep','--strict','--verbose=2',str(verified)],stdout=log,stderr=subprocess.STDOUT)
 log.write('\nEXIT_STATUS='+str(result.returncode)+'\n')
assert result.returncode==0
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(exe)==sha(verified/'Contents/MacOS/OcPlayer')
summary={'productionConfiguration':'Release','selfTestTokenAbsent':True,'zip':str(output),'sha256':sha(output),'entries':archive_entries,'executableSHA256':sha(exe),'extractedApp':str(verified),'extractedDeepStrictSignaturePassed':True}
(root/'production-app-receipt.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))

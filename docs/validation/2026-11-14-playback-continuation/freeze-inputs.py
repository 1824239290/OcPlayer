from pathlib import Path
import hashlib,json,tempfile,shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');out=Path('/tmp/ocp-continuation-macos');previous=Path('/tmp/ocp-preparation-macos');out.mkdir(exist_ok=True)
source=set(json.loads((previous/'source-inputs.json').read_text()))|{'crates/ocp-session/src/recovery.rs'}
gates=set(json.loads((previous/'gate-inputs.json').read_text()))
inputs=set(json.loads((previous/'native-inputs.json').read_text()))|{'AppTests/AppPlaybackContinuationTests.swift','Docs/SHARED-PLAYBACK-CONTINUATION.md'}
for name,paths,root in [('source-inputs.json',source,core),('gate-inputs.json',gates,core),('native-inputs.json',inputs,native)]:
 hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)};(out/name).write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n');print(name,len(hashes))
copy=Path(tempfile.mkdtemp(prefix='ocp-continuation-source-final-'));Path('/tmp/ocp-continuation-source-path').write_text(str(copy))
for p in source:
 dst=copy/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
print('independentCopy',copy)

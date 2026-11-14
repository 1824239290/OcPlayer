from pathlib import Path
import hashlib,json,tempfile,shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');out=Path('/tmp/ocp-media-projection-macos');previous=Path('/tmp/ocp-nullable-macos');out.mkdir(exist_ok=True)
source=set(json.loads((previous/'source-inputs.json').read_text()))|{'crates/ocp-core/src/media.rs'}
gates=set(json.loads((previous/'gate-inputs.json').read_text()))|{'tests/media_projection_contract.py','tests/media_projection_server.py'}
inputs=set(json.loads((previous/'native-inputs.json').read_text()))|{'Packages/JellyfinKit/Tests/JellyfinKitTests/MediaProjectionHTTPTests.swift','Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_projection_server.py','Docs/SHARED-MEDIA-PROJECTION.md'}
for name,paths,root in [('source-inputs.json',source,core),('gate-inputs.json',gates,core),('native-inputs.json',inputs,native)]:
 hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)};(out/name).write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n');print(name,len(hashes))
copy=Path(tempfile.mkdtemp(prefix='ocp-media-projection-source-final-'));Path('/tmp/ocp-media-projection-source-path').write_text(str(copy))
for p in source:
 dst=copy/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
(out/'DerivedData').mkdir(exist_ok=True)
print('independentCopy',copy)

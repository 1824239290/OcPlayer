from pathlib import Path
import hashlib,json,tempfile,shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');out=Path('/tmp/ocp-nullable-macos');previous=Path('/tmp/ocp-continuation-macos');out.mkdir(exist_ok=True)
source=set(json.loads((previous/'source-inputs.json').read_text()))
gates=set(json.loads((previous/'gate-inputs.json').read_text()))|{'tests/media_nullable_contract.py','tests/media_nullable_server.py'}
inputs=set(json.loads((previous/'native-inputs.json').read_text()))|{'Packages/JellyfinKit/Tests/JellyfinKitTests/MediaNullableHTTPTests.swift','Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_nullable_server.py','Docs/SHARED-MEDIA-NULLABILITY.md'}
for name,paths,root in [('source-inputs.json',source,core),('gate-inputs.json',gates,core),('native-inputs.json',inputs,native)]:
 hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)};(out/name).write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n');print(name,len(hashes))
copy=Path(tempfile.mkdtemp(prefix='ocp-nullable-source-final-'));Path('/tmp/ocp-nullable-source-path').write_text(str(copy))
for p in source:
 dst=copy/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
if not (out/'DerivedData').exists():(out/'DerivedData').symlink_to(previous/'DerivedData')
print('independentCopy',copy)

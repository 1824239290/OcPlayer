from pathlib import Path
import hashlib,json,shutil
out=Path('/tmp/ocp-continuation-macos');pre=out/'preliminary/before-wire-completion';pre.mkdir(parents=True,exist_ok=True)
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer')
for p in out.iterdir():
 if p.is_file() and p.suffix in ['.log','.json']:shutil.copy2(p,pre/p.name)
for p in ['bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpPlaybackFlow.swift','bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpPlaybackEvents.swift','bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpDanmakuLoader.swift','bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/OcpPlaybackPreparationTests.swift','docs/playback-continuation-contract.md']:
 dst=pre/'source'/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
exec(Path('/tmp/ocp-continuation-complete-wire-decode.py').read_text())
for name,root in [('source-inputs.json',core),('gate-inputs.json',core),('native-inputs.json',native)]:
 manifest=out/name;before=json.loads(manifest.read_text());after={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in before}
 print(name,'changed',[p for p in before if before[p]!=after[p]])
 manifest.write_text(json.dumps(after,ensure_ascii=False,indent=2)+'\n')

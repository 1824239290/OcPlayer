from pathlib import Path
import hashlib,json,tempfile,shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');output=Path('/tmp/ocp-preparation-macos');previous=Path('/tmp/ocp-tracks-macos');output.mkdir(exist_ok=True)
source=set(json.loads((previous/'source-inputs.json').read_text()))|{'crates/ocp-session/src/preparation.rs'}
gates=set(json.loads((previous/'gate-inputs.json').read_text()))|{'tests/playback_preparation_contract.py','tests/playback_preparation_server.py','bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpPlaybackPreparation.swift','bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/OcpPlaybackPreparationTests.swift'}
inputs=set(json.loads((previous/'native-inputs.json').read_text()))|{
'Packages/OcPlayerCore/Sources/OcPlayerCore/OcpPlaybackPreparation.swift',
'Packages/OcPlayerCore/Tests/OcPlayerCoreTests/OcpPlaybackPreparationTests.swift',
'Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPreparationWorkflow.swift',
'Packages/JellyfinKit/Tests/JellyfinKitTests/PlaybackPreparationFixture.swift',
'Packages/JellyfinKit/Tests/JellyfinKitTests/PlaybackPreparationWorkflowTests.swift',
'Packages/JellyfinKit/Tests/JellyfinKitTests/PlaybackPreparationHTTPTests.swift',
'Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/playback_preparation_server.py',
'Docs/SHARED-PLAYBACK-PREPARATION.md'}
for name,paths,root in [('source-inputs.json',source,core),('gate-inputs.json',gates,core),('native-inputs.json',inputs,native)]:
 hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)};(output/name).write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n');print(name,len(hashes))
copy=Path(tempfile.mkdtemp(prefix='ocp-preparation-source-final-'));Path('/tmp/ocp-preparation-source-path').write_text(str(copy))
for p in source:
 dst=copy/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
print('independentCopy',copy)

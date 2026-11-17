from pathlib import Path
import hashlib,json,tempfile,shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer');out=Path('/tmp/ocp-settings-backup-macos');previous=Path('/tmp/ocp-diagnostic-export-macos');out.mkdir(exist_ok=True)
source=set(json.loads((previous/'source-inputs.json').read_text()))|{'crates/ocp-core/src/settings_backup.rs'}
gates=set(json.loads((previous/'gate-inputs.json').read_text()))|{'tests/settings_backup_contract.py','bindings/apple/OcPlayerCore/Sources/OcPlayerCore/OcpSettingsBackup.swift','bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/OcpSettingsBackupTests.swift'}
inputs=set(json.loads((previous/'native-inputs.json').read_text()))|{'Packages/OcPlayerCore/Sources/OcPlayerCore/OcpSettingsBackup.swift','Packages/OcPlayerCore/Tests/OcPlayerCoreTests/OcpSettingsBackupTests.swift','AppTests/CoreSettingsBackupParityTests.swift','Docs/SHARED-SETTINGS-BACKUP.md'}
for name,paths,root in [('source-inputs.json',source,core),('gate-inputs.json',gates,core),('native-inputs.json',inputs,native)]:
 hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(paths)};(out/name).write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n');print(name,len(hashes))
copy=Path(tempfile.mkdtemp(prefix='ocp-settings-backup-source-final-'));Path('/tmp/ocp-settings-backup-source-path').write_text(str(copy))
for p in source:
 dst=copy/p;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(core/p,dst)
shutil.copy2(previous/'sdk-reference.json',out/'sdk-reference.json')
(out/'DerivedData').mkdir(exist_ok=True)
print('independentCopy',copy)

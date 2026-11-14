from pathlib import Path
import hashlib,json,re,shutil,subprocess,difflib
r=Path('/Users/jumusu/Documents/project/OcPlayer');source=r/'OcPlayer.xcodeproj';destination=r/'.OcPlayerReleaseProbe.xcodeproj'
assert not destination.exists()
shutil.copytree(source,destination)
p=destination/'project.pbxproj';original=p.read_text()
pattern=r'(1A0000000000000000000013 /\*[^*]+\*/ = \{.*?buildSettings = \{)'
updated,count=re.subn(pattern,lambda m:m.group(1)+'\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) OCPLAYER_SELFTEST";',original,flags=re.S)
assert count==1
p.write_text(updated)
def model(path):return json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
a=model(source/'project.pbxproj');b=model(p)
a['objects']['1A0000000000000000000013']['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) OCPLAYER_SELFTEST'
assert a==b
for scheme in destination.rglob('*.xcscheme'):
 scheme.write_text(scheme.read_text().replace('container:OcPlayer.xcodeproj','container:.OcPlayerReleaseProbe.xcodeproj'))
record={'sourceProjectSHA256':hashlib.sha256((source/'project.pbxproj').read_bytes()).hexdigest(),'probeProjectSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'onlyConfigurationChange':'OcPlayer-macOS Release: SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OCPLAYER_SELFTEST','sourceUntouched':(source/'project.pbxproj').read_text()==original,'project':str(destination)}
Path('/tmp/ocp-apple-delivery/probe-project-provenance.json').write_text(json.dumps(record,indent=2)+'\n')
Path('/tmp/ocp-apple-delivery/probe-project.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),updated.splitlines(True),fromfile='original',tofile='release-probe')))
print(json.dumps(record))

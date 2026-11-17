from pathlib import Path
import hashlib
import json
import re
import struct

output = Path('/tmp/ocp-moviepilot-flow-macos')
core = Path('/Volumes/Backup/软件/OcPlayer-Core')
native = Path('/Users/jumusu/Documents/project/OcPlayer')
source_copy = Path('/tmp/ocp-moviepilot-flow-source-path').read_text()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for name, root in [('source-inputs.json', core), ('native-inputs.json', native),
                   ('source-inputs.json', Path(source_copy))]:
    for relative, expected in json.loads((output / name).read_text()).items():
        assert digest(root / relative) == expected, relative

def rust_count(name):
    return sum(map(int, re.findall(r'test result: ok\. (\d+) passed;', (output / name).read_text())))

def swift_count(name):
    text = (output / name).read_text()
    runs = re.findall(r'Executed (\d+) tests, with ([^\n]+)', text)
    executed = skipped = failures = 0
    if runs:
        executed = int(runs[-1][0])
        tail = runs[-1][1]
        failures = int(re.search(r'(\d+) failures', tail)[1])
        skip = re.search(r'(\d+) tests skipped', tail)
        skipped = int(skip[1]) if skip else 0
    testing = re.findall(r'Test run with (\d+) tests.*passed', text)
    executed += int(testing[-1]) if testing else 0
    assert failures == 0, name
    return dict(executed=executed, passed=executed-skipped, skipped=skipped, failures=failures)

def sections(path):
    data = path.read_bytes()
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    commands = struct.unpack_from('<I', data, 16)[0]
    cursor = 32
    result = {}
    for _ in range(commands):
        command, length = struct.unpack_from('<II', data, cursor)
        if command == 0x19:
            count = struct.unpack_from('<I', data, cursor+64)[0]
            for i in range(count):
                section = struct.unpack_from('<16s16sQQIIIIIIII', data, cursor+72+80*i)
                name, segment, _, size, offset, _, _, _, flags, *_ = section
                if offset and size and (flags & 255) not in [1, 12, 18]:
                    key = segment.rstrip(b'\0').decode() + '/' + name.rstrip(b'\0').decode()
                    result[key] = hashlib.sha256(data[offset:offset+size]).hexdigest()
        cursor += length
    return result

library = output / 'libocp_ffi.dylib'
app = output / 'DerivedData/Build/Products/Debug/OcPlayer.app'
embedded = app / 'Contents/Frameworks/libocp_ffi.dylib'
runtime = sections(library)
assert runtime == sections(embedded)
assert len(runtime) == 14
packages = {name: swift_count(name+'-tests.log') for name in
            ['OcPlayerCore','JellyfinKit','MetadataKit','MoviePilotKit','BangumiKit','PlaybackKit','DanmakuKit']}
abi = {path.name: int(re.search(r'Ran (\d+) tests', path.read_text())[1])
       for path in output.glob('*contract-tests.log')}
summary = dict(rust=rust_count('rust-tests.log'), independentRust=rust_count('independent-rust.log'),
    abi=sum(abi.values()), abiSuites=abi, exportedSDK=swift_count('apple-binding-tests.log'),
    nativePackages=packages, nativeTotal=sum(v['executed'] for v in packages.values()),
    app=swift_count('macos-app-tests.log'), disabledMoviePilot=swift_count('disabled-moviepilot.log'),
    sourceFiles=len(json.loads((output/'source-inputs.json').read_text())), sourceCopy=source_copy,
    sourceAndNativeInputsUnchanged=True, sourceLibrarySHA256=digest(library), embeddedLibrarySHA256=digest(embedded),
    runtimeSections=runtime, runtimeSectionCount=len(runtime), runtimeSectionsMatch=True,
    derivedDataReuse='/tmp/ocp-bangumi-sync-macos/DerivedData', appPath=str(app))
(output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({key:summary[key] for key in ['rust','independentRust','abi','nativeTotal','app','disabledMoviePilot','runtimeSectionCount']}))

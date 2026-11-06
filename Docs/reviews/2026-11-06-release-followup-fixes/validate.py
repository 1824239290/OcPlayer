from pathlib import Path
import subprocess, json, os, sys, time, hashlib

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
platform = sys.argv[1]
with (out / f'clean-{platform}.log').open('w') as f:
    subprocess.run([root / 'Scripts/clean.sh'], cwd=root, stdout=f, stderr=subprocess.STDOUT, check=True)
scheme = 'OcPlayer-macOS' if platform == 'macos' else 'OcPlayer-iOS'
destination = 'platform=macOS,arch=arm64' if platform == 'macos' else 'platform=iOS Simulator,id=6FE48A06-F30F-483F-918A-2160A2D43AAD'
bundle = out / f'{platform}.xcresult'
command = ['xcodebuild', '-project', 'OcPlayer.xcodeproj', '-scheme', scheme,
           '-configuration', 'Debug', '-destination', destination,
           '-derivedDataPath', str(root / '.local-build/followup-fixes'),
           '-resultBundlePath', str(bundle), '-onlyUsePackageVersionsFromResolvedFile',
           '-disableAutomaticPackageResolution', '-skipPackageUpdates',
           'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', '-test-timeouts-enabled', 'YES',
           '-maximum-test-execution-time-allowance', '60', 'test']
settings = [('submodule.SQLiteCustom/src.update', 'none'), ('protocol.https.allow', 'never'),
            ('protocol.http.allow', 'never'), ('protocol.ssh.allow', 'never'),
            ('protocol.git.allow', 'never'), ('protocol.file.allow', 'always')]
env = os.environ.copy()
env['GIT_CONFIG_COUNT'] = str(len(settings))
env['GIT_TERMINAL_PROMPT'] = '0'
for i, (key, value) in enumerate(settings):
    env[f'GIT_CONFIG_KEY_{i}'] = key
    env[f'GIT_CONFIG_VALUE_{i}'] = value
started = time.monotonic()
with (out / f'{platform}-tests.log').open('w') as f:
    result = subprocess.run(command, cwd=root, env=env, stdout=f, stderr=subprocess.STDOUT)
record = dict(command=command, exit_code=result.returncode,
              duration_seconds=round(time.monotonic() - started, 1),
              source_sha256={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for folder in ('App', 'AppTests') for p in (root / folder).rglob('*.swift')})
(out / f'{platform}-result.json').write_text(json.dumps(record, indent=2) + '\n')
print(platform, 'exit:', result.returncode, flush=True)
if bundle.exists():
    summary = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                      '--path', str(bundle), '--format', 'json'])
    (out / f'{platform}-summary.json').write_bytes(summary)
    print(summary.decode(), flush=True)
sys.exit(result.returncode)

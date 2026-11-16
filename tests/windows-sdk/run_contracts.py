"""Run the C# real-DLL contracts and all shared ABI suites on the current host."""
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
from network_contract import Handler


class SlowHandler(Handler):
    def do_GET(self):
        # endpoint.probe appends protocol routes to the supplied base URL.
        if self.path.startswith('/slow/') or self.path == '/slow':
            time.sleep(2)
        super().do_GET()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    sdk = args.sdk.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    os.environ['OCP_CORE_LIBRARY_PATH'] = str(library)
    started = time.monotonic()
    server = ThreadingHTTPServer(('127.0.0.1', 0), SlowHandler)
    server.daemon_threads = True
    server.records = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        real = subprocess.run(['dotnet', str(sdk), 'real', f'http://127.0.0.1:{server.server_port}'],
                              capture_output=True, text=True, encoding='utf-8', timeout=60)
        (args.output / 'sdk-real.log').write_text(real.stdout + real.stderr, encoding='utf-8')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print(real.stdout, end='', flush=True)
    if real.returncode:
        print(real.stderr, file=sys.stderr)
        return real.returncode
    suite = unittest.TestSuite()
    for path in sorted(TESTS.glob('*_contract.py')):
        module = importlib.import_module(path.stem)
        # Several suites inherit reusable network helpers. Execute each declared
        # contract once, rather than rediscovering imported or inherited tests.
        classes = {value for value in vars(module).values()
                   if isinstance(value, type) and issubclass(value, unittest.TestCase)
                   and value.__module__ == module.__name__}
        for case in sorted(classes, key=lambda value: value.__name__):
            for name in unittest.defaultTestLoader.getTestCaseNames(case):
                if name in vars(case):
                    suite.addTest(case(name))
    with (args.output / 'abi-contracts.log').open('w', encoding='utf-8') as log:
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    summary = {
        'platform': platform.platform(), 'architecture': platform.machine(),
        'python': platform.python_version(), 'library': str(library),
        'librarySha256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'sdk': json.loads(real.stdout),
        'abi': {'executed': result.testsRun,
                'passed': result.testsRun - len(result.failures) - len(result.errors) - len(result.skipped),
                'failures': len(result.failures), 'errors': len(result.errors),
                'skipped': [{'test': str(test), 'reason': reason} for test, reason in result.skipped]},
        'seconds': round(time.monotonic() - started, 3),
    }
    (args.output / 'runtime-results.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary), flush=True)
    if not result.wasSuccessful():
        print((args.output / 'abi-contracts.log').read_text(encoding='utf-8')[-16000:], file=sys.stderr)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())

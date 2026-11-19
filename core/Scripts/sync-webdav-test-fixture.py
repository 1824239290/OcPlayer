#!/usr/bin/env python3
"""Embed the shared DAV fixture in AppTests; the app needs no repository file access."""
import argparse
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
source = repo / 'core/tests/fixtures/file_library_webdav.py'
target = repo / 'apps/apple/AppTests/FileLibraryIntegrationTests.swift'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
begin = '    // BEGIN GENERATED WEBDAV FIXTURE\n'
end = '    // END GENERATED WEBDAV FIXTURE\n'
text = target.read_text()
a, b = text.index(begin), text.index(end) + len(end)
script = source.read_text().rstrip()
replacement = (begin + '    // Generated from core/tests/fixtures/file_library_webdav.py.\n'
    + '    // Run core/Scripts/sync-webdav-test-fixture.py after editing the shared fixture.\n'
    + '    private static let script = #"""\n'
    + ''.join(('    ' + line if line else '') + '\n' for line in script.splitlines())
    + '    """#\n' + end)
updated = text[:a] + replacement + text[b:]
if args.check:
    if updated != text: raise SystemExit('Embedded DAV fixture is stale; run this script without --check')
else:
    target.write_text(updated)

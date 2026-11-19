#!/usr/bin/env python3
"""Loopback SMB2 protocol fixture. Requires impacket==0.13.0, not a real NAS.

Optional first argument is playable media. Sparse file content above 4 GiB is
used to verify 64-bit readAt without allocating a giant fixture.
"""
import json
import logging
import os
import shutil
import tempfile
import threading
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from impacket import smbserver
from impacket.ntlm import compute_lmhash, compute_nthash
from impacket import smb3structs as smb2
from impacket.nt_errors import STATUS_ACCESS_DENIED

logging.disable(logging.CRITICAL)
directory = tempfile.mkdtemp(prefix='ocp-smb-fixture-')
os.makedirs(os.path.join(directory, 'Movies'))
os.makedirs(os.path.join(directory, 'Denied'))
os.makedirs(os.path.join(directory, 'Shows', 'Show', 'Season 0'))
os.makedirs(os.path.join(directory, 'Shows', 'Show', 'Season 1'))
movie = os.path.join(directory, 'Movies', '中文 100% # & (2020).mkv')
size = 5 * 1024**3 + 1025
if len(sys.argv) > 1:
    shutil.copyfile(sys.argv[1], movie)
    size = os.path.getsize(movie)
else:
    with open(movie, 'wb') as f:
        f.truncate(size)
        for position in (0, 4 * 1024**3 - 16, size - 32):
            f.seek(position)
            f.write(bytes(i % 251 for i in range(position, position + 32)))
for season in (0, 1):
    with open(os.path.join(directory, 'Shows', 'Show', f'Season {season}', f'Show S0{season}E01.mkv'), 'wb') as f:
        f.write(bytes(range(100)))
# A reparse-point-like symlink must never escape a scan root (the fixture does
# not expose Windows reparse metadata; provider path checks are tested separately).
server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
server.setSMB2Support(True)
server.addShare('Media', directory, readOnly='yes')
server.addCredential('user', 0, compute_lmhash('fixture-password'), compute_nthash('fixture-password'))
def guarded_create(conn_id, smb_server, packet):
    request = smb2.SMB2Create(packet['Data'])
    if request['Buffer'].decode('utf-16le').replace('\\', '/').strip('/') == 'Denied':
        return [smb2.SMB2Error()], None, STATUS_ACCESS_DENIED
    return original_create(conn_id, smb_server, packet)
original_create = server.getServer().hookSmb2Command(smb2.SMB2_CREATE, guarded_create)
threading.Thread(target=server.start, daemon=True).start()
guest = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
guest.setSMB2Support(True)
guest.addShare('Media', directory, readOnly='yes')
threading.Thread(target=guest.start, daemon=True).start()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path.startswith('/3/configuration'):
            data = {'images': {'secure_base_url': 'https://image.tmdb.org/t/p/', 'poster_sizes': ['w500']}, 'change_keys': ['title']}
        elif self.path.startswith('/3/search/movie'):
            data = {'results': [{'id': 11, 'title': '中文 100% # &', 'release_date': '2020-01-01'}]}
        elif self.path.startswith('/3/movie/11'):
            data = {'id': 11, 'title': 'SMB 刮削电影', 'release_date': '2020-01-01', 'overview': '永久 SMB 元数据'}
        else: data = {'results': []}
        body = json.dumps(data).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
http.daemon_threads = True
print(json.dumps({'root': f'smb://127.0.0.1:{server.getServer().server_address[1]}/Media/',
                  'guestRoot': f'smb://127.0.0.1:{guest.getServer().server_address[1]}/Media/',
                  'base': f'http://127.0.0.1:{http.server_port}', 'directory': directory, 'size': size}), flush=True)
http.serve_forever()

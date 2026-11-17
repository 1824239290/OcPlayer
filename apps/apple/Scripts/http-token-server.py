#!/usr/bin/env python3
"""带 token 校验 + Range 支持的极简 HTTP 文件服务器，模拟 Jellyfin 直连。

用途：验证内核的 `open_with_headers` —— 带对的 Authorization 才给数据，否则 401。
    python3 Scripts/http-token-server.py <file> <token> [port]
启动后往 stdout 打一行 `listening <port>`，测试脚本据此知道可以连了。
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PATH = sys.argv[1]
TOKEN = sys.argv[2]
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 0
SIZE = os.path.getsize(PATH)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # 静音，别把测试输出淹了

    def _authorized(self):
        # 精确匹配 "Bearer <TOKEN>"：子串包含会让任意含 token 字样的头放行，
        # 测不出「带错凭证必须 401」这条行为。
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _range(self):
        raw = self.headers.get("Range")
        if not raw or not raw.startswith("bytes="):
            return 0, SIZE - 1, False
        spec = raw[len("bytes="):].split(",")[0]
        start_text, _, end_text = spec.partition("-")
        start = int(start_text) if start_text else 0
        end = int(end_text) if end_text else SIZE - 1
        return start, min(end, SIZE - 1), True

    def do_HEAD(self):
        self.do_GET(body=False)

    def do_GET(self, body=True):
        if not self._authorized():
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end, partial = self._range()
        length = max(0, end - start + 1)
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{SIZE}")
        self.end_headers()
        if not body:
            return
        with open(PATH, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)


server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
print(f"listening {server.server_address[1]}", flush=True)
try:
    server.serve_forever()          # 由调用方 terminate()（SIGTERM）结束
except KeyboardInterrupt:
    pass

#!/usr/bin/env python3
"""Origin server for the cache test fixture.

Every body is generated from its path (and Accept-Encoding, for /vary/), so a
body read back out of the cache can be checked against body_for().

  /small/N     a few bytes to ~20 KB, one fragment
  /large/N     3 MB and up, several fragments
  /huge/N      9 MB and up, more fragments than fit in an alternate's
               integral offset table (4)
  /vary/N      Vary: Accept-Encoding, one alternate per encoding asked for
  /query?...   same path, the query makes the key differ

usage: origin.py PORT
"""

import hashlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def body_len(path):
    kind, _, n = path.strip("/").partition("/")
    n = int(n) if n.isdigit() else 0
    if kind == "small":
        return (n * 1373) % 20000 + 1
    if kind == "large":
        return 3 * 1024 * 1024 + n * 4099
    if kind == "huge":
        return 9 * 1024 * 1024 + n * 4099
    return 1000 + n


def body_for(path_and_query, accept_encoding=""):
    """Deterministic body: SHA-256 counter stream seeded by the request."""
    seed = (path_and_query + "|" + accept_encoding).encode()
    length = body_len(urlsplit(path_and_query).path)
    out = bytearray()
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(seed + counter.to_bytes(8, "little")).digest()
        counter += 1
    return bytes(out[:length])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        vary = self.path.startswith("/vary/")
        encoding = self.headers.get("Accept-Encoding", "") if vary else ""
        body = body_for(self.path, encoding)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Last-Modified", "Mon, 05 Oct 2026 12:00:00 GMT")
        if vary:
            self.send_header("Vary", "Accept-Encoding")
            self.send_header("X-Encoding", encoding or "none")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()

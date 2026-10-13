#!/usr/bin/env python3
"""Origin server for the cache test fixture.

Every body is generated from its path (and Accept-Encoding, for /vary/, or
Accept-Language, for /lang/), so a body read back out of the cache can be
checked against body_for().

  /small/N     a few bytes to ~20 KB, one fragment
  /large/N     3 MB and up, several fragments
  /huge/N      9 MB and up, more fragments than fit in an alternate's
               integral offset table (4)
  /vary/N      Vary: Accept-Encoding, one alternate per encoding asked for
  /lang/N      Vary: Accept-Language, and Content-Language: the first
               language asked for
  /query?...   same path, the query makes the key differ

/small/ and /large/ responses carry an ETag: the first 16 hex digits of
the body's SHA-256, quoted.

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


def body_for(path_and_query, selector=""):
    """Deterministic body: SHA-256 counter stream seeded by the request."""
    seed = (path_and_query + "|" + selector).encode()
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
        lang = self.path.startswith("/lang/")
        if vary:
            selector = self.headers.get("Accept-Encoding", "")
        elif lang:
            selector = self.headers.get("Accept-Language", "")
        else:
            selector = ""
        body = body_for(self.path, selector)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Last-Modified", "Mon, 05 Oct 2026 12:00:00 GMT")
        if self.path.startswith(("/small/", "/large/")):
            self.send_header("ETag", '"%s"' % hashlib.sha256(body).hexdigest()[:16])
        if vary:
            self.send_header("Vary", "Accept-Encoding")
            self.send_header("X-Encoding", selector or "none")
        if lang:
            self.send_header("Vary", "Accept-Language")
            first = selector.split(",")[0].split(";")[0].strip()
            if first:
                self.send_header("Content-Language", first)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()

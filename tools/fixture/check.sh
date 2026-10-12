#!/bin/sh
# Checks cyclone's tools against a fixture made by make-fixture.sh, using what
# ATS itself logged while making it.
#
# usage: tools/fixture/check.sh [FIXTURE_DIR]     (default: tests/fixtures/basic)
#
# Needs `zig build` first. Exits non-zero if any check fails.
set -eu

fix=$(cd "${1:-tests/fixtures/basic}" && pwd)
bin=$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin
log=$fix/traffic_server.out
spans="--span $fix/spans/span0.db --span $fix/spans/span1.db --seed seed-span1"
urls=$(cut -f1 "$fix/manifest.tsv" | tail -n +2 | sort -u)
fail=0

check() { # name, expected, got
  if [ "$2" = "$3" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1"
    echo "      expected: $2"
    echo "      got:      $3"
    fail=1
  fi
}

# 1. The strings ATS hashed for each URL (debug tag url_cachekey: canonical
#    string followed by the port in decimal) against cyc-key --explain.
want=$(sort -u "$fix/cachekeys.txt")
got=$(echo "$urls" | while read -r u; do
  "$bin/cyc-key" --explain "$u" | sed -n 's/^hashed *"\(.*\)" + port \([0-9]*\).*/\1\2/p'
done | sort -u)
check "cache key strings ($(echo "$want" | wc -l) URLs)" "$want" "$got"

# 2. Directory sizes ATS allocated, in stripe order, against cyc-doc stripe.
want=$(sed -n 's/.*Stripe \(.*\): allocating \([0-9]*\) directory bytes.*/\1 \2/p' "$log" | sort)
got=$("$bin/cyc-doc" stripe $spans --json | python3 -I -c '
import json, sys
for s in json.load(sys.stdin):
    print(s["hash_text"], s["dir_len"])' | sort)
check "stripe hash texts and directory sizes" "$want" "$got"

# 3. The stripe assignment table: ATS logs requested and got per stripe.
want=$(sed -n 's/.*build_vol_hash_table index \([0-9]*\) mapped to [0-9]* requested \([0-9]*\) got \([0-9]*\).*/\1 \2 \3/p' "$log")
got=$("$bin/cyc-lookup" $spans --table --json | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    print(r["index"], r["requested"], r["got"])')
check "stripe assignment table" "$want" "$got"

# 4. Every cached URL is a hit: one tag match, a valid head entry, and its
#    Doc's first_key is the URL's key.
got=$(echo "$urls" | "$bin/cyc-lookup" $spans - | awk -F'\t' '
  $3 == "hit" && $4 ~ /^[0-9]+h$/ { ok++; next } { bad++; print "  " $0 > "/dev/stderr" }
  END { printf "%d found, %d not", ok, bad }')
check "lookups" "$(echo "$urls" | wc -l | tr -d ' ') found, 0 not" "$got"

# 5. Every head entry belongs to a cached URL: filed under its Doc's
#    first_key (a URL's vector) or under its own key (the first data fragment
#    of a multi-fragment object, or an alternate's own Doc), and each URL key
#    has exactly one vector.
got=$("$bin/cyc-doc" dir $spans --docs --json | python3 -I -c '
import json, sys
keys = set(sys.argv[1].split())
vectors, other, bad = {}, 0, 0
for s in json.load(sys.stdin):
    for e in s["entries"]:
        d = e["doc"]
        if not e["head"]:
            continue
        if d["first_key"] not in keys or d["filed_under"] is None:
            bad += 1
        elif d["filed_under"] == "first_key":
            vectors[d["first_key"]] = vectors.get(d["first_key"], 0) + 1
        else:
            other += 1
print(len(vectors), "vectors,", sum(v != 1 for v in vectors.values()), "duplicated,", bad, "unexplained")
' "$(echo "$urls" | "$bin/cyc-key" - | cut -f1)")
check "head entries" "$(echo "$urls" | wc -l | tr -d ' ') vectors, 0 duplicated, 0 unexplained" "$got"

# 6. Alternates, if tools/ats-httpinfo/build.sh has written ATS's own decoding
#    of every head Doc (alts_golden.txt): cyc-doc fragment must agree on every
#    field of every alternate.
if [ -f "$fix/alts_golden.txt" ]; then
  want=$(cat "$fix/alts_golden.txt")
  got=$(grep '^doc ' "$fix/alts_golden.txt" | cut -d' ' -f2,3 | uniq | while read -r name off; do
    case $name in span0.db) i=0 ;; span1.db) i=1 ;; esac
    "$bin/cyc-doc" fragment $spans --at "$i:$off" --json
  done | python3 -I -c '
import json, sys

def q(s):
    out = []
    for c in s:
        o = ord(c)
        if c in "\"\\":
            out.append("\\" + c)
        elif o < 0x20 or o >= 0x7f:
            out.append("\\x%02x" % o)
        else:
            out.append(c)
    return "\"" + "".join(out) + "\""

dec = json.JSONDecoder()
text = sys.stdin.read()
pos = 0
while pos < len(text.rstrip()):
    while text[pos].isspace():
        pos += 1
    r, pos = dec.raw_decode(text, pos)
    name = r["span"].rsplit("/", 1)[-1]
    for a in r["alternates"]:
        print("doc %s %d alt %d" % (name, r["offset"], a["index"]))
        print("object_key %s  object_size %d  frags %d%s" % (a["object_key"].upper(), a["object_size"],
              len(a["frag_offsets"]), "".join(" %d" % o for o in a["frag_offsets"])))
        print("times %d %d" % (a["request_sent_time"], a["response_received_time"]))
        u = a["url"] or {}
        parts = [u.get(k, "") for k in ("scheme", "host", "port", "path", "params", "query", "fragment")]
        print("request " + " ".join(q(p) for p in [a["method"]] + parts) + " " + a["request_version"])
        for f in a["request_fields"]:
            print("> %s %s" % (q(f["name"]), q(f["value"])))
        print("response %d %s %s" % (a["status"], q(a["reason"]), a["response_version"]))
        for f in a["response_fields"]:
            print("< %s %s" % (q(f["name"]), q(f["value"])))
')
  if [ "$want" = "$got" ]; then
    echo "ok    alternates ($(grep -c '^doc ' "$fix/alts_golden.txt") decoded as ATS does)"
  else
    echo "FAIL  alternates (diff: golden vs cyc-doc)"
    echo "$got" | diff "$fix/alts_golden.txt" - | head -20
    fail=1
  fi
else
  echo "skip  alternates (no alts_golden.txt; see tools/ats-httpinfo/build.sh)"
fi

# 7. Whole objects: every alternate of every URL is complete, and its body
#    is one the origin sent for that URL (manifest.tsv: length and sha256);
#    every body the origin sent is in some alternate.
got=$(python3 -I - "$bin/cyc-doc" "$fix/manifest.tsv" $spans <<'PY'
import collections, hashlib, json, subprocess, sys
tool, manifest, spans = sys.argv[1], sys.argv[2], sys.argv[3:]
sent = collections.defaultdict(set)
for line in open(manifest).read().splitlines()[1:]:
    url, _, length, sha = line.split("\t")
    sent[url].add((int(length), sha))
bad = []
alts = 0
for url, bodies in sorted(sent.items()):
    r = json.loads(subprocess.run([tool, "object", *spans, url, "--json"], capture_output=True, text=True).stdout)
    if not r["found"]:
        bad.append(url + ": not found")
        continue
    seen = set()
    for i in range(len(r["alternates"])):
        alts += 1
        p = subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--body"], capture_output=True)
        body = (len(p.stdout), hashlib.sha256(p.stdout).hexdigest())
        if p.returncode != 0:
            bad.append("%s alt %d: %s" % (url, i, p.stderr.decode().strip()))
        elif body not in bodies:
            bad.append("%s alt %d: body not one the origin sent" % (url, i))
        seen.add(body)
    for b in bodies - seen:
        bad.append("%s: no alternate has the %d-byte body %s" % (url, b[0], b[1][:12]))
for b in bad:
    print("  " + b, file=sys.stderr)
print("%d URLs, %d problems\t%d" % (len(sent), len(bad), alts))
PY
)
check "whole objects ($(echo "$got" | cut -f2) alternates, bodies match the origin)" \
  "$(echo "$urls" | wc -l | tr -d ' ') URLs, 0 problems" "$(echo "$got" | cut -f1)"

# 8. Ranges: for every alternate, ranges at and around each fragment
#    boundary, suffixes and open ends give the same bytes as slicing the
#    whole body, and read only the fragments the offset table says hold them.
got=$(python3 -I - "$bin/cyc-doc" "$fix/manifest.tsv" $spans <<'PY'
import json, subprocess, sys
tool, manifest, spans = sys.argv[1], sys.argv[2], sys.argv[3:]
urls = sorted({l.split("\t")[0] for l in open(manifest).read().splitlines()[1:]})
bad = []
n = 0
for url in urls:
    r = json.loads(subprocess.run([tool, "object", *spans, url, "--json"], capture_output=True, text=True).stdout)
    for alt in r["alternates"]:
        i, size, offs = alt["index"], alt["object_size"], alt["frag_offsets"]
        whole = subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--body"], capture_output=True).stdout
        starts = [0] + offs
        specs = {"0-0", "-1", "0-", "-%d" % (size + 5), "%d-" % (size - 1), "%d-%d" % (size // 3, 2 * size // 3)}
        for b in offs:
            specs |= {"%d-%d" % (b - 1, b), "%d-" % b, "%d-%d" % (b, b), "-%d" % (size - b), "%d-%d" % (b - 1, b - 1)}
        for spec in sorted(specs):
            n += 1
            first, _, last = spec.partition("-")
            if first == "":
                lo, hi = size - min(int(last), size), size
            else:
                lo, hi = int(first), min(int(last), size - 1) + 1 if last else size
            p = subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--range", spec, "--body"], capture_output=True)
            if p.returncode != 0 or p.stdout != whole[lo:hi]:
                bad.append("%s alt %d range %s: wrong bytes (%s)" % (url, i, spec, p.stderr.decode().strip()))
                continue
            j = json.loads(subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--range", spec, "--json"], capture_output=True, text=True).stdout)
            want = [k for k, st in enumerate(starts) if st < hi and (k + 1 == len(starts) or starts[k + 1] > lo)]
            if [f["index"] for f in j["fragments"]] != want:
                bad.append("%s alt %d range %s: read fragments %s, want %s" % (url, i, spec, [f["index"] for f in j["fragments"]], want))
        p = subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--range", "%d-" % size, "--body"], capture_output=True)
        if p.returncode != 1 or b"not satisfiable" not in p.stderr:
            bad.append("%s alt %d: range past the end is not refused" % (url, i))
for b in bad:
    print("  " + b, file=sys.stderr)
print("%d problems\t%d" % (len(bad), n))
PY
)
check "ranges ($(echo "$got" | cut -f2) ranges, bytes and fragments read)" "0 problems" "$(echo "$got" | cut -f1)"

# 9. Alternate selection: for each request in select.tsv, the alternate
#    `cyc-doc object --select` picks has the body ATS served from the cache,
#    and where ATS had nothing to serve (504), nothing is picked.
if [ -f "$fix/select.tsv" ]; then
  got=$(python3 -I - "$bin/cyc-doc" "$fix/select.tsv" $spans <<'PY'
import hashlib, subprocess, sys
tool, table, spans = sys.argv[1], sys.argv[2], sys.argv[3:]
bad = []
rows = [l.split("\t") for l in open(table).read().splitlines()[1:]]
for url, hdr, status, length, sha in rows:
    # The request curl sent (make-fixture.sh fetch), less Host and User-Agent.
    if hdr == "-":
        fields = ["Accept: */*"]
    elif hdr.startswith("Accept:"):
        fields = [hdr]
    else:
        fields = ["Accept: */*", hdr]
    args = [a for f in fields for a in ("--req-header", f)]
    p = subprocess.run([tool, "object", *spans, url, *args, "--body"], capture_output=True)
    if status == "200":
        if p.returncode != 0 or hashlib.sha256(p.stdout).hexdigest() != sha:
            bad.append("%s [%s]: ATS served %s, cyclone %s" % (url, hdr, sha[:12], p.stderr.decode().strip() or hashlib.sha256(p.stdout).hexdigest()[:12]))
    elif p.returncode != 1 or b"no alternate matches" not in p.stderr:
        bad.append("%s [%s]: ATS had no match (%s), cyclone picked one" % (url, hdr, status))
for b in bad:
    print("  " + b, file=sys.stderr)
print("%d problems\t%d" % (len(bad), len(rows)))
PY
)
  check "alternate selection ($(echo "$got" | cut -f2) requests, as ATS served them)" "0 problems" "$(echo "$got" | cut -f1)"
else
  echo "skip  alternate selection (no $fix/select.tsv; rerun make-fixture.sh)"
fi

# 10. The service: cyclone-d on a unix socket answers as the tools do, with
#     its directories in memory and read from disk.
#     Bodies of every alternate, selection as ATS served it (select.tsv),
#     ranges, If-Range, HEAD, JSON reports, errors, keep-alive, and many
#     connections at once.
for mode in "" --disk-directories; do
label=${mode:+directories on disk}
label=${label:-directories in memory}
tmp=$(mktemp -d)
"$bin/cyclone-d" $spans --unix "$tmp/sock" $mode > "$tmp/log" 2>&1 &
daemon=$!
for _ in $(seq 50); do [ -S "$tmp/sock" ] && break; sleep 0.1; done
got=$(python3 -I - "$bin" "$tmp/sock" "$fix/manifest.tsv" "$fix/select.tsv" $spans <<'PY'
import concurrent.futures, hashlib, json, os, socket, subprocess, sys, urllib.parse
bindir, sock, manifest, select_tsv, spans = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
tool = os.path.join(bindir, "cyc-doc")
lookup_tool = os.path.join(bindir, "cyc-lookup")

class Conn:
    """A minimal HTTP/1.1 client: exactly the header fields given."""
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(30)  # a protocol bug fails the check instead of hanging it
        self.s.connect(sock)
        self.buf = b""
    def _read_until(self, sep):
        while sep not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        i = self.buf.index(sep) + len(sep)
        out, self.buf = self.buf[:i], self.buf[i:]
        return out
    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out
    def get(self, target, fields=(), method="GET"):
        req = "%s %s HTTP/1.1\r\nHost: cyclone\r\n" % (method, target)
        req += "".join("%s\r\n" % f for f in fields) + "\r\n"
        self.s.sendall(req.encode())
        head = self._read_until(b"\r\n\r\n").decode("latin-1").split("\r\n")
        status = int(head[0].split()[1])
        hdrs = {}
        for line in head[1:]:
            if line:
                k, _, v = line.partition(":")
                hdrs[k.strip().lower()] = v.strip()
        if method == "HEAD":
            body = b""
        elif hdrs.get("transfer-encoding") == "chunked":
            body = b""
            while True:
                size = int(self._read_until(b"\r\n").split(b";")[0], 16)
                body += self._read(size)
                self._read_until(b"\r\n")
                if size == 0:
                    break
        else:
            body = self._read(int(hdrs.get("content-length", "0")))
        return status, hdrs, body

def q(url):
    return urllib.parse.quote(url, safe="")

bad = []
n = 0
c = Conn()
urls = sorted({l.split("\t")[0] for l in open(manifest).read().splitlines()[1:]})

# Bodies of every alternate, and the reports.
for url in urls:
    doc = json.loads(subprocess.run([tool, "object", *spans, url, "--alt", "0", "--json"], capture_output=True, text=True).stdout)
    st, h, b = c.get("/v1/object?url=%s&alt=0" % q(url))
    n += 1
    if st != 200 or json.loads(b) != doc:
        bad.append("%s: /v1/object differs from cyc-doc object --json" % url)
    lk = json.loads(subprocess.run([lookup_tool, *spans, url, "--json"], capture_output=True, text=True).stdout)
    lk = lk[0] if isinstance(lk, list) else lk
    st, h, b = c.get("/v1/lookup?url=%s" % q(url))
    n += 1
    if st != 200 or json.loads(b) != lk:
        bad.append("%s: /v1/lookup differs from cyc-lookup --json" % url)
    for alt in doc["alternates"]:
        i, size = alt["index"], alt["object_size"]
        whole = subprocess.run([tool, "object", *spans, url, "--alt", str(i), "--body"], capture_output=True).stdout
        st, h, b = c.get("/v1/body?url=%s&alt=%d" % (q(url), i))
        n += 1
        if st != alt["status"] or b != whole or h.get("x-cyclone-alternate") != str(i):
            bad.append("%s alt %d: body differs (status %d)" % (url, i, st))
        st, h, b = c.get("/v1/body/%s?alt=%d" % (doc["key"], i), method="HEAD")
        n += 1
        if st != 200 or h.get("content-length") != str(size):
            bad.append("%s alt %d: HEAD gives %d, length %s" % (url, i, st, h.get("content-length")))
        lm = next((f["value"] for f in alt["response_fields"] if f["name"].lower() == "last-modified"), None)
        cases = [("bytes=%d-%d" % (size // 3, 2 * size // 3), None, 206, whole[size // 3:2 * size // 3 + 1]),
                 ("bytes=-7", None, 206, whole[-7:]),
                 ("bytes=%d-" % (size - 1), None, 206, whole[-1:]),
                 ("bytes=%d-" % size, None, 416, None),
                 ("bytes=0-1,5-6", None, 200, whole),
                 ("bytes=0-0", "Mon, 01 Jan 2001 00:00:00 GMT", 200, whole)]
        if lm:
            cases.append(("bytes=0-0", lm, 206, whole[:1]))
        for rng, if_range, want_status, want in cases:
            fields = ["Range: " + rng] + (["If-Range: " + if_range] if if_range else [])
            st, h, b = c.get("/v1/body?url=%s&alt=%d" % (q(url), i), fields)
            n += 1
            if st != want_status or (want is not None and b != want):
                bad.append("%s alt %d %s%s: status %d, want %d" % (url, i, rng, " If-Range" if if_range else "", st, want_status))
            if st == 416 and h.get("content-range") != "bytes */%d" % size:
                bad.append("%s alt %d: 416 without Content-Range bytes */%d" % (url, i, size))

# Selection by the request's own fields, as ATS served (select.tsv).
for line in open(select_tsv).read().splitlines()[1:]:
    url, hdr, status, length, sha = line.split("\t")
    fields = ["Accept: */*"] if hdr == "-" else [hdr] if hdr.startswith("Accept:") else ["Accept: */*", hdr]
    st, h, b = c.get("/v1/body?url=" + q(url), fields)
    n += 1
    if status == "200":
        if st != 200 or hashlib.sha256(b).hexdigest() != sha:
            bad.append("%s [%s]: ATS served %s, cyclone-d %d" % (url, hdr, sha[:12], st))
    elif st != 404 or h.get("x-cyclone-cache") != "no-match":
        bad.append("%s [%s]: ATS had no match, cyclone-d %d %s" % (url, hdr, st, h.get("x-cyclone-cache")))

# Stripes and directory scans, against cyc-doc stripe and dir.
want_stripes = json.loads(subprocess.run([tool, "stripe", *spans, "--json"], capture_output=True, text=True).stdout)
want_dirs = json.loads(subprocess.run([tool, "dir", *spans, "--entries", "--docs", "--json"], capture_output=True, text=True).stdout)
st, h, b = c.get("/v1/stripes?stats=1")
n += 1
got = json.loads(b) if st == 200 else []
if [{k: v for k, v in r.items() if k != "dir_stats"} for r in got] != [{k: v for k, v in r.items() if k != "dir_stats"} for r in want_stripes]:
    bad.append("/v1/stripes differs from cyc-doc stripe --json")
if [r.get("dir_stats") for r in got] != [d["stats"] for d in want_dirs]:
    bad.append("/v1/stripes?stats=1 differs from cyc-doc dir --json stats")
st, h, b = c.get("/v1/stripes/1:0")
n += 1
if st != 200 or json.loads(b)["block_index"] != 0 or json.loads(b)["span_index"] != 1:
    bad.append("/v1/stripes/1:0: status %d" % st)
want_entries = [e for d in want_dirs for e in d["entries"]]
for qs, keep in [("?docs=1", lambda e: True), ("?docs=1&heads=1", lambda e: e["head"]),
                ("?docs=1&valid=1", lambda e: e["valid"])]:
    st, h, b = c.get("/v1/dir" + qs)
    n += 1
    lines = [json.loads(l) for l in b.decode().splitlines()]
    if st != 200 or h.get("transfer-encoding") != "chunked" or lines != [e for e in want_entries if keep(e)]:
        bad.append("/v1/dir%s differs from cyc-doc dir --entries --docs (%d lines, want %d)" % (qs, len(lines), len([e for e in want_entries if keep(e)])))
for d in want_dirs:
    st, h, b = c.get("/v1/dir/%d:%d?segment=0" % (d["span_index"], d["block_index"]))
    n += 1
    lines = [json.loads(l) for l in b.decode().splitlines()]
    want = [{k: v for k, v in e.items() if k != "doc"} for e in d["entries"] if e["segment"] == 0]
    if st != 200 or [{k: v for k, v in e.items() if k != "doc"} for e in lines] != want:
        bad.append("/v1/dir/%d:%d?segment=0: %d lines, want %d" % (d["span_index"], d["block_index"], len(lines), len(want)))
st, h, b = c.get("/v1/dir", method="HEAD")
n += 1
if st != 200 or b:
    bad.append("HEAD /v1/dir: status %d" % st)

# Errors.
for target, method, want in [("/v1/body?url=" + q("http://127.0.0.1:18081/never"), "GET", 404),
                             ("/v1/body/zz", "GET", 400), ("/nope", "GET", 404),
                             ("/v1/body/00000000000000000000000000000000?alt=x", "GET", 400),
                             ("/v1/object", "GET", 400), ("/v1/stripes/9:9", "GET", 404),
                             ("/v1/dir/0:0?segment=99", "GET", 404), ("/v1/dir?nope=1", "GET", 400),
                             ("/v1/dir/x", "GET", 400)]:
    st, h, b = c.get(target, method=method)
    n += 1
    if st != want:
        bad.append("%s: status %d, want %d" % (target, st, want))
c.s.sendall(b"POST /v1/body/x HTTP/1.1\r\nHost: c\r\nContent-Length: 0\r\n\r\n")
n += 1
if b" 405 " not in c._read_until(b"\r\n\r\n"):
    bad.append("POST is not refused with 405")

# Many connections at once, each reading every large body.
big = [u for u in urls if "/large/" in u or "/huge/" in u]
want = {u: subprocess.run([tool, "object", *spans, u, "--body"], capture_output=True).stdout for u in big}
def worker(k):
    w = Conn()
    errs = []
    for u in big[k % len(big):] + big[:k % len(big)]:
        st, h, b = w.get("/v1/body?url=" + q(u))
        if st != 200 or b != want[u]:
            errs.append("concurrent %s: status %d, %d bytes" % (u, st, len(b)))
    return errs
with concurrent.futures.ThreadPoolExecutor(32) as ex:
    for errs in ex.map(worker, range(32)):
        bad += errs
n += 32 * len(big)
for b in bad:
    print("  " + b, file=sys.stderr)
print("%d problems\t%d" % (len(bad), n))
PY
)
kill $daemon 2>/dev/null; wait $daemon 2>/dev/null || true
check "service, $label ($(echo "$got" | cut -f2) requests over one socket, 32 at once)" "0 problems" "$(echo "$got" | cut -f1)"
# Anything the daemon said besides starting up is worth seeing.
grep -v -e 'listening on' -e 'directories in memory' "$tmp/log" | sed 's/^/  /' >&2 || true
rm -rf "$tmp"
done

# 11. Graceful shutdown: on SIGTERM an idle keep-alive connection is closed,
#     a body being read slowly is finished, the daemon exits 0 and removes
#     its socket file.
tmp=$(mktemp -d)
"$bin/cyclone-d" $spans --unix "$tmp/sock" > "$tmp/log" 2>&1 &
daemon=$!
for _ in $(seq 50); do [ -S "$tmp/sock" ] && break; sleep 0.1; done
got=$(python3 -I - "$tmp/sock" "$daemon" <<'PY'
import os, signal, socket, sys, time
sock, pid = sys.argv[1], int(sys.argv[2])
def conn():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)
    s.connect(sock)
    return s
idle = conn()
idle.sendall(b"GET /v1/key?url=http%3A%2F%2Fa%2F HTTP/1.1\r\nHost: c\r\n\r\n")
time.sleep(0.2)
idle.recv(65536)
slow = conn()
slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
slow.sendall(b"GET /v1/body?url=http%3A%2F%2F127.0.0.1%3A18081%2Fhuge%2F1 HTTP/1.1\r\nHost: c\r\n\r\n")
time.sleep(0.3)
os.kill(pid, signal.SIGTERM)
problems = []
if idle.recv(100) != b"":
    problems.append("the idle connection was not closed")
data = b""
while True:
    x = slow.recv(1 << 18)
    if not x:
        break
    data += x
    time.sleep(0.02)
if len(data.partition(b"\r\n\r\n")[2]) != 9441283:
    problems.append("the body in flight was not finished")
for p in problems:
    print("  " + p, file=sys.stderr)
print("%d problems" % len(problems))
PY
)
status=0
wait $daemon || status=$?
[ -e "$tmp/sock" ] && got="$got, socket file left"
check "graceful shutdown (idle connection closed, body in flight finished)" "0 problems, exit 0" "$got, exit $status"
rm -rf "$tmp"

exit $fail

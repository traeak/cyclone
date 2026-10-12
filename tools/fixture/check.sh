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

exit $fail

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

exit $fail

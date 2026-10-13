#!/bin/sh
# Checks cyc-delete on a copy of a fixture: the objects deleted miss and the
# rest still hit, only the directory copies written change, a second run
# finds nothing to do, and ATS itself, started on the copy, misses exactly
# the deleted objects and serves the rest unchanged (as recorded in
# manifest.tsv), with no directory recovery or clearing.
#
# usage: tools/fixture/check-delete.sh [FIXTURE_DIR [ATS_PREFIX]]
#
# FIXTURE_DIR defaults to tests/fixtures/basic. Without ATS_PREFIX (an
# installed ATS master, as for make-fixture.sh) the part that runs ATS is
# skipped. Needs `zig build` first. Prints "N problems" last; exits non-zero
# if there are any.
set -eu

fix=$(cd "${1:-tests/fixtures/basic}" && pwd)
prefix=${2:-}
[ -n "$prefix" ] && prefix=$(cd "$prefix" && pwd)
bin=$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin
proxy_port=18090
origin=http://127.0.0.1:18081

tmp=$(mktemp -d)
ts_pid=
trap '[ -n "$ts_pid" ] && kill $ts_pid 2>/dev/null; rm -rf "$tmp"' EXIT
cp --sparse=always "$fix/spans/span0.db" "$fix/spans/span1.db" "$tmp/"
# The copies hash as the originals did: span0 by its original path, span1 by
# its hash_seed.
spans="--span $tmp/span0.db --seed $fix/spans/span0.db --span $tmp/span1.db --seed seed-span1"
problems=0
problem() {
  echo "  $*" >&2
  problems=$((problems + 1))
}

# A small object, one of several fragments, one with three alternates, and
# one with a query string.
deleted="/small/1 /large/1 /vary/1 /query?a=1"
for p in $deleted; do echo "$origin$p"; done > "$tmp/deleted.txt"
cut -f1 "$fix/manifest.tsv" | tail -n +2 | sort -u > "$tmp/all.txt"
grep -v -x -F -f "$tmp/deleted.txt" "$tmp/all.txt" > "$tmp/kept.txt"

# 1. Delete, then again: the second run finds nothing and writes nothing.
"$bin/cyc-delete" $spans - < "$tmp/deleted.txt" > "$tmp/first.out" 2> "$tmp/first.err" || problem "cyc-delete failed: $(cat "$tmp/first.err")"
n=$(grep -c "	removed 1	" "$tmp/first.out" || true)
[ "$n" = 4 ] || problem "first run removed $n of 4: $(cat "$tmp/first.out")"
grep -q "	written$" "$tmp/first.out" || problem "first run wrote no stripe"
cp --sparse=always "$tmp/span1.db" "$tmp/span1.after"
"$bin/cyc-delete" $spans - < "$tmp/deleted.txt" > "$tmp/second.out" 2>/dev/null || problem "second cyc-delete failed"
n=$(grep -c "	not-found	" "$tmp/second.out" || true)
[ "$n" = 4 ] || problem "second run: $n of 4 not found"
grep -q "^stripe" "$tmp/second.out" && problem "second run wrote a stripe"
cmp -s "$tmp/span1.db" "$tmp/span1.after" || problem "second run changed span1"
rm "$tmp/span1.after"

# 2. Lookups: deleted miss, the rest hit.
lookups() { # FILE WANT
  "$bin/cyc-lookup" $spans - < "$1" | while IFS="$(printf '\t')" read -r key stripe status rest; do
    [ "$status" = "$2" ] || echo "$rest: $status, expected $2"
  done
}
for x in "deleted.txt miss" "kept.txt hit"; do
  set -- $x
  lookups "$tmp/$1" "$2" > "$tmp/bad" || true
  [ -s "$tmp/bad" ] && problem "lookups: $(cat "$tmp/bad")"
done

# 3. Only the written directory copies changed: every differing byte lies in
#    a stripe's directory area (between its start and its content).
"$bin/cyc-doc" stripe $spans --json > "$tmp/stripes.json"
for i in 0 1; do
  cmp -l "$fix/spans/span$i.db" "$tmp/span$i.db" | awk '{print $1 - 1}' > "$tmp/diff$i" || true
done
out=$(python3 -I - "$tmp/stripes.json" "$tmp/diff0" "$tmp/diff1" <<'PY'
import json, sys
stripes = json.load(open(sys.argv[1]))
for i, path in enumerate(sys.argv[2:]):
    areas = [(s["offset"], s["content_start"]) for s in stripes if s["span_index"] == i]
    outside = [o for o in map(int, open(path).read().split()) if not any(a <= o < b for a, b in areas)]
    if outside:
        print("span%d: %d bytes changed outside the directories, first at %d" % (i, len(outside), outside[0]))
PY
)
[ -n "$out" ] && problem "$out"

# 4. ATS on the copy.
: > "$tmp/tally"
if [ -z "$prefix" ]; then
  echo "skip  ATS on the copy (no ATS_PREFIX)" >&2
else
  rr=$tmp/runroot
  "$prefix/bin/traffic_layout" init --path "$rr" --copy-style soft --absolute >/dev/null 2>&1 || true
  logdir=$rr/var/log/trafficserver
  sed -i -e "s|^runtimedir:.*|runtimedir: $rr/var/run|" -e "s|^logdir:.*|logdir: $logdir|" \
    -e "s|^cachedir:.*|cachedir: $rr/var/cache|" "$rr/runroot.yaml"
  mkdir -p "$logdir" "$rr/var/run" "$rr/var/cache"
  etc=$(sed -n 's/^sysconfdir: *//p' "$rr/runroot.yaml")
  fetc=$(sed -n 's/^sysconfdir: *//p' "$fix/runroot/runroot.yaml")
  sed "s/server_ports: .*/server_ports: \"$proxy_port\"/" "$fetc/records.yaml" > "$etc/records.yaml"
  cp "$fetc/remap.config" "$etc/remap.config"
  cat > "$etc/storage.yaml" <<EOF
cache:
  spans:
    - name: span0
      path: $tmp/span0.db
      size: 512M
      hash_seed: $fix/spans/span0.db
    - name: span1
      path: $tmp/span1.db
      size: 384M
      hash_seed: seed-span1
  volumes:
    - id: 1
      size: 50%
    - id: 2
      size: 50%
EOF
  "$prefix/bin/traffic_server" --run-root="$rr/runroot.yaml" > "$tmp/ts.out" 2>&1 &
  ts_pid=$!
  for _ in $(seq 100); do
    curl -s -o /dev/null "http://127.0.0.1:$proxy_port/" && break
    sleep 0.2
  done

  # cyc-delete refuses while ATS has the spans open.
  if echo "$origin/small/2" | "$bin/cyc-delete" $spans - > /dev/null 2> "$tmp/refused"; then
    problem "cyc-delete wrote while ATS was running"
  else
    grep -q "is open in process" "$tmp/refused" || problem "cyc-delete failed otherwise: $(cat "$tmp/refused")"
  fi

  # Every manifest row, from the cache only: 504 for a deleted object, else
  # the body the origin sent.
  tail -n +2 "$fix/manifest.tsv" | while IFS="$(printf '\t')" read -r url hdr len sum; do
    path=${url#"$origin"}
    set -- -s -H "Host: origin.test" -H "Cache-Control: only-if-cached"
    case $hdr in
      -) ;;
      Accept:*) set -- "$@" -H "$hdr" ;;
      *) set -- "$@" -H "Accept: */*" -H "$hdr" ;;
    esac
    : > "$tmp/body"
    status=$(curl "$@" -o "$tmp/body" -w '%{http_code}' "http://127.0.0.1:$proxy_port$path")
    if grep -q -x -F "$url" "$tmp/deleted.txt"; then
      if [ "$status" = 504 ]; then echo missed >> "$tmp/tally"; else echo "ATS: $path ($hdr): $status, expected 504 (deleted)"; fi
    else
      got=$(sha256sum "$tmp/body" | cut -d' ' -f1)
      if [ "$status" = 200 ] && [ "$got" = "$sum" ]; then echo served >> "$tmp/tally"
      else echo "ATS: $path ($hdr): $status, body $(wc -c < "$tmp/body") bytes, expected 200 and $len"; fi
    fi
  done > "$tmp/bad"
  [ -s "$tmp/bad" ] && problem "$(cat "$tmp/bad")"
  echo "ATS: $(grep -c served "$tmp/tally" || true) served as recorded, $(grep -c missed "$tmp/tally" || true) deleted missed"

  kill -TERM $ts_pid
  wait $ts_pid || true
  ts_pid=
  # ATS used the directories written: no disk or directory cleared. (Every
  # restart logs "recovery clearing offsets" for the area just past
  # write_pos, which the next writes would overwrite; that is not a loss.)
  logs="$tmp/ts.out $logdir/diags.log $logdir/traffic.out"
  bad=$(cat $logs 2>/dev/null | grep -i -e "clearing the disk" -e "clearing cache directory" -e "bad footer" -e "no valid directory" || true)
  [ -n "$bad" ] && problem "ATS log: $bad"
  # After ATS's own shutdown sync, the deleted objects are still gone.
  lookups "$tmp/deleted.txt" miss > "$tmp/bad" || true
  [ -s "$tmp/bad" ] && problem "after ATS ran: $(cat "$tmp/bad")"
  lookups "$tmp/kept.txt" hit > "$tmp/bad" || true
  [ -s "$tmp/bad" ] && problem "after ATS ran: $(cat "$tmp/bad")"
fi

echo "$problems problems"
[ $problems = 0 ]

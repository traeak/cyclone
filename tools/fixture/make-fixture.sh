#!/bin/sh
# Builds a small, known ATS cache to test cyclone against.
#
# usage: tools/fixture/make-fixture.sh ATS_PREFIX OUT_DIR
#
# ATS_PREFIX is an installed ATS master (bin/traffic_server, bin/traffic_layout).
# OUT_DIR gets:
#   spans/span0.db, spans/span1.db   the cache (span1 uses hash_seed "seed-span1")
#   manifest.tsv                     what was cached: cache-key URL, Accept-Encoding,
#                                    body length, body sha256
#   cachekeys.txt                    the exact strings ATS hashed (debug tag url_cachekey)
#   runroot/                         the ATS sandbox, with logs
#
# Layout: two volumes (ids 1 and 2) spread over both spans. ATS runs as a
# reverse proxy on 127.0.0.1:18080 in front of origin.py on 127.0.0.1:18081,
# and is stopped cleanly so the stripe directories are synced to disk.
set -eu

prefix=$(cd "${1:?usage: $0 ATS_PREFIX OUT_DIR}" && pwd)
out=${2:?usage: $0 ATS_PREFIX OUT_DIR}
here=$(cd "$(dirname "$0")" && pwd)
proxy_port=18080
origin_port=18081

mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -rf "$out/runroot" "$out/spans"
mkdir -p "$out/spans"

"$prefix/bin/traffic_layout" init --path "$out/runroot" --copy-style soft --absolute >/dev/null 2>&1 || true
# Keep everything ATS writes inside the sandbox, whatever the install layout says.
logdir=$out/runroot/var/log/trafficserver
sed -i -e "s|^runtimedir:.*|runtimedir: $out/runroot/var/run|" \
  -e "s|^logdir:.*|logdir: $logdir|" \
  -e "s|^cachedir:.*|cachedir: $out/runroot/var/cache|" "$out/runroot/runroot.yaml"
mkdir -p "$logdir" "$out/runroot/var/run" "$out/runroot/var/cache"
etc=$(sed -n 's/^sysconfdir: *//p' "$out/runroot/runroot.yaml")
[ -f "$etc/records.yaml" ] || { echo "runroot init failed" >&2; exit 1; }

cat > "$etc/records.yaml" <<EOF
records:
  admin:
    user_id: "#-1"
  http:
    server_ports: "$proxy_port"
    cache:
      required_headers: 0
  url_remap:
    remap_required: 1
  cache:
    dir:
      sync_frequency: 2
  diags:
    debug:
      enabled: 1
      tags: "url_cachekey|dir_sync|cache_init|cache_hosting"
EOF

cat > "$etc/storage.yaml" <<EOF
cache:
  spans:
    - name: span0
      path: $out/spans/span0.db
      size: 512M
    - name: span1
      path: $out/spans/span1.db
      size: 384M
      hash_seed: seed-span1
  volumes:
    - id: 1
      size: 50%
    - id: 2
      size: 50%
EOF

echo "map http://origin.test/ http://127.0.0.1:$origin_port/" > "$etc/remap.config"

# File spans must exist before ATS starts; ATS writes the span header itself.
truncate -s 512M "$out/spans/span0.db"
truncate -s 384M "$out/spans/span1.db"

python3 "$here/origin.py" $origin_port &
origin_pid=$!
"$prefix/bin/traffic_server" --run-root="$out/runroot/runroot.yaml" > "$out/traffic_server.out" 2>&1 &
ts_pid=$!
trap 'kill $origin_pid $ts_pid 2>/dev/null || true' EXIT

for _ in $(seq 100); do
  curl -s -o /dev/null "http://127.0.0.1:$proxy_port/" && break
  sleep 0.2
done

# path<TAB>Accept-Encoding ("-" for none)
requests() {
  for n in $(seq 1 40); do printf '/small/%s\t-\n' "$n"; done
  for n in 1 2 3; do printf '/large/%s\t-\n' "$n"; done
  for n in 1 2; do
    for enc in gzip br identity; do printf '/vary/%s\t%s\n' "$n" "$enc"; done
  done
  for q in 'a=1' 'a=2' 'a=1&b=2' 'b=2&a=1'; do printf '/query?%s\t-\n' "$q"; done
}

printf 'url\taccept_encoding\tlength\tsha256\n' > "$out/manifest.tsv"
requests | while IFS="$(printf '\t')" read -r path enc; do
  set -- -s -H "Host: origin.test"
  [ "$enc" = - ] || set -- "$@" -H "Accept-Encoding: $enc"
  curl "$@" -o "$out/body.tmp" "http://127.0.0.1:$proxy_port$path"
  len=$(wc -c < "$out/body.tmp")
  sum=$(sha256sum "$out/body.tmp" | cut -d' ' -f1)
  printf 'http://127.0.0.1:%s%s\t%s\t%s\t%s\n' "$origin_port" "$path" "$enc" "$len" "$sum" >> "$out/manifest.tsv"
done
rm -f "$out/body.tmp"

# Let a periodic directory sync run, then stop cleanly (which syncs again).
sleep 5
kill -TERM $ts_pid
wait $ts_pid || true
kill $origin_pid 2>/dev/null || true
trap - EXIT

sed -n 's/.*Final url string for cache hash key //p' "$out/traffic_server.out" | sort -u > "$out/cachekeys.txt"
echo "fixture in $out: $(($(wc -l < "$out/manifest.tsv") - 1)) objects, spans:"
ls -l "$out/spans"

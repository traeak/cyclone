#!/bin/sh
# Builds a small, known ATS cache to test cyclone against.
#
# usage: tools/fixture/make-fixture.sh ATS_PREFIX OUT_DIR
#
# ATS_PREFIX is an installed ATS master (bin/traffic_server, bin/traffic_layout).
# OUT_DIR gets:
#   spans/span0.db, spans/span1.db   the cache (span1 uses hash_seed "seed-span1")
#   manifest.tsv                     what was cached: cache-key URL, the request
#                                    header that selects the variant, body length,
#                                    body sha256
#   select.tsv                       what ATS then served from the cache (only-if-cached)
#                                    for each URL and request header: status, body
#                                    length, body sha256
#   conditional.tsv                  the same for conditional and range requests;
#                                    request fields joined with ";;"
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

# path<TAB>request header ("-" for none)
requests() {
  for n in $(seq 1 40); do printf '/small/%s\t-\n' "$n"; done
  for n in 1 2 3; do printf '/large/%s\t-\n' "$n"; done
  printf '/huge/1\t-\n'
  for n in 1 2; do
    for enc in gzip br identity; do printf '/vary/%s\tAccept-Encoding: %s\n' "$n" "$enc"; done
  done
  printf '/lang/1\t%s\n' 'Accept-Language: en' 'Accept-Language: de' -
  for q in 'a=1' 'a=2' 'a=1&b=2' 'b=2&a=1'; do printf '/query?%s\t-\n' "$q"; done
}

# Lookups after the cache is filled: path<TAB>request header. With
# only-if-cached ATS answers from the cache or with 504, and writes nothing.
lookups() {
  for h in - 'Accept-Encoding: gzip' 'Accept-Encoding: GZIP' 'Accept-Encoding: x-gzip' \
    'Accept-Encoding: br' 'Accept-Encoding: identity' 'Accept-Encoding: gzip, br' \
    'Accept-Encoding: br, gzip;q=0' 'Accept-Encoding: gzip;q=0' 'Accept-Encoding: deflate' \
    'Accept-Encoding: *' 'Accept-Encoding: identity;q=0, gzip' 'Accept: text/html' \
    'Accept: application/*;q=0.5' 'Accept-Language: en'; do
    printf '/vary/1\t%s\n' "$h"
  done
  for h in - 'Accept-Language: en' 'Accept-Language: de' 'Accept-Language: EN' \
    'Accept-Language: en-US' 'Accept-Language: en, de' 'Accept-Language: fr' \
    'Accept-Language: *' 'Accept-Language: de;q=0.5' 'Accept-Encoding: gzip'; do
    printf '/lang/1\t%s\n' "$h"
  done
  for h in - 'Accept: image/png' 'Accept-Encoding: br' 'Accept-Language: fr'; do
    printf '/small/1\t%s\n' "$h"
  done
}

# Conditional and range requests, answered from the cache: path<TAB>fields
# joined with ";;". ETAG is /small/1's ETag (see origin.py).
conditionals() {
  lm='Mon, 05 Oct 2026 12:00:00 GMT'
  old='Sun, 04 Oct 2026 12:00:00 GMT'
  for h in "If-None-Match: $ETAG" "If-None-Match: W/$ETAG" 'If-None-Match: "nope"' 'If-None-Match: *' \
    "If-None-Match: \"nope\", $ETAG" "If-Match: $ETAG" 'If-Match: "nope"' 'If-Match: *' \
    "If-Modified-Since: $lm" "If-Modified-Since: $old" "If-Unmodified-Since: $old" "If-Unmodified-Since: $lm" \
    "If-None-Match: \"nope\";;If-Modified-Since: $lm" "Range: bytes=0-9;;If-Range: $ETAG" \
    'Range: bytes=0-9;;If-Range: "nope"' "Range: bytes=0-9;;If-Range: $lm" "Range: bytes=0-9;;If-Range: $old" \
    "Range: bytes=5-;;If-None-Match: $ETAG" "Range: bytes=99999-;;If-Modified-Since: $lm" 'Range: bytes=99999-'; do
    printf '/small/1\t%s\n' "$h"
  done
  for h in "If-Modified-Since: $lm" "If-Modified-Since: $old" 'If-None-Match: "x"' "Range: bytes=-10;;If-Modified-Since: $old" \
    "Range: bytes=1048500-1048600;;If-Range: $lm"; do
    printf '/huge/1\t%s\n' "$h"
  done
  for h in "Accept-Encoding: gzip;;If-Modified-Since: $lm" "If-Modified-Since: $lm"; do
    printf '/vary/1\t%s\n' "$h"
  done
}

# fetch PATH HEADER [CURL_ARGS...]: sets status, len and sum. The request
# has Accept: */* (curl's default) unless HEADER is an Accept.
fetch() {
  path=$1 hdr=$2
  shift 2
  set -- -s -H "Host: origin.test" "$@"
  case $hdr in
    -) ;;
    Accept:*) set -- "$@" -H "$hdr" ;;
    *) set -- "$@" -H "Accept: */*" ;;
  esac
  # Several fields are joined with ";;".
  rest=$hdr
  while [ "$rest" != - ] && [ "${rest#Accept:}" = "$rest" ] && [ -n "$rest" ]; do
    set -- "$@" -H "${rest%%;;*}"
    case $rest in *";;"*) rest=${rest#*;;} ;; *) rest= ;; esac
  done
  : > "$out/body.tmp" # a 304 writes nothing
  status=$(curl "$@" -o "$out/body.tmp" -w '%{http_code}' "http://127.0.0.1:$proxy_port$path")
  len=$(wc -c < "$out/body.tmp")
  sum=$(sha256sum "$out/body.tmp" | cut -d' ' -f1)
}

printf 'url\trequest_header\tlength\tsha256\n' > "$out/manifest.tsv"
requests | while IFS="$(printf '\t')" read -r path hdr; do
  fetch "$path" "$hdr"
  printf 'http://127.0.0.1:%s%s\t%s\t%s\t%s\n' "$origin_port" "$path" "$hdr" "$len" "$sum" >> "$out/manifest.tsv"
done

printf 'url\trequest_header\tstatus\tlength\tsha256\n' > "$out/select.tsv"
lookups | while IFS="$(printf '\t')" read -r path hdr; do
  fetch "$path" "$hdr" -H "Cache-Control: only-if-cached"
  printf 'http://127.0.0.1:%s%s\t%s\t%s\t%s\t%s\n' "$origin_port" "$path" "$hdr" "$status" "$len" "$sum" >> "$out/select.tsv"
done
ETAG=\"$(awk -F'\t' '$1 ~ /\/small\/1$/ {print substr($4, 1, 16)}' "$out/manifest.tsv")\"
printf 'url\trequest_fields\tstatus\tlength\tsha256\n' > "$out/conditional.tsv"
conditionals | while IFS="$(printf '\t')" read -r path hdr; do
  fetch "$path" "$hdr" -H "Cache-Control: only-if-cached"
  printf 'http://127.0.0.1:%s%s\t%s\t%s\t%s\t%s\n' "$origin_port" "$path" "$hdr" "$status" "$len" "$sum" >> "$out/conditional.tsv"
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

#!/bin/sh
# Builds three small programs against ATS master's own header code:
#   layout   prints the struct layout of a marshalled alternate; its output is
#            src/testdata/hdr_layout.txt, which a unit test checks cyclone's
#            offsets against.
#   altdump  decodes alternate vectors with HTTPInfo::unmarshal. Given a
#            fixture, it writes FIXTURE/alts_golden.txt for every Doc with a
#            header, which tools/fixture/check.sh compares with cyc-doc.
#   selectq  runs ATS's alternate matching (HttpTransactCache.cc) on the cases
#            from gen-select-cases.py; its output is
#            src/testdata/select_golden.txt, which src/select.zig's tests replay.
#
# usage: tools/ats-httpinfo/build.sh ATS_SOURCE_DIR [BUILD_DIR [FIXTURE_DIR]]
#
# BUILD_DIR (default: ./.ats-build) is a separate out-of-tree ATS build, as for
# tools/ats-keygen. FIXTURE_DIR needs `zig build` first.
set -eu

src=$(cd "${1:?usage: $0 ATS_SOURCE_DIR [BUILD_DIR [FIXTURE_DIR]]}" && pwd)
build=${2:-.ats-build}
fixture=${3:+$(cd "$3" && pwd)}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

[ -f "$build/build.ninja" ] ||
  cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
ninja -C "$build" test_proxy_hdrs
build=$(cd "$build" && pwd)

# Reuse the compile flags of test_URL.cc and the link line of test_proxy_hdrs,
# with the test objects and Catch2 swapped out (as tools/ats-keygen does).
cmds=$(ninja -C "$build" -t commands src/proxy/hdrs/test_proxy_hdrs)
compile=$(echo "$cmds" | grep 'test_URL.cc.o -c' | head -1 |
  sed -E 's/ -o [^ ]+//; s/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c [^ ]+$//')
link=$(echo "$cmds" | tail -1 | sed -E '
  s/^: && //; s/ && :$//
  s#-Wl,--dependency-file=[^ ]+##
  s#src/proxy/hdrs/CMakeFiles/test_proxy_hdrs.dir/unit_tests/[^ ]+\.o##g
  s#lib/Catch2/src/libCatch2[^ ]+##g
  s#-o src/proxy/hdrs/test_proxy_hdrs#-o PROG PROG.o#')

cd "$build"
for prog in layout altdump; do
  eval "$compile -o $prog.o -c $here/$prog.cc"
  eval "$(echo "$link" | sed "s/PROG/$prog/g")"
done
# selectq also needs HttpTransactCache.cc (from the cache library) and the
# global hook table; it stubs the rest of src/api.
eval "$compile -o selectq.o -c $here/selectq.cc"
eval "$compile -o HttpTransactCache.o -c $src/src/iocore/cache/HttpTransactCache.cc"
eval "$compile -o HttpAPIHooks.o -c $src/src/api/HttpAPIHooks.cc"
eval "$(echo "$link" | sed "s/PROG\.o/selectq.o HttpTransactCache.o HttpAPIHooks.o/; s/PROG/selectq/g")"

./layout > "$root/src/testdata/hdr_layout.txt"
echo "wrote src/testdata/hdr_layout.txt ($(wc -l < "$root/src/testdata/hdr_layout.txt") lines)"

python3 -I "$here/gen-select-cases.py" | ./selectq > "$root/src/testdata/select_golden.txt"
echo "wrote src/testdata/select_golden.txt ($(grep -c '^case ' "$root/src/testdata/select_golden.txt") cases)"

if [ -n "$fixture" ]; then
  fix=$fixture
  "$root/zig-out/bin/cyc-doc" dir --span "$fix/spans/span0.db" --span "$fix/spans/span1.db" --seed seed-span1 --docs --json |
    python3 -I -c '
import json, sys
spans = sys.argv[1:]
for s in json.load(sys.stdin):
    for e in s["entries"]:
        if e["doc"]["magic_ok"] and e["doc"]["hlen"] > 0:
            print(spans[s["span_index"]], e["offset"])' "$fix/spans/span0.db" "$fix/spans/span1.db" |
    sort -k1,1 -k2n | ./altdump > "$fix/alts_golden.txt"
  echo "wrote $fix/alts_golden.txt ($(grep -c '^doc ' "$fix/alts_golden.txt") alternates)"
fi

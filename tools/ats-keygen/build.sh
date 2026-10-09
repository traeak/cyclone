#!/bin/sh
# Builds keygen, a small program linked against ATS master's own URL code,
# and regenerates src/testdata/key_golden.txt from src/testdata/key_urls.txt.
#
# usage: tools/ats-keygen/build.sh ATS_SOURCE_DIR [BUILD_DIR]
#
# BUILD_DIR (default: ./.ats-build) is a separate out-of-tree ATS build; only
# the test_proxy_hdrs target and its dependencies are built. The ATS source
# tree is not modified.
set -eu

src=$(cd "${1:?usage: $0 ATS_SOURCE_DIR [BUILD_DIR]}" && pwd)
build=${2:-.ats-build}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

[ -f "$build/build.ninja" ] ||
  cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
ninja -C "$build" test_proxy_hdrs
build=$(cd "$build" && pwd)

# Reuse the compile flags of test_URL.cc and the link line of test_proxy_hdrs,
# with the test objects and Catch2 swapped out for keygen.
cmds=$(ninja -C "$build" -t commands src/proxy/hdrs/test_proxy_hdrs)
compile=$(echo "$cmds" | grep 'test_URL.cc.o -c' | head -1 |
  sed -E 's/ -o [^ ]+/ -o '"$(echo "$build" | sed 's/[\/&]/\\&/g')"'\/keygen.o/; s/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c [^ ]+$//')
link=$(echo "$cmds" | tail -1 | sed -E '
  s/^: && //; s/ && :$//
  s#-Wl,--dependency-file=[^ ]+##
  s#src/proxy/hdrs/CMakeFiles/test_proxy_hdrs.dir/unit_tests/[^ ]+\.o##g
  s#lib/Catch2/src/libCatch2[^ ]+##g
  s#-o src/proxy/hdrs/test_proxy_hdrs#-o keygen keygen.o#')

cd "$build"
eval "$compile -c $here/keygen.cc"
eval "$link"
./keygen < "$root/src/testdata/key_urls.txt" > "$root/src/testdata/key_golden.txt"
echo "wrote src/testdata/key_golden.txt ($(wc -l < "$root/src/testdata/key_golden.txt") lines)"

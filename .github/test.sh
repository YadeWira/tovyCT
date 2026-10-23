#!/bin/sh
# Build-and-test helper used by CI; also runnable locally after scripts/build.sh.
set -e
cd "$(dirname "$0")/.."

# Deterministic sample: every file under src/, sorted by byte order.
find src -type f -print | LC_ALL=C sort | xargs cat > /tmp/tvct-sample.txt

./build/tests/test_sais /tmp/tvct-sample.txt
./build/tests/test_bwt /tmp/tvct-sample.txt
./build/tests/test_codec /tmp/tvct-sample.txt

if [ -x build/test_api ]; then
  if [ "$(uname -s)" = Darwin ]; then
    DYLD_LIBRARY_PATH=build ./build/test_api /tmp/tvct-sample.txt
  else
    ./build/test_api /tmp/tvct-sample.txt
  fi
fi

./build/tvct c /tmp/tvct-sample.txt /tmp/tvct-sample.tvct -b 1 -T 1
./build/tvct t /tmp/tvct-sample.tvct
./build/tvct d /tmp/tvct-sample.tvct /tmp/tvct-sample.out -T 2
cmp /tmp/tvct-sample.txt /tmp/tvct-sample.out

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum /tmp/tvct-sample.tvct | cut -d' ' -f1 > hash.txt
else
  shasum -a 256 /tmp/tvct-sample.tvct | cut -d' ' -f1 > hash.txt
fi
echo "compressed sample: $(cat hash.txt)"

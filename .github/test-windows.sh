#!/bin/sh
# Windows-native test run (Git Bash on a Windows runner). The Linux/macOS
# script uses the build path without .exe and cannot be shared.
set -e
cd "$(dirname "$0")/.."
OUT=${TVCT_OUT:-build/win-native}

find src -type f -print | LC_ALL=C sort | xargs cat > /tmp/tvct-sample.txt

"$OUT/tests/test_sais.exe" /tmp/tvct-sample.txt
"$OUT/tests/test_bwt.exe" /tmp/tvct-sample.txt
"$OUT/tests/test_codec.exe" /tmp/tvct-sample.txt
"$OUT/tests/test_blake3.exe" third_party/pjablake3/tests/kat.txt

"$OUT/tvct.exe" c /tmp/tvct-sample.txt /tmp/tvct-sample.tvct -b 1 -T 1
"$OUT/tvct.exe" t /tmp/tvct-sample.tvct
"$OUT/tvct.exe" d /tmp/tvct-sample.tvct /tmp/tvct-sample.out -T 2
cmp /tmp/tvct-sample.txt /tmp/tvct-sample.out

# Presets and the text transform path.
for p in compact max; do
  "$OUT/tvct.exe" c /tmp/tvct-sample.txt "/tmp/tvct-sample-$p.tvct" -l "$p" -T 1
  "$OUT/tvct.exe" d "/tmp/tvct-sample-$p.tvct" "/tmp/tvct-sample-$p.out" -T 1
  cmp /tmp/tvct-sample.txt "/tmp/tvct-sample-$p.out"
done

python scripts/gen_prose.py 2500000 > /tmp/tvct-prose.txt
"$OUT/tvct.exe" c /tmp/tvct-prose.txt /tmp/tvct-prose.tvct -b 1 -T 3
"$OUT/tvct.exe" d /tmp/tvct-prose.tvct /tmp/tvct-prose.out -T 1
cmp /tmp/tvct-prose.txt /tmp/tvct-prose.out
"$OUT/tvct.exe" c /tmp/tvct-prose.txt /tmp/tvct-prose-h.tvct -b 1 -H -T 2
"$OUT/tvct.exe" i /tmp/tvct-prose-h.tvct | grep -q BLAKE3
"$OUT/tvct.exe" d /tmp/tvct-prose-h.tvct /tmp/tvct-prose-h.out -T 3
cmp /tmp/tvct-prose.txt /tmp/tvct-prose-h.out
for x in off best; do
  "$OUT/tvct.exe" c /tmp/tvct-prose.txt "/tmp/tvct-prose-x$x.tvct" -b 1 -x "$x" -T 2
  "$OUT/tvct.exe" d "/tmp/tvct-prose-x$x.tvct" "/tmp/tvct-prose-x$x.out" -T 3
  cmp /tmp/tvct-prose.txt "/tmp/tvct-prose-x$x.out"
done

# Same line as .github/test.sh so the determinism job can compare it.
sha256sum /tmp/tvct-sample.tvct | cut -d' ' -f1 > /tmp/tvct-sample.sha
sha256sum /tmp/tvct-prose.tvct | cut -d' ' -f1 > /tmp/tvct-prose.sha
echo "sample:$(cat /tmp/tvct-sample.sha) prose:$(cat /tmp/tvct-prose.sha)" > hash.txt
echo "compressed samples: $(cat hash.txt)"

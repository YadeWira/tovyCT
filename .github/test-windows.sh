#!/bin/sh
# Windows-native test run (Git Bash on a Windows runner). The Linux/macOS
# script uses the build path without .exe and cannot be shared.
set -e
cd "$(dirname "$0")/.."
OUT=${TVCT_OUT:-build/win-native}

# The binary reports the version it was built from.
"$OUT/tvct.exe" --version | grep -q '^tovyCT [0-9]' || {
  echo "FAIL: tvct --version did not print a version" >&2
  exit 1
}

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

# UTF-8 text: same path as the Linux suite, without the C test_text binary.
python - <<'PY' > /tmp/tvct-utf8.txt
import sys
text = ("El r\u00e1pido zorro salt\u00f3 sobre el perro perezoso. "
        "Le c\u0153ur d\u00e9\u00e7u mais l'\u00e2me plut\u00f4t na\u00efve. "
        "Gr\u00f6\u00dfe und \u00dcbermut. "
        "\u041f\u0440\u0438\u0432\u0435\u0442, \u043c\u0438\u0440! "
        "\u3053\u3093\u306b\u3061\u306f\u4e16\u754c\u3002 "
        "\u4f60\u597d\u4e16\u754c\u3002\n")
sys.stdout.buffer.write((text * 700).encode("utf-8"))
PY
"$OUT/tvct.exe" c /tmp/tvct-utf8.txt /tmp/tvct-utf8-auto.tvct -b 1 -T 1
"$OUT/tvct.exe" c /tmp/tvct-utf8.txt /tmp/tvct-utf8-off.tvct -b 1 -x off -T 1
a=$(wc -c < /tmp/tvct-utf8-auto.tvct)
o=$(wc -c < /tmp/tvct-utf8-off.tvct)
if [ "$a" -gt "$o" ]; then
  echo "FAIL: the text transform made the UTF-8 sample larger ($a > $o)" >&2
  exit 1
fi
"$OUT/tvct.exe" d /tmp/tvct-utf8-auto.tvct /tmp/tvct-utf8.out -T 2
cmp /tmp/tvct-utf8.txt /tmp/tvct-utf8.out

# Same line as .github/test.sh so the determinism job can compare it.
sha256sum /tmp/tvct-sample.tvct | cut -d' ' -f1 > /tmp/tvct-sample.sha
sha256sum /tmp/tvct-prose.tvct | cut -d' ' -f1 > /tmp/tvct-prose.sha
echo "sample:$(cat /tmp/tvct-sample.sha) prose:$(cat /tmp/tvct-prose.sha)" > hash.txt
echo "compressed samples: $(cat hash.txt)"

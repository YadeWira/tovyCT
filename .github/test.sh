#!/bin/sh
# Build-and-test helper used by CI; also runnable locally after scripts/build.sh.
set -e
cd "$(dirname "$0")/.."

# Deterministic sample: every file under src/, sorted by byte order.
find src -type f -print | LC_ALL=C sort | xargs cat > /tmp/tvct-sample.txt

./build/tests/test_sais /tmp/tvct-sample.txt
./build/tests/test_bwt /tmp/tvct-sample.txt
./build/tests/test_codec /tmp/tvct-sample.txt
if [ -x build/tests/test_blake3 ]; then
  ./build/tests/test_blake3 third_party/pjablake3/tests/kat.txt
fi

if [ -x build/test_api ]; then
  if [ "$(uname -s)" = Darwin ]; then
    DYLD_LIBRARY_PATH=build ./build/test_api /tmp/tvct-sample.txt
  else
    ./build/test_api /tmp/tvct-sample.txt
  fi
fi

if [ -x build/test_text ]; then
  ./build/test_text /tmp/tvct-sample.txt
  ./build/test_text -b 4096 /tmp/tvct-sample.txt
fi

if [ -x build/test_hostile ]; then
  ./build/test_hostile
fi

if [ -x build/test_truncate ]; then
  head -c 65536 /tmp/tvct-sample.txt > /tmp/tvct-trunc.txt
  ./build/test_truncate /tmp/tvct-trunc.txt
fi

./build/tvct c /tmp/tvct-sample.txt /tmp/tvct-sample.tvct -b 1 -T 1
if [ -x build/test_payload ]; then
  ./build/test_payload /tmp/tvct-sample.tvct /tmp/tvct-sample.txt
fi

# Presets: compact and max must be the same streams as the explicit flags.
for p in compact max; do
  ./build/tvct c /tmp/tvct-sample.txt /tmp/tvct-sample-$p.tvct -l $p -T 1
  ./build/tvct t /tmp/tvct-sample-$p.tvct
  ./build/tvct d /tmp/tvct-sample-$p.tvct /tmp/tvct-sample-$p.out -T 1
  cmp /tmp/tvct-sample.txt /tmp/tvct-sample-$p.out
done

# Text transform. The source sample never takes it, so a generated prose
# sample does: the stream must contain text blocks, round-trip with several
# threads, and survive payload mutations along the text path.
python3 scripts/gen_prose.py 2500000 > /tmp/tvct-prose.txt
./build/test_text -b 1048576 /tmp/tvct-prose.txt
./build/tvct c /tmp/tvct-prose.txt /tmp/tvct-prose.tvct -b 1 -T 3 | tee /tmp/tvct-prose.log
if grep -q ' 0 text)' /tmp/tvct-prose.log; then
  echo "FAIL: the prose sample produced no text blocks"
  exit 1
fi
./build/tvct d /tmp/tvct-prose.tvct /tmp/tvct-prose.out -T 1
cmp /tmp/tvct-prose.txt /tmp/tvct-prose.out
if [ -x build/test_payload ]; then
  ./build/test_payload /tmp/tvct-prose.tvct /tmp/tvct-prose.txt
fi
# BLAKE3 digest: round trip, and the header reports it.
./build/tvct c /tmp/tvct-prose.txt /tmp/tvct-prose-h.tvct -b 1 -H -T 2
./build/tvct i /tmp/tvct-prose-h.tvct | grep -q BLAKE3
./build/tvct d /tmp/tvct-prose-h.tvct /tmp/tvct-prose-h.out -T 3
cmp /tmp/tvct-prose.txt /tmp/tvct-prose-h.out
for x in off best; do
  ./build/tvct c /tmp/tvct-prose.txt /tmp/tvct-prose-x$x.tvct -b 1 -x $x -T 2
  ./build/tvct d /tmp/tvct-prose-x$x.tvct /tmp/tvct-prose-x$x.out -T 3
  cmp /tmp/tvct-prose.txt /tmp/tvct-prose-x$x.out
done

# UTF-8 text: the transform is ASCII-only, so accented and Cyrillic letters are
# not folded, but it must still help (or at least not hurt) and round-trip.
python3 - <<'PY' > /tmp/tvct-utf8.txt
text = ("El r\u00e1pido zorro salt\u00f3 sobre el perro perezoso. "
        "Le c\u0153ur d\u00e9\u00e7u mais l'\u00e2me plut\u00f4t na\u00efve. "
        "Gr\u00f6\u00dfe und \u00dcbermut. "
        "\u041f\u0440\u0438\u0432\u0435\u0442, \u043c\u0438\u0440! "
        "\u3053\u3093\u306b\u3061\u306f\u4e16\u754c\u3002 "
        "\u4f60\u597d\u4e16\u754c\u3002\n")
print(text * 700, end="")
PY
if [ -x build/test_text ]; then
  ./build/test_text /tmp/tvct-utf8.txt
fi
./build/tvct c /tmp/tvct-utf8.txt /tmp/tvct-utf8-auto.tvct -b 1 -T 1
./build/tvct c /tmp/tvct-utf8.txt /tmp/tvct-utf8-off.tvct -b 1 -x off -T 1
a=$(stat -c%s /tmp/tvct-utf8-auto.tvct 2>/dev/null || stat -f%z /tmp/tvct-utf8-auto.tvct)
o=$(stat -c%s /tmp/tvct-utf8-off.tvct 2>/dev/null || stat -f%z /tmp/tvct-utf8-off.tvct)
if [ "$a" -gt "$o" ]; then
  echo "FAIL: the text transform made the UTF-8 sample larger ($a > $o)" >&2
  exit 1
fi
./build/tvct d /tmp/tvct-utf8-auto.tvct /tmp/tvct-utf8.out -T 2
cmp /tmp/tvct-utf8.txt /tmp/tvct-utf8.out

# Adaptive coder and no sample rows: a different method in the block header and
# a serial inverse BWT, both reachable from a hostile stream.
./build/tvct c /tmp/tvct-sample.txt /tmp/tvct-sample-adapt.tvct -b 1 -a -s -T 1
./build/tvct t /tmp/tvct-sample-adapt.tvct
./build/tvct d /tmp/tvct-sample-adapt.tvct /tmp/tvct-sample-adapt.out -T 2
cmp /tmp/tvct-sample.txt /tmp/tvct-sample-adapt.out
if [ -x build/test_payload ]; then
  ./build/test_payload /tmp/tvct-sample-adapt.tvct /tmp/tvct-sample.txt
fi
./build/tvct t /tmp/tvct-sample.tvct
./build/tvct d /tmp/tvct-sample.tvct /tmp/tvct-sample.out -T 2
cmp /tmp/tvct-sample.txt /tmp/tvct-sample.out

# One line with both hashes: the source sample (no text transform) and the
# prose sample (text transform, three blocks). CI compares the line across
# platforms, so both pipelines must give the same bytes everywhere.
sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
echo "sample:$(sha /tmp/tvct-sample.tvct) prose:$(sha /tmp/tvct-prose.tvct)" > hash.txt
echo "compressed samples: $(cat hash.txt)"

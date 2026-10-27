#!/bin/sh
# Builds and runs the decoder fuzzers.
#   .github/fuzz.sh [seconds] [jobs]
#
# The text transform has its own target, tests/fuzz_text.c, also plain C with
# full coverage and sanitizers.
#
# The main target is tests/fuzz_qlfc.c: the QLFC entropy decoder compiled into
# the fuzzer with coverage, AddressSanitizer and UBSan. That is the only build
# where libFuzzer gets feedback from the code it mutates, and the only one where
# every write is checked: the output buffer is a static array with redzones and
# the logical limit is passed in explicitly.
#
# tests/fuzz_decode.c still runs as a short smoke test of the container (header,
# block table, CRCs) through the public API, but the Pascal library cannot be
# instrumented with sanitizers, so its coverage number means nothing.
#
# The seed corpus is regenerated on every run: a corpus left over from an older
# format version is rejected at the version byte, and the fuzzer then reports
# millions of executions while exploring nothing.
set -e
cd "$(dirname "$0")/.."

SECS=${1:-120}
JOBS=${2:-8}
[ "$JOBS" -gt 16 ] && JOBS=16

./scripts/build.sh --libsais

# QLFC fuzzer: instrumented coder objects, no Pascal involved.
FLAGS="-O1 -g -fsanitize=fuzzer-no-link,address,undefined -fno-omit-frame-pointer -DLIBBSC_NO_UNALIGNED_ACCESS"
B=third_party/libbsc/src
rm -rf build/fuzz/qlfc
mkdir -p build/fuzz/qlfc
for f in coder/coder.cpp coder/qlfc/qlfc.cpp coder/qlfc/qlfc_model.cpp \
         platform/platform.cpp adler32/adler32.cpp; do
  clang++ $FLAGS -c "$B/$f" -o "build/fuzz/qlfc/$(basename "$f" .cpp).o"
done
clang $FLAGS -c tests/fuzz_qlfc.c -o build/fuzz/qlfc/harness.o
clang $FLAGS -DQLFC_CODER=2 -c tests/fuzz_qlfc.c -o build/fuzz/qlfc/harness_adapt.o
CODER_OBJS=$(ls build/fuzz/qlfc/*.o | grep -v harness)
clang++ -fsanitize=fuzzer,address,undefined $CODER_OBJS \
  build/fuzz/qlfc/harness.o -o build/fuzz/fuzz_qlfc
clang++ -fsanitize=fuzzer,address,undefined $CODER_OBJS \
  build/fuzz/qlfc/harness_adapt.o -o build/fuzz/fuzz_qlfc_adapt

# Fresh seeds from the current format.
rm -rf build/fuzz/corpus_qlfc
mkdir -p build/fuzz/corpus_qlfc
printf 'hello tovyCT, a small deterministic payload for the fuzzer\n' > /tmp/tvct-seed.txt
./build/tvct c /tmp/tvct-seed.txt build/fuzz/corpus_qlfc/small.tvct -b 1 >/dev/null
head -c 65536 /dev/zero > /tmp/tvct-seed-zeros.bin
./build/tvct c /tmp/tvct-seed-zeros.bin build/fuzz/corpus_qlfc/zeros.tvct -b 6 >/dev/null
yes 'the quick brown fox jumps over the lazy dog' | head -c 65536 > /tmp/tvct-seed-text.bin
./build/tvct c /tmp/tvct-seed-text.bin build/fuzz/corpus_qlfc/text.tvct -b 6 >/dev/null
./build/tvct c /tmp/tvct-seed-text.bin build/fuzz/corpus_qlfc/text-adapt.tvct -b 6 -a -s >/dev/null
python3 scripts/gen_prose.py 300000 > /tmp/tvct-seed-prose.txt
./build/tvct c /tmp/tvct-seed-prose.txt build/fuzz/corpus_qlfc/prose.tvct -b 1 >/dev/null
./build/tvct c /tmp/tvct-seed-zeros.bin build/fuzz/corpus_qlfc/zeros-adapt.tvct -b 6 -a -s >/dev/null
for f in build/fuzz/corpus_qlfc/*.tvct; do
  python3 scripts/extract_qlfc_seed.py "$f" build/fuzz/corpus_qlfc >/dev/null
done
# Seeds for the adaptive decoder get their own prefix, so they do not collide
# with the payload-NN.bin of the static streams.
for f in build/fuzz/corpus_qlfc/text-adapt.tvct build/fuzz/corpus_qlfc/zeros-adapt.tvct; do
  python3 scripts/extract_qlfc_seed.py "$f" build/fuzz/corpus_qlfc adapt >/dev/null
done
# Inputs that found real bugs; keep them as regression seeds.
cp tests/fixtures/qlfc-*.bin build/fuzz/corpus_qlfc/

./build/fuzz/fuzz_qlfc -max_total_time="$SECS" -max_len=24000 \
  -rss_limit_mb=4096 -jobs="$JOBS" -workers="$JOBS" -print_final_stats=1 \
  build/fuzz/corpus_qlfc

# Same corpus, adaptive QLFC decoder.
./build/fuzz/fuzz_qlfc_adapt -max_total_time="$SECS" -max_len=24000 \
  -rss_limit_mb=4096 -jobs="$JOBS" -workers="$JOBS" -print_final_stats=1 \
  build/fuzz/corpus_qlfc

# Text transform: decoder and encoder round trip, plain C with coverage.
clang -O1 -g -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all \
  tests/fuzz_text.c src/c/tvct_text.c -o build/fuzz/fuzz_text
rm -rf build/fuzz/corpus_text
mkdir -p build/fuzz/corpus_text
cat src/*.pas src/*.lpr > /tmp/tvct-seed-src.txt
for f in /tmp/tvct-seed-text.bin /tmp/tvct-seed-src.txt /tmp/tvct-seed-prose.txt; do
  # Round-trip seeds: a 0 mode byte, then the block.
  { printf '\000'; head -c 60000 "$f"; } > "build/fuzz/corpus_text/rt-$(basename "$f")"
  # Decode seeds: a transformed block, when the encoder takes the input.
  ./build/test_text -seed "build/fuzz/corpus_text/dec-$(basename "$f")" "$f" || true
done
./build/fuzz/fuzz_text -max_total_time="$SECS" -max_len=70000 \
  -rss_limit_mb=4096 -jobs="$JOBS" -workers="$JOBS" -print_final_stats=1 \
  build/fuzz/corpus_text

# Container smoke test: arbitrary bytes through the public API. No coverage
# feedback (the library is not instrumented), so it only looks for crashes.
rm -rf build/fuzz/corpus_api
mkdir -p build/fuzz/corpus_api
cp build/fuzz/corpus_qlfc/*.tvct build/fuzz/corpus_api/ 2>/dev/null || true
clang -O1 -g -fsanitize=fuzzer,address,undefined -Ibuild \
  tests/fuzz_decode.c -Lbuild -ltvct -Wl,-rpath,"$(pwd)/build" \
  -o build/fuzz/fuzz_decode
./build/fuzz/fuzz_decode -max_total_time=30 -max_len=65536 -rss_limit_mb=4096 \
  build/fuzz/corpus_api

#!/bin/sh
# Builds and runs the decoder fuzzer for a few minutes.
#   .github/fuzz.sh [seconds]
set -e
cd "$(dirname "$0")/.."

SECS=${1:-120}
./scripts/build.sh --libsais
mkdir -p build/fuzz/corpus
printf 'hello tovyCT, a small deterministic payload for the fuzzer\n' > /tmp/tvct-seed.txt
./build/tvct c /tmp/tvct-seed.txt build/fuzz/corpus/small.tvct -b 1 >/dev/null

clang -O1 -g -fsanitize=fuzzer,address,undefined -Ibuild \
  tests/fuzz_decode.c -Lbuild -ltvct -Wl,-rpath,"$(pwd)/build" \
  -o build/fuzz/fuzz_decode
./build/fuzz/fuzz_decode -max_total_time="$SECS" -max_len=8192 \
  -rss_limit_mb=4096 build/fuzz/corpus

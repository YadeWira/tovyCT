#!/bin/sh
# Builds tovyCT's tests (and, later, the CLI).
#
#   scripts/build.sh             pure Pascal suffix array
#   scripts/build.sh --libsais   vendor libsais as an optional accelerator
#   scripts/build.sh --debug     -O1 with line info
#
# libsais is compiled by the host C compiler; the archive format is identical
# either way, because the Pascal code computes the BWT from the suffix array.
set -e
cd "$(dirname "$0")/.."

OUT=build
mkdir -p "$OUT/tests" "$OUT/libsais"

DEFS=""
LIBS=""
OPT="-O3"
MODE=""

for arg in "$@"; do
  case "$arg" in
    --libsais) USE_LIBSAIS=1 ;;
    --debug)   OPT="-O1"; MODE="-g -gl"; OUT=build/dbg ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ -n "$USE_LIBSAIS" ]; then
  CC=${CC:-cc}
  "$CC" -O3 -c third_party/libsais/libsais.c -o "$OUT/libsais/libsais.o"
  ar rcs "$OUT/libsais/libsais.a" "$OUT/libsais/libsais.o"
  DEFS="-dTVCT_LIBSAIS"
  LIBS="-Fl$(pwd)/$OUT/libsais"
  echo "libsais: $OUT/libsais/libsais.a"
fi

mkdir -p "$OUT/tests"
for t in tests/test_sais.lpr tests/test_bwt.lpr; do
  echo "== $t"
  fpc $OPT $MODE -Mobjfpc $DEFS -Fusrc $LIBS -Fu"$OUT/tests" -FU"$OUT/tests" \
      -FE"$OUT/tests" "$t"
done

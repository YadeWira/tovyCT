#!/bin/sh
# Builds tovyCT.
#
#   scripts/build.sh [--target NAME] [--libsais] [--portable] [--debug]
#
# Targets:
#   host          this machine (default)              build/
#   win64         Windows x86-64, XP/7 and later      build/win64/
#   win32         Windows i386, XP/7 and later        build/win32/
#   linux-arm64   Linux AArch64                      build/linux-arm64/
#
# macOS AArch64 has no target: it is the host target, built on macOS (CI).
#
# libsais is the suffix array backend (Apache-2.0, vendored). The entropy coder
# is libbsc's QLFC (Apache-2.0, vendored). Both are compiled by the target C/C++
# compiler; the Pascal side is built by Free Pascal, cross where needed.
set -e
cd "$(dirname "$0")/.."

TARGET=host
USE_LIBSAIS=0
DEBUG=0
PORTABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --libsais) USE_LIBSAIS=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --portable) PORTABLE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross/bin}

case "$TARGET" in
  host)
    CC=${CC:-cc}; CXX=${CXX:-c++}; AR=${AR:-ar}
    FPC=${FPC:-fpc}
    CFLAGS="-O3 -fPIC -march=native"; [ "$PORTABLE" = 1 ] && CFLAGS="-O3"
    EXE=""; SO="libtvct.so"; OUT=build
    if [ "$(uname -s)" = Darwin ]; then
      SO="libtvct.dylib"
      CFLAGS="-O3"          # Apple clang has no -march=native
    fi
    ;;
  win64)
    CC=x86_64-w64-mingw32-gcc; CXX=x86_64-w64-mingw32-g++; AR=x86_64-w64-mingw32-ar
    FPC="$FPC_CROSS/fpc-win64"
    CFLAGS="-O3 -fPIC -DTVCT_PORTABLE"; EXE=".exe"; SO="tvct.dll"; OUT=build/win64
    WINLIB="/usr/x86_64-w64-mingw32/lib $(ls -d /usr/lib/gcc/x86_64-w64-mingw32/*/ | head -1)"
    ;;
  win32)
    CC=i686-w64-mingw32-gcc; CXX=i686-w64-mingw32-g++; AR=i686-w64-mingw32-ar
    FPC="$FPC_CROSS/fpc-win32"
    CFLAGS="-O3 -fPIC -DTVCT_PORTABLE"; EXE=".exe"; SO="tvct.dll"; OUT=build/win32
    WINLIB="/usr/i686-w64-mingw32/lib $(ls -d /usr/lib/gcc/i686-w64-mingw32/*/ | head -1)"
    ;;
  linux-arm64)
    CC=aarch64-linux-gnu-gcc; CXX=aarch64-linux-gnu-g++; AR=aarch64-linux-gnu-ar
    FPC=${FPC_ARM64:-fpc-aarch64}
    CFLAGS="-O3 -mcpu=cortex-a53"; EXE=""; SO="libtvct.so"; OUT=build/linux-arm64
    ;;
  *)
    echo "unknown target: $TARGET" >&2; exit 1
    ;;
esac

if [ "$DEBUG" = 1 ]; then
  FPCOPT="-O1"; MODE="-g -gl"; CFLAGS="-O1 -g"
else
  FPCOPT="-O3"; MODE=""
fi

DEFS=""
LIBS=""
for d in $WINLIB; do
  LIBS="$LIBS -Fl$d"
done
mkdir -p "$OUT/tests" "$OUT/lib" "$OUT/bsc" "$OUT/libsais" "$OUT/units"

# C kernels: decode paths.
$CC $CFLAGS -c src/c/tvct_kernels.c -o "$OUT/lib/tvct_kernels.o"
$AR rcs "$OUT/lib/libtvctkern.a" "$OUT/lib/tvct_kernels.o"
LIBS="$LIBS -Fl$(pwd)/$OUT/lib"

# libbsc coder (C++), the entropy backend.
BSC="$(pwd)/third_party/libbsc/src"
$CXX $CFLAGS -c "$BSC/coder/coder.cpp" -o "$OUT/bsc/coder.o"
$CXX $CFLAGS -c "$BSC/coder/qlfc/qlfc.cpp" -o "$OUT/bsc/qlfc.o"
$CXX $CFLAGS -c "$BSC/coder/qlfc/qlfc_model.cpp" -o "$OUT/bsc/qlfc_model.o"
$CXX $CFLAGS -c "$BSC/platform/platform.cpp" -o "$OUT/bsc/platform.o"
$CXX $CFLAGS -c "$BSC/adler32/adler32.cpp" -o "$OUT/bsc/adler32.o"
$AR rcs "$OUT/bsc/libbsc.a" "$OUT/bsc/coder.o" "$OUT/bsc/qlfc.o" \
    "$OUT/bsc/qlfc_model.o" "$OUT/bsc/platform.o" "$OUT/bsc/adler32.o"
LIBS="$LIBS -Fl$(pwd)/$OUT/bsc"

if [ "$USE_LIBSAIS" = 1 ]; then
  $CC $CFLAGS -c third_party/libsais/libsais.c -o "$OUT/libsais/libsais.o"
  $AR rcs "$OUT/libsais/libsais.a" "$OUT/libsais/libsais.o"
  DEFS="-dTVCT_LIBSAIS"
  LIBS="$LIBS -Fl$(pwd)/$OUT/libsais"
  echo "libsais: $OUT/libsais/libsais.a"
else
  echo "warning: no libsais; the suffix array falls back to the Pascal SA-IS" >&2
fi

for t in tests/test_sais.lpr tests/test_bwt.lpr tests/test_codec.lpr; do
  echo "== $t"
  $FPC $FPCOPT $MODE -Mobjfpc $DEFS -Fusrc -Fi"$(pwd)/src" $LIBS -Fu"$OUT/tests" -FU"$OUT/tests" \
      -FE"$OUT/tests" "$t"
done

echo "== tvct"
$FPC $FPCOPT $MODE -Mobjfpc $DEFS -Fusrc -Fi"$(pwd)/src" $LIBS -Fu"$OUT/tests" -FU"$OUT/tests" \
    -FE"$OUT" src/tvct.lpr

echo "== $SO"
$FPC $FPCOPT $MODE -Mobjfpc $DEFS -Fusrc -Fi"$(pwd)/src" $LIBS -Fu"$OUT/units" -FU"$OUT/units" \
    -o"$OUT/$SO" src/tvct.api.lpr
cp include/tvct.h "$OUT/tvct.h"

if [ "$TARGET" = host ] && command -v cc >/dev/null 2>&1; then
  if [ "$(uname -s)" = Darwin ]; then
    cc -O2 -I"$OUT" tests/test_api.c -L"$OUT" -ltvct -o "$OUT/test_api"
  else
    cc -O2 -I"$OUT" tests/test_api.c -L"$OUT" -ltvct -Wl,-rpath,"$(pwd)/$OUT" \
       -o "$OUT/test_api"
    cc -O2 -I"$OUT" tests/test_truncate.c -L"$OUT" -ltvct \
       -Wl,-rpath,"$(pwd)/$OUT" -o "$OUT/test_truncate"
  fi
fi

echo "built in $OUT"

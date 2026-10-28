#!/bin/sh
# Builds tovyCT.
#
#   scripts/build.sh [--target NAME] [--libsais] [--portable] [--debug]
#
# Targets:
#   host          this machine (default)              build/
#   win64         Windows x86-64, XP/7 and later      build/win64/
#   win32         Windows i386, XP/7 and later        build/win32/
#   win-native    Windows x86-64 on a Windows host    build/win-native/
#   win-native32  Windows i386 on a Windows host      build/win-native32/
#   linux-arm64   Linux AArch64                      build/linux-arm64/
#   linux-x86     Linux i386                         build/linux-x86/
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
PROFILE=0
PORTABLE=0
CHECKS=0
FPCSTRIP=

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --libsais) USE_LIBSAIS=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --checked) CHECKS=1; shift ;;
    --profile) PROFILE=1; shift ;;
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
  linux-x86)
    CC=${CC:-gcc}; CXX=${CXX:-g++}; AR=${AR:-ar}
    FPC=${FPC_I386:-fpc}
    # The 32-bit FPC runs with -n (no fpc.cfg), so it does not strip by
    # default the way the host compiler does; ask for it explicitly.
    CFLAGS="-O3 -m32"; EXE=""; SO="libtvct.so"; OUT=build/linux-x86
    FPCSTRIP="-Xs"
    ;;
  win-native32)
    CC=${CC:-i686-w64-mingw32-gcc}; CXX=${CXX:-i686-w64-mingw32-g++}
    AR=${AR:-ar}
    FPC=${FPC:-fpc}
    CFLAGS="-O3 -DTVCT_PORTABLE"; EXE=".exe"; SO="tvct.dll"; OUT=build/win-native32
    ;;
  win-native)
    CC=${CC:-cc}; CXX=${CXX:-c++}; AR=${AR:-ar}
    # The fpc driver in the combined installer refuses to select the cross
    # compiler; ppcrossx64 targets x86_64-win64 directly.
    if [ -z "$FPC" ] && command -v ppcrossx64 >/dev/null 2>&1; then
      FPC=ppcrossx64
    else
      FPC=${FPC:-fpc}
    fi
    CFLAGS="-O3 -DTVCT_PORTABLE"; EXE=".exe"; SO="tvct.dll"; OUT=build/win-native
    ;;
  *)
    echo "unknown target: $TARGET" >&2; exit 1
    ;;
esac

FPC_TARGET=""
if [ "$TARGET" = win-native ] || [ "$TARGET" = win-native32 ]; then
  FPC_TARGET=""
  # Git Bash rewrites arguments that look like POSIX paths before handing them
  # to native programs; FPC must see the -Fl paths exactly as written.
  export MSYS2_ARG_CONV_EXCL='*'
fi

if [ "$DEBUG" = 1 ]; then
  FPCOPT="-O1"; MODE="-g -gl"; CFLAGS="-O1 -g"
else
  FPCOPT="-O3"; MODE=""
fi

if [ "$PROFILE" = 1 ]; then
  # Optimised but with symbols, for perf and callgrind.
  FPCOPT="-O3"; MODE="-g"; CFLAGS="$CFLAGS -g"
fi

if [ "$CHECKS" = 1 ]; then
  FPCOPT="-O1 -Cr -Co"; MODE="-g -gl"
  CFLAGS="$CFLAGS -O1 -g"
fi

# libbsc reads the compressed stream through 16-bit loads; the explicit memcpy
# path is well defined and does not depend on the architecture tolerating
# misaligned accesses.
CFLAGS="$CFLAGS -DLIBBSC_NO_UNALIGNED_ACCESS"
# The kernels are linked into a shared library and the guard module keeps its
# fault state in thread-local storage, which needs position-independent code.
CFLAGS="$CFLAGS -fPIC"

DEFS=""
if [ "$CHECKS" = 1 ]; then
  DEFS="-dTVCT_CHECKED"
fi
LIBS=""
for d in $WINLIB; do
  LIBS="$LIBS -Fl$d"
done

# The compiled C++ subset uses only C allocation and memcpy, so it needs no
# libstdc++; the cross build passes the mingw library directories only because
# they are part of its toolchain.
if [ "$TARGET" = linux-x86 ]; then
  for lib in libstdc++.a libgcc.a; do
    path=$(g++ -m32 -print-file-name=$lib)
    if [ -f "$path" ]; then
      LIBS="$LIBS -Fl$(dirname "$path")"
    fi
  done
fi
mkdir -p "$OUT/tests" "$OUT/lib" "$OUT/bsc" "$OUT/libsais" "$OUT/units"

# Native Windows links need the mingw import libraries (kernel32, advapi32 and
# friends). Copy the ones FPC asks for into the local lib directory: the mingw
# path may contain spaces and cannot be passed as a single -Fl argument.
if [ "$TARGET" = win-native ] || [ "$TARGET" = win-native32 ]; then
  for lib in libkernel32.a libadvapi32.a libuser32.a libgdi32.a libshell32.a \
             libole32.a liboleaut32.a libuuid.a libws2_32.a libmsvcrt.a \
             libmingwex.a libgcc.a libstdc++.a; do
    src=$($CC -print-file-name=$lib)
    if [ -f "$src" ]; then cp "$src" "$OUT/lib/"; fi
  done
fi

# C kernels: the inverse BWT and the text transform.
$CC $CFLAGS -c src/c/tvct_kernels.c -o "$OUT/lib/tvct_kernels.o"
$CC $CFLAGS -c src/c/tvct_text.c -o "$OUT/lib/tvct_text.o"
$CC $CFLAGS -c src/c/tvct_guard.c -o "$OUT/lib/tvct_guard.o"
$CC $CFLAGS -c src/c/tvct_crc.c -o "$OUT/lib/tvct_crc.o"
$AR rcs "$OUT/lib/libtvctkern.a" "$OUT/lib/tvct_kernels.o" "$OUT/lib/tvct_text.o" \
    "$OUT/lib/tvct_guard.o" "$OUT/lib/tvct_crc.o"
LIBS="$LIBS -Fl$OUT/lib"

# libbsc coder (C++), the entropy backend.
#
# QLFC has per-ISA decoders. The portable one is always built; on x86 an AVX
# copy of the same source is built too, with its symbols renamed so both can be
# linked, and the coder picks it at run time when the CPU has AVX. Only the
# instruction mix changes: the decoded bytes and the stream are identical.
BSC="third_party/libbsc/src"
# nm and objcopy must match the compiler's target (the cross builds produce
# COFF objects the host tools do not understand).
tool_for() {
  case "$CC" in
    *-gcc) echo "${CC%-gcc}-$1" ;;
    *) echo "$1" ;;
  esac
}
OBJCOPY=${OBJCOPY:-$(tool_for objcopy)}
NM=${NM:-$(tool_for nm)}
$CXX $CFLAGS -c "$BSC/coder/qlfc/qlfc.cpp" -o "$OUT/bsc/qlfc.o"
case "$($CC -dumpmachine 2>/dev/null)" in
  x86_64*|i[3-6]86*)
    $CXX $CFLAGS -mavx -c "$BSC/coder/qlfc/qlfc.cpp" -o "$OUT/bsc/qlfc_avx.o"
    "$NM" -g --defined-only "$OUT/bsc/qlfc_avx.o" | awk '{print $3}' \
      | sed 's/.*/& tvct_avx_&/' > "$OUT/bsc/qlfc_avx.syms"
    "$OBJCOPY" --redefine-syms="$OUT/bsc/qlfc_avx.syms" "$OUT/bsc/qlfc_avx.o"
    QLFC_OBJS="$OUT/bsc/qlfc_avx.o"
    QLFC_DEF="-DTVCT_QLFC_AVX"
    ;;
  *)
    QLFC_OBJS=""
    QLFC_DEF=""
    ;;
esac
$CXX $CFLAGS $QLFC_DEF -c "$BSC/coder/coder.cpp" -o "$OUT/bsc/coder.o"
$CXX $CFLAGS -c "$BSC/coder/qlfc/qlfc_model.cpp" -o "$OUT/bsc/qlfc_model.o"
$CXX $CFLAGS -c "$BSC/platform/platform.cpp" -o "$OUT/bsc/platform.o"
$CXX $CFLAGS -c "$BSC/adler32/adler32.cpp" -o "$OUT/bsc/adler32.o"
$AR rcs "$OUT/bsc/libbsc.a" "$OUT/bsc/coder.o" "$OUT/bsc/qlfc.o" $QLFC_OBJS \
    "$OUT/bsc/qlfc_model.o" "$OUT/bsc/platform.o" "$OUT/bsc/adler32.o"
LIBS="$LIBS -Fl$OUT/bsc"

if [ "$USE_LIBSAIS" = 1 ]; then
  $CC $CFLAGS -c third_party/libsais/libsais.c -o "$OUT/libsais/libsais.o"
  $AR rcs "$OUT/libsais/libsais.a" "$OUT/libsais/libsais.o"
  DEFS="-dTVCT_LIBSAIS"
  LIBS="$LIBS -Fl$OUT/libsais"
  echo "libsais: $OUT/libsais/libsais.a"
else
  echo "warning: no libsais; the suffix array falls back to the Pascal SA-IS" >&2
fi

for t in tests/test_sais.lpr tests/test_bwt.lpr tests/test_codec.lpr; do
  echo "== $t"
  $FPC $FPCOPT $MODE $FPCSTRIP $FPC_TARGET -Mobjfpc $DEFS -Fusrc -Fisrc -Futhird_party/pjablake3 -Fithird_party/pjablake3 $LIBS -Fu"$OUT/tests" -FU"$OUT/tests" \
      -FE"$OUT/tests" "$t"
done

echo "== third_party/pjablake3/tests/test_blake3.pas"
$FPC -O2 $FPC_TARGET -Futhird_party/pjablake3 -Fithird_party/pjablake3 -Fu"$OUT/tests" -FU"$OUT/tests" \
    -FE"$OUT/tests" third_party/pjablake3/tests/test_blake3.pas

echo "== tvct"
$FPC $FPCOPT $MODE $FPCSTRIP $FPC_TARGET -Mobjfpc $DEFS -Fusrc -Fisrc -Futhird_party/pjablake3 -Fithird_party/pjablake3 $LIBS -Fu"$OUT/tests" -FU"$OUT/tests" \
    -FE"$OUT" src/tvct.lpr

echo "== $SO"
$FPC $FPCOPT $MODE $FPCSTRIP $FPC_TARGET -Mobjfpc $DEFS -Fusrc -Fisrc -Futhird_party/pjablake3 -Fithird_party/pjablake3 $LIBS -Fu"$OUT/units" -FU"$OUT/units" \
    -o"$OUT/$SO" src/tvct.api.lpr
cp include/tvct.h "$OUT/tvct.h"

if { [ "$TARGET" = host ] || [ "$TARGET" = linux-x86 ]; } && command -v cc >/dev/null 2>&1; then
  TFLAGS="-O2"
  [ "$TARGET" = linux-x86 ] && TFLAGS="-O2 -m32"
  for t in tests/test_api.c tests/test_truncate.c tests/test_hostile.c \
           tests/test_payload.c; do
    $CC $TFLAGS -I"$OUT" "$t" -L"$OUT" -ltvct -Wl,-rpath,"$(pwd)/$OUT" \
       -o "$OUT/$(basename "$t" .c)"
  done
  $CC $TFLAGS tests/test_text.c src/c/tvct_text.c -o "$OUT/test_text"
fi

echo "built in $OUT"

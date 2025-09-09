#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#
# scripts/build_libpng.sh
# Build zlib + libpng instrumented with AFL compiler and link OSS-Fuzz libpng harness
# into a single AFL-instrumented binary using your wrapper.
#
# Outputs:
#   build/libpng_fuzzer
#
# Usage: ./scripts/build_libpng.sh
#

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/build"
TMP_BUILD="$OUT_DIR/tmp_libpng_build"
STAGING="$TMP_BUILD/install"
NUM_JOBS="$(nproc || echo 1)"

detect_afl_compiler() {
  if command -v afl-clang-lto >/dev/null 2>&1; then
    echo "afl-clang-lto"
  elif command -v afl-clang-fast >/dev/null 2>&1; then
    echo "afl-clang-fast"
  else
    echo ""
  fi
}

AFL_CC="$(detect_afl_compiler)"
if [ -z "$AFL_CC" ]; then
  echo "ERROR: No AFL compiler found. Install afl++ (provides afl-clang-lto or afl-clang-fast)." >&2
  exit 1
fi

if command -v "${AFL_CC}++" >/dev/null 2>&1; then
  AFL_CXX="${AFL_CC}++"
else
  AFL_CXX="$AFL_CC"
fi

echo "Using AFL C compiler: $AFL_CC"
echo "Using AFL C++ compiler: $AFL_CXX"

CFLAGS="-g -O1 -fno-omit-frame-pointer"
CXXFLAGS="-g -O1 -fno-omit-frame-pointer -std=c++11"
LDFLAGS=""

rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD"
mkdir -p "$STAGING"
mkdir -p "$OUT_DIR"

cd "$TMP_BUILD"

if [ ! -d "$TMP_BUILD/zlib" ]; then
  git clone --depth 1 https://github.com/madler/zlib.git
fi
echo "[*] Building zlib..."
cd zlib
CC="$AFL_CC" CFLAGS="$CFLAGS" ./configure --static --prefix="$STAGING"
make -j"$NUM_JOBS"
make install
cd "$TMP_BUILD"

if [ ! -d "$TMP_BUILD/libpng" ]; then
  git clone --depth 1 https://github.com/pnggroup/libpng.git
fi
echo "[*] Building libpng..."
cd libpng

if [ -f scripts/pnglibconf.dfa ]; then
  sed -e "s/option STDIO/option STDIO disabled/" \
      -e "s/option WARNING /option WARNING disabled/" \
      -e "s/option WRITE enables WRITE_INT_FUNCTIONS/option WRITE disabled/" \
      scripts/pnglibconf.dfa > scripts/pnglibconf.dfa.temp
  mv scripts/pnglibconf.dfa.temp scripts/pnglibconf.dfa
fi

autoreconf -f -i

export CPPFLAGS="-I${STAGING}/include"
export LDFLAGS="-L${STAGING}/lib ${LDFLAGS}"
export CC="$AFL_CC"
export CXX="$AFL_CXX"

./configure --prefix="$STAGING" || {
  echo "configure failed; dumping config.log:"
  sed -n '1,200p' config.log || true
  exit 1
}

make -j"$NUM_JOBS" clean || true
make -j"$NUM_JOBS" libpng16.la

LIBPNG_LIB="$PWD/.libs/libpng16.a"
LIBPNG_INC="$PWD"   # root contains png.h etc

if [ ! -f "$LIBPNG_LIB" ]; then
  echo "ERROR: libpng static library not found at expected location: $LIBPNG_LIB" >&2
  exit 1
fi

HARNESS_SRC="$TMP_BUILD/libpng/contrib/oss-fuzz/libpng_read_fuzzer.cc"
if [ ! -f "$HARNESS_SRC" ]; then
  echo "ERROR: OSS-Fuzz harness not found at $HARNESS_SRC" >&2
  exit 1
fi

echo "[*] Compiling libpng OSS-Fuzz harness to object (no -lFuzzer)..."
$AFL_CXX $CXXFLAGS -I"$LIBPNG_INC" -I"$STAGING/include" -c "$HARNESS_SRC" -o libpng_read_fuzzer.o

WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"

echo "[*] Compiling wrapper + linking final AFL-instrumented binary..."
OUT_BINARY="$OUT_DIR/libpng_fuzzer"
$AFL_CXX $CXXFLAGS -I"$LIBPNG_INC" -I"$STAGING/include" \
    "$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp" libpng_read_fuzzer.o \
    "$LIBPNG_LIB" "$STAGING/lib/libz.a" -o "$OUT_BINARY" $LDFLAGS

echo "[+] Built fuzz binary: $OUT_BINARY"

echo "
DONE.

How to run AFL:
  # Example run (replace /path/to/afl-fuzz if custom):
  afl-fuzz -i $PROJECT_ROOT/data/libpng -o $OUT_DIR/afl-out -- $OUT_BINARY @@
"

exit 0

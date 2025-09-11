#!/usr/bin/env bash
set -euo pipefail

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
  elif command -v afl-cc >/dev/null 2>&1; then
    echo "afl-cc"
  else
    echo ""
  fi
}

AFL_CC="$(detect_afl_compiler)"
if [ -z "$AFL_CC" ]; then
  echo "ERROR: No AFL compiler found. Install afl++ (provides afl-clang-lto, afl-clang-fast, or afl-cc)." >&2
  exit 1
fi

if command -v "${AFL_CC}++" >/dev/null 2>&1; then
  AFL_CXX="${AFL_CC}++"
else
  AFL_CXX="$AFL_CC"
fi

echo "Using AFL C compiler: $AFL_CC"
echo "Using AFL C++ compiler: $AFL_CXX"

CFLAGS=( -g -O1 -fno-omit-frame-pointer )
CXXFLAGS=( -g -O1 -fno-omit-frame-pointer -std=c++11 )
LDFLAGS=()

# prepare dirs
rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD" "$STAGING" "$OUT_DIR"

cd "$TMP_BUILD"

# -------------------------
# Build zlib (static) first
# -------------------------
echo "[*] Cloning zlib..."
if [ ! -d "$TMP_BUILD/zlib" ]; then
  git clone --depth 1 -b develop https://github.com/madler/zlib.git "$TMP_BUILD/zlib"
fi

echo "[*] Building zlib with AFL..."
cd "$TMP_BUILD/zlib"
CC="$AFL_CC" CFLAGS="${CFLAGS[*]}" ./configure --static --prefix="$STAGING"
make -j"$NUM_JOBS" clean
make -j"$NUM_JOBS" all
make -j"$NUM_JOBS" install

ZLIB_LIB="$STAGING/lib/libz.a"
ZLIB_INC="$STAGING/include"

if [ ! -f "$ZLIB_LIB" ]; then
  # also check local libz.a in case configure installed differently
  if [ -f "$PWD/libz.a" ]; then
    ZLIB_LIB="$PWD/libz.a"
    ZLIB_INC="$PWD"
  else
    echo "ERROR: libz.a not found at expected location: $STAGING/lib/libz.a or $PWD/libz.a" >&2
    exit 1
  fi
fi
echo "[+] Built zlib static library: $ZLIB_LIB"

# -------------------------
# Build libpng
# -------------------------
echo "[*] Cloning libpng..."
if [ ! -d "$TMP_BUILD/libpng" ]; then
  git clone --depth 1 https://github.com/pnggroup/libpng.git "$TMP_BUILD/libpng"
fi

echo "[*] Building libpng with AFL..."
cd "$TMP_BUILD/libpng"

# apply small config tweaks if present (same pattern used previously)
if [ -f scripts/pnglibconf.dfa ]; then
  sed -e "s/option STDIO/option STDIO disabled/" \
      -e "s/option WARNING /option WARNING disabled/" \
      -e "s/option WRITE enables WRITE_INT_FUNCTIONS/option WRITE disabled/" \
      scripts/pnglibconf.dfa > scripts/pnglibconf.dfa.temp || true
  if [ -f scripts/pnglibconf.dfa.temp ]; then
    mv scripts/pnglibconf.dfa.temp scripts/pnglibconf.dfa
  fi
fi

autoreconf -f -i || true

export CPPFLAGS="-I${STAGING}/include"
export LDFLAGS="-L${STAGING}/lib ${LDFLAGS[*]}"
export CC="$AFL_CC"
export CXX="$AFL_CXX"

./configure --prefix="$STAGING" || {
  echo "configure failed; dumping config.log (first 200 lines):"
  sed -n '1,200p' config.log || true
  exit 1
}

make -j"$NUM_JOBS" clean || true
# build static libpng (libpng16.a is typically created inside .libs)
make -j"$NUM_JOBS" libpng16.la || {
  echo "make libpng16.la failed; trying full build..."
  make -j"$NUM_JOBS"
}

LIBPNG_LIB="$PWD/.libs/libpng16.a"
# fallback locations
if [ ! -f "$LIBPNG_LIB" ]; then
  if [ -f "$PWD/.libs/libpng.a" ]; then
    LIBPNG_LIB="$PWD/.libs/libpng.a"
  elif [ -f "$PWD/libpng16.a" ]; then
    LIBPNG_LIB="$PWD/libpng16.a"
  fi
fi

LIBPNG_INC="$PWD"   # root contains png.h etc

if [ ! -f "$LIBPNG_LIB" ]; then
  echo "ERROR: libpng static library not found at expected locations. Checked: .libs/libpng16.a, .libs/libpng.a, libpng16.a" >&2
  exit 1
fi
echo "[+] Built libpng static library: $LIBPNG_LIB"

# -------------------------
# Prepare OSS-Fuzz harness
# -------------------------
HARNESS_SRC="$TMP_BUILD/libpng/contrib/oss-fuzz/libpng_read_fuzzer.cc"
if [ ! -f "$HARNESS_SRC" ]; then
  echo "ERROR: OSS-Fuzz harness not found at expected path: $HARNESS_SRC" >&2
  exit 1
fi

echo "[*] Compiling libpng OSS-Fuzz harness to object (no -lFuzzer)..."
# compile harness to object
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$LIBPNG_INC" -I"$STAGING/include" -c "$HARNESS_SRC" -o libpng_read_fuzzer.o

# -------------------------
# Compile wrapper + link
# -------------------------
WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"
if [ ! -f "$WRAPPER_SRC" ]; then
  echo "ERROR: wrapper source not found at: $WRAPPER_SRC" >&2
  exit 1
fi

echo "[*] Compiling wrapper + linking final AFL-instrumented binary..."
OUT_BINARY="$OUT_DIR/libpng_fuzzer"
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$LIBPNG_INC" -I"$STAGING/include" \
    "$WRAPPER_SRC" libpng_read_fuzzer.o \
    "$LIBPNG_LIB" "$ZLIB_LIB" -o "$OUT_BINARY" "${LDFLAGS[@]}"

echo "[+] Built fuzz binary: $OUT_BINARY"

# copy dict if present in OSS-Fuzz harness dir
if [ -f "$TMP_BUILD/libpng/contrib/oss-fuzz/libpng_read_fuzzer.dict" ]; then
  cp "$TMP_BUILD/libpng/contrib/oss-fuzz/libpng_read_fuzzer.dict" "$OUT_DIR/libpng_fuzzer.dict"
  echo "[+] Copied dict: $OUT_DIR/libpng_fuzzer.dict"
fi

echo "
DONE.

How to run afl:
  afl-fuzz -i $PROJECT_ROOT/data/libpng -o $OUT_DIR/afl-out -- $OUT_BINARY @@

Notes:
 - This script builds zlib and libpng statically with your detected AFL compiler and links the OSS-Fuzz libpng_read_fuzzer harness.
 - If configure/make fail due to missing autotools on your system, install autoconf/automake/libtool.
 - If you want a different optimization level or extra flags, edit CFLAGS / CXXFLAGS arrays at the top of the script.
"

exit 0

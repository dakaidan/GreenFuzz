#!/usr/bin/env bash
set -euo pipefail

# Build script for libjpeg-turbo with AFL++ instrumentation.
# Pattern follows scripts/build_jsoncpp.sh and scripts/build_libpng.sh.
#
# Memory-bound profile: DCT blocks, color conversion buffers, MCU output
# buffers -- working set typically exceeds L2 for non-trivial JPEGs.
# Strong candidate for GreenAFL DRAM-channel evaluation.

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$PROJECT_ROOT/build"
TMP_BUILD="$OUT_DIR/tmp_libjpeg_turbo_build"
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

echo "Using AFL C compiler:   $AFL_CC"
echo "Using AFL C++ compiler: $AFL_CXX"

CFLAGS=( -g -O1 -fno-omit-frame-pointer )
CXXFLAGS=( -g -O1 -fno-omit-frame-pointer -std=c++11 )
LDFLAGS=()

rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD" "$OUT_DIR"
cd "$TMP_BUILD"

# -------------------------
# Clone & build libjpeg-turbo (static)
# -------------------------
echo "[*] Cloning libjpeg-turbo..."
if [ ! -d "$TMP_BUILD/libjpeg-turbo" ]; then
  git clone --depth 1 https://github.com/libjpeg-turbo/libjpeg-turbo.git
fi

if [ ! -f "$TMP_BUILD/libjpeg-turbo/fuzz/decompress.cc" ]; then
  echo "ERROR: fuzz/decompress.cc not found in libjpeg-turbo source tree." >&2
  echo "       Expected path: $TMP_BUILD/libjpeg-turbo/fuzz/decompress.cc" >&2
  exit 1
fi

echo "[*] Configuring libjpeg-turbo with AFL..."
BUILD_DIR="$TMP_BUILD/libjpeg-turbo/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Keep SIMD setting CONSISTENT across all runs in a campaign for fair
# vanilla-vs-GreenAFL comparison. Disable if NASM is missing.
SIMD_OPT=""
if ! command -v nasm >/dev/null 2>&1; then
  echo "[!] NASM not found; building without SIMD acceleration."
  SIMD_OPT="-DWITH_SIMD=0"
fi

cmake -G "Unix Makefiles" \
      -DCMAKE_C_COMPILER="$AFL_CC" \
      -DCMAKE_CXX_COMPILER="$AFL_CXX" \
      -DCMAKE_C_FLAGS="${CFLAGS[*]}" \
      -DCMAKE_CXX_FLAGS="${CXXFLAGS[*]}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_STATIC=1 \
      -DENABLE_SHARED=0 \
      $SIMD_OPT \
      ..

make -j"$NUM_JOBS" jpeg-static turbojpeg-static

JPEG_LIB="$BUILD_DIR/libjpeg.a"
TJPEG_LIB="$BUILD_DIR/libturbojpeg.a"
JPEG_SRC_INC="$TMP_BUILD/libjpeg-turbo/src"   # turbojpeg.h lives here in 2025+
JPEG_GEN_INC="$BUILD_DIR"

if [ ! -f "$JPEG_LIB" ]; then
  echo "ERROR: libjpeg.a not found at: $JPEG_LIB" >&2
  exit 1
fi
echo "[+] Built libjpeg static library:     $JPEG_LIB"
echo "[+] Built libturbojpeg static library: $TJPEG_LIB"

# -------------------------
# Compile in-tree harness (fuzz/decompress.cc) and link
# -------------------------
HARNESS_SRC="$TMP_BUILD/libjpeg-turbo/fuzz/decompress.cc"
echo "[*] Compiling in-tree harness (fuzz/decompress.cc)..."
cd "$TMP_BUILD"
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$JPEG_GEN_INC" \
    -c "$HARNESS_SRC" -o libjpeg_turbo_fuzzer.o


# -------------------------
# Compile wrapper + link
# -------------------------
WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"
if [ ! -f "$WRAPPER_SRC" ]; then
  echo "ERROR: wrapper source not found at: $WRAPPER_SRC" >&2
  exit 1
fi

echo "[*] Linking final AFL-instrumented binary..."
OUT_BINARY="$OUT_DIR/libjpeg_turbo_fuzzer"
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$JPEG_SRC_INC" -I"$JPEG_GEN_INC" \
    "$WRAPPER_SRC" libjpeg_turbo_fuzzer.o \
    "$TJPEG_LIB" "$JPEG_LIB" -o "$OUT_BINARY" "${LDFLAGS[@]}"

echo "[+] Built fuzz binary: $OUT_BINARY"

if [ -f "$TMP_BUILD/libjpeg-turbo/fuzz/jpeg.dict" ]; then
  cp "$TMP_BUILD/libjpeg-turbo/fuzz/jpeg.dict" "$OUT_DIR/libjpeg_turbo_fuzzer.dict"
  echo "[+] Copied dict: $OUT_DIR/libjpeg_turbo_fuzzer.dict"
fi

echo "
DONE.

Run a campaign with:
  bash case_study/scripts/run_campaign.sh 3 12h $OUT_BINARY $PROJECT_ROOT/case_study/data/libjpeg-turbo/public.zip true false
"
exit 0

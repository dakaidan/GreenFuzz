#!/usr/bin/env bash
set -euo pipefail

# Build script for harfbuzz with AFL++ instrumentation, using harfbuzz's
# own in-tree hb-shape-fuzzer harness (the canonical OSS-Fuzz / FuzzBench one).
# Pattern follows scripts/build_jsoncpp.sh and scripts/build_libpng.sh.
#
# Memory-bound profile: pointer chasing through SFNT tables, GSUB/GPOS
# lookup chains, glyph cache, scattered allocations. Different DRAM access
# pattern from libjpeg-turbo (latency-bound vs. bandwidth-bound), giving
# two complementary memory-bound data points for GreenAFL evaluation.

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$PROJECT_ROOT/build"
TMP_BUILD="$OUT_DIR/tmp_harfbuzz_build"
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
# Clone harfbuzz
# -------------------------
echo "[*] Cloning harfbuzz..."
if [ ! -d "$TMP_BUILD/harfbuzz" ]; then
  git clone --depth 1 https://github.com/harfbuzz/harfbuzz.git
fi

# -------------------------
# Build static libharfbuzz.a via CMake
#
# Disable optional system deps (freetype/glib/icu/graphite2) so the build
# is self-contained, fast, and the energy measurement doesn't include
# unrelated code paths. This matches FuzzBench's minimal config.
# -------------------------
BUILD_DIR="$TMP_BUILD/harfbuzz_build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[*] Configuring harfbuzz with AFL..."
cmake -G "Unix Makefiles" \
      -DCMAKE_C_COMPILER="$AFL_CC" \
      -DCMAKE_CXX_COMPILER="$AFL_CXX" \
      -DCMAKE_C_FLAGS="${CFLAGS[*]}" \
      -DCMAKE_CXX_FLAGS="${CXXFLAGS[*]}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DHB_HAVE_FREETYPE=OFF \
      -DHB_HAVE_GLIB=OFF \
      -DHB_HAVE_ICU=OFF \
      -DHB_HAVE_GRAPHITE2=OFF \
      "$TMP_BUILD/harfbuzz"

echo "[*] Building libharfbuzz.a (this takes a few minutes)..."
make -j"$NUM_JOBS" harfbuzz

HB_LIB="$BUILD_DIR/libharfbuzz.a"
HB_SRC_INC="$TMP_BUILD/harfbuzz/src"
HB_TEST_FUZZING_INC="$TMP_BUILD/harfbuzz/test/fuzzing"
HB_TEST_API_INC="$TMP_BUILD/harfbuzz/test/api"

if [ ! -f "$HB_LIB" ]; then
  echo "ERROR: libharfbuzz.a not found at: $HB_LIB" >&2
  exit 1
fi
echo "[+] Built harfbuzz static library: $HB_LIB"

# -------------------------
# Compile the in-tree hb-shape-fuzzer harness
#
# The harness lives at test/fuzzing/hb-shape-fuzzer.cc and provides
# LLVMFuzzerTestOneInput(). It transitively includes:
#   - test/fuzzing/hb-shape-input.hh
#   - test/fuzzing/hb-fuzzer.hh   (needs src/ on include path)
#   - test/api/test-ot-face.c     (via relative #include "../api/test-ot-face.c")
#
# We compile WITHOUT -DHB_IS_IN_FUZZER, so the dummy `alloc_state` in
# hb-fuzzer.hh is used (we don't need libFuzzer's failing-alloc.c hook).
# -------------------------
cd "$TMP_BUILD"

HARNESS_SRC="$TMP_BUILD/harfbuzz/test/fuzzing/hb-shape-fuzzer.cc"
if [ ! -f "$HARNESS_SRC" ]; then
  echo "ERROR: hb-shape-fuzzer.cc not found at: $HARNESS_SRC" >&2
  echo "       (harfbuzz tree layout may have changed.)" >&2
  exit 1
fi

echo "[*] Compiling hb-shape-fuzzer harness to object (no -lFuzzer)..."
"$AFL_CXX" "${CXXFLAGS[@]}" \
    -I"$HB_SRC_INC" \
    -I"$HB_TEST_FUZZING_INC" \
    -I"$HB_TEST_API_INC" \
    -c "$HARNESS_SRC" -o hb_shape_fuzzer.o

# -------------------------
# Compile wrapper + link
# -------------------------
WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"
if [ ! -f "$WRAPPER_SRC" ]; then
  echo "ERROR: wrapper source not found at: $WRAPPER_SRC" >&2
  exit 1
fi

echo "[*] Linking final AFL-instrumented binary..."
OUT_BINARY="$OUT_DIR/harfbuzz_fuzzer"
"$AFL_CXX" "${CXXFLAGS[@]}" \
    -I"$HB_SRC_INC" \
    "$WRAPPER_SRC" hb_shape_fuzzer.o \
    "$HB_LIB" -lpthread \
    -o "$OUT_BINARY" "${LDFLAGS[@]}"

echo "[+] Built fuzz binary: $OUT_BINARY"

echo "
DONE.

Run a campaign with:
  bash case_study/scripts/run_campaign.sh 3 12h $OUT_BINARY $PROJECT_ROOT/case_study/data/harfbuzz/public.zip true false
"
exit 0

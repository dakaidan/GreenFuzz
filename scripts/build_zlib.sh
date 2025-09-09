#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/build"
TMP_BUILD="$OUT_DIR/tmp_zlib_build"
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
  echo "ERROR: No AFL compiler found. Install afl++." >&2
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

rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD" "$OUT_DIR"
cd "$TMP_BUILD"

echo "[*] Cloning zlib..."
if [ ! -d "$TMP_BUILD/zlib" ]; then
  git clone --depth 1 -b develop https://github.com/madler/zlib.git
fi
cd zlib

echo "[*] Building zlib with AFL..."
CC="$AFL_CC" CFLAGS="${CFLAGS[*]}" ./configure --static
make -j"$NUM_JOBS" clean
make -j"$NUM_JOBS" all

ZLIB_LIB="$PWD/libz.a"
ZLIB_INC="$PWD"

if [ ! -f "$ZLIB_LIB" ]; then
  echo "ERROR: libz.a not built at $ZLIB_LIB" >&2
  exit 1
fi
echo "[+] Built zlib static library: $ZLIB_LIB"

WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"

# --- Pull OSS-Fuzz harnesses ---
OSS_FUZZ_DIR="$TMP_BUILD/oss-fuzz"
FUZZERS_DIR="$TMP_BUILD/zlib_fuzzers"
mkdir -p "$FUZZERS_DIR"
if [ ! -d "$OSS_FUZZ_DIR" ]; then
  echo "[*] Cloning OSS-Fuzz repo..."
  git clone --depth 1 https://github.com/google/oss-fuzz.git "$OSS_FUZZ_DIR"
fi
echo "[*] Copying zlib uncompress fuzzers..."
cp "$OSS_FUZZ_DIR/projects/zlib/zlib_uncompress"*fuzzer.cc "$FUZZERS_DIR/"

echo "[*] Building uncompress fuzzers..."
for f in "$FUZZERS_DIR"/*.cc; do
  [ -f "$f" ] || continue
  b=$(basename -s .cc "$f")
  echo "  -> $b"
  "$AFL_CXX" "${CXXFLAGS[@]}" -I"$ZLIB_INC" -c "$f" -o "$b.o"
  "$AFL_CXX" "${CXXFLAGS[@]}" -I"$ZLIB_INC" \
      "$WRAPPER_SRC" "$b.o" "$ZLIB_LIB" -o "$OUT_DIR/$b" "${LDFLAGS[@]}"
  rm -f "$b.o"
done

echo "
[+] Done. Fuzzers are in: $OUT_DIR
Example run:
  afl-fuzz -i $PROJECT_ROOT/data/zlib -o $OUT_DIR/afl-out -- $OUT_DIR/zlib_uncompress_fuzzer @@
"
exit 0

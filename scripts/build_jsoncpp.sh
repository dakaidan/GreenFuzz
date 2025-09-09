#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/build"
TMP_BUILD="$OUT_DIR/tmp_jsoncpp_build"
LPM_DIR="$TMP_BUILD/LPM"
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

CXXFLAGS=( -g -O1 -fno-omit-frame-pointer -std=c++17 )
CFLAGS=( -g -O1 -fno-omit-frame-pointer )
LDFLAGS=()

rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD"
mkdir -p "$OUT_DIR"

cd "$TMP_BUILD"

echo "[*] Cloning libprotobuf-mutator..."
if [ ! -d "$TMP_BUILD/libprotobuf-mutator" ]; then
  git clone --depth 1 https://github.com/google/libprotobuf-mutator.git
fi

echo "[*] Building libprotobuf-mutator (LPM)..."
mkdir -p "$LPM_DIR"
cd "$LPM_DIR"
cmake ../libprotobuf-mutator -GNinja \
  -DLIB_PROTO_MUTATOR_DOWNLOAD_PROTOBUF=ON \
  -DLIB_PROTO_MUTATOR_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release
ninja

cd "$TMP_BUILD"

echo "[*] Cloning jsoncpp..."
if [ ! -d "$TMP_BUILD/jsoncpp" ]; then
  git clone --depth 1 https://github.com/open-source-parsers/jsoncpp.git
fi
cd jsoncpp

if grep -q "CMAKE_CXX_STANDARD 11" CMakeLists.txt >/dev/null 2>&1; then
  sed -i 's/set(CMAKE_CXX_STANDARD 11)/set(CMAKE_CXX_STANDARD 17)/' CMakeLists.txt || true
fi

echo "[*] Configuring jsoncpp with AFL C++ compiler..."
BUILD_DIR="$TMP_BUILD/jsoncpp/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake -DCMAKE_CXX_COMPILER="$AFL_CXX" \
      -DCMAKE_C_COMPILER="$AFL_CC" \
      -DCMAKE_CXX_FLAGS="${CXXFLAGS[*]}" \
      -DCMAKE_C_FLAGS="${CFLAGS[*]}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DJSONCPP_WITH_TESTS=ON \
      -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF \
      -G "Unix Makefiles" \
      ..
make -j"$NUM_JOBS"

if [ -f "$BUILD_DIR/lib/libjsoncpp.a" ]; then
  JSONCPP_LIB="$BUILD_DIR/lib/libjsoncpp.a"
elif [ -f "$BUILD_DIR/libjsoncpp.a" ]; then
  JSONCPP_LIB="$BUILD_DIR/libjsoncpp.a"
else
  echo "ERROR: libjsoncpp.a not found after build (looked in build dir)." >&2
  exit 1
fi
JSONCPP_INCLUDE="$TMP_BUILD/jsoncpp/include"

echo "[+] Built jsoncpp static library: $JSONCPP_LIB"

HARNESS_SRC="$TMP_BUILD/jsoncpp/src/test_lib_json/fuzz.cpp"
if [ ! -f "$HARNESS_SRC" ]; then
  echo "ERROR: fuzz.cpp not found at expected path: $HARNESS_SRC" >&2
  exit 1
fi

echo "[*] Compiling OSS-Fuzz fuzz.cpp to object (no -lFuzzer)..."
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" -c "$HARNESS_SRC" -o fuzz_fuzz_o.o

WRAPPER_SRC="$PROJECT_ROOT/src/oss-fuzz/oss-harness-wrapper.cpp"

echo "[*] Linking final AFL-instrumented binary..."
OUT_BINARY="$OUT_DIR/jsoncpp_fuzzer"
"$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" \
    "$WRAPPER_SRC" fuzz_fuzz_o.o \
    "$JSONCPP_LIB" -o "$OUT_BINARY" "${LDFLAGS[@]}"

echo "[+] Built fuzz binary: $OUT_BINARY"

if [ -f "$TMP_BUILD/jsoncpp/src/test_lib_json/fuzz.dict" ]; then
  cp "$TMP_BUILD/jsoncpp/src/test_lib_json/fuzz.dict" "$OUT_DIR/jsoncpp_fuzzer.dict"
  echo "[+] Copied dict: $OUT_DIR/jsoncpp_fuzzer.dict"
fi

PROTO_SRC="$PROJECT_ROOT/json.proto"
PROTO_FUZZ_SRC="$PROJECT_ROOT/jsoncpp_fuzz_proto.cc"
PROTO_CONVERTER="$PROJECT_ROOT/json_proto_converter.cc"

if [ -f "$PROTO_SRC" ] && [ -f "$PROTO_FUZZ_SRC" ] && [ -f "$PROTO_CONVERTER" ]; then
  echo "[*] Proto sources found, attempting to build proto fuzzer using LPM's protoc..."
  PROTOC_BIN="$LPM_DIR/external.protobuf/bin/protoc"
  if [ ! -x "$PROTOC_BIN" ]; then
    echo "ERROR: protoc not found at expected LPM path: $PROTOC_BIN" >&2
  else
    GEN_DIR="$TMP_BUILD/genfiles"
    rm -rf "$GEN_DIR"
    mkdir -p "$GEN_DIR"
    "$PROTOC_BIN" "$PROTO_SRC" --cpp_out="$GEN_DIR" --proto_path="$PROJECT_ROOT"

    echo "[*] Compiling proto fuzzer object files..."
    "$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" -I"$GEN_DIR" -I"$LPM_DIR/external.protobuf/include" \
        -c "$GEN_DIR/json.pb.cc" -o gen_json_pb_o.o

    "$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" -I"$GEN_DIR" -I"$LPM_DIR/external.protobuf/include" \
        -c "$PROTO_CONVERTER" -o proto_converter_o.o

    "$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" -I"$GEN_DIR" -I"$LPM_DIR/external.protobuf/include" \
        -c "$PROTO_FUZZ_SRC" -o proto_fuzz_o.o

    echo "[*] Linking proto fuzzer (this links LPM static libs)..."
    LPM_LIB_A="$LPM_DIR/src/libprotobuf-mutator.a"
    LPM_LIB_LIBFUZZER="$LPM_DIR/src/libprotobuf-mutator-libfuzzer.a"
    PROTO_A_DIR="$LPM_DIR/external.protobuf/lib"
    "$AFL_CXX" "${CXXFLAGS[@]}" -I"$JSONCPP_INCLUDE" -I"$GEN_DIR" -I"$LPM_DIR/external.protobuf/include" \
        gen_json_pb_o.o proto_converter_o.o proto_fuzz_o.o \
        "$LPM_LIB_LIBFUZZER" "$LPM_LIB_A" \
        -Wl,--start-group "$PROTO_A_DIR"/lib*.a -Wl,--end-group \
        "$JSONCPP_LIB" -o "$OUT_DIR/jsoncpp_proto_fuzzer"
    echo "[+] Built proto fuzz binary: $OUT_DIR/jsoncpp_proto_fuzzer"
  fi
else
  echo "[!] Proto fuzzer sources not present in project root; skipping proto fuzzer build."
  echo "    To enable proto fuzzer build, place json.proto, jsoncpp_fuzz_proto.cc and json_proto_converter.cc in the project root."
fi

echo "
DONE.

Example run:
  afl-fuzz -i $PROJECT_ROOT/data/jsoncpp -o $OUT_DIR/afl-out -- $OUT_BINARY @@
"
exit 0

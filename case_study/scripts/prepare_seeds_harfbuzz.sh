#!/usr/bin/env bash
set -euo pipefail

# Prepares data/harfbuzz/public.zip seed corpus for fuzzing.
#
# Follows the FuzzBench harfbuzz_hb-shape-fuzzer build.sh pattern: pulls
# fonts from the harfbuzz repo itself (public GitHub, no GCP / auth) and
# packages them in the existing data/<target>/public.zip format used here
# (SHA-1-named files at root, fuzzing-discovered fonts under regressions/).
#
# Source directories (from harfbuzz repo):
#   Main corpus  -> test/shape/data/in-house/fonts
#                   test/shape/data/aots/fonts
#                   test/shape/data/text-rendering-tests/fonts
#                   test/api/fonts
#                   perf/fonts
#   Regressions  -> test/fuzzing/fonts  (fuzzer-discovered crash/regression fonts)
#
# Output: $PROJECT_ROOT/data/harfbuzz/public.zip

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$PROJECT_ROOT/data/harfbuzz"
WORK_DIR="$(mktemp -d -t harfbuzz-seeds.XXXXXX)"
OUT_ZIP="$DATA_DIR/public.zip"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "[*] Working in: $WORK_DIR"
mkdir -p "$DATA_DIR"

# -------------------------
# Clone harfbuzz (shallow)
# -------------------------
cd "$WORK_DIR"

echo "[*] Cloning harfbuzz (public, ~100 MB shallow)..."
git clone --depth 1 https://github.com/harfbuzz/harfbuzz.git

# -------------------------
# Build staging area
# -------------------------
mkdir -p staging/main staging/regressions

echo "[*] Collecting main corpus fonts..."
for d in \
    test/shape/data/in-house/fonts \
    test/shape/data/aots/fonts \
    test/shape/data/text-rendering-tests/fonts \
    test/api/fonts \
    perf/fonts
do
  if [ -d "harfbuzz/$d" ]; then
    find "harfbuzz/$d" -type f -exec cp {} staging/main/ \; 2>/dev/null || true
  else
    echo "  [!] Skipping missing dir: $d"
  fi
done

echo "[*] Collecting fuzzing-discovered fonts -> regressions/ ..."
if [ -d "harfbuzz/test/fuzzing/fonts" ]; then
  find harfbuzz/test/fuzzing/fonts -type f -exec cp {} staging/regressions/ \; 2>/dev/null || true
else
  echo "  [!] No test/fuzzing/fonts directory found"
fi

MAIN_PRE=$(ls staging/main 2>/dev/null | wc -l)
REG_PRE=$(ls staging/regressions 2>/dev/null | wc -l)
echo "[+] Pre-dedup: main=$MAIN_PRE, regressions=$REG_PRE"

# -------------------------
# Rename by SHA-1 of content (matches existing public.zip pattern)
# -------------------------
echo "[*] SHA-1-renaming files for content-addressed dedup..."

mkdir -p staging/final/regressions

for f in staging/main/*; do
  [ -f "$f" ] || continue
  h=$(sha1sum "$f" | cut -c1-40)
  cp -n "$f" "staging/final/$h" 2>/dev/null || true
done

for f in staging/regressions/*; do
  [ -f "$f" ] || continue
  h=$(sha1sum "$f" | cut -c1-40)
  cp -n "$f" "staging/final/regressions/$h" 2>/dev/null || true
done

MAIN_FINAL=$(find staging/final -maxdepth 1 -type f | wc -l)
REG_FINAL=$(find staging/final/regressions -maxdepth 1 -type f | wc -l)
echo "[+] Post-dedup: main=$MAIN_FINAL, regressions=$REG_FINAL"

# -------------------------
# Create public.zip
# -------------------------
echo "[*] Creating $OUT_ZIP ..."
rm -f "$OUT_ZIP"
(cd staging/final && zip -q -r "$OUT_ZIP" . -x ".*")

SIZE=$(ls -lh "$OUT_ZIP" | awk '{print $5}')
echo "
[+] DONE
    Output:      $OUT_ZIP
    Size:        $SIZE
    Main seeds:  $MAIN_FINAL
    Regressions: $REG_FINAL

You can now run AFL with:
  unzip $OUT_ZIP -d $DATA_DIR/
  afl-fuzz -G 524288 -i $DATA_DIR -o build/afl-out -- build/harfbuzz_fuzzer @@
"

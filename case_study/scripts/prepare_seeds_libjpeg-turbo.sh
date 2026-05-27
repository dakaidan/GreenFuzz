#!/usr/bin/env bash
set -euo pipefail

# Prepares data/libjpeg-turbo/public.zip seed corpus for fuzzing.
#
# Follows the FuzzBench Dockerfile pattern exactly: pulls public seed
# sources from GitHub (no GCP / gsutil / auth required) and packages them
# matching the existing data/<target>/public.zip format used in this repo
# (SHA-1-named files at root, bug regressions under regressions/).
#
# Sources (all public GitHub):
#   - github.com/libjpeg-turbo/seed-corpora   (afl-testcases/jpeg*, bugs/decompress*)
#   - github.com/libjpeg-turbo/libjpeg-turbo  (testimages/*.jpg)
#
# Output: $PROJECT_ROOT/data/libjpeg-turbo/public.zip

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$PROJECT_ROOT/data/libjpeg-turbo"
WORK_DIR="$(mktemp -d -t libjpeg-seeds.XXXXXX)"
OUT_ZIP="$DATA_DIR/public.zip"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "[*] Working in: $WORK_DIR"
mkdir -p "$DATA_DIR"

# -------------------------
# Clone public seed sources
# -------------------------
cd "$WORK_DIR"

echo "[*] Cloning libjpeg-turbo/seed-corpora (public, ~48 MB)..."
git clone --depth 1 https://github.com/libjpeg-turbo/seed-corpora.git

echo "[*] Cloning libjpeg-turbo (for testimages/)..."
git clone --depth 1 https://github.com/libjpeg-turbo/libjpeg-turbo.git ljt-src

# -------------------------
# Build staging area
# -------------------------
mkdir -p staging/main staging/regressions

echo "[*] Collecting main corpus (afl-testcases + testimages)..."
# Use find -exec cp to recurse into edges-only/ and full/ subdirs.
# Filename collisions across the two trees are OK; SHA-1 rename below dedups.
find seed-corpora/afl-testcases/jpeg \
     seed-corpora/afl-testcases/jpeg_turbo \
     -type f -exec cp {} staging/main/ \; 2>/dev/null || true

# Include libjpeg-turbo's own canonical test images
cp ljt-src/testimages/*.jpg staging/main/ 2>/dev/null || true

echo "[*] Collecting bug regressions (bugs/decompress/*)..."
find seed-corpora/bugs/decompress -type f -exec cp {} staging/regressions/ \; 2>/dev/null || true

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
  # Use cp -n so duplicate content doesn't overwrite
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
  afl-fuzz -G 524288 -i $DATA_DIR -o build/afl-out -- build/libjpeg_turbo_fuzzer @@
"

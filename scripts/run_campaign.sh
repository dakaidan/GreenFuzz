#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run_campaign.sh <repetitions> <timeout> <target_bin> <corpus_zip> [local_fuzz] [local_cmin]
# Example: ./run_campaign.sh 3 24h ./build/libpng_fuzzer ./data/libpng/public.zip true true

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <repetitions> <timeout> <target_bin> <corpus_zip> [local_fuzz] [local_cmin]"
    exit 1
fi

REPS=$1
TIMEOUT=$2
TARGET=$3
CORPUS_ZIP=$4
LOCAL_FUZZ=${5:-false}
LOCAL_CMIN=${6:-false}

EXP_NAME="experiment_$(basename "$TARGET")_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXP_NAME"

echo "[*] Experiment dir: $EXP_NAME"

INIT_CORPUS="$EXP_NAME/initial_corpus"
mkdir -p "$INIT_CORPUS"
unzip -qq "$CORPUS_ZIP" -d "$INIT_CORPUS"

MIN_CORPUS="$EXP_NAME/minimised_corpus"
mkdir -p "$MIN_CORPUS"

echo "[*] Minimising corpus..."
if [[ "$LOCAL_CMIN" == "true" ]]; then
    echo "[*] Using local AFL++ afl-cmin with energy options"
    AFL_PRELOAD="build/energy_print.so" python3 AFLPlusPlus/afl-cmin.py \
        --energy-first --no-batch \
        -i "$INIT_CORPUS" \
        -o "$MIN_CORPUS" \
        -- "$TARGET" @@
else
    python3 "$(which afl-cmin.py)" \
        -i "$INIT_CORPUS" \
        -o "$MIN_CORPUS" \
        -- "$TARGET" @@
fi

for i in $(seq 1 "$REPS"); do
    REP_DIR="$EXP_NAME/rep-$i"
    mkdir -p "$REP_DIR/in" "$REP_DIR/out"
    cp -r "$MIN_CORPUS"/* "$REP_DIR/in/"
done

for i in $(seq 1 "$REPS"); do
    REP_DIR="$EXP_NAME/rep-$i"
    echo "[*] Running repetition $i in $REP_DIR"

    if [[ "$LOCAL_FUZZ" == "true" ]]; then
        CMD="AFLPlusPlus/afl-fuzz -i $REP_DIR/in -o $REP_DIR/out -- $TARGET @@"
        CMD="AFL_PRELOAD=build/energy_afl.so $CMD"
    else
        CMD="afl-fuzz -i $REP_DIR/in -o $REP_DIR/out -- $TARGET @@"
    fi

    perf stat -a -e power/energy-pkg/,power/energy-ram/ \
        -o "$REP_DIR/perf_stat.txt" \
        timeout "$TIMEOUT" bash -c "$CMD"
done

echo "[*] Experiment finished: $EXP_NAME"

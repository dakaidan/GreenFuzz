#!/usr/bin/env bash
# Usage: ./run_campaign.sh <repetitions> <timeout> <target_bin> <corpus_zip> [config] [local_cmin]
# Example: ./run_campaign.sh 3 24h ./build/libpng_fuzzer ./data/libpng/public.zip c3 false
#
# config selects one of the four experiment configurations:
#
#   config  binary                 AFL_PRELOAD            decision   gives you
#   ------  ---------------------  ---------------------  ---------  ----------------------
#   c0      afl-fuzz (PATH)        -                      off        external reference
#   c1      AFLPlusPlus/afl-fuzz   -                      off        clean E_baseline 
#   c2      AFLPlusPlus/afl-fuzz   build/energy_afl.so    off        E_logging (measure only)
#   c3      AFLPlusPlus/afl-fuzz   build/energy_afl.so    on         E_GreenFuzz (full)
#
#   D_frame+meas = c2 - c1   (energy measurement cost on the baseline workload)
#   D_decision   = c3 - c2   (behavioural effect of the energy heuristic)
#   c1 - c0 ~= 0             (check everything off == upstream vanilla)

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <repetitions> <timeout> <target_bin> <corpus_zip> [config] [local_cmin]"
    echo "       config = c0 | c1 | c2 | c3   (default: c3)"
    exit 1
fi

REPS=$1
TIMEOUT=$2
TARGET=$3
CORPUS_ZIP=$4
CONFIG=${5:-c3}
LOCAL_CMIN=${6:-false}

# Normalise legacy config aliases.
case "$CONFIG" in
    vanilla|false) CONFIG="c0" ;;
    greenfuzz|true) CONFIG="c3" ;;
esac

case "$CONFIG" in
    c0|c1|c2|c3) ;;
    *) echo "ERROR: config must be c0, c1, c2, or c3 (got: $CONFIG)" >&2; exit 1 ;;
esac

export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_SKIP_CPUFREQ=1
export AFL_NO_UI=1

EXP_NAME="experiment_$(basename "$TARGET")_${CONFIG}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXP_NAME"

echo "[*] Experiment dir: $EXP_NAME  (config: $CONFIG)"

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

# ---------------------------------------------------------------------------
# Build the per-config fuzz command.
#   AFL_BIN  : which afl-fuzz binary to run
#   PRELOAD  : AFL_PRELOAD prefix (energy measurement on/off)
#   NODECIDE : AFL_ENERGY_NO_DECISION prefix (heuristic neutralised when set)
# ---------------------------------------------------------------------------
case "$CONFIG" in
    c0)  AFL_BIN="afl-fuzz";              PRELOAD="";                          NODECIDE="" ;;
    c1)  AFL_BIN="AFLPlusPlus/afl-fuzz";  PRELOAD="";                          NODECIDE="" ;;
    c2)  AFL_BIN="AFLPlusPlus/afl-fuzz";  PRELOAD="AFL_PRELOAD=build/energy_afl.so"; NODECIDE="AFL_ENERGY_NO_DECISION=1" ;;
    c3)  AFL_BIN="AFLPlusPlus/afl-fuzz";  PRELOAD="AFL_PRELOAD=build/energy_afl.so"; NODECIDE="" ;;
esac

for i in $(seq 1 "$REPS"); do
    REP_DIR="$EXP_NAME/rep-$i"
    echo "[*] Running repetition $i in $REP_DIR  (config: $CONFIG)"

    CMD="$NODECIDE $PRELOAD $AFL_BIN -i $REP_DIR/in -o $REP_DIR/out -- $TARGET @@"

    perf stat -a -I 1000 \
        -e power/energy-pkg/,power/energy-ram/,instructions,cycles,LLC-loads,LLC-load-misses \
        -o "$REP_DIR/perf_stat.txt" \
        timeout "$TIMEOUT" bash -c "$CMD"
done

echo "[*] Experiment finished: $EXP_NAME"

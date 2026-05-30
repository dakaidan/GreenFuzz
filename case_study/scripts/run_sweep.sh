#!/usr/bin/env bash
#
# Per-machine sweep runner for GreenFuzz energy evaluation.
#
# DESIGN: R=4 replicates, 6 machines, 8 days.
#   48 campaigns = 4 configs x 3 targets x 4 reps

# Output layout:
#   /local/sweep_m<N>_<datetime>/
#   /local/sweep_m<N>.tar.gz                          

set -euo pipefail

NODE_ID="${NODE_ID:?must set NODE_ID env var (0..5 for machines M1..M6)}"
DURATION="${DURATION:-24h}"

case "$NODE_ID" in
  0|1|2|3|4|5) ;;
  *) echo "ERROR: NODE_ID must be 0..5 (got: $NODE_ID)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Config codes V/B/L/G are mapped to c0/c1/c2/c3 below.
# ---------------------------------------------------------------------------
declare -A SCHEDULE
SCHEDULE[0]="jsoncpp:V jsoncpp:B jsoncpp:L jsoncpp:G libjpeg_turbo:L libjpeg_turbo:G libjpeg_turbo:V libjpeg_turbo:B"
SCHEDULE[1]="jsoncpp:B jsoncpp:L jsoncpp:G jsoncpp:V libjpeg_turbo:G libjpeg_turbo:V libjpeg_turbo:B libjpeg_turbo:L"
SCHEDULE[2]="jsoncpp:L jsoncpp:G jsoncpp:V jsoncpp:B harfbuzz:V harfbuzz:B harfbuzz:L harfbuzz:G"
SCHEDULE[3]="jsoncpp:G jsoncpp:V jsoncpp:B jsoncpp:L harfbuzz:B harfbuzz:L harfbuzz:G harfbuzz:V"
SCHEDULE[4]="libjpeg_turbo:V libjpeg_turbo:B libjpeg_turbo:L libjpeg_turbo:G harfbuzz:L harfbuzz:G harfbuzz:V harfbuzz:B"
SCHEDULE[5]="libjpeg_turbo:B libjpeg_turbo:L libjpeg_turbo:G libjpeg_turbo:V harfbuzz:G harfbuzz:V harfbuzz:B harfbuzz:L"

# Code -> run_campaign.sh config token.
declare -A CODE2CFG=( [V]=c0 [B]=c1 [L]=c2 [G]=c3 )

declare -A CORPUS=(
  ["jsoncpp"]="data/jsoncpp/public.zip"
  ["libjpeg_turbo"]="case_study/data/libjpeg-turbo/public.zip"
  ["harfbuzz"]="case_study/data/harfbuzz/public.zip"
)
declare -A BINARY=(
  ["jsoncpp"]="build/jsoncpp_fuzzer"
  ["libjpeg_turbo"]="build/libjpeg_turbo_fuzzer"
  ["harfbuzz"]="build/harfbuzz_fuzzer"
)

SEQ=(${SCHEDULE[$NODE_ID]})
MACHINE=$((NODE_ID + 1))

HOST="$(hostname -s)"
SWEEP_DIR="/local/sweep_m${MACHINE}_${HOST}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SWEEP_DIR"

# Friendly log redirected to file so screen detach doesn't lose it
exec > >(tee -a "$SWEEP_DIR/sweep.log") 2>&1

echo "================================================================"
echo "  Sweep machine M$MACHINE (NODE_ID=$NODE_ID, $HOST)"
echo "  Sweep dir: $SWEEP_DIR"
echo "  Duration per cell: $DURATION   (8 cells -> 8 x $DURATION total)"
echo "  Schedule (code -> config):"
i=1
for cell in "${SEQ[@]}"; do
  t="${cell%:*}"; code="${cell#*:}"
  echo "    [pos $i]  $t  $code -> ${CODE2CFG[$code]}"
  i=$((i+1))
done
echo "================================================================"

idle_baseline() {
  local label="$1"
  echo "[*] Measuring idle baseline ($label, 60s)..."
  perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
      -o "$SWEEP_DIR/idle_baseline_${label}.txt" \
      -- sleep 60
}

# Initial idle baseline
idle_baseline start

# Manifest header
MANIFEST="$SWEEP_DIR/manifest.tsv"
echo -e "machine\tposition\tunit\tcell_dir\ttarget\tcode\tconfig\tstart\tend\tstatus" > "$MANIFEST"

# ---------------------------------------------------------------------------
# Cell runner
# ---------------------------------------------------------------------------

run_cell() {
  local position="$1" target="$2" code="$3"
  local config="${CODE2CFG[$code]}"
  local unit=$(( (position > 4) ? 2 : 1 ))

  local cell_name="cell_${target}_${config}_u${unit}_pos${position}"
  local cell_start
  cell_start=$(date -Iseconds)

  echo
  echo "============================================================="
  echo "  [M$MACHINE pos $position/8]  $target / $code ($config)  unit $unit"
  echo "  start: $cell_start"
  echo "============================================================="

  # Snapshot experiment_* dirs before run, so we can pick out the new one
  local before
  before=$(ls -d experiment_* 2>/dev/null | sort || true)

  local status="ok"
  if ! bash case_study/scripts/run_campaign.sh 1 "$DURATION" \
       "${BINARY[$target]}" "${CORPUS[$target]}" "$config" false \
       > "$SWEEP_DIR/${cell_name}.log" 2>&1; then
    status="FAIL"
    echo "[!] $cell_name FAILED (see ${cell_name}.log)"
  fi

  # Find the new experiment_* dir and move it under the sweep dir
  local after new_exp
  after=$(ls -d experiment_* 2>/dev/null | sort)
  new_exp=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
  if [ -n "$new_exp" ]; then
    mv "$new_exp" "$SWEEP_DIR/$cell_name"
  else
    status="${status}_no_expdir"
    echo "[!] could not identify new experiment_ dir for $cell_name"
  fi

  local cell_end
  cell_end=$(date -Iseconds)
  echo -e "${MACHINE}\t${position}\t${unit}\t${cell_name}\t${target}\t${code}\t${config}\t${cell_start}\t${cell_end}\t${status}" >> "$MANIFEST"
  echo "[+] $cell_name done: $status  end: $cell_end"
}

# ---------------------------------------------------------------------------
# Run the 8 cells, with an idle drift check at the unit boundary (day 4/5).
# ---------------------------------------------------------------------------

position=1
for cell in "${SEQ[@]}"; do
  target="${cell%:*}"
  code="${cell#*:}"

  if [ "$position" -eq 5 ]; then idle_baseline mid; fi

  run_cell "$position" "$target" "$code"
  position=$((position+1))
done

# End-of-sweep idle baseline (drift check)
idle_baseline end

echo
echo "[*] Compressing sweep results..."
ARCHIVE="/local/sweep_m${MACHINE}.tar.gz"
tar czf "$ARCHIVE" -C /local "$(basename "$SWEEP_DIR")"
SIZE=$(du -h "$ARCHIVE" | cut -f1)

touch /local/SWEEP_FINISHED

echo
echo "================================================================"
echo "  SWEEP FINISHED (machine M$MACHINE)"
echo "================================================================"
echo "  Archive:        $ARCHIVE  ($SIZE)"
echo "  Marker (flag):  /local/SWEEP_FINISHED"
echo "  Manifest:       $MANIFEST"

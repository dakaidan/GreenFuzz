#!/usr/bin/env bash
#
# Per-node Latin-Square sweep runner for GreenFuzz energy evaluation.
#
# Design: each node runs 6 cells (3 targets × 2 configs), in an order that
# varies between nodes. This counteracts time-of-day thermal drift -- e.g.
# vanilla doesn't ALWAYS run first; it sometimes runs in the middle of the
# campaign, sometimes at the end, while greenfuzz takes the other slot.
#
# Usage on a CloudLab node (run from /local/GreenFuzz):
#   NODE_ID=0 bash per_node_sweep.sh   # on node0
#   NODE_ID=1 bash per_node_sweep.sh   # on node1
#   NODE_ID=2 bash per_node_sweep.sh   # on node2
#
# DURATION env var defaults to 24h per cell.
# Total wall-clock per node: 6 × 24h = 6 days.
#
# Output layout:
#   /local/sweep_node<N>_<datetime>/
#     idle_baseline_start.txt
#     idle_baseline_mid.txt          (after cell 3)
#     idle_baseline_end.txt
#     manifest.tsv
#     cell_<target>_<config>_pos<N>/   <- the per-cell artifact tree
#     cell_<...>.log                    <- per-cell stdout/stderr
#   /local/SWEEP_FINISHED                <- empty marker file (see below)
#   /local/sweep_node<N>.tar.gz          <- final compressed archive

set -euo pipefail

NODE_ID="${NODE_ID:?must set NODE_ID env var (0, 1, or 2)}"
DURATION="${DURATION:-24h}"

case "$NODE_ID" in
  0|1|2) ;;
  *) echo "ERROR: NODE_ID must be 0, 1, or 2 (got: $NODE_ID)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Balanced cell ordering across the 3 nodes.
#
# Verified balance properties:
#   - Each (target, config) cell appears once per node (6 cells × 3 nodes = 18)
#   - At every time-position (1..6) across nodes, all 3 targets are represented
#   - At every time-position, V/G split is 2:1 or 1:2 (never 3:0)
#   - Per-target V vs G mean position delta = 0.33 (nearly perfectly balanced)
#
# This counteracts any time-of-day or thermal drift bias that could otherwise
# make vanilla or greenfuzz look better just because it ran in cooler/hotter
# conditions.
#
# Layout (V = vanilla, G = greenfuzz):
#   pos:   1       2       3       4       5       6
#   node0: json-V  json-G  ljpeg-V ljpeg-G hb-V    hb-G
#   node1: ljpeg-G ljpeg-V hb-G    hb-V    json-G  json-V
#   node2: hb-V    hb-G    json-V  json-G  ljpeg-V ljpeg-G
# ---------------------------------------------------------------------------

# Format: "target:config"
declare -A SEQUENCE
SEQUENCE[0]="jsoncpp:vanilla jsoncpp:greenfuzz libjpeg_turbo:vanilla libjpeg_turbo:greenfuzz harfbuzz:vanilla harfbuzz:greenfuzz"
SEQUENCE[1]="libjpeg_turbo:greenfuzz libjpeg_turbo:vanilla harfbuzz:greenfuzz harfbuzz:vanilla jsoncpp:greenfuzz jsoncpp:vanilla"
SEQUENCE[2]="harfbuzz:vanilla harfbuzz:greenfuzz jsoncpp:vanilla jsoncpp:greenfuzz libjpeg_turbo:vanilla libjpeg_turbo:greenfuzz"

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

HOST="$(hostname -s)"
SWEEP_DIR="/local/sweep_node${NODE_ID}_${HOST}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SWEEP_DIR"

# Friendly log redirected to file so screen detach doesn't lose it
exec > >(tee -a "$SWEEP_DIR/sweep.log") 2>&1

echo "================================================================"
echo "  Latin-square sweep, node $NODE_ID ($HOST)"
echo "  Sweep dir: $SWEEP_DIR"
echo "  Duration per cell: $DURATION"
echo "  Cell order:"
i=1
for cell in ${SEQUENCE[$NODE_ID]}; do
  echo "    [pos $i] $cell"
  i=$((i+1))
done
echo "================================================================"

# ---------------------------------------------------------------------------
# Initial idle baseline (60s)
# ---------------------------------------------------------------------------
echo "[*] Measuring idle baseline at start (60s)..."
perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
    -o "$SWEEP_DIR/idle_baseline_start.txt" \
    -- sleep 60

# Manifest header
MANIFEST="$SWEEP_DIR/manifest.tsv"
echo -e "position\tcell_dir\ttarget\tconfig\tstart\tend\tstatus" > "$MANIFEST"

# ---------------------------------------------------------------------------
# Cell runner
# ---------------------------------------------------------------------------

run_cell() {
  local position="$1" target="$2" config="$3"
  local local_fuzz
  case "$config" in
    vanilla)   local_fuzz="false" ;;
    greenfuzz) local_fuzz="true"  ;;
    *) echo "Bad config: $config" >&2; return 1 ;;
  esac

  local cell_name="cell_${target}_${config}_pos${position}"
  local cell_start
  cell_start=$(date -Iseconds)

  echo
  echo "============================================================="
  echo "  [pos $position/6]  $target / $config"
  echo "  start: $cell_start"
  echo "============================================================="

  # Snapshot experiment_* dirs before run, so we can pick out the new one
  local before
  before=$(ls -d experiment_* 2>/dev/null | sort || true)

  local status="ok"
  if ! bash case_study/scripts/run_campaign.sh 1 "$DURATION" \
       "${BINARY[$target]}" "${CORPUS[$target]}" "$local_fuzz" false \
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
  echo -e "${position}\t${cell_name}\t${target}\t${config}\t${cell_start}\t${cell_end}\t${status}" >> "$MANIFEST"
  echo "[+] $cell_name done: $status  end: $cell_end"
}

# ---------------------------------------------------------------------------
# Run the 6 cells for this node, in the assigned latin-square order
# ---------------------------------------------------------------------------

position=1
for cell in ${SEQUENCE[$NODE_ID]}; do
  target="${cell%:*}"
  config="${cell#*:}"

  # Mid-sweep idle baseline (after 3 cells = ~halfway through)
  if [ "$position" -eq 4 ]; then
    echo "[*] Measuring idle baseline at midpoint (60s)..."
    perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
        -o "$SWEEP_DIR/idle_baseline_mid.txt" \
        -- sleep 60
  fi

  run_cell "$position" "$target" "$config"
  position=$((position+1))
done

# ---------------------------------------------------------------------------
# End-of-sweep idle baseline (drift check)
# ---------------------------------------------------------------------------
echo
echo "[*] Measuring idle baseline at end (60s)..."
perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
    -o "$SWEEP_DIR/idle_baseline_end.txt" \
    -- sleep 60

# ---------------------------------------------------------------------------
# COMPRESSION + FLAG (the "flag file" feature)
#
# After the whole sweep finishes:
#   1. tar.gz the entire sweep_<node>_<datetime>/ directory into a single
#      portable archive (much easier to scp than a deep tree).
#   2. Drop a TINY marker file at a well-known path: /local/SWEEP_FINISHED
#
# The marker file is the "flag". From your laptop, you can run a tiny
# poller loop that checks for this flag every hour. When it appears,
# the laptop knows the sweep is done and starts downloading the tar.gz
# without needing to remember to check manually.
#
# The flag is a SIGNAL, not data. It just says "I'm done."
# ---------------------------------------------------------------------------

echo
echo "[*] Compressing sweep results..."
ARCHIVE="/local/sweep_node${NODE_ID}.tar.gz"
tar czf "$ARCHIVE" -C /local "$(basename "$SWEEP_DIR")"
SIZE=$(du -h "$ARCHIVE" | cut -f1)

# Drop the marker FLAG file — small empty file at a predictable path.
# Polling from your laptop becomes a 1-liner:
#   ssh node 'test -f /local/SWEEP_FINISHED && echo DONE'
touch /local/SWEEP_FINISHED

echo
echo "================================================================"
echo "  SWEEP FINISHED"
echo "================================================================"
echo "  Archive:        $ARCHIVE  ($SIZE)"
echo "  Marker (flag):  /local/SWEEP_FINISHED"
echo "  Manifest:       $MANIFEST"
echo
echo "  From your laptop, poll the flag and pull the archive:"
echo "    while ! ssh user@<this-node-ip> 'test -f /local/SWEEP_FINISHED'; do"
echo "      echo 'not yet, sleeping 1h'; sleep 3600;"
echo "    done"
echo "    scp user@<this-node-ip>:$ARCHIVE ./"
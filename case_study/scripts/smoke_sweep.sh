#!/usr/bin/env bash

set -uo pipefail   # intentionally NOT -e: run every cell, then report

NODE_ID="${NODE_ID:?must set NODE_ID env var (0, 1, or 2)}"
DURATION="${DURATION:-30s}"
BASELINE_SECS="${BASELINE_SECS:-5}"
OUT_BASE="${OUT_BASE:-$(pwd)}"

case "$NODE_ID" in
  0|1|2) ;;
  *) echo "ERROR: NODE_ID must be 0, 1, or 2 (got: $NODE_ID)" >&2; exit 2 ;;
esac

# Be tolerant during a smoke test (don't abort on a piped core_pattern or a
# reverted CPU governor -- we just want to confirm the pipeline runs).
export AFL_SKIP_CPUFREQ=1
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_NO_UI=1

# --- node-specific latin-square order (same balance as run_sweep.sh) --------
#   node0: json-V  json-G  ljpeg-V ljpeg-G hb-V    hb-G
#   node1: ljpeg-G ljpeg-V hb-G    hb-V    json-G  json-V
#   node2: hb-V    hb-G    json-V  json-G  ljpeg-V ljpeg-G
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

# --- must run from repo root -------------------------------------------------
if [ ! -f case_study/scripts/run_campaign.sh ] || [ ! -d build ]; then
  echo "ERROR: run this from the GreenFuzz repo root" >&2
  echo "       (build/ and case_study/scripts/run_campaign.sh must be visible)." >&2
  exit 2
fi

HOST="$(hostname -s)"
SWEEP_DIR="${OUT_BASE}/smoke_sweep_node${NODE_ID}_${HOST}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SWEEP_DIR"
exec > >(tee -a "$SWEEP_DIR/sweep.log") 2>&1

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

echo "================================================================"
echo "  GreenFuzz smoke sweep, node $NODE_ID ($HOST)"
echo "  Output dir:    $SWEEP_DIR"
echo "  Duration/cell: $DURATION   Baseline: ${BASELINE_SECS}s"
echo "  Cell order:"
i=1
for cell in ${SEQUENCE[$NODE_ID]}; do
  echo "    [pos $i] $cell"
  i=$((i+1))
done
echo "================================================================"

# --- Phase 1: environment & build artifacts ---------------------------------
echo
echo "[1] Environment & build artifacts"
command -v afl-clang-fast >/dev/null && ok "afl-clang-fast: $(command -v afl-clang-fast)" || bad "afl-clang-fast not on PATH"
[ -x AFLPlusPlus/afl-fuzz ] && ok "GreenAFL afl-fuzz present" || bad "AFLPlusPlus/afl-fuzz missing or not executable"
[ -f build/energy_afl.so ] && ok "preload build/energy_afl.so present" || bad "build/energy_afl.so missing"
command -v perf >/dev/null && ok "perf: $(command -v perf)" || bad "perf not installed"

gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
[ "$gov" = performance ] && ok "CPU governor = performance" || warn "CPU governor = $gov (expected performance; energy noisier)"

par="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
if [ "$par" != unknown ] && [ "$par" -le 0 ] 2>/dev/null; then
  ok "perf_event_paranoid = $par"
else
  warn "perf_event_paranoid = $par (want <= 0 for system-wide perf -a)"
fi

for cell in ${SEQUENCE[$NODE_ID]}; do
  t="${cell%:*}"
  [ -x "${BINARY[$t]}" ] || bad "missing target binary ${BINARY[$t]}"
  [ -f "${CORPUS[$t]}" ] || bad "missing corpus ${CORPUS[$t]}"
done

# --- Phase 2: RAPL energy probe + start baseline ----------------------------
echo
echo "[2] RAPL energy counter probe + start baseline (${BASELINE_SECS}s)"
perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
    -o "$SWEEP_DIR/idle_baseline_start.txt" -- sleep "$BASELINE_SECS" 2>/dev/null || true
pkg_probe="$(awk '/Joules/ && /energy-pkg/ {gsub(",","",$2); s+=$2} END{printf "%.2f", s+0}' "$SWEEP_DIR/idle_baseline_start.txt" 2>/dev/null)"
if grep -qi "not supported\|not counted" "$SWEEP_DIR/idle_baseline_start.txt" 2>/dev/null; then
  bad "RAPL counters not supported here (typical in VMs). Energy data invalid -> use bare-metal (RawPC)."
elif [ -n "${pkg_probe:-}" ] && awk "BEGIN{exit !($pkg_probe > 0)}" 2>/dev/null; then
  ok "RAPL energy-pkg reports ${pkg_probe} J over ${BASELINE_SECS}s idle"
else
  bad "RAPL energy-pkg read as zero/empty (check read perms on intel-rapl:*/energy_uj)"
fi

# --- Phase 3: run the 6 cells in this node's order --------------------------
echo
echo "[3] Cells (${DURATION} each, node $NODE_ID order)"
MANIFEST="$SWEEP_DIR/manifest.tsv"
printf 'position\tcell_dir\ttarget\tconfig\tstatus\texecs\tedges\tpkg_J\tstart\tend\n' > "$MANIFEST"

run_cell() {
  local position="$1" target="$2" config="$3" local_fuzz="false"
  [ "$config" = greenfuzz ] && local_fuzz="true"
  local cell_name="cell_${target}_${config}_pos${position}"
  local cell_start cell_end before after new_exp rc
  cell_start=$(date -Iseconds)

  echo
  echo "  [pos $position/6] $target / $config  ($cell_start)"

  before=$(ls -d experiment_* 2>/dev/null | sort || true)
  bash case_study/scripts/run_campaign.sh 1 "$DURATION" \
       "${BINARY[$target]}" "${CORPUS[$target]}" "$local_fuzz" false \
       > "$SWEEP_DIR/${cell_name}.log" 2>&1
  rc=$?
  after=$(ls -d experiment_* 2>/dev/null | sort)
  new_exp=$(comm -13 <(echo "$before") <(echo "$after") | head -1)

  local status="ok" execs=0 edges=0 pkg_J=0 stats pf
  [ "$rc" -ne 0 ] && status="campaign_rc$rc"

  if [ -n "$new_exp" ]; then
    mv "$new_exp" "$SWEEP_DIR/$cell_name"
    stats="$SWEEP_DIR/$cell_name/rep-1/out/default/fuzzer_stats"
    if [ -f "$stats" ]; then
      execs="$(awk -F: '/execs_done/{gsub(/ /,"",$2);print $2}' "$stats")"
      edges="$(awk -F: '/edges_found/{gsub(/ /,"",$2);print $2}' "$stats")"
    else
      [ "$status" = ok ] && status="no_fuzzer_stats"
    fi
    pf="$SWEEP_DIR/$cell_name/rep-1/perf_stat.txt"
    [ -f "$pf" ] && pkg_J="$(awk '/Joules/ && /energy-pkg/ {gsub(",","",$2); s+=$2} END{printf "%.1f", s+0}' "$pf")"
  else
    [ "$status" = ok ] && status="no_experiment_dir"
  fi

  : "${execs:=0}" "${edges:=0}" "${pkg_J:=0}"
  cell_end=$(date -Iseconds)
  if [ "$status" = ok ] && [ "$execs" -gt 0 ] 2>/dev/null; then
    ok "$target/$config: execs=$execs edges=$edges pkg=${pkg_J}J"
  else
    bad "$target/$config: status=$status execs=$execs (see ${cell_name}.log)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$position" "$cell_name" "$target" "$config" "$status" \
    "$execs" "$edges" "$pkg_J" "$cell_start" "$cell_end" >> "$MANIFEST"
}

position=1
for cell in ${SEQUENCE[$NODE_ID]}; do
  run_cell "$position" "${cell%:*}" "${cell#*:}"
  position=$((position+1))
done

# --- end baseline + verdict --------------------------------------------------
echo
echo "[*] End idle baseline (${BASELINE_SECS}s, drift check)..."
perf stat -a -I 1000 -e power/energy-pkg/,power/energy-ram/ \
    -o "$SWEEP_DIR/idle_baseline_end.txt" -- sleep "$BASELINE_SECS" 2>/dev/null || true

echo
echo "================================================================"
echo "  RESULT (node $NODE_ID): $PASS passed, $WARN warnings, $FAIL failed"
echo "  Output dir: $SWEEP_DIR"
echo "  Manifest:   $MANIFEST"
echo "================================================================"
column -t -s "$(printf '\t')" "$MANIFEST" 2>/dev/null || cat "$MANIFEST"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[+] Node $NODE_ID looks healthy — ready for the full run_sweep.sh."
  exit 0
else
  echo "[!] Node $NODE_ID has FAILURES — not ready for the full sweep (see above)."
  exit 1
fi

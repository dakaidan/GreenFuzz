#!/usr/bin/env bash
#
# Fast smoke version of run_sweep.sh: same one-machine 8-cell schedule and
# same manifest schema, but short DURATION + health checks, so you can
# validate the whole chain (build -> cmin -> 4 configs -> perf -> manifest)
# in a few minutes before committing the real 8-day sweep.
#
# Usage (from repo root):
#   NODE_ID=0 bash case_study/scripts/smoke_sweep.sh              # M1's 8 cells
#   NODE_ID=0 MAX_CELLS=4 DURATION=20s bash .../smoke_sweep.sh    # just unit 1
# The output dir is analyze_sweep.py-compatible:
#   python3 case_study/scripts/analyze_sweep.py <smoke_sweep_dir>

set -uo pipefail   # intentionally NOT -e: run every cell, then report

NODE_ID="${NODE_ID:-0}"
DURATION="${DURATION:-30s}"
BASELINE_SECS="${BASELINE_SECS:-5}"
MAX_CELLS="${MAX_CELLS:-8}"
OUT_BASE="${OUT_BASE:-$(pwd)}"

case "$NODE_ID" in
  0|1|2|3|4|5) ;;
  *) echo "ERROR: NODE_ID must be 0..5 (got: $NODE_ID)" >&2; exit 2 ;;
esac

# Be tolerant during a smoke test (don't abort on a piped core_pattern or a
# reverted CPU governor -- we just want to confirm the pipeline runs).
export AFL_SKIP_CPUFREQ=1
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_NO_UI=1

# --- same schedule as run_sweep.sh (codes V/B/L/G -> c0/c1/c2/c3) ------------
declare -A SCHEDULE
SCHEDULE[0]="jsoncpp:V jsoncpp:B jsoncpp:L jsoncpp:G libjpeg_turbo:L libjpeg_turbo:G libjpeg_turbo:V libjpeg_turbo:B"
SCHEDULE[1]="jsoncpp:B jsoncpp:L jsoncpp:G jsoncpp:V libjpeg_turbo:G libjpeg_turbo:V libjpeg_turbo:B libjpeg_turbo:L"
SCHEDULE[2]="jsoncpp:L jsoncpp:G jsoncpp:V jsoncpp:B harfbuzz:V harfbuzz:B harfbuzz:L harfbuzz:G"
SCHEDULE[3]="jsoncpp:G jsoncpp:V jsoncpp:B jsoncpp:L harfbuzz:B harfbuzz:L harfbuzz:G harfbuzz:V"
SCHEDULE[4]="libjpeg_turbo:V libjpeg_turbo:B libjpeg_turbo:L libjpeg_turbo:G harfbuzz:L harfbuzz:G harfbuzz:V harfbuzz:B"
SCHEDULE[5]="libjpeg_turbo:B libjpeg_turbo:L libjpeg_turbo:G libjpeg_turbo:V harfbuzz:G harfbuzz:V harfbuzz:B harfbuzz:L"
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

# Truncate this machine's schedule to MAX_CELLS for a fast run.
ALL=(${SCHEDULE[$NODE_ID]})
SEQ=("${ALL[@]:0:$MAX_CELLS}")
MACHINE=$((NODE_ID + 1))

# --- must run from repo root -------------------------------------------------
if [ ! -f case_study/scripts/run_campaign.sh ] || [ ! -d build ]; then
  echo "ERROR: run this from the GreenFuzz repo root" >&2
  echo "       (build/ and case_study/scripts/run_campaign.sh must be visible)." >&2
  exit 2
fi

HOST="$(hostname -s)"
SWEEP_DIR="${OUT_BASE}/smoke_sweep_m${MACHINE}_${HOST}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SWEEP_DIR"
exec > >(tee -a "$SWEEP_DIR/sweep.log") 2>&1

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

echo "================================================================"
echo "  GreenFuzz smoke sweep, machine M$MACHINE (NODE_ID=$NODE_ID, $HOST)"
echo "  Output dir:    $SWEEP_DIR"
echo "  Duration/cell: $DURATION   Baseline: ${BASELINE_SECS}s   Cells: ${#SEQ[@]}/8"
echo "  Schedule:"
i=1
for cell in "${SEQ[@]}"; do
  t="${cell%:*}"; code="${cell#*:}"
  echo "    [pos $i] $t  $code -> ${CODE2CFG[$code]}"
  i=$((i+1))
done
echo "================================================================"

# --- Phase 1: environment & build artifacts ---------------------------------
echo
echo "[1] Environment & build artifacts"
command -v afl-clang-fast >/dev/null && ok "afl-clang-fast: $(command -v afl-clang-fast)" || warn "afl-clang-fast not on PATH (only needed to (re)build targets)"
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

for cell in "${SEQ[@]}"; do
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

# --- Phase 3: run the cells (analyze_sweep.py-compatible manifest) -----------
echo
echo "[3] Cells (${DURATION} each, M$MACHINE order)"
MANIFEST="$SWEEP_DIR/manifest.tsv"
printf 'machine\tposition\tunit\tcell_dir\ttarget\tcode\tconfig\tstart\tend\tstatus\texecs\tedges\tpkg_J\n' > "$MANIFEST"

run_cell() {
  local position="$1" target="$2" code="$3"
  local config="${CODE2CFG[$code]}"
  local unit=$(( (position > 4) ? 2 : 1 ))
  local cell_name="cell_${target}_${config}_u${unit}_pos${position}"
  local cell_start cell_end before after new_exp rc
  cell_start=$(date -Iseconds)

  echo
  echo "  [M$MACHINE pos $position/${#SEQ[@]}] $target / $code ($config) unit $unit  ($cell_start)"

  before=$(ls -d experiment_* 2>/dev/null | sort || true)
  bash case_study/scripts/run_campaign.sh 1 "$DURATION" \
       "${BINARY[$target]}" "${CORPUS[$target]}" "$config" false \
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$MACHINE" "$position" "$unit" "$cell_name" "$target" "$code" "$config" \
    "$cell_start" "$cell_end" "$status" "$execs" "$edges" "$pkg_J" >> "$MANIFEST"
}

position=1
for cell in "${SEQ[@]}"; do
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
echo "  RESULT (M$MACHINE): $PASS passed, $WARN warnings, $FAIL failed"
echo "  Output dir: $SWEEP_DIR"
echo "  Manifest:   $MANIFEST"
echo "================================================================"
column -t -s "$(printf '\t')" "$MANIFEST" 2>/dev/null || cat "$MANIFEST"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[+] M$MACHINE looks healthy -- ready for the full run_sweep.sh."
  echo "    Analyze: python3 case_study/scripts/analyze_sweep.py $SWEEP_DIR"
  exit 0
else
  echo "[!] M$MACHINE has FAILURES -- not ready for the full sweep (see above)."
  exit 1
fi

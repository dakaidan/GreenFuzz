#!/usr/bin/env bash
#
# Node smoke test for the GreenFuzz energy sweep.
#
# Verifies that a freshly-provisioned node can run the sweep end-to-end:
#   1. toolchain + build artifacts present
#   2. perf + RAPL energy counters actually report non-zero Joules
#   3. a short fuzz of each target (vanilla + greenfuzz) executes and
#      produces fuzzer_stats and energy numbers
#
# Unlike run_sweep.sh (6 cells x 24h, output under /local) this finishes in
# minutes and writes EVERYTHING UNDER THE CURRENT DIRECTORY.
#
# Run from the GreenFuzz repo root:
#   bash case_study/scripts/smoke_test.sh
#
# Optional env overrides (e.g. a 20s single-target probe):
#   DURATION=20s TARGETS=jsoncpp CONFIGS=greenfuzz bash case_study/scripts/smoke_test.sh
#
set -uo pipefail   # intentionally NOT -e: run every check, then report

DURATION="${DURATION:-30s}"
TARGETS="${TARGETS:-jsoncpp libjpeg_turbo harfbuzz}"
CONFIGS="${CONFIGS:-c1 c2 c3}"

# Be tolerant during a smoke test (don't abort on a piped core_pattern, a
# reverted CPU governor, etc. -- we just want to confirm things run).
export AFL_SKIP_CPUFREQ=1
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
export AFL_NO_UI=1

declare -A CORPUS=(
  [jsoncpp]="data/jsoncpp/public.zip"
  [libjpeg_turbo]="case_study/data/libjpeg-turbo/public.zip"
  [harfbuzz]="case_study/data/harfbuzz/public.zip"
)
declare -A BINARY=(
  [jsoncpp]="build/jsoncpp_fuzzer"
  [libjpeg_turbo]="build/libjpeg_turbo_fuzzer"
  [harfbuzz]="build/harfbuzz_fuzzer"
)

# --- must run from repo root -------------------------------------------------
if [ ! -f case_study/scripts/run_campaign.sh ] || [ ! -d build ]; then
  echo "ERROR: run this from the GreenFuzz repo root" >&2
  echo "       (build/ and case_study/scripts/run_campaign.sh must be visible)." >&2
  exit 2
fi

HOST="$(hostname -s)"
OUT="$(pwd)/smoke_test_${HOST}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/report.txt") 2>&1

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

echo "================================================================"
echo "  GreenFuzz node smoke test  ($HOST)"
echo "  Output dir:    $OUT"
echo "  Duration/cell: $DURATION"
echo "  Targets:       $TARGETS"
echo "  Configs:       $CONFIGS"
echo "================================================================"

# --- Phase 1: environment & build artifacts ---------------------------------
echo
echo "[1] Environment & build artifacts"
command -v afl-clang-fast >/dev/null && ok "afl-clang-fast: $(command -v afl-clang-fast)" || bad "afl-clang-fast not on PATH"
[ -x AFLPlusPlus/afl-fuzz ] && ok "GreenAFL afl-fuzz present" || bad "AFLPlusPlus/afl-fuzz missing or not executable"
[ -f build/energy_afl.so ] && ok "preload build/energy_afl.so present" || bad "build/energy_afl.so missing"
command -v perf >/dev/null && ok "perf: $(command -v perf)" || bad "perf not installed"

gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
[ "$gov" = performance ] && ok "CPU governor = performance" || warn "CPU governor = $gov (expected performance; energy numbers will be noisier)"

par="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)"
if [ "$par" != unknown ] && [ "$par" -le 0 ] 2>/dev/null; then
  ok "perf_event_paranoid = $par"
else
  warn "perf_event_paranoid = $par (want <= 0 for system-wide perf -a)"
fi

for t in $TARGETS; do
  [ -x "${BINARY[$t]}" ] && ok "target binary ${BINARY[$t]}" || bad "missing target binary ${BINARY[$t]}"
  [ -f "${CORPUS[$t]}" ] && ok "corpus ${CORPUS[$t]}" || bad "missing corpus ${CORPUS[$t]}"
done

# --- Phase 2: RAPL energy probe (the crux for energy experiments) -----------
# On VMs RAPL is usually unavailable -> energy data would be meaningless.
echo
echo "[2] RAPL energy counter probe (perf, 2s)"
perf stat -a -e power/energy-pkg/,power/energy-ram/ -o "$OUT/rapl_probe.txt" -- sleep 2 2>/dev/null || true
pkg_probe="$(awk '/Joules/ && /energy-pkg/ {gsub(",","",$1); print $1+0; exit}' "$OUT/rapl_probe.txt" 2>/dev/null)"
if grep -qi "not supported\|not counted" "$OUT/rapl_probe.txt" 2>/dev/null; then
  bad "RAPL counters not supported here (typical in VMs). Energy data invalid -> use bare-metal (RawPC)."
elif [ -n "${pkg_probe:-}" ] && awk "BEGIN{exit !($pkg_probe > 0)}" 2>/dev/null; then
  ok "RAPL energy-pkg reports ${pkg_probe} J over 2s"
else
  bad "RAPL energy-pkg read as zero/empty (check read perms on intel-rapl:*/energy_uj)"
fi

# --- Phase 3: short fuzz per target x config --------------------------------
echo
echo "[3] Short fuzz runs ($DURATION each)"
SUMMARY="$OUT/cells.tsv"
printf 'target\tconfig\tstatus\texecs\tedges\tpkg_J\n' > "$SUMMARY"

run_one() {
  local t="$1" c="$2"
  local cell="cell_${t}_${c}"
  echo "  - $t / $c ..."

  local before after newexp rc
  before="$(ls -d experiment_* 2>/dev/null | sort || true)"
  bash case_study/scripts/run_campaign.sh 1 "$DURATION" \
       "${BINARY[$t]}" "${CORPUS[$t]}" "$c" false \
       > "$OUT/${cell}.log" 2>&1
  rc=$?
  after="$(ls -d experiment_* 2>/dev/null | sort)"
  newexp="$(comm -13 <(echo "$before") <(echo "$after") | head -1)"

  local status="ok" execs=0 edges=0 pkg_J=0 stats pf
  [ "$rc" -ne 0 ] && status="campaign_rc$rc"

  if [ -n "$newexp" ]; then
    mv "$newexp" "$OUT/$cell"
    stats="$OUT/$cell/rep-1/out/default/fuzzer_stats"
    if [ -f "$stats" ]; then
      execs="$(awk -F: '/execs_done/{gsub(/ /,"",$2);print $2}' "$stats")"
      edges="$(awk -F: '/edges_found/{gsub(/ /,"",$2);print $2}' "$stats")"
    else
      [ "$status" = ok ] && status="no_fuzzer_stats"
    fi
    pf="$OUT/$cell/rep-1/perf_stat.txt"
    [ -f "$pf" ] && pkg_J="$(awk '/Joules/ && /energy-pkg/ {gsub(",","",$2); s+=$2} END{printf "%.1f", s+0}' "$pf")"
  else
    [ "$status" = ok ] && status="no_experiment_dir"
  fi

  : "${execs:=0}" "${edges:=0}" "${pkg_J:=0}"
  if [ "$status" = ok ] && [ "$execs" -gt 0 ] 2>/dev/null; then
    ok "$t/$c: execs=$execs edges=$edges pkg=${pkg_J}J"
  else
    bad "$t/$c: status=$status execs=$execs edges=$edges (see ${cell}.log)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$c" "$status" "$execs" "$edges" "$pkg_J" >> "$SUMMARY"
}

for t in $TARGETS; do
  for c in $CONFIGS; do
    run_one "$t" "$c"
  done
done

# --- Summary -----------------------------------------------------------------
echo
echo "================================================================"
echo "  RESULT: $PASS passed, $WARN warnings, $FAIL failed"
echo "  Report:   $OUT/report.txt"
echo "  Per-cell: $OUT/cells.tsv"
echo "================================================================"
column -t -s "$(printf '\t')" "$SUMMARY" 2>/dev/null || cat "$SUMMARY"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[+] Node looks healthy — ready for the full sweep."
  exit 0
else
  echo "[!] Node has FAILURES — not ready for the full sweep (see report above)."
  exit 1
fi

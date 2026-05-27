#!/usr/bin/env bash

# Case-study environment setup for GreenFuzz
# Workflow:
#   1. Installs all system dependencies (build tools, LLVM, etc.)
#   2. Installs UPSTREAM AFL++ system-wide (provides /usr/local/bin/afl-clang-fast
#      used to instrument target binaries)
#   3. Installs CPPJoules + latest cmake + perf
#   4. System tuning (governor, RAPL perms, perf_event_paranoid)
#   5. If not already inside a GreenFuzz checkout, clones it
#   6. Builds GreenAFL-modified 


set -e

START_DIR="$(pwd)"
NPROC="$(nproc 2>/dev/null || echo 2)"


echo "[*] Installing AFL++ dependencies..."
sudo apt-get update
sudo apt-get install -y build-essential python3-dev automake cmake git flex bison libglib2.0-dev libpixman-1-dev python3-setuptools cargo libgtk-3-dev
sudo apt-get install -y lld-14 llvm-14 llvm-14-dev clang-14 || sudo apt-get install -y lld llvm llvm-dev clang
sudo apt-get install -y gcc-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-plugin-dev libstdc++-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-dev
sudo apt-get install -y ninja-build # for QEMU mode
sudo apt-get install -y cpio libcapstone-dev # for Nyx mode
sudo apt-get install -y wget curl # for Frida mode
sudo apt-get install -y python3-pip # for Unicorn mode

echo "[*] Installing case-study target-specific dependencies..."
sudo apt-get install -y nasm
sudo apt-get install -y libarchive-dev

echo "[*] Installing base AFL++"
sudo mkdir -p /tmp/afl
sudo chown "$USER":"$USER" /tmp/afl
git clone https://github.com/AFLplusplus/AFLplusplus
cd AFLplusplus
make distrib
sudo make install

# Verify install succeeded
if ! command -v afl-clang-fast >/dev/null 2>&1; then
  echo "ERROR: afl-clang-fast not on PATH after install." >&2
  echo "       Check /tmp/AFLplusplus build log; usually means clang-14/llvm-14-dev missing." >&2
  exit 1
fi
echo "[+][+][+] System AFL++ compiler: $(which afl-clang-fast)"

echo "[*] Setting CPU governor to 'performance'..."
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -e "$f" ] && echo performance | sudo tee "$f" >/dev/null
done

echo "[*] Loosening RAPL sysfs read permissions..."
sudo chmod a+r /sys/class/powercap/intel-rapl:*/energy_uj /sys/class/powercap/intel-rapl:*:*/energy_uj 2>/dev/null || true

echo "[*] Setting perf event paranoid to '-1'..."
echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo "[*] Installing perf..."
sudo apt-get install linux-tools-common linux-tools-generic linux-tools-`uname -r`

echo "[*] Installing CPPJoules..."
cd "$START_DIR"
curl -sSL https://raw.githubusercontent.com/rishalab/CPPJoules/main/installer.sh | bash
source ~/.bashrc || true
sudo ldconfig

echo "[*] Installing latest CMake (from kitware repo)..."
sudo apt-get install -y apt-transport-https ca-certificates gnupg
wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo apt-key add -
sudo apt-add-repository -y "deb https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main" || true
sudo apt-get update
sudo apt-get install -y cmake
cmake --version

# ============================================================================
#    Locate / clone GreenFuzz
#    If we're already inside a GreenFuzz checkout (AFLPlusPlus/ subdir
#    exists), use it. Otherwise clone next to $START_DIR.
# ============================================================================
cd "$START_DIR"
echo "[*] Cloning GreenFuzz (development branch)..."
git clone https://github.com/dakaidan/GreenFuzz.git "$START_DIR/GreenFuzz"
GREENFUZZ_ROOT="$START_DIR/GreenFuzz"


cd "$GREENFUZZ_ROOT"
git fetch origin development 2>/dev/null || true
git checkout development 2>/dev/null || true
git pull --ff-only origin development 2>/dev/null || true

echo ""
echo "================================================================"
echo "  Building GreenFuzz"
echo "  Project root: $GREENFUZZ_ROOT"
echo "  Parallel jobs: $NPROC"
echo "================================================================"

echo "[*] (1/3) Building preload libraries..."
make -j"$NPROC" preload_all

echo "[*] (2/3) Building local GreenAFL-modified AFL++..."
make -j"$NPROC" local_afl

if [ ! -x "$GREENFUZZ_ROOT/AFLPlusPlus/afl-fuzz" ]; then
  echo "ERROR: GreenAFL afl-fuzz was not built." >&2
  exit 1
fi
echo "[+] GreenAFL runtime fuzzer: $GREENFUZZ_ROOT/AFLPlusPlus/afl-fuzz"

echo "[*] (3/3) Building target fuzzers..."
echo "    libpng, zlib, jsoncpp, libjpeg-turbo, harfbuzz"
make -j"$NPROC" targets

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "================================================================"
echo "  Build complete."
echo "================================================================"
echo ""
echo "AFL++ checkouts (Solution 1 — two side-by-side AFL++ trees):"
echo "  Instrumentation (vanilla): $(which afl-clang-fast)"
echo "  Runtime fuzzer (GreenAFL): $GREENFUZZ_ROOT/AFLPlusPlus/afl-fuzz"
echo ""
echo "Preload libs:"
ls -1 "$GREENFUZZ_ROOT/build/"*.so 2>/dev/null | sed 's/^/  /'
echo ""
echo "Target fuzzers:"
find "$GREENFUZZ_ROOT/build/" -maxdepth 1 -type f -executable -not -name "*.so" 2>/dev/null | sed 's/^/  /'
echo ""
echo "Next steps:"
echo "  cd $GREENFUZZ_ROOT"
echo ""
echo "  # Prepare new seed corpora (only if data/<target>/public.zip missing):"
echo "  make seeds"
echo ""
echo "  # Run 3-rep 12h campaigns:"
echo "  bash scripts/run_campaign.sh 3 12h build/jsoncpp_fuzzer       data/jsoncpp/public.zip       true false"
echo "  bash scripts/run_campaign.sh 3 12h build/libjpeg_turbo_fuzzer data/libjpeg-turbo/public.zip true false"
echo "  bash scripts/run_campaign.sh 3 12h build/harfbuzz_fuzzer      data/harfbuzz/public.zip      true false"
echo ""
echo "Notes:"
echo "  - perf_event_paranoid change is system-wide (no reboot needed)."
echo "  - CPU governor reverts on reboot; rerun setup or re-apply manually."
echo "  - For cleanest energy measurements, stop background services before"
echo "    each campaign (display manager, snapd, browsers, etc.)."
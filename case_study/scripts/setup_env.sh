#!/usr/bin/env bash

set -e

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

APT="sudo -E apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

START_DIR="$(pwd)"
NPROC="$(nproc 2>/dev/null || echo 2)"


echo "[*] Installing AFL++ dependencies..."
$APT update
$APT install -y build-essential python3-dev automake cmake git flex bison libglib2.0-dev libpixman-1-dev python3-setuptools cargo libgtk-3-dev
$APT install -y lld-14 llvm-14 llvm-14-dev clang-14 || $APT install -y lld llvm llvm-dev clang
$APT install -y gcc-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-plugin-dev libstdc++-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-dev
$APT install -y ninja-build # for QEMU mode
$APT install -y cpio libcapstone-dev # for Nyx mode
$APT install -y wget curl # for Frida mode
$APT install -y python3-pip # for Unicorn mode

echo "[*] Installing case-study target-specific dependencies..."
$APT install -y nasm
$APT install -y libarchive-dev

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
$APT install -y linux-tools-common linux-tools-generic linux-tools-`uname -r`

echo "[*] Installing CPPJoules..."
cd "$START_DIR"
curl -sSL https://raw.githubusercontent.com/rishalab/CPPJoules/main/installer.sh | bash
source ~/.bashrc || true
sudo ldconfig

echo "[*] Installing latest CMake (from kitware repo)..."
$APT install -y apt-transport-https ca-certificates gnupg
wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo apt-key add -
sudo apt-add-repository -y "deb https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main" || true
$APT update
$APT install -y cmake
cmake --version

echo "[*] Clone GreenFuzz..."
cd "$START_DIR"
echo "[*] Cloning GreenFuzz (case-study branch)..."
git clone https://github.com/dakaidan/GreenFuzz.git "$START_DIR/GreenFuzz"
GREENFUZZ_ROOT="$START_DIR/GreenFuzz"


cd "$GREENFUZZ_ROOT"
git fetch origin feat/case-study 2>/dev/null || true
git checkout feat/case-study 2>/dev/null || true
git pull --ff-only origin feat/case-study 2>/dev/null || true

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
echo "    jsoncpp, libjpeg-turbo, harfbuzz"
make -j"$NPROC" targets_memory_bound

echo ""
echo "Next steps:"
echo "  cd $GREENFUZZ_ROOT"
echo ""
echo "  # Prepare new seed corpora (only if data/<target>/public.zip missing):"
echo "  make seeds"
echo ""
echo "  # Run 3-rep 12h campaigns:"
echo "  bash scripts/run_campaign.sh 3 24h build/jsoncpp_fuzzer       data/jsoncpp/public.zip       true false"
echo "  bash scripts/run_campaign.sh 3 24h build/libjpeg_turbo_fuzzer data/libjpeg-turbo/public.zip true false"
echo "  bash scripts/run_campaign.sh 3 24h build/harfbuzz_fuzzer      data/harfbuzz/public.zip      true false"
echo ""

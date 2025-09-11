#!/usr/bin/env bash

echo "[*] Installing AFL++ dependencies..."
sudo apt-get update
sudo apt-get install -y build-essential python3-dev automake cmake git flex bison libglib2.0-dev libpixman-1-dev python3-setuptools cargo libgtk-3-dev
# try to install llvm 14 and install the distro default if that fails
sudo apt-get install -y lld-14 llvm-14 llvm-14-dev clang-14 || sudo apt-get install -y lld llvm llvm-dev clang
sudo apt-get install -y gcc-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-plugin-dev libstdc++-$(gcc --version|head -n1|sed 's/\..*//'|sed 's/.* //')-dev
sudo apt-get install -y ninja-build # for QEMU mode
sudo apt-get install -y cpio libcapstone-dev # for Nyx mode
sudo apt-get install -y wget curl # for Frida mode
sudo apt-get install -y python3-pip # for Unicorn mode

echo "[*] Installing base AFL++"
sudo mkdir -p /tmp/afl
sudo chown "$USER":"$USER" /tmp/afl
git clone https://github.com/AFLplusplus/AFLplusplus
cd AFLplusplus
make distrib
sudo make install

echo "[*] Setting governor to 'performance'..."
cd /sys/devices/system/cpu
echo performance | sudo tee cpu*/cpufreq/scaling_governor

echo "[*] Installing JoulesCPP..."
curl https://raw.githubusercontent.com/rishalab/CPPJoules/main/installer.sh | bash
source ~/.bashrc

echo "[*] Installing perf..."
sudo apt-get install linux-tools-common linux-tools-generic linux-tools-`uname -r`

echo "[*] Setting perf event paranoid to '-1'..."
echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo "[*] Installing latest CMake..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates gnupg wget
wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo apt-key add -
sudo apt-add-repository "deb https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main"
sudo apt-get update
sudo apt-get install -y cmake
cmake --version

echo "[*] Installing utilities..."
sudo apt-get install screen
sudo apt-get install libtool

echo "Done"
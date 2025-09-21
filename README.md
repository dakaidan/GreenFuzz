# GreenAFL

**GreenAFL** is a modified version of AFLPlusPlus that integrates energy measurement into program execution. It allows users to measure energy consumption of target programs, either directly or during fuzzing with AFL.

---

## Table of Contents

1. Project Structure
2. Dependencies
3. Build Instructions
4. Using the Preload Library
5. Testing
6. AFLPlusPlus Integration
7. Cleaning the Build
8. Notes on Modifications

---

## Project Structure
```bash
.
├── AFLPlusPlus              # Local AFLPlusPlus clone/build
├── data
├── Makefile
├── README.md
├── scripts
└── src
    ├── oss-fuzz
    ├── preload
    │   └── energy_preload.cpp   # Preload library to measure energy
    └── tests
        └── hello.cpp            # Example test program
```

- `AFLPlusPlus/`: Directory for the AFL++ fuzzer. This project includes a customized AFLPlusPlus build.
- `src/preload/`: Contains energy_preload.cpp, the preload library measuring energy usage.
- `src/tests/`: Example test programs that can be compiled and run with the preload library.
- `build/`: Build artifacts will be generated here, including the compiled preload library and test binaries.

---


## Prerequisites

In order to fuzz with AFL++ you must set the power governor to `performance`:
```bash
cd /sys/devices/system/cpu
echo performance | sudo tee cpu*/cpufreq/scaling_governor
```

## Dependencies

- `GCC`/`G++` newer than 11.0
- `Make`
- `CPPJoules` (linked in the preload library)
- `perf` (for performance monitoring)
- `CMake` (for building jsoncpp)

To install `CPPJoules` follow instructions [here](https://rishalab.github.io/CPPJoules/), or use the following commands on Ubuntu:

```bash
curl https://raw.githubusercontent.com/rishalab/CPPJoules/main/installer.sh | bash
source ~/.bashrc
```

To install `perf` on Ubuntu:

```bash
sudo apt-get install linux-tools-common linux-tools-generic linux-tools-`uname -r`
```

And in order to use perf without root you must set the following kernel parameter:
```bash
echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
````

You need `CMake` (>=3.24) which can be installed via Kitware's APT repository:
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates gnupg wget
wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo apt-key add -
sudo apt-add-repository "deb https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main"
sudo apt-get update
sudo apt-get install -y cmake
cmake --version
```

---

## Build Instructions

GreenAFL uses a Makefile to build both the preload library and test binaries. Please make sure CPPJoules is installed before build.

### Build Everything

```bash
make
```

This will:

1. Build the energy measurement preload library (`build/energy.so`).
2. Clone and build a AFLPlusPlus instance in `AFLplusplus/`
3. Build a local AFLPlusPlus instance in `AFLPlusPlus/`.

### Build Preload Library Only

```bash
make preload
```

### Build Preload Library with AFL Integration

```bash
make preload_afl
```

Adds `-DAFL_ENERGY_MAPPING` to the build, enabling energy tracking in AFL fuzzing runs.

### Build Preload Library with Forced Print

```bash
make preload_print
```

Adds `-DAFL_FORCE_PRINT` to the build, enabling output of energy measurements, even when within AFL (required for cmin)

### Combined: AFL + Print

```bash 
make preload_print_afl
```

Enables both AFL energy tracking and forced printing.

---

## Using the Preload Library

The preload library can be used in two modes:

### Direct Execution

```bash
LD_PRELOAD=/path/to/build/energy.so ./build/tests/hello
```

This runs the program with energy measurement.

### AFL Fuzzing

```bash
AFL_PRELOAD=/path/to/build/energy.so afl-prog ...
```

This injects the energy measurement library into programs being fuzzed.

---

## Testing

Test file hello.cpp in src/tests/ will be build with `make hello`

Example:

```bash
./build/tests/hello
```   

- `.cpp` and `.c` test sources are supported.
- Build artifacts are placed in build/tests/.

---

## AFLPlusPlus Integration

GreenAFL comes with a local copy of AFLPlusPlus, which is built automatically:

```bash
make afl
```

This builds AFL in the `AFLPlusPlus/llvm_mode` and `AFLPlusPlus/qemu_mode` directories depending on the chosen build options.

---

## Cleaning the Build

Remove all compiled artifacts:

```bash
make clean
```

- Deletes the `build/` directory entirely.
- Does not affect AFLPlusPlus or source files.

---

## Notes on Modifications

GreenAFL modifies AFLPlusPlus to integrate with the energy measurement preload library. Key features:

- Seed Minimisation with energy tracking.
  - Edits to `AFLPlusPlus/afl-cmin.py` to support energy measurement during minimisation.
  - Requires `-DAFL_FORCE_PRINT` to ensure energy data is output during minimisation.
- Fuzzing with energy tracking.
  - Edits to `AFLPlusPlus/include/afl-fuzz.h` to add maps for child process to write to, and to store energy data in each fuzzing iteration.
  - Edits to `AFLPlusPlus/src/afl-fuzz-init.c` to initialise the new maps, and set the env variable for the preload library.
  - Edits to `AFLPlusPlus/src/afl-fuzz-run.c` to read energy data from the maps after each execution, and store it in the fuzzing queue entry.
  - Edits to `AFLPlusPlus/src/afl-fuzz-queue.c` to modify the heuristics of a fuzzing entry to include energy data.
  - Requires `-DAFL_ENERGY_MAPPING` to enable energy tracking during fuzzing.

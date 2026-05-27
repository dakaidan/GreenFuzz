CXX      ?= g++
CC       ?= gcc
CXXFLAGS ?= -Wall -O2 -fPIC
CFLAGS   ?= -Wall -O2
LDFLAGS  ?= -shared
CPPJOULES_LIB ?= -lCPP_Joules

SRC_DIR := src
PRELOAD_DIR := $(SRC_DIR)/preload
TESTS_DIR := $(SRC_DIR)/tests
BUILD_DIR := build
BUILD_TESTS_DIR := $(BUILD_DIR)/tests
AFL_DIR := AFLPlusPlus

PRELOAD_SRC := $(PRELOAD_DIR)/energy_preload.cpp
PRELOAD_BASE := $(BUILD_DIR)/energy.so
PRELOAD_AFL := $(BUILD_DIR)/energy_afl.so
PRELOAD_PRINT := $(BUILD_DIR)/energy_print.so
PRELOAD_PRINT_AFL := $(BUILD_DIR)/energy_print_afl.so

NPROC := $(shell nproc 2>/dev/null || echo 1)

# =============================================================================
# TOP-LEVEL TARGETS
# =============================================================================

.PHONY: all
all: setup_environment preload_all local_afl targets

.PHONY: build_all
build_all: preload_all local_afl targets

.PHONY: preload_all
preload_all: preload preload_afl preload_print preload_print_afl

.PHONY: targets
targets: libpng zlib jsoncpp libjpeg-turbo harfbuzz

# Memory-bound case-study targets only (libjpeg-turbo + harfbuzz)
.PHONY: targets_memory_bound
targets_memory_bound: jsoncpp libjpeg-turbo harfbuzz

# Prepare seed corpora for new targets (zips into data/<target>/public.zip)
.PHONY: seeds
seeds: seeds_libjpeg-turbo seeds_harfbuzz

# =============================================================================
# DIRECTORY RULES
# =============================================================================

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_TESTS_DIR):
	mkdir -p $(BUILD_TESTS_DIR)

# =============================================================================
# PRELOAD LIBRARIES
# =============================================================================

preload: $(PRELOAD_BASE)
$(PRELOAD_BASE): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

preload_afl: $(PRELOAD_AFL)
$(PRELOAD_AFL): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_ENERGY_MAPPING $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

preload_print: $(PRELOAD_PRINT)
$(PRELOAD_PRINT): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_FORCE_PRINT $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

preload_print_afl: $(PRELOAD_PRINT_AFL)
$(PRELOAD_PRINT_AFL): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_FORCE_PRINT -DAFL_ENERGY_MAPPING $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

# =============================================================================
# TEST PROGRAMS
# =============================================================================

.PHONY: hello
hello: $(BUILD_TESTS_DIR)/hello
$(BUILD_TESTS_DIR)/hello: $(TESTS_DIR)/hello.cpp | $(BUILD_TESTS_DIR)
	$(CXX) $(CXXFLAGS) $(CFLAGS) -o $@ $^

# =============================================================================
# GreenAFL-modified AFL++ (in-tree, used as RUNTIME fuzzer)
# =============================================================================

.PHONY: local_afl afl
local_afl:
	@cd $(AFL_DIR) && make -j$(NPROC) all

afl: local_afl

# =============================================================================
# FUZZ TARGET BUILDS
#
# Each rule delegates to its dedicated build script.
# The build scripts use `command -v afl-clang-fast` -- this finds the
# SYSTEM-installed vanilla AFL++ at /usr/local/bin/afl-clang-fast that was
# put there by case_study/scripts/setup_env.sh (Solution 1).
#
# If `make jsoncpp` fails with "No AFL compiler found":
#   -> setup_env.sh was not run, OR `sudo make install` of upstream AFL++
#      failed during setup. Re-run setup_env.sh.
# =============================================================================

.PHONY: libpng zlib jsoncpp libjpeg-turbo harfbuzz

# Sanity check: vanilla afl-clang-fast must be on PATH (Solution 1).
# Order-only prereq so it's checked once, not on every target.
.PHONY: check_afl
check_afl:
	@command -v afl-clang-fast >/dev/null 2>&1 || { \
	  echo "ERROR: afl-clang-fast not found on PATH."; \
	  echo "       Run case_study/scripts/setup_env.sh first."; \
	  echo "       It installs upstream AFL++ system-wide via 'sudo make install'."; \
	  exit 1; \
	}

libpng: | check_afl
	./scripts/build_libpng.sh

zlib: | check_afl
	./scripts/build_zlib.sh

jsoncpp: | check_afl
	./scripts/build_jsoncpp.sh

libjpeg-turbo: | check_afl
	./case_study/scripts/build_libjpeg-turbo.sh

harfbuzz: | check_afl
	./case_study/scripts/build_harfbuzz.sh

# =============================================================================
# SEED CORPUS PREPARATION
# Pull from public GitHub sources; no GCP / gsutil / auth required.
# =============================================================================

.PHONY: seeds_libjpeg-turbo seeds_harfbuzz

seeds_libjpeg-turbo:
	./case_study/scripts/prepare_seeds_libjpeg-turbo.sh

seeds_harfbuzz:
	./case_study/scripts/prepare_seeds_harfbuzz.sh

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================

setup_environment:
	./case_study/scripts/setup_env.sh

# =============================================================================
# CLEAN
# =============================================================================

.PHONY: clean clean_targets clean_all

# Remove preload libs + target binaries (keeps AFL++ build)
clean:
	rm -rf $(BUILD_DIR)

# Remove only the temporary per-target build directories under build/,
# preserving the final fuzzer binaries.
clean_targets:
	rm -rf $(BUILD_DIR)/tmp_*_build

# Full clean including AFL++ artifacts
clean_all: clean
	@cd $(AFL_DIR) && make clean || true
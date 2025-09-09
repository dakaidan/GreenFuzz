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

.PHONY: all
all: setup_environment preload preload_afl preload_print preload_print_afl local_afl libpng zlib jsoncpp

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_TESTS_DIR):
	mkdir -p $(BUILD_TESTS_DIR)

preload: $(PRELOAD_BASE)
$(PRELOAD_BASE): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

# AFL preload
preload_afl: $(PRELOAD_AFL)
$(PRELOAD_AFL): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_ENERGY_MAPPING $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

# Print preload
preload_print: $(PRELOAD_PRINT)
$(PRELOAD_PRINT): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_FORCE_PRINT $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

# Print + AFL preload
preload_print_afl: $(PRELOAD_PRINT_AFL)
$(PRELOAD_PRINT_AFL): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -DAFL_FORCE_PRINT -DAFL_ENERGY_MAPPING $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

.PHONY: hello
hello: $(BUILD_TESTS_DIR)/hello
$(BUILD_TESTS_DIR)/hello: $(TESTS_DIR)/hello.cpp | $(BUILD_TESTS_DIR)
	$(CXX) $(CXXFLAGS) $(CFLAGS) -o $@ $^

.PHONY: local_afl afl
local_afl:
	@cd $(AFL_DIR) && make distrib

afl: local_afl

libpng:
	./scripts/build_libpng.sh

zlib:
	./scripts/build_zlib.sh

jsoncpp:
	./scripts/build_jsoncpp.sh

setup_environment:
	./scripts/setup_environment.sh

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

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
PRELOAD_LIB := $(BUILD_DIR)/energy.so

.PHONY: all
all: $(PRELOAD_LIB) hello local_afl

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_TESTS_DIR):
	mkdir -p $(BUILD_TESTS_DIR)

$(PRELOAD_LIB): $(PRELOAD_SRC) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^ $(CPPJOULES_LIB)

preload: $(PRELOAD_LIB)

preload_afl: CXXFLAGS += -DAFL_ENERGY_MAPPING
preload_afl: $(PRELOAD_LIB)

preload_print: CXXFLAGS += -DAFL_FORCE_PRINT
preload_print: $(PRELOAD_LIB)

preload_print_afl: CXXFLAGS += -DAFL_FORCE_PRINT -DAFL_ENERGY_MAPPING
preload_print_afl: $(PRELOAD_LIB)

.PHONY: hello
hello: $(BUILD_TESTS_DIR)/hello
$(BUILD_TESTS_DIR)/hello: $(TESTS_DIR)/hello.cpp | $(BUILD_TESTS_DIR)
	$(CXX) $(CXXFLAGS) $(CFLAGS) -o $@ $^

.PHONY: local_afl afl
local_afl:
	@cd $(AFL_DIR) && make distrib

afl: local_afl

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

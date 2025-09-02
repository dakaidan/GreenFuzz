CXX      ?= g++
CXXFLAGS ?= -Wall -O2 -fPIC
LDFLAGS  ?= -shared

CPPJOULES_INC ?=           
CPPJOULES_LIB ?= -lCPP_Joules  

PROGRAMS := hello          
PRELOAD_LIB := energy.so
PRELOAD_SRC := preload.cpp

all: $(PROGRAMS) $(PRELOAD_LIB)

$(PROGRAMS):
	$(CXX) $(CXXFLAGS) -o $@ src/$@.cpp

$(PRELOAD_LIB):
	$(CXX) $(CXXFLAGS) $(CPPJOULES_INC) $(LDFLAGS) -o $@ src/$(PRELOAD_SRC) $(CPPJOULES_LIB)

preload: $(PRELOAD_LIB)

clean:
	rm -f $(PROGRAMS) $(PRELOAD_LIB)


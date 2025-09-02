CXX      ?= g++
CXXFLAGS ?= -Wall -O2 -fPIC
LDFLAGS  ?= -shared

CPPJOULES_INC ?=           
CPPJOULES_LIB ?= -lCPP_Joules  

PROGRAMS := hello          
PRELOAD_LIB := energy.so
PRELOAD_SRC := energy_preload.cpp

all: $(PRELOAD_LIB)

$(PRELOAD_LIB):
	g++ -Wall -O2 -fPIC  -shared -o energy.so energy_preload.cpp -lCPP_Joules

preload: $(PRELOAD_LIB)

clean:
	rm -f $(PRELOAD_LIB)


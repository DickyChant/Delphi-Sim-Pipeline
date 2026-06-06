CXX = g++
CXXFLAGS = -std=c++11 -O2 -fPIC

# Try to find PYTHIA 8 installation
ifeq ($(shell command -v pythia8-config 2>/dev/null),)
    # No pythia8-config, try common locations
    PYTHIA8_DIR = /usr/local/pythia8
    ifeq ($(wildcard $(PYTHIA8_DIR)/include/Pythia8/Pythia.h),)
        PYTHIA8_DIR = /opt/pythia8
    endif
    ifeq ($(wildcard $(PYTHIA8_DIR)/include/Pythia8/Pythia.h),)
        PYTHIA8_DIR = /usr/include
    endif
    
    INCLUDES = -I$(PYTHIA8_DIR)/include
    LIBS = -L$(PYTHIA8_DIR)/lib -lpythia8 -ldl
else
    # Use pythia8-config
    INCLUDES = $(shell pythia8-config --cflags)
    LIBS = $(shell pythia8-config --ldflags) -lpythia8
endif

# Optional: modern heavy-flavour decays via EvtGen (`make EVTGEN=1`).
# EvtGen + the Pythia8<->EvtGen header ship in the same LCG view as Pythia8,
# so headers come from `pythia8-config --cflags` (the view include dir) and the
# libs are in the view's lib64, derived from pythia8-config's own location
# (no hard-coded view path). EvtGen needs >= c++17, so bump the standard.
EVTGEN ?= 0
ifeq ($(EVTGEN),1)
    CXXFLAGS := $(filter-out -std=c++11,$(CXXFLAGS)) -std=c++17 -DUSE_EVTGEN
    # pythia8-config --cflags also injects -std=c++11; drop it so c++17 wins.
    INCLUDES := $(filter-out -std=c++11,$(INCLUDES))
    EVTGEN_LIBDIR := $(abspath $(dir $(shell command -v pythia8-config))/../lib64)
    LIBS += -L$(EVTGEN_LIBDIR) -lEvtGen -lEvtGenExternal
endif

# Target
pythia8_generate: pythia8_generate.cpp
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ $< $(LIBS)

clean:
	rm -f pythia8_generate fort.26 *.fadgen

.PHONY: clean

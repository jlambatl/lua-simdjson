OBJ = src/luasimdjson.o src/simdjson.o
CPPFLAGS = -I$(LUA_INCDIR)
CXX_STD ?= -std=c++11
CXXFLAGS = $(CXX_STD) -Wall -fvisibility=hidden $(CFLAGS)
LDFLAGS = $(LIBFLAG)
LDLIBS = -lpthread

ifdef LUA_LIBDIR
LDLIBS += $(LUA_LIBDIR)/$(LUALIB)
endif

ifeq ($(OS),Windows_NT)
	LIBEXT = dll
else
	UNAME := $(shell uname -s)
	ifeq ($(findstring MINGW,$(UNAME)),MINGW)
		LIBEXT = dll
	else ifeq ($(findstring CYGWIN,$(UNAME)),CYGWIN)
		LIBEXT = dll
	else
		LIBEXT = so
	endif
endif

TARGET = simdjson.$(LIBEXT)

all: $(TARGET)

DEP_FILES = $(OBJ:.o=.d)
-include $(DEP_FILES)

%.o: %.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(TARGET): $(OBJ)
	$(CXX) $(LDFLAGS) $^ -o $@ $(LDLIBS)

clean:
	rm -f *.$(LIBEXT) src/*.{o,d}

install: $(TARGET)
	cp $(TARGET) $(INST_LIBDIR)

# Test targets for different C++ standards
test-cpp11:
	@echo "=== Testing with C++11 (default)==="
	luarocks remove simdjson
	$(MAKE) clean
	luarocks make
	busted --verbose

test-cpp17:
	@echo "=== Testing with C++17 ==="
	luarocks remove simdjson
	$(MAKE) clean
	luarocks make CXX_STD="-std=c++17"
	busted --verbose

test-cpp20:
	@echo "=== Testing with C++20 ==="
	luarocks remove simdjson
	$(MAKE) clean
	luarocks make CXX_STD="-std=c++20"
	busted --verbose

test-cpp23:
	@echo "=== Testing with C++23 ==="
	luarocks remove simdjson
	$(MAKE) clean
	luarocks make CXX_STD="-std=c++23"
	busted --verbose

test-all-standards: test-cpp11 test-cpp17 test-cpp20 test-cpp23
	@echo "=== All C++ standards tested successfully ==="

.PHONY: clean install test-cpp11 test-cpp17 test-cpp20 test-cpp23 test-all-standards
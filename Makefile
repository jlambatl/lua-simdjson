OBJ = src/luasimdjson.o src/simdjson.o
CPPFLAGS += -I$(LUA_INCDIR)
CPPVERSION = "-std=c++11"
CXXFLAGS = $(CPPVERSION) -Wall -fvisibility=hidden $(CFLAGS)
LDFLAGS = $(LIBFLAG)
LDLIBS = -lpthread

# Only link Lua library if explicitly needed (not typical for macOS)
ifdef LUA_LIBDIR
  ifdef LUALIB
    # Make sure LUALIB is a filename, not empty or directory
    ifneq ($(LUALIB),)
      LDLIBS += $(LUA_LIBDIR)/$(LUALIB)
    endif
  endif
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
	$(MAKE) clean
	luarocks make
	busted --verbose

test-cpp17:
	@echo "=== Testing with C++17 ==="
	$(MAKE) clean
	luarocks make CPPVERSION="-std=c++17"
	busted --verbose

test-cpp20:
	@echo "=== Testing with C++20 ==="
	$(MAKE) clean
	luarocks make CPPVERSION="-std=c++20"
	busted --verbose

test-cpp23:
	@echo "=== Testing with C++23 ==="
	$(MAKE) clean
	luarocks make CPPVERSION="-std=c++23"
	busted --verbose

test-all-standards: test-cpp11 test-cpp17 test-cpp20 test-cpp23
	@echo "=== All C++ standards tested successfully ==="

.PHONY: clean install test-cpp11 test-cpp17 test-cpp20 test-all-standards
OBJ = src/luasimdjson.o src/simdjson.o
CPPFLAGS += -I$(LUA_INCDIR)
CXXFLAGS = -std=c++11 -Wall -fvisibility=hidden $(CFLAGS)
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
    else ifeq ($(UNAME),Darwin)
        LIBEXT = so
        # macOS specific flags for Lua modules
        LDFLAGS += -bundle -undefined dynamic_lookup
    else
        LIBEXT = so
        # Linux/Unix specific flags for shared libraries
        LDFLAGS += -shared -fPIC
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
	@echo "=== Testing with C++11 ==="
	$(MAKE) clean
	$(MAKE) CXXFLAGS="-std=c++11 -Wall -fvisibility=hidden $(CFLAGS) -I$(LUA_INCDIR)"
	busted --verbose

test-cpp17:
	@echo "=== Testing with C++17 ==="
	$(MAKE) clean
	$(MAKE) CXXFLAGS="-std=c++17 -Wall -fvisibility=hidden $(CFLAGS) -I$(LUA_INCDIR)"
	busted --verbose

test-cpp20:
	@echo "=== Testing with C++20 ==="
	$(MAKE) clean
	$(MAKE) CXXFLAGS="-std=c++20 -Wall -fvisibility=hidden $(CFLAGS) -I$(LUA_INCDIR)"
	busted --verbose

test-cpp23:
	@echo "=== Testing with C++23 ==="
	$(MAKE) clean
	$(MAKE) CXXFLAGS="-std=c++23 -Wall -fvisibility=hidden $(CFLAGS) -I$(LUA_INCDIR)"
	busted --verbose

test-all-standards: test-cpp11 test-cpp17 test-cpp20 test-cpp23
	@echo "=== All C++ standards tested successfully ==="

.PHONY: clean install test-cpp11 test-cpp17 test-cpp20 test-all-standards
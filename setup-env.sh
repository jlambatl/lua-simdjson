#!/bin/bash

# Environment setup for lua-simdjson development
# Source this file: source setup-env.sh

export LUA_INCDIR="/opt/homebrew/Cellar/lua/5.4.8/include/lua5.4"
export LUA_LIBDIR="/opt/homebrew/Cellar/lua/5.4.8/lib"
export LDFLAGS="-L/opt/homebrew/Cellar/lua/5.4.8/lib"
export LDLIBS="-llua5.4 -lpthread"
export CFLAGS="-I/opt/homebrew/Cellar/lua/5.4.8/include/lua5.4"
export LUA_CPATH="./?.so"

# Add homebrew to PATH if not already there
if [[ ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

echo "Environment variables set:"
echo "  LUA_INCDIR=$LUA_INCDIR"
echo "  LUA_LIBDIR=$LUA_LIBDIR"
echo "  LDFLAGS=$LDFLAGS"
echo "  LDLIBS=$LDLIBS"
echo "  CFLAGS=$CFLAGS"
echo "  LUA_CPATH=$LUA_CPATH"
echo ""
echo "To build: make"
echo "To test:  busted --verbose --cpath=?.so"
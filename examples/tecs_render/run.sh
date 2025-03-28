#!/bin/bash
# Run the tecs_render demo
# This script should be run from the tecs project root

# Compile the Teal source to build directory
mkdir -p examples/tecs_render/build
tl gen -I src -I build examples/tecs_render/src/main.tl -o examples/tecs_render/build/main.lua

cp examples/tecs_render/conf.lua examples/tecs_render/build/

# Set up Lua path to find Tecs modules and run Love2D from build directory
cd examples/tecs_render/build && LUA_PATH="../../../build/?.lua;../../../build/?/init.lua;;" love .
#!/bin/bash
# Run the gamepad demo example
# This script should be run from the tecs project root

# Compile the Teal source to build directory
tl gen -I src -I build examples/tecs_controller/src/main.tl -o examples/tecs_controller/build/main.lua

cp examples/tecs_controller/conf.lua examples/tecs_controller/build/

# Set up Lua path to find Tecs modules and run Love2D from build directory
cd examples/tecs_controller/build && LUA_PATH="../../../build/?.lua;../../../build/?/init.lua;;" love .
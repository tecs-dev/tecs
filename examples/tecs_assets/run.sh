#!/usr/bin/env bash
# Run the tecs_assets loading screen example
# This script should be run from the tecs project root

# Compile the Teal source files to build directory
tl gen -I src -I build examples/tecs_assets/src/main.tl -o examples/tecs_assets/build/main.lua
tl gen -I src -I build examples/tecs_assets/src/game_state.tl -o examples/tecs_assets/build/game_state.lua
tl gen -I src -I build examples/tecs_assets/src/loading.tl -o examples/tecs_assets/build/loading.lua
tl gen -I src -I build examples/tecs_assets/src/gameplay.tl -o examples/tecs_assets/build/gameplay.lua

cp examples/tecs_assets/conf.lua examples/tecs_assets/build/

# Create symbolic link to assets for Love2D filesystem access
ln -sf ../../../build/tecs_assets examples/tecs_assets/build/assets

# Set up Lua path to find Tecs modules and run Love2D from build directory
cd examples/tecs_assets/build && LUA_PATH="../../../build/?.lua;../../../build/?/init.lua;;" love .
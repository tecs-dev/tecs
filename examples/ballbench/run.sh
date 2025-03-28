#!/bin/bash
# Run the ball benchmark example
# This script should be run from the tecs project root
#
# Usage: ./examples/ballbench/run.sh [max_entities] [draw_sprites]
#   max_entities: Maximum number of entities (default: 50000)
#   draw_sprites: Whether to draw sprites (true/false, default: true)

MAX_ENTITIES=${1:-50000}
DRAW_SPRITES=${2:-true}

echo "Running bench: $MAX_ENTITIES entities, draw_sprites=$DRAW_SPRITES"

# Compile the Teal source to build directory
tl gen -I src -I build examples/ballbench/src/main.tl -o examples/ballbench/build/main.lua

cp examples/ballbench/conf.lua examples/ballbench/build/

# Set up Lua path to find Tecs modules and run Love2D from build directory
cd examples/ballbench/build && LUA_PATH="../../../build/?.lua;../../../build/?/init.lua;;" love . $MAX_ENTITIES $DRAW_SPRITES
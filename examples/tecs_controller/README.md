# Tecs2D Tecs_Controller Example

This example demonstrates the Tecs_Controller gamepad support with Teal, Tecs2D, and Love2D.

## Features

- Gamepad detection and auto-assignment
- Real-time button state visualization
- Support for buttons, axes, and d-pad/hat controls
- Shows gamepad diagnostic information
- Clean visual interface with dark theme

## Running the Example

### From project root:

```bash
./examples/tecs_controller/gamepad/run.sh
```

### Manual compilation and run:

```bash
# From project root
tl gen -I src -I build examples/tecs_controller/gamepad/main.tl -o examples/tecs_controller/gamepad/main.lua

# Run with Love2D
cd examples/tecs_controller/gamepad
LUA_PATH="./build/?.lua;./build/?/init.lua;;" love .
```

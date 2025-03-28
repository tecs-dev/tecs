# Install Example

This is a minimal Love2D project demonstrating how to set up Tecs with the vendor directory approach, including asset
loading and sprite rendering.

## Structure

- `main.tl` - Love2D entry point with vendor path setup and asset loading (Teal source)
- `conf.tl` - Love2D configuration (Teal source)
- `build.sh` - Automated build script that compiles Teal files and copies assets
- `assets/player.png` - Simple player sprite asset
- `build/main.lua` - Compiled Lua output from main.tl
- `build/conf.lua` - Compiled Lua output from conf.tl
- `build/assets/` - Copied assets for runtime access
- `tlconfig.lua` - Teal compiler configuration with type paths
- `types/` - Type definitions for Love2D and LuaJIT (symlinked to main repo)
- `src/vendor/` - Where Tecs modules would be installed (empty in this repo)

## Running

This example cannot run directly from this repository since the vendor directory is empty.
Use the `make test-install` target to create a working copy in `build/test-install/` with actual Tecs modules installed.

## Usage in your projects

1. Copy this example structure to your project
2. Set up type definitions (see main installation guide for commands):
   ```bash
   mkdir -p types/luajit types/string types/table
   curl -o types/love2d.d.tl https://raw.githubusercontent.com/MikuAuahDark/love2d-tl/refs/heads/master/love.d.tl
   # Download LuaJIT types (ffi.d.tl, jit.d.tl, string/buffer.d.tl, table/new.d.tl, table/clear.d.tl)
   ```
3. Install Tecs modules: `luarocks install --tree=src/vendor tecs.tl` (etc.)
4. Compile Teal source files: `cyan build`
5. Run with Love2D from the build directory: `cd build && love .`

**Important**: You must run Love2D from the `build/` directory where the compiled `.lua` files are located, not from
the project root with the `.tl` source files.
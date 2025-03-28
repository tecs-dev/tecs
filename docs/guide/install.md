# Installation Guide

This guide shows how to install Tecs and its modules for your Love2D game projects using a vendor directory approach,
which keeps dependencies as part of your project and ensures reproducible builds.

## Prerequisites

Before installing Tecs modules, you'll need:

1. LuaRocks - Lua package manager ([installation instructions](https://github.com/luarocks/luarocks/blob/main/docs/download.md)).
2. Teal compiler - Compiles .tl files to .lua
3. Cyan - Teal's build system

```bash
luarocks install tl
luarocks install cyan
```

## Vendor Directory Installation

The easiest way to make Love2D games is typically to put all your code and dependencies in your repo/source files.
So we'll install Tecs modules into a `src/vendor/` directory within your project.

### Setup

Create a vendor directory structure in your project:

```bash
mkdir -p src/vendor
cd your-game-project
```

### Install Modules

```bash
# Install core Tecs framework
luarocks install --tree=src/vendor tecs.tl

# Install Love2D integration
luarocks install --tree=src/vendor tecs2d.tl

# Install optional modules as needed
luarocks install --tree=src/vendor tecs_render.tl
luarocks install --tree=src/vendor tecs_controller.tl
luarocks install --tree=src/vendor tecs_assets.tl
```

### Configure Teal

Create a `tlconfig.lua` file in your project root to automatically include vendor modules and type definitions:

```lua
return {
    build_dir = "build",
    source_dir = "src",
    include_dir = {
        "types/",  -- For Love2D and LuaJIT type definitions
        "src/",
        "src/vendor/share/lua/5.1/",
    },
    gen_target = "5.1",
    gen_compat = "off",
    global_env_def = "love2d",
}
```

### Setup Type Definitions

For proper Teal type checking, you'll need Love2D and LuaJIT type definitions:

```bash
# Create types directory
mkdir -p types/luajit types/string types/table

# Download Love2D type definitions
curl -o types/love2d.d.tl https://raw.githubusercontent.com/MikuAuahDark/love2d-tl/refs/heads/master/love.d.tl

# Download LuaJIT types (FFI, JIT compiler, bit operations, etc.)
curl -o types/luajit/ffi.d.tl https://raw.githubusercontent.com/teal-language/teal-types/main/types/luajit/ffi.d.tl
curl -o types/luajit/jit.d.tl https://raw.githubusercontent.com/teal-language/teal-types/main/types/luajit/jit.d.tl
curl -o types/string/buffer.d.tl https://raw.githubusercontent.com/teal-language/teal-types/main/types/string/buffer.d.tl
curl -o types/table/new.d.tl https://raw.githubusercontent.com/teal-language/teal-types/main/types/table/new.d.tl
curl -o types/table/clear.d.tl https://raw.githubusercontent.com/teal-language/teal-types/main/types/table/clear.d.tl
```

### Configure Love2D

Add this to the top of your `main.lua` for runtime module loading:

```lua
-- Add vendor modules to Lua path
local function addVendorPath(path)
    package.path = path .. "/share/lua/5.1/?.lua;" ..
                   path .. "/share/lua/5.1/?/init.lua;" .. package.path
    package.cpath = path .. "/lib/lua/5.1/?.so;" .. package.cpath
end

-- Add vendor directory to search paths
addVendorPath("src/vendor")
```

### Project Structure

Your project should look like this:

```
your-game/
├── main.tl                   # Game entry point (Teal source)
├── conf.tl                   # Love2D configuration (Teal source)
├── tlconfig.lua              # Teal compiler configuration
├── build.sh                  # Automated build script (optional)
├── types/
│   ├── love2d.d.tl           # Love2D type definitions
│   ├── luajit/
│   │   ├── ffi.d.tl          # FFI library types
│   │   └── jit.d.tl          # JIT compiler types
│   ├── string/
│   │   └── buffer.d.tl       # String buffer types
│   ├── table/
│   │   ├── new.d.tl          # table.new types
│   │   └── clear.d.tl        # table.clear types
│   └── ... (other type definitions)
├── assets/                   # Game assets (images, sounds, fonts)
│   ├── images/
│   │   ├── player.png
│   │   └── background.png
│   ├── sounds/
│   │   └── jump.wav
│   └── fonts/
│       └── game.ttf
├── build/                    # Compiled output directory
│   ├── main.lua              # Compiled from main.tl
│   ├── conf.lua              # Compiled from conf.tl
│   ├── assets/               # Copied or symlinked assets
│   │   ├── images/
│   │   ├── sounds/
│   │   └── fonts/
│   └── (other compiled .lua files)
├── src/
│   ├── vendor/               # Installed Tecs modules
│   │   ├── share/lua/5.1/
│   │   │   ├── tecs/
│   │   │   ├── tecs2d/
│   │   │   ├── tecs_render/
│   │   │   └── ... (other modules)
│   │   └── lib/lua/5.1/
│   │       └── (compiled libraries if any)
│   └── (your game code in .tl files)
└── README.md
```

### Development Workflow

Since you're using Teal source files (.tl), you need to compile them to Lua before running:

#### Initial Setup

```bash
# Create project structure
mkdir -p assets build src

# Set up assets directory for game resources
mkdir -p assets/images assets/sounds assets/fonts
```

#### Building Your Project

```bash
# Compile all .tl files to build/ directory
cyan build
```

#### Asset Management

Assets need to be accessible from the build directory where Love2D runs:

```bash
# Copy assets to build directory
cp -r assets build/

# Or create a symlink
ln -sf ../assets build/assets
```

#### Running Your Game

```bash
love build
```

#### Automated Build Script

Create a build script to automate compilation and asset copying:

```bash
# Create the build script
cat > build.sh << 'EOF'
#!/bin/bash
set -e

echo "Building Teal files..."
cyan build

echo "Copying assets..."
cp -r assets build/ 2>/dev/null || true

echo "Build complete! Run with: love build"
EOF

# Make it executable
chmod +x build.sh
```

Then run with: `./build.sh`

### Usage Example

```lua
-- main.tl --

-- Configure vendor path (as shown above)
addVendorPath("src/vendor")

-- Now you can require Tecs modules
local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local render <const> = require("tecs_render")

-- Define typed components
local record Position is tecs.Component
    x: number
    y: number
end

-- Create FFI component for better performance
tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

function love.run()
    return tecs2d.run(1 / 60, function(world)
        -- Load assets (remember: running from build/ directory)
        local playerImage = love.graphics.newImage("assets/images/player.png")

        -- Spawn an entity with position
        world:spawn(Position(100, 100))

        -- Add a simple render system
        world:addSystem({
            name = "Render",
            phase = tecs.phases.Render,
            run = function()
                for archetype, length in world:query({include = {Position}})() do
                    local positions = archetype[Position]
                    for i = 1, length do
                        local pos = positions[i]
                        love.graphics.draw(playerImage, pos.x, pos.y)
                    end
                end
            end
        })
    end)
end
```

## Module Descriptions

### Core Modules

| Module | Description | Dependencies |
|--------|-------------|--------------|
| `tecs.tl` | Core ECS framework with FFI optimization | None |
| `tecs2d.tl` | Love2D integration and input handling | `tecs.tl` |

### Plugin Modules

| Module | Description | Dependencies |
|--------|-------------|--------------|
| `tecs_render.tl` | 2D rendering pipeline with lighting | `tecs.tl`, `tecs2d.tl` |
| `tecs_controller.tl` | Rebindable controller system | `tecs.tl`, `tecs2d.tl` |
| `tecs_assets.tl` | Threaded asset loading | `tecs.tl`, `tecs2d.tl` |

## Troubleshooting

### Module Not Found
- Ensure the vendor path is added before requiring modules
- Check that installation completed successfully
- Verify directory structure matches examples above

### FFI Errors
- Tecs automatically uses LuaJIT FFI for optimal performance when available, but falls back to pure Lua 5.1+
  compatibility
- For best performance, use LuaJIT (included by default in Love2D)
- If you encounter FFI-related errors on non-LuaJIT platforms, Tecs will automatically use table-based fallbacks

### Version Conflicts
- Use the vendor directory approach to isolate dependencies
- Check `luarocks list --tree=src/vendor` to see installed versions

### Build Errors
- Ensure `cyan` (Teal compiler) is available during installation
- Check that you have a C compiler available for any native dependencies
- Verify your `tlconfig.lua` paths are correct relative to your project structure

### Asset Loading Issues
- Make sure assets are copied or symlinked into the `build/` directory
- Use relative paths in your code (e.g., `love.graphics.newImage("assets/images/player.png")`)
- Check that asset files exist and have correct permissions

### Development Tips
- Use symlinks for assets during development: `ln -sf ../assets build/assets`
- Create a `.gitignore` to exclude the `build/` directory from version control
- Consider using a Makefile or build script to automate compilation and asset copying

## Updating

Run the same commands you ran to install your modules.

```bash
luarocks install --tree=src/vendor tecs.tl
# ... update other modules as needed
```

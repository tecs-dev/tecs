---
outline: deep
---

# Stats plugin

The Tecs2D `stats` module provides a debug overlay that displays real-time performance metrics and system information,
helping you monitor and optimize your game's performance. You install the plugin, and hit F1 to see the debug info.

<img src="../images/debug-overlay.png" alt="Debug overlay"/>

## Overview

The stats system shows performance data including:
- Frame rate (FPS)
- Memory usage (Lua and texture memory)
- Draw call statistics and batching efficiency
- ECS metrics (entities, components, systems, archetypes)
- Active archetype breakdown (optional)

## Getting started

Add the stats plugin to your world to enable the debug overlay:

```lua
local tecs = require("tecs")
local tecs2d = require("tecs2d")

-- In your game plugin....
function gamePlugin(world)
    -- Add the stats plugin with default settings
    world:addPlugin(tecs2d.stats.newStatsPlugin())

    -- Your game systems...
end

-- Use with tecs2d.run
function love.run(): function(): string | number
    return tecs2d.run(1 / 60, gamePlugin)
end
```

## Basic usage

Once installed, the stats overlay can be toggled between two modes:

1. **Off** (default): No overlay visible
2. **On**: Shows performance stats

Press **F1** (the default binding) to toggle between these modes.

## Configuration

Customize the stats plugin behavior with a configuration table:

```lua
local tecs2d = require("tecs2d")
local statsPlugin = tecs2d.stats.newStatsPlugin({
    -- Custom font for the overlay
    font = love.graphics.newFont(12),

    -- Key to toggle debug modes (default: "f1")
    keyBinding = "f1",

    -- Key to show/hide archetype breakdown (default: "f2")
    archetypeBinding = "f2",

    -- How often to update memory stats in seconds (default: 2)
    sampleFrequency = 2,

    -- How often to run garbage collection in seconds (default: 8)
    gcFrequency = 8
})

world:addPlugin(statsPlugin)
```

## Displayed metrics

### Performance metrics

The overlay displays the following information:

#### Frame rate
- **FPS**: Current frames per second

#### Memory usage
- **Lua Memory**: Current Lua heap memory usage in MB
- **Texture Memory**: GPU texture memory usage in MB

#### Rendering statistics
- **Draws**: Number of draw calls this frame
- **Batched**: Number of draw calls that were batched together
- **Canvas Switches**: Number of render target changes
- **Shader Switches**: Number of shader program changes

#### ECS statistics
- **E**: Total number of entities
- **C**: Total number of component instances
- **S**: Total number of systems
- **A**: Number of unique archetypes

### Archetype breakdown

Press **F2** (default) to toggle the archetype breakdown view, which shows:
- Each active archetype's component composition
- Number of entities in each archetype

This helps identify:
- Unexpected archetype fragmentation
- Component combination patterns
- Entity distribution across archetypes

## Debug states

The stats system uses Tecs's built-in Debug state with two values:

```lua
local tecs = require("tecs")

-- Check current debug state
local debugState = world:getState(tecs.builtins.Debug)

-- Programmatically set debug state
world:setState(tecs.builtins.Debug, "on")  -- Enable stats
world:setState(tecs.builtins.Debug, "off") -- Disable stats
```
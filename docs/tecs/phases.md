# Phases

Tecs divides its game loop into _phases_. Add [systems](/tecs/systems) to phases to run game logic at
specific points: when the game starts, each frame update, frame render, and shutdown.

::: tip Love2D bindings
The [Love2D integration](/tecs2d/love2d) provides these phases out of the box.
:::

## Phase groups

Tecs organizes phases into hierarchical groups:

### StartupGroup
One-time initialization phases run when `world:startup()` is called.

- `PreStartup` - Critical initialization before main startup
- `Startup` - Main startup phase
- `PostStartup` - Final setup after startup

### MainGroup
The main game loop that runs every frame when `world:update(dt)` is called.

- `First` - Very start of each frame (typically reserved for framework code)
- `PreUpdate` - Before main update
- **`FixedUpdateGroup`** - Fixed timestep loop (may run 0-N times per frame)
  - `FixedFirst` - Start of fixed update iteration (typically reserved for framework code)
  - `FixedPreUpdate` - Preparation for game logic
  - `FixedUpdate` - Main game logic and physics
  - `FixedPostUpdate` - After game logic
  - `FixedLast` - End of fixed update iteration (typically reserved for framework code)
- `Update` - Variable timestep presentation update
- `PostUpdate` - After presentation, before rendering
- **`RenderGroup`** - Rendering phases
  - `RenderFirst` - Start of rendering (typically reserved for framework code)
  - `PreRender` - Render preparation
  - `Render` - Main rendering
    - `Draw` - [Custom CPU draw calls](/tecs2d/rendering/custom-drawing) with lighting and depth sorting (runs inside Render)
  - `PostRender` - Post-processing and effects
  - `RenderLast` - End of rendering (typically reserved for framework code)
- `Last` - Very end of each frame

### ShutdownGroup
One-time cleanup phases run when `world:shutdown()` is called.

- `PreShutdown` - Preparation for shutdown
- `Shutdown` - Main shutdown phase
- `PostShutdown` - Final cleanup

## Fixed vs variable phases

- **Fixed timestep phases** (`FixedUpdate` and related): used for physics, game logic, AI, and anything affecting
  gameplay that should feel consistent regardless of speed of the computer.
- **Variable timestep phases** (`Update` and related) - used for visual presentation, animations, camera smoothing,
  UI effects, and generally anything else that looks or feels better the faster the computer.

## Using phases

Access phases through `tecs.phases`:

```lua
local tecs = require("tecs")

-- Add a system to the Update phase
world:addSystem({
    phase = tecs.phases.Update,
    run = myUpdateSystem
})

-- Add a physics system to the fixed timestep
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    run = myPhysicsSystem
})
```

## Managing phases

### Enabling and disabling phases

You can dynamically enable and disable phases to control which systems run:

```lua
-- Disable a phase (and all its systems)
world:disablePhase(tecs.phases.RenderGroup)  -- Disable all rendering

-- Re-enable a phase
world:enablePhase(tecs.phases.RenderGroup)

-- Disable fixed timestep when paused
world:disablePhase(tecs.phases.FixedUpdateGroup)
```

::: warning Disabling parent phases
Disabling a parent phase (like `RenderGroup`) also disables all its children phases.
:::

### Running specific phases

You can explicitly run a specific phase using `world:runPhase()`:

```lua
-- Run only the Render phase
world:runPhase(tecs.phases.Render)

-- Run the entire RenderGroup
world:runPhase(tecs.phases.RenderGroup)
```

::: info Disabled phases behavior
When you disable a phase:
- It won't run during the normal game loop
- You can still explicitly run it with `world:runPhase()`
- If you disable a parent phase, its child phases remain disabled even when you explicitly run the parent
:::

```lua
-- Disable all rendering
world:disablePhase(tecs.phases.RenderGroup)

-- This runs RenderGroup but NOT its children (PreRender, Render, PostRender, etc.)
world:runPhase(tecs.phases.RenderGroup)

-- To run a specific child phase when parent is disabled:
world:runPhase(tecs.phases.Render)  -- This works even though RenderGroup is disabled
```

---
description: "Game-loop phase groups and the enablePhase, disablePhase, registerPhase, and runPhase world methods for controlling system execution"
outline: deep
---

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
- **Variable timestep phases** (`Update` and related): used for visual presentation, animations, camera smoothing,
  UI effects, and generally anything else that looks or feels better the faster the computer.

Tecs2D's renderer can [interpolate supported Transforms](/tecs2d/rendering/interpolation)
written in fixed phases. Keep the authoritative gameplay write in the fixed
loop; interpolation does not require a second variable-rate presentation
system.

## Using phases

Access phases through `tecs.phases`:

```teal
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

Concrete indexed phases expose a public `position`: their numeric slot in the pipeline. It can be used for
inspection and ordering diagnostics:

```teal
print(tecs.phases.Update.name, tecs.phases.Update.position)
```

Phase groups expose their child phase tree through `children` instead. A custom leaf phase receives a position when
it is registered. Systems should still select phases by object, not by hard-coded numeric positions.

## Managing phases

These methods are available on every `World`.

| Method | Description |
| ------ | ----------- |
| [`world:enablePhase`](#world-enable-phase) | Enable a phase or phase group. |
| [`world:disablePhase`](#world-disable-phase) | Disable a phase or phase group. |
| [`world:registerPhase`](#world-register-phase) | Register a custom phase with the world's pipeline. |
| [`world:runPhase`](#world-run-phase) | Run a phase or phase group explicitly. |

### Enabling and disabling phases

You can dynamically enable and disable phases to control which systems run:

```teal
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

```teal
-- Run only the Render phase
world:runPhase(tecs.phases.Render)

-- Run the entire RenderGroup
world:runPhase(tecs.phases.RenderGroup)
```

::: info Disabled phases behavior
When you disable a phase:
- It won't run during the normal game loop
- `world:runPhase()` honors the disabled state too, so it also skips the phase
- Disabling a parent phase cascades to its children, so they are disabled as well

Re-enable a phase with `world:enablePhase()` before running it directly.
:::

```teal
-- Disable all rendering (this cascades to RenderGroup's children too)
world:disablePhase(tecs.phases.RenderGroup)

-- runPhase honors the disabled state, so this runs nothing
world:runPhase(tecs.phases.RenderGroup)

-- Re-enable a phase before running it directly
world:enablePhase(tecs.phases.Render)
world:runPhase(tecs.phases.Render)
```

### world:enablePhase {#world-enable-phase}

Enables a phase or phase group so it runs during normal pipeline execution.

```teal
function World:enablePhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase or phase group to enable.

### world:disablePhase {#world-disable-phase}

Disables a phase or phase group during normal pipeline execution. Disabling a parent phase also disables its child
phases.

```teal
function World:disablePhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase or phase group to disable.

### world:registerPhase {#world-register-phase}

Registers a custom phase with the world's pipeline. Use this when an extension or custom pipeline adds phases outside
the built-in `tecs.phases` tree.

```teal
function World:registerPhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase to register.

### world:runPhase {#world-run-phase}

Runs a phase or phase group immediately. Disabled phases are skipped whether you run them directly or via a parent
group; re-enable a phase with `world:enablePhase()` before running it.

```teal
function World:runPhase(phase: Phase, dt?: number)
```

**Parameters:**

- `phase`: Phase or phase group to run.
- `dt`: Optional delta time passed to systems in that phase. Defaults to `0`.

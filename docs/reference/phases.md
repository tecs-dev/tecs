# Phases

The main game loop of Tecs is divided into _phases_. [Systems](/reference/systems) are added to these phases to run
game logic at specific points in time like when the game starts, updating the frame, rendering the frame, and when
the game shuts down.

::: tip Love2D bindings via tecs2d
The [Tecs2D](/tecs2d/quickstart) library provides Love2D integration of these phases out of the box.
:::

## Phase groups

Phases are organized into hierarchical groups:

| Group           | Description                               |
|-----------------|-------------------------------------------|
| `StartupGroup`  | One-time initialization phases            |
| `MainGroup`     | The main game loop that runs every frame  |
| `ShutdownGroup` | One-time cleanup phases                   |

## Fixed vs variable phases

- **Fixed timestep phases** (`FixedUpdate` and related): used for physics, game logic, AI, and anything affecting
  gameplay that should feel consistent regardless of speed of the computer.
- **Variable timestep phases** (`Update` and related) - used for visual presentation, animations, camera smoothing,
  UI effects, instant input reaction (like mouse wheel movement), and generally anything else that looks or feels
  better the faster the computer.

## Using phases

Phases are accessed through `tecs.phases`:

```lua
local tecs = require("tecs")

-- Add a system to the Update phase
world:addSystem({
    phase = tecs.phases.Update,
    system = myUpdateSystem
})

-- Add a physics system to the fixed timestep
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    system = myPhysicsSystem
})
```

## StartupGroup phases

These phases are called once at startup when `world:startup()` is invoked.

### PreStartup

Called before main startup. Use for critical initialization that other systems depend on.

**Common uses:**
- Initialize logging systems
- Configure rendering backend

### Startup

Main startup phase for general initialization.

**Common uses:**
- Load game assets
- Create initial entities

### PostStartup

Called after startup for final setup.

**Common uses:**
- Show main menu
- Enable gameplay systems

## MainGroup phases

The main game loop called each time `world:update(dt)` is called.

### First

Called at the very start of each frame.

**Common uses:**
- Poll input devices
- Process window events

::: tip Framework system
This phase is typically reserved for framework/engine code. Game logic should use `PreUpdate` or `FixedPreUpdate`
for game initialization at the start of a frame.
:::

### PreUpdate

Called before the main update phase.

**Common uses:**
- Process input events
- Handle network messages

### FixedUpdateGroup

The fixed timestep loop for **game logic and simulation**. This group may run multiple times per frame to catch up with
real time, or may not run at all if the frame is too fast.

#### FixedFirst

Start of fixed update iteration.

::: tip Framework system
This phase is typically reserved for framework code. Game logic should use `FixedPreUpdate` for game setup at the start
of fixed timestep.
:::

#### FixedPreUpdate

Preparation for game logic updates.

**Common uses:**
- Input command processing
- Pre-physics setup

#### FixedUpdate

Main game logic at fixed timestep.

**Common uses:**
- Game logic and rules
- Physics simulation
- AI decisions

#### FixedPostUpdate

After game logic processing.

**Common uses:**
- Collision response
- Trigger gameplay events

#### FixedLast

End of fixed update iteration.

::: tip Framework system
This phase is typically reserved for framework code. Game logic should use `FixedPostUpdate` for game cleanup at the
end of fixed timestep.
:::

### Update

Main **presentation** update phase with variable timestep.

**Presentation uses:**
- Animation playback
- Particle effects
- Camera smoothing

::: tip
Gameplay and AI go in `FixedUpdate` for consistency. Visuals go in `Update` for smoothness.
:::

### PostUpdate

After presentation updates, prepare for rendering.

- **Transform matrix calculation**
- **Camera finalization**

### RenderGroup

Rendering phases for drawing the game.

#### RenderFirst

Start of rendering.

::: tip Framework system
This phase is typically reserved for framework code. Game logic should use `PreRender` for game-specific render
preparation.
:::

#### PreRender

Preparation for rendering. Used for things like attaching a camera.

#### Render

Main rendering phase.
- Draw game world
- Draw UI

#### PostRender

After main rendering.
- Post-processing effects
- Debug overlays
- Detaching a camera

#### RenderLast

End of rendering.

::: tip Framework system
This phase is typically reserved for framework code. Game logic should use `PostRender` for game-specific
post-processing.
:::

### Last

Phase called at the very end of the frame after updates and rendering.

::: tip Framework system
This phase is typically reserved for framework code. Game logic should use `PostUpdate` or `PostRender` for
end-of-frame game logic.
:::

## ShutdownGroup phases

These phases are called once when `world:shutdown()` is invoked.

### PreShutdown

Preparation for shutdown.

**Common uses:**
- Save game state
- Close network connections

### Shutdown

Main shutdown phase.

**Common uses:**
- Despawn all entities
- Release resources

### PostShutdown

Final cleanup phase.

**Common uses:**
- Write shutdown logs
- Final cleanup

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
When a phase is disabled:
- It won't run during the normal game loop
- You can still explicitly run it with `world:runPhase()`
- However, if a parent phase is disabled, its child phases remain disabled even when the parent is explicitly run
:::

```lua
-- Disable all rendering
world:disablePhase(tecs.phases.RenderGroup)

-- This runs RenderGroup but NOT its children (PreRender, Render, PostRender, etc.)
world:runPhase(tecs.phases.RenderGroup)

-- To run a specific child phase when parent is disabled:
world:runPhase(tecs.phases.Render)  -- This works even though RenderGroup is disabled
```

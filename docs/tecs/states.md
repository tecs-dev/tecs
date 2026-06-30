---
outline: deep
---

# State Stack

The state stack manages game states (play, pause, menus) with automatic entity lifecycle. Push a state to enter it,
pop to leave. Entities spawned during a state are automatically tagged with that state's component and cleaned up
when the state is popped.

## Creating states

Define states with `world:createState()`. Each state gets a tag component that is auto-added to entities spawned
while the state is active. The returned component can be used in queries.

```teal
local GameState = world:createState("game", {
    onBlur = "pause",    -- pause game entities when another state is pushed on top
    onFocus = "resume",  -- resume game entities when this state becomes top again
})

local PausedState = world:createState("paused")
-- Default onExit = "despawn": entities tagged with this state are despawned when popped
```

## Pushing and popping states

```teal
-- Start gameplay
world:pushState("game")
-- All entities spawned from here are auto-tagged with the gameState component

-- Pause the game
world:pushState("paused")
-- game.onBlur fires: adds Paused to all gameState entities (they freeze but keep rendering)
-- Entities spawned now are auto-tagged with pausedState

-- Unpause
world:popState()
-- paused.onExit fires: despawns all pausedState entities (pause menu cleaned up)
-- game.onFocus fires: removes Paused from gameState entities (they resume)
```

Check the current state with `peekState()`:

```teal
local current = world:peekState()  -- returns "game", "paused", etc. or nil if stack empty
```

## Lifecycle policies

Each state can define policies for lifecycle events:

| Policy      | When it fires                                              |
| ----------- | ---------------------------------------------------------- |
| `onEnter`   | When this state is first pushed                            |
| `onExit`    | When this state is popped (default: `"despawn"`)           |
| `onBlur`    | When this state is no longer top (another state pushed)    |
| `onFocus`   | When this state becomes top again (state above popped)     |

### Policy actions

Each policy can be a string action or a custom function:

| Action       | Effect                                                       |
| ------------ | ------------------------------------------------------------ |
| `"pause"`    | Adds `Paused` component to all entities with this state tag  |
| `"resume"`   | Removes `Paused` component from those entities               |
| `"despawn"`  | Despawns all entities with this state tag                    |
| `"disable"`  | Adds `Disabled` component to those entities                  |
| function     | Calls the function with the world as argument                |

```teal
world:createState("cutscene", {
    onEnter = function(world)
        -- custom enter logic
    end,
    onExit = "despawn",
})
```

If no policies are specified, the default is `onExit = "despawn"`.

## Auto-tagging

Entities spawned while a state is active automatically receive that state's tag component. This happens
transparently in the spawn path.

```teal
world:pushState("game")

-- This entity automatically gets the gameState component
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("enemy.png", "idle")
)

-- Entities spawned before any pushState have no state tag
-- and persist across all state transitions
```

::: tip Permanent entities
Spawn persistent entities (stars, HUD, cameras) before the first `pushState` call. They won't have a state
tag and will persist through all state transitions without needing any special handling.
:::

## Events

The state stack emits events on transitions. Observe them at address 0 (world-level):

```teal
world:observe(0, tecs.builtins.StateEnter, function(e)
    print("Entered state:", e.state)
end)

world:observe(0, tecs.builtins.StateExit, function(e)
    print("Exited state:", e.state)
end)

world:observe(0, tecs.builtins.StateBlur, function(e)
    print(e.state, "lost focus, pushed:", e.pushed)
end)

world:observe(0, tecs.builtins.StateFocus, function(e)
    print(e.state, "regained focus, popped:", e.popped)
end)
```

## Querying by state

The state component returned by `createState` can be used in queries:

```teal
local GameState = world:createState("game")

-- Find all entities in the "game" state
local gameEntities = world:query({include = {GameState}})
```

## Conditional systems

Use `runIf.inState` to conditionally run systems based on the current state:

```teal
local runIf = tecs.runif

world:addSystem({
    name = "GameplayUpdate",
    phase = tecs.phases.Update,
    runIf = runIf.inState("game"),
    run = function(dt)
        -- only runs when "game" is the top state
    end
})
```

## Example: full game flow

```teal
-- Create states
local GameState = world:createState("game", {
    onBlur = "pause",
    onFocus = "resume",
})
world:createState("paused")
world:createState("dead")

-- Spawn permanent entities (HUD, stars) before pushState
world:spawn(tecs.builtins.Transform(0, 0), gfx.Text(font, "SCORE"))

-- Start game
world:pushState("game")
-- Spawn game entities (auto-tagged)

-- Pause
world:pushState("paused")
-- Game entities freeze, pause menu entities spawned

-- Unpause
world:popState()
-- Pause menu despawned, game entities resume

-- Player dies
world:pushState("dead")
-- Game entities freeze again, death overlay spawned

-- Restart
world:popState()   -- dead entities despawned, game entities resume
world:popState()   -- game entities despawned
world:pushState("game")  -- fresh start
```

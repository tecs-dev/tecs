---
description: "The world's state stack: createState, pushState, popState, peekState, lifecycle policies, auto-tagging, and transition events"
outline: deep
---

# State stack

Every world owns a stack of named states, which is how play, pause, menus and game-over screens are modeled.
Push a state to enter it, pop to leave. Each state carries a tag component that is added automatically to
entities spawned while the state is on top, and a lifecycle policy decides what happens to those entities when
the state loses focus or is popped.

States are created from a game's entry plugin, along with everything else it registers. See
[Plugins](/ecs/plugins).

## World methods

These methods are available on every `World`.

| Method                                     | Description                                        |
| ------------------------------------------ | -------------------------------------------------- |
| [`world:createState`](#world-create-state) | Create a named state and return its tag component. |
| [`world:pushState`](#world-push-state)     | Push a state onto the stack.                       |
| [`world:popState`](#world-pop-state)       | Pop the current state off the stack.               |
| [`world:peekState`](#world-peek-state)     | The name of the state currently on top.            |

### world:createState {#world-create-state}

Creates a named state with an optional lifecycle policy, and returns the tag component that is auto-added to
entities spawned while the state is on top of the stack.

```teal
function World:createState(name: string, policy?: StatePolicy): Component
```

**Parameters:**

- `name`: the state name. Creating a state whose name already exists in this world is an error.
- `policy`: optional lifecycle policy. When `onExit` is not given, it defaults to `"despawn"`.

**Returns:** the tag component for this state. It is registered under the state name with `State` appended, so
the state `"game"` gets the component named `gameState`.

### world:pushState {#world-push-state}

Pushes a state onto the stack. Entities spawned after this call receive the state's tag component.

```teal
function World:pushState(name: string)
```

**Parameters:**

- `name`: the state name, which must already have been created with `world:createState`.

In order: the outgoing top state's `onBlur` policy runs, [`StateBlur`](#transition-events) is emitted, the new
state is pushed and becomes the auto-tag, its `onEnter` policy runs, and [`StateEnter`](#transition-events) is
emitted. Pushing onto an empty stack skips the blur half.

### world:popState {#world-pop-state}

Pops the state currently on top. Popping an empty stack is an error.

```teal
function World:popState()
```

In order: the popped state's `onExit` policy runs, [`StateExit`](#transition-events) is emitted, the state is
removed from the stack, and then, when a state is revealed beneath it, that state becomes the auto-tag, its
`onFocus` policy runs and [`StateFocus`](#transition-events) is emitted. Popping the last state leaves the world
with no auto-tag, so later spawns carry no state tag.

### world:peekState {#world-peek-state}

Returns the name of the state on top of the stack, or `nil` when the stack is empty.

```teal
function World:peekState(): string
```

## Creating states

Define states with `world:createState()`. The component it returns can be used in queries like any other tag.

```teal
local GameState <const> = world:createState("game", {
    onBlur = "pause",    -- pause game entities when another state is pushed on top
    onFocus = "resume",  -- resume them when this state is on top again
})

local PausedState <const> = world:createState("paused")
-- The default onExit = "despawn": entities tagged with this state are
-- despawned when it is popped.
```

## Pushing and popping

```teal
-- Start gameplay
world:pushState("game")
-- Everything spawned from here is auto-tagged with the gameState component

-- Pause the game
world:pushState("paused")
-- game's onBlur fires: Paused is added to every gameState entity
-- Entities spawned now are auto-tagged with pausedState

-- Unpause
world:popState()
-- paused's onExit fires: every pausedState entity is despawned
-- game's onFocus fires: Paused is removed from the gameState entities
```

Read the current state with `peekState`:

```teal
local current <const> = world:peekState()  -- "game", "paused", ... or nil
```

## Lifecycle policies

A state's policy has four hooks:

| Hook      | When it fires                                                       |
| --------- | ------------------------------------------------------------------- |
| `onEnter` | When this state is pushed                                           |
| `onExit`  | When this state is popped. Defaults to `"despawn"`                  |
| `onBlur`  | When this state stops being top, because one was pushed on it       |
| `onFocus` | When this state becomes top again, because the one above was popped |

### Policy actions

`onBlur`, `onFocus` and `onExit` accept a string action, a function, or a table carrying both. `onEnter` accepts
only a function.

| Value                       | Effect                                                                    |
| --------------------------- | ------------------------------------------------------------------------- |
| `"pause"`                   | Adds [`Paused`](/ecs/builtins#paused) to every entity with this state tag |
| `"resume"`                  | Removes `Paused` from those entities                                      |
| `"despawn"`                 | Despawns every entity with this state tag                                 |
| `"disable"`                 | Adds [`Disabled`](/ecs/builtins#disabled) to those entities               |
| `function(world)`           | Called with the world                                                     |
| `{apply = ..., call = ...}` | Runs the string action, then calls the function                           |

Any unknown string action is an error when the hook fires. Each hook runs inside a deferred scope, so the
mutations it makes are staged and drained together.

```teal
world:createState("cutscene", {
    onEnter = function(world: tecs.World)
        -- custom enter logic
    end,
    onExit = "despawn",
})
```

::: warning `"pause"` needs queries that opt out
`"pause"` adds `Paused` to the state's entities, but a system only stops acting on them if its query declares
`type = "logic"`, which auto-excludes `Paused`. A movement query without it keeps moving paused entities, and
nothing reports an error. See [Queries](/ecs/queries/).
:::

Pausing does not hide anything. The extractor's renderable and light queries declare no query type, so they
still match `Paused` entities: a paused world keeps drawing, which is what a pause menu drawn over the frozen
game depends on. Use [`Disabled`](/ecs/builtins#disabled) when the entity should also stop being drawn.

## Auto-tagging

Entities spawned while a state is on top automatically receive that state's tag component. This happens inside
the spawn path itself, on the instant, deferred and batch paths alike, so nothing has to remember to add it.

```teal
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable

world:pushState("game")

-- This entity automatically gets the gameState component
world:spawn(Transform(100, 100), Tint(1, 0.4, 0.3, 1), Renderable())
```

::: tip Permanent entities
Spawn persistent entities, cameras and the HUD among them, before the first `pushState`. They get no state tag
and so survive every transition without special handling.
:::

## Transition events

The stack emits four builtin events at address `0`. See [Events](/ecs/events) for the observer API and
[Builtins](/ecs/builtins#events) for the event records.

```teal
world:observe(0, tecs.ecs.StateEnter, function(e: tecs.ecs.StateEnter)
    print("Entered state:", e.state)
end)

world:observe(0, tecs.ecs.StateExit, function(e: tecs.ecs.StateExit)
    print("Exited state:", e.state)
end)

world:observe(0, tecs.ecs.StateBlur, function(e: tecs.ecs.StateBlur)
    print(e.state, "lost focus, pushed:", e.pushed)
end)

world:observe(0, tecs.ecs.StateFocus, function(e: tecs.ecs.StateFocus)
    print(e.state, "regained focus, popped:", e.popped)
end)
```

## Querying by state

The component `createState` returns is an ordinary tag component, so it composes with any other query term.

```teal
local GameState <const> = world:createState("game")

-- Every entity that belongs to the "game" state
local gameEntities <const> = world:query({include = {GameState}})

-- Narrowed to one kind of entity in that state
local enemies <const> = world:query({include = {GameState, Enemy}})
```

## Conditional systems

`tecs.ecs.runif.inState` gates a system on the state currently on top:

```teal
world:addSystem({
    name = "GameplayUpdate",
    phase = tecs.ecs.phases.Update,
    runIf = tecs.ecs.runif.inState("game"),
    run = function(dt: number, world: tecs.World)
        -- only runs while "game" is the top state
    end
})
```

See [Systems](/ecs/systems#instate) for the rest of the predicates.

## Save and load

A snapshot carries the state stack, so loading one restores which states are on the stack and which is on top,
and the world's auto-tag is re-derived from the restored top. The state tags themselves are ordinary components
on entities, so they are saved and restored with everything else; that includes the `Paused` and `Disabled` tags
a policy had applied.

Policies are functions and closures, so they are not in the snapshot. Call `world:createState` with its policy
during plugin setup, before a load can happen, so the states a snapshot names already exist with their hooks
attached when it arrives.

Local variables and runtime indexes have to be rebuilt after a load rather than restored. Query the state tag
for whole groups, and reserve [`EntityKey`](/ecs/builtins#entitykey) for the few anchors you need to rediscover
directly,
such as the player or the active camera.

```teal
local GameState <const> = world:createState("game")
local enemies <const> = world:query({include = {GameState, Enemy}})

world:observe(0, tecs.ecs.FinishSnapshotLoad, function()
    playerId = world:requireKey("player")
    rebuildEnemyIndex(enemies)
end)
```

See [Save games](/ecs/save-games) for the snapshot API.

## Example: a full game flow

```teal
local GameState <const> = world:createState("game", {
    onBlur = "pause",
    onFocus = "resume",
})
world:createState("paused")
world:createState("dead")

-- Permanent entities, spawned before the first push: the camera, the HUD,
-- anything that outlives every state.
world:spawn(Transform(24, 24), Tint(0.92, 0.96, 1.0, 1.0), Renderable())

world:pushState("game")
-- Game entities spawn here and are auto-tagged

world:pushState("paused")
-- Game entities freeze; pause-menu entities spawn tagged with pausedState

world:popState()
-- Pause menu despawned, game entities resume

world:pushState("dead")
-- Game entities freeze again, death overlay spawns

world:popState()       -- death overlay despawned, game entities resume
world:popState()       -- game entities despawned
world:pushState("game") -- fresh start
```

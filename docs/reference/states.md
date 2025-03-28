# States

Tecs provides a simple, built-in way to define game state. This state can be used to conditionally run systems
or react to state changes.

## Defining states

You define states using a record and an enum. The following example defines a `GameState`:

```lua
local tecs = require("tecs")

--- Defines the states of a game.
local record GameState is tecs.States<Value>
    enum Value
        "menu"
        "play"
        "paused"
    end
end
```

### Default values

You can optionally provide default values for states using `DefaultedStates`:

```lua
-- State with a default value
local record GameState is tecs.DefaultedStates<Value>
    enum Value
        "menu"
        "play"
        "paused"
    end
    default: Value  -- Type declaration
end

-- Set the default value
GameState.default = "menu"
```

States without defaults (using regular `States`) will return `nil` from `getState` until explicitly set.

## Using states

You can now set this state on a [World](/reference/world):

```lua
-- Transition to the "menu" state.
world:setState(GameState, "menu")
```

You can get the current value of a state:

```lua
local currentState = world:getState(GameState) -- gets "menu"
```

And check if the state has a specific value:

```lua
if world:inState(GameState, "play") then
    print("In the play state")
end
```

## Conditionally run systems

One of the primary use cases of states is to conditionally run systems. You don't need to maintain a stack of
game states or anything like that; you can just make systems conditionally run based on state.

```lua{8-10,20-22}
-- Update the menu.
world:addSystem({
    phase = tecs.phases.Update,
    name = "UpdateMenu",
    run = function()
        -- do something here to update your menu
    end,
    runIf = function(world: tecs.World): boolean
        return world:inState(GameState, "menu")
    end
})

-- Update the pause screen.
world:addSystem({
    phase = tecs.phases.Update,
    name = "UpdatePause",
    run = function()
        -- do something here to update your pause screen
    end,
    runIf = function(world: tecs.World): boolean
        return world:inState(GameState, "paused")
    end
})
```

## React to state changes

It's often necessary to run logic when a state changes. For example, when pausing the game, you might
want to pause all currently playing sound effects. Tecs offers three different callbacks to react
to state changes, emitted in the following order: `onExitState`, `onTransitionState`, `onEnterState`.

### onExitState

Emitted first, when a state is leaving a non-nil state value.

```lua
world:onExitState(GameState, "play", function()
    -- do something when exiting the play state
end)
```

### onTransitionState

Emitted when a state transitions from one specific state to another.

```lua
world:onTransitionState(GameState, "play", "paused", function()
    -- do something when transitioning from play -> paused
end)
```

### onEnterState

Emitted last, when a state transitions into a new state value.

```lua
world:onEnterState(GameState, "paused", function()
    -- do something when entering the "paused" state
end)
```

## Advanced: Custom State Containers

For advanced use cases, you can create independent state containers using `tecs.newStateContainer()`:

```lua
local tecs = require("tecs")

-- Create a custom state container (separate from the world)
local customContainer = tecs.newStateContainer()

-- Use it independently
customContainer:setState(GameState, "menu")
local currentState = customContainer:getState(GameState)

-- Set up callbacks
customContainer:onEnterState(GameState, "play", function()
    print("Custom container entered play state")
end)
```

Most users should use the world's built-in state management (`world:setState`, etc.) instead of creating separate containers.
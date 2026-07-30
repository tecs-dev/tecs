---
description: "The world state stack, lifecycle policies, automatic tags, and transition events"
outline: deep
---

# State stack

Every world owns a stack of named states. Use it for play, pause, menus,
cutscenes, and game-over overlays.

Each state owns a tag component. A spawn automatically receives the tag of the
state currently on top.

```teal
local GameState <const> = world:createState("game", {
    onBlur = "pause",
    onFocus = "resume",
})

local PauseState <const> = world:createState("pause")

world:pushState("game")
world:spawn(Player()) -- receives GameState

world:pushState("pause")
world:spawn(PauseMenu()) -- receives PauseState

world:popState()
```

The default exit action despawns the entities tagged with the popped state.
Spawn permanent cameras, services, and HUD entities before the first
`pushState` so they receive no state tag.

## Transition order

Pushing a state performs these steps:

1. Apply the outgoing state's blur policy.
2. Emit `StateBlur`.
3. Push the new state and select its auto-tag.
4. Apply its enter policy.
5. Emit `StateEnter`.

Popping performs these steps:

1. Apply the top state's exit policy.
2. Emit `StateExit`.
3. Remove it from the stack.
4. Select the revealed state's auto-tag.
5. Apply its focus policy and emit `StateFocus`.

Popping the last state clears the auto-tag. Popping an empty stack or pushing
an unregistered name raises.

Each transition runs inside a deferred scope, so its entity mutations drain
together.

## Lifecycle policies

| Hook      | Moment                                                 |
| --------- | ------------------------------------------------------ |
| `onEnter` | The state reaches the top through a push.              |
| `onBlur`  | Another state covers it.                               |
| `onFocus` | A pop reveals it.                                      |
| `onExit`  | The state leaves through a pop. Defaults to `despawn`. |

Blur, focus, and exit hooks accept these built-in actions:

| Action    | Effect on entities carrying the state tag |
| --------- | ----------------------------------------- |
| `pause`   | Add `Paused`.                             |
| `resume`  | Remove `Paused`.                          |
| `disable` | Add `Disabled`.                           |
| `despawn` | Despawn the entities.                     |

A hook may instead call a function. A table with `apply` and `call` runs the
built-in action first, then the function. Enter accepts a function.

`pause` only affects queries declared with `type = "logic"` or an explicit
`Paused` exclusion. Render queries continue to match paused entities. Use
`disable` when the entities should leave all ordinary queries and stop
drawing.

## State-aware work

The tag returned by `createState` works in any query:

```teal
local enemies <const> = world:newQuery({
    include = {GameState, Enemy},
    type = "logic",
})
```

Gate a whole system on the current top state:

```teal
world:addSystem({
    name = "game.Update",
    phase = tecs.ecs.phases.Update,
    runIf = tecs.ecs.runif.inState("game"),
    run = updateGame,
})
```

Observe transition events at address zero when runtime code needs
notification:

```teal
world:observe(0, tecs.ecs.StateEnter,
    function(event: tecs.ecs.StateEnter)
        print("entered", event.state)
    end
)
```

## Snapshot setup

Snapshots carry the stack, state tags, `Paused`, and `Disabled`. Policies are
functions and do not enter the save.

Create every state with its policy during plugin setup before loading a
snapshot. Load raises when the saved stack names a state this world has not
registered.

After load, use state-tag queries to rebuild group indexes and `EntityKey` for
the few individual entities that code must rediscover. See
[Save games](/modules/ecs/save-games).

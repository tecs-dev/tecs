---
description: "Advanced per-world gameplay suspension with independently owned claims"
---

# World suspension

World suspension temporarily stops a world's gameplay simulation while keeping the world alive. Its entities and
resources remain intact, render phases continue, and process-level services such as asset loading and debugging keep
running. When suspension ends, gameplay continues from the same world state.

It exists for features that must keep running while gameplay does not. Without suspension, a loading screen or modal
tool would require loading- or pause-state predicates on every gameplay system. Suspension applies that boundary once
at the world level while another world can animate and render the interface independently.

## When to use it

Use world suspension when:

- A loading screen runs in a separate world while the gameplay world waits for assets.
- A pause or modal interface needs its own clock and must remain animated.
- The debugger or another tool needs rendering and input to continue while simulation is stopped.
- Multiple independent features may pause the same world and must not accidentally resume one another.

Do not use suspension merely to show another gameplay screen or disable a few systems. States, system predicates, and
cameras are simpler for those cases. Suspension is an advanced boundary for stopping essentially the entire gameplay
simulation.

## Suspension ownership

Each feature suspending a world creates a named suspension claim. The name identifies the feature that owns the claim,
such as `assets.loading`, `debugger`, or `mcp.operator`.

Calling `resume` removes only that owner's claim. Gameplay resumes only after every owner has released its claim. This
prevents a loading screen from accidentally resuming a world that the debugger also suspended.

## Basic usage

```teal
local suspension <const> = require("tecs2d.suspension")

suspension.suspend(world, "pause-menu")
assert(suspension.heldBy(world, "pause-menu"))
suspension.resume(world, "pause-menu")
```

`suspend` creates at most one claim for an owner. `heldBy` reports whether that owner currently has a claim. Repeated
`suspend` or `resume` calls for the same owner do nothing and return `false`; owner names must be non-empty.

## Runtime behavior

The first active claim disables `First`, `PreUpdate`, fixed update, `Update`, `PostUpdate`, and `Last`, and freezes the
render pipeline clock. Render phases remain active. Gameplay and its prior time scale are restored only after every
owner has released its claim.

## Independent UI worlds

For an independently animated pause or loading interface, put it in a small secondary world with its own real-time clock.
See [Multiple render worlds and compositing](/tecs2d/rendering/multi-world#loading-screens).

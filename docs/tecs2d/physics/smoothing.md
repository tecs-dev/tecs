# Transform Smoothing

Physics runs on a fixed timestep (typically 60Hz) for determinism, but rendering runs at the display's refresh rate.
Without smoothing, objects appear to stutter as the same position is rendered multiple times between physics steps.

The `smoothing` option on the physics plugin controls how visual positions are computed between physics steps.

## interpolate (default)

Blends between the previous and current physics position. Produces perfectly smooth motion but introduces
approximately one frame of visual latency (~16ms at 60Hz).

```lua
world:addPlugin(physics.new({
    world = physicsWorld,
    smoothing = "interpolate"
}))
```

Best for most games. The latency is imperceptible to most players.

## extrapolate

Predicts position beyond the current physics state using velocity. More responsive (no latency) but can overshoot
when physics changes suddenly, such as hitting a wall or changing direction.

```lua
world:addPlugin(physics.new({
    world = physicsWorld,
    smoothing = "extrapolate"
}))
```

Potentially a good fit for competitive games where input latency matters more than visual stability.

## disabled

No smoothing. Transform is set directly from the physics body position. Objects may visually stutter unless your game
logic and display run at the exact same rate (e.g., vsync enabled).

```lua
world:addPlugin(physics.new({
    world = physicsWorld,
    smoothing = "disabled"
}))
```

# Systems

A system is a function that runs game logic by operating on entities with specific
[components](/reference/components). Systems are how behavior is added to the game. Systems are added to
[phases](/reference/phases) in the [World](/reference/world).

## What do systems do

Systems do different things depending on what phase they are added to. The most common use of a system is
to iterate over the results of a [query](/reference/queries) and process matching entities. Other uses for
systems include:

* Loading assets if the system is added to the `Startup` phase.
* Saving the state of the game or closing resources if a system is added to the `Shutdown` phase.
* Updating other parts of the game that aren't entity specific if the system is added to the `Update` phase.

## Creating a system

Systems are added to the world using `world:addSystem()` and a table that contains specific key value pairs.

```lua
world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        print("The game is starting up!")
    end
})
```

Systems are typically created within [plugins](/reference/plugins).

## System configuration settings

```lua
--- Configuration used when adding systems to the world.
record SystemConfig
    --- The required phase the system should run in.
    phase: Phase

    --- The name of the system, useful for debugging or to ensure a system
    --- is run before or after others.
    name: string

    --- The required function to call each time the system runs.
    run: function(dt: number, world: World)

    --- An optional function that determines if the system should run.
    ---
    --- @param dt The time since the last update.
    --- @param world The world that is being updated.
    runIf: function(dt: number, world: World): boolean

    --- An optional list of systems that should run before this system,
    --- forming a directed acyclic graph.
    before: {string}

    --- An optional list of systems that should run after this system,
    --- forming a directed acyclic graph.
    after: {string}
end
```

## Naming systems

You can give systems a name using the `name` property. This makes it easier to debug, and also
allows other systems to be added relative to the system by referencing the name.

```lua{3}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyUpdateSystem",
    run = function()
        -- update logic...
    end
})
```

## Conditionally running systems

You might not want a system to always run. You can provide a predicate function to the `runIf`
property to decide if a system can run or not. This function accepts the `World` and the time
since the world was last updated, and returns true or false if it should run.

Run a system once every second:

```lua
local countDown = 1

world:addSystem({
    phase = tecs.phases.Update,
    name = "RunEverySecond",
    run = function()
        print("One second has passed")
    end,
    runIf = function(world: tecs.World, dt: number): boolean
        countDown = countDown - 1
        if countDown <= 0 then
            countDown = 1
            return true
        end
        return false
    end
})
```

## Adding systems before or after other systems

Systems in the same phase can be added before or after other systems. Tecs will topologically sort systems
for you to ensure systems are run in the correct order and have no cycles.

Add a system before another named system:

```lua{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyOtherUpdateSystem",
    run = function()
        -- update logic...
    end,
    before = {"MyUpdateSystem"}
})
```

Add a system after another named system:

```lua{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "YetAnotherUpdateSystem",
    run = function()
        -- update logic...
    end,
    after = {"MyUpdateSystem"}
})
```
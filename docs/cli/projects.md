---
description: "The tecs.lua project manifest, its fields, and entry-file discovery"
outline: deep
---

# Projects

A project contains a `tecs.lua` manifest. Project commands search upward from the working directory, so they also
work from a subdirectory.

```lua
return {
    name = "hello",
    identifier = "com.example.hello",
    entry = "src/main.tl",
    assets = "assets",
    window = { title = "Hello", width = 1280, height = 960 },
}
```

The Lua manifest supports comments and uses the same toolchain as the game. Every field except `name` has a
default.

`tlconfig.lua` is still written by `tecs new`, because `tl` needs it, but it is not the project marker.

The `tecs dist` command compiles the entry to `build/main.lua`; every entry must return an application. See
[getting started](/getting-started#entry-file).

---
description: "What the tecs command treats as a project: the tecs.lua manifest, its fields, and how the entry file is found"
outline: deep
---

# Projects

A directory containing `tecs.lua`, which returns a table. The file is both the marker and the manifest, and the
tool searches upward from the working directory for it, so it can be run from a subdirectory.

```lua
return {
    name = "hello",
    identifier = "com.example.hello",
    entry = "src/main.tl",
    assets = "assets",
    window = { title = "Hello", width = 1280, height = 960 },
}
```

Lua rather than JSON, for three reasons: no parser is needed, it takes comments, and it can be type-checked by the
same `tl` the tool already runs. Every field except `name` has a default.

`tlconfig.lua` is still written by `tecs new`, because `tl` needs it, but it is not the project marker.

The entry file compiles to `build/main.lua` and runs through the seam the host already has: `tecs --entry
build/main.lua`. It must return an application. See [getting started](/getting-started#the-entry-file).

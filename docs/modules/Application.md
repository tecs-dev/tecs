---
description: "The application object an entry file returns and the host drives through init, event, iterate and quit"
outline: deep
---

# Application

`tecs.Application` is the lifecycle the C host drives. An entry file ends with `return tecs.application(config)`,
and the host calls into the returned object for initialisation, each event, each frame, and shutdown. It is not a
function that runs until done: a platform that never hands control back has no loop to block in, so the loop lives
below Lua and the application is what it calls.

::: warning This page is pending
`Application.Config` is being reworked right now. Writing the field reference today would mean writing it twice,
so this page carries the shape of the module and nothing that is about to move.

Read `src/tecs/Application.tl` for the current surface, and the ["One way in"](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
section of the design record for why the entry file is shaped this way.
:::

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")`. `tecs` is also set as a global, so a require line is optional; engine
modules resolve on first field access, which keeps a headless tool from loading a graphics stack it never asked
for.

## The entry file

```teal
return tecs.application(config)
```

`tecs.application` builds the application the host drives. The host loads an already-compiled chunk through its
`--entry <path>` seam and enforces that the chunk returns an application.

## What it owns

An application owns the window, the graphics device, the world, the renderer, input, audio and, when enabled, the
debug server. Those are reachable as fields once it is running, and each has its own page:

- [`Window`](/modules/Window)
- [`Renderer`](/modules/Renderer)
- [`Input`](/modules/Input)
- [`Audio`](/modules/Audio)
- [`mcp`](/modules/mcp)
- The world itself, at [`/ecs/world`](/ecs/world)

## Design record

- [One way in](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
- [One plugin, and what it is handed](https://github.com/tecs-dev/tecs/blob/main/README.md#one-plugin-and-what-it-is-handed)
- [A frame that throws puts back what it was holding](https://github.com/tecs-dev/tecs/blob/main/README.md#a-frame-that-throws-puts-back-what-it-was-holding)

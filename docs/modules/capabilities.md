---
description: "What this build of the engine can do on this target, read from the platform rather than inferred from the OS name"
outline: deep
---

# tecs.capabilities

`tecs.capabilities` reports what this build of the engine can do on the machine it is running on: whether machine
code is being generated, whether shaders can be compiled at run time, whether a touch device is attached, how
many cores a worker pool has to size itself against.

It is read rather than inferred. Selecting behaviour from `ffi.os` guesses: it cannot tell a build that linked a
shader compiler from one that did not, or an interpreter-only LuaJIT from a jitting one, and both distinctions
change what the engine is allowed to attempt.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.capabilities`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily on
first field access.

## get

Reads the capabilities of the running build.

```teal
function capabilities.get(): capabilities
```

**Returns:** the same table on every call until the platform changes. It is shared, so a caller that means to
keep it does not also mean to edit it.

The answer is cached, since none of it changes while a platform is installed. The cache is keyed on the platform
generation, so installing a platform drops it without anybody calling `reset`.

**Example:**

```teal
local caps <const> = tecs.capabilities.get()
local decoders <const> = caps.workers and math.max(1, caps.cores - 1) or 0
print(("%s on %s, %d decode workers"):format(caps.target, caps.architecture, decoders))
```

## What it answers

| Field              | Type       | Description                                                                                                                                                                                   |
| ------------------ | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `target`           | `string`   | Platform name as SDL reports it, such as `"macOS"` or `"Android"`. A licensed port answers with its own name instead, since everything here describes the platform actually installed.        |
| `architecture`     | `string`   | CPU architecture LuaJIT was built for.                                                                                                                                                        |
| `jit`              | `boolean`  | Whether machine code is being generated. False on a target that forbids it, where the interpreter runs instead. Independent of `ffi`.                                                         |
| `ffi`              | `boolean`  | Always true. The engine has no path that does not use the FFI, so a build without it does not run at all rather than running degraded.                                                        |
| `dynamicLibraries` | `boolean`  | Whether a library can be loaded by name at run time. False where every library is linked into the executable.                                                                                 |
| `runtimeShaders`   | `boolean`  | Whether shaders can be compiled from source at run time.                                                                                                                                      |
| `packagedShaders`  | `boolean`  | Whether shaders are being read from a packaged artifact. Independent of `runtimeShaders`: a development build may have both, and a release has only this.                                     |
| `shaderFormats`    | `{string}` | Shader formats this target consumes. One entry, since a build supplies one format.                                                                                                            |
| `touch`            | `boolean`  | Whether a touch device is attached right now. A property of the machine rather than of the target: a desktop with a touchscreen has one.                                                      |
| `gamepad`          | `boolean`  | Always true. Every target reaches gamepads through the same subsystem, so what varies is whether one is plugged in.                                                                           |
| `sensors`          | `boolean`  | Whether the device itself carries a gyroscope or an accelerometer. True on iOS and Android. Says nothing about a gamepad's sensors.                                                           |
| `workers`          | `boolean`  | Whether work can be run off the main thread.                                                                                                                                                  |
| `cores`            | `integer`  | Logical cores, for sizing a worker pool.                                                                                                                                                      |
| `writableStorage`  | `boolean`  | Always true. Every target has somewhere to write, and [`paths.pref`](/modules/paths#pref) is where. The field exists so a caller can ask rather than assume, not because a target answers no. |

### Fields whose answer is about a device, not the target

`gamepad` says the subsystem exists, not that a pad is plugged in; ask [`Input`](/modules/Input) which gamepads
are connected. `sensors` says the device itself carries a gyroscope or an accelerometer, which is a different
question from whether a particular pad has one; [`Gamepad`](/modules/Gamepad) answers that per device. `touch`
is the one hardware answer here that is asked of the platform each time the capabilities are resolved, because
neither a desktop with a touchscreen nor a simulator without one follows from the OS name.

### The two shader bits

`runtimeShaders` is whether a shader compiler was linked into this build, and it is what separates a development
build from a release. [`watch`](/modules/watch) refuses to install without it, on the grounds that a release has
no business polling the filesystem for reloads it could not complete. `packagedShaders` is whether a prebuilt
pack was loaded, which a release always has and a development build may have as well.

## reset

Forgets the cached answer.

```teal
function capabilities.reset()
```

A platform change is noticed without this, so it is for a test that changed something the resolution reads.

## Design record

- [Porting to a platform SDL does not cover](https://github.com/tecs-dev/tecs/blob/main/README.md#porting-to-a-platform-sdl-does-not-cover)
- [The file watcher](https://github.com/tecs-dev/tecs/blob/main/README.md#the-file-watcher)

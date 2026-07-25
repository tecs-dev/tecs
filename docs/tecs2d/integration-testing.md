---
description: "Writing tecs integ specs with the fixture harness to drive a built game over MCP for integration tests"
outline: deep
---

# Integration Testing

`tecs integ` runs the specs in your project's `spec/` directory with a
[busted](https://lunarmodules.github.io/busted/) runner bundled in the Tecs
CLI. No busted, LuaRocks, or Lua installation is required.

Specs named `*_lovespec.tl` are integration tests: they launch the built game
under a real Love process and drive it over the game's
[MCP server](/tecs2d/mcp/). A spec can run Lua inside the game, send input
events, read entity and component state, sample framebuffer pixels, and take
screenshots. These are the same tools available to a debugger session or
coding agent.

![The space example under test: the screenshot was captured through the same MCP tools the specs use](/images/integration-testing.png)

## Running

```sh
tecs integ
```

`tecs integ` builds the game, compiles `spec/**/*.tl` to `build/spec/`, and
runs busted over the result. The command exits non-zero if any spec fails.

Integration runs are not headless: each `fixture.start` opens a real game
window (on macOS it opens unfocused, so it does not interrupt you). `tecs
integ` runs on macOS and Linux; the process harness is POSIX-only.

Projects created by `tecs new` include a working spec in
`spec/game_lovespec.tl` and a CI workflow that runs `tecs integ` on macOS
runners, which provide a windowing session. Linux CI runners do not, so the
generated workflow skips integration tests there.

## The fixture harness

`tecs2d.testing.fixture` boots a game directory on a free MCP port and hands
back a connected client:

```teal
local fixture <const> = require("tecs2d.testing.fixture")
local luassert <const> = require("luassert")

describe("the game", function()
    local app: fixture.App

    setup(function()
        app = fixture.start("build")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("boots and responds over MCP", function()
        local values = fixture.runLua(app, "return 1 + 1")
        luassert.equal("2", values[1])
    end)
end)
```

`fixture.start(appDir)` launches `appDir` under the Love runtime with
`TECS_MCP_PORT` set to a free port. The default `mcp.new()` plugin honors that
variable, so games created by `tecs new` need no extra wiring. `fixture.stop`
asks the game to quit over MCP and escalates to signals if it does not exit.

The harness API:

| Function | Description |
| -------- | ----------- |
| `fixture.start(appDir): App` | Launch the game and wait for its MCP server |
| `fixture.stop(app)` | Shut the game down |
| `fixture.runLua(app, code): {string}` | Run Lua inside the game; returns the stringified return values. `world` is in scope and `require` resolves game modules |
| `fixture.probePixels(app, points): {{number}}` | Sample framebuffer pixels at normalized `{fx, fy}` points; returns `{r, g, b}` triples |
| `fixture.eventually(seconds, fn): T` | Poll `fn` until it returns non-nil or the deadline passes |
| `app.client:call(tool, params): table` | Call any [MCP tool](/tecs2d/mcp/tools) directly |
| `app.client:screenshot(): string` | Capture the framebuffer as base64 PNG (`tecs2d.testing.png_util` decodes and parses headers) |

## Driving the game

Input goes through the `send_love_event` MCP tool, which feeds the same event
pipeline as real input. The current [input-layer owner](/tecs2d/input/#input-layers) receives it: gameplay polling and
Controller bindings respond when `input.base` is top, while an open menu or debugger receives and may intercept it
instead. This makes injected input suitable for testing modal isolation as well as ordinary controls:

```teal
local function pressKey(key: string)
    app.client:call("send_love_event", {event = "keypressed", args = {key, key, false}})
    app.client:call("send_love_event", {event = "keyreleased", args = {key, key}})
end
```

Game state is read with `fixture.runLua`. The code runs inside the game
process with `world` in scope, and `require` resolves your game's modules:

```teal
local function countComponent(component: string): integer
    local values = fixture.runLua(app, string.format([[
        local shared = require("plugins.shared")
        local query = world:query({include = {shared.%s}})
        local count = 0
        for _, len in query:iter() do count = count + len end
        return tostring(count)
    ]], component))
    return math.floor(tonumber(values[1]) or -1)
end
```

Because a game advances frame by frame, assertions about state that changes
over time should poll with `fixture.eventually` instead of asserting
immediately:

```teal
it("starts gameplay when Enter is pressed", function()
    pressKey("return")
    local state = fixture.eventually(fixture.callTimeout, function(): string
        local values = fixture.runLua(app, "return world:peekState()")
        if values[1] == "game" then return values[1] end
        return nil
    end)
    luassert.equal("game", state)
end)
```

The [tecs-space-example](https://github.com/tecs-dev/tecs-space-example)
repository walks its shooter through the full state machine this way: boot to
the ready screen, start gameplay, spawn the player, hold Space to fire, then
pause and resume. The whole run takes about four seconds. Its
[`spec/game_lovespec.tl`](https://github.com/tecs-dev/tecs-space-example/blob/main/spec/game_lovespec.tl)
is a complete reference.

## Assertions

Specs use the bundled [luassert](https://github.com/lunarmodules/luassert)
through its flat API: `luassert.equal`, `luassert.same`, `luassert.is_true`,
and friends. Type declarations for busted's globals (`describe`, `it`,
`setup`, ...) and luassert ship with the CLI, so `tecs integ` type-checks
specs before running them.

## Conventions

- `spec/**/*_lovespec.tl` files are integration specs; each `fixture.start`
  boots a real game process.
- `spec/**/*_spec.tl` files are plain busted specs; they run in the same pass
  without launching anything.
- Specs in one `describe` block share state and run in order. Booting a game
  per `describe` (in `setup`/`teardown`) keeps runs fast; walk the game
  through its states in sequence rather than restarting per test.
- Game logs are written under `build/test_deps/love_test_logs/` and are
  printed when a fixture fails to become ready.

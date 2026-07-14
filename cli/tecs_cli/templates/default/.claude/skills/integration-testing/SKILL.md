---
name: integration-testing
description: Write and run integration specs that drive the built game over MCP with `tecs integ`. Use when adding, writing, or debugging game-behavior tests.
---

# Tecs integration testing

`tecs integ` builds the game, compiles `spec/**/*.tl`, and runs it with the bundled busted runner.
Specs named `*_lovespec.tl` launch the built game under real LÖVE and drive it over MCP; `*_spec.tl`
files are plain busted specs. Love-driven runs are not headless (a game window opens, unfocused on
macOS) and work on macOS and Linux only. Always finish by running `tecs integ` and making it pass.

## Spec shape

```teal
local fixture <const> = require("tecs2d.testing.fixture")
local luassert <const> = require("luassert")

describe("the game", function()
    local app: fixture.App

    setup(function() app = fixture.start("build") end)
    teardown(function() fixture.stop(app) end)

    it("responds over MCP", function()
        local values = fixture.runLua(app, "return 1 + 1")
        luassert.equal("2", values[1])
    end)
end)
```

Boot one game per `describe` (booting takes ~1s) and walk it through its states in test order
instead of restarting per test. `fixture.start("build")` assigns a free MCP port automatically.

## Driving and reading the game

- Send input through the event pipeline:

  ```teal
  app.client:call("send_love_event", {event = "keypressed", args = {key, key, false}})
  app.client:call("send_love_event", {event = "keyreleased", args = {key, key}})
  ```

  To hold a key, send `keypressed` and delay the `keyreleased`.

- Read state with `fixture.runLua(app, code)`: the code runs inside the game, `world` is in scope,
  `require` resolves game modules, and return values come back stringified. Count entities by
  querying a component and returning `tostring(count)`.

- The game advances frame by frame, so poll time-dependent assertions with `fixture.eventually`
  rather than sleeping.

- `fixture.probePixels(app, {{0.5, 0.5}})` samples framebuffer pixels (normalized coords,
  `{r, g, b}`). `app.client:screenshot()` returns a base64 PNG. Any MCP tool is reachable via
  `app.client:call(tool, params)`.

## Rules and gotchas

- Assertions use luassert's flat API: `luassert.equal`, `luassert.same`, `luassert.is_true`. There
  is no `luassert.are.*` in the type declarations.
- Specs are Teal and type-checked: `socket.sleep(3)` compiles, `socket.sleep(3.0)` does not.
- Prefer polling (`fixture.eventually`) over sleeps.
- For deterministic assertions, seed randomness at startup and expose queryable state (a dedicated
  tag or a world resource) rather than guessing from pixels.

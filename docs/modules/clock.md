---
description: "Frame timing with a monotonic counter, a clamped delta, and an injectable provider for deterministic replay"
outline: deep
---

# tecs.clock

`tecs.clock` is the engine's frame timing. It reads the platform's monotonic performance counter, turns the
interval between two frames into the `dt` a world receives, and clamps that interval so a stalled frame does not
integrate as one enormous step.

Nondeterminism enters the engine here and through [`events`](/modules/events), and both take their input from a
provider that defaults to the real thing. That is what makes recorded replay possible: frames are the coordinate
system and `dt` is data. Reading the performance counter directly from the run loop would make deterministic
replay unimplementable rather than merely unimplemented.

[`Application`](/modules/Application) drives this module for you: it calls `clock.reset` after startup and
`clock.step` once per iteration, and hands the result to the world. A game reads `clock.now` for its own
measurements and sets `provider` only when it is driving a replay.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.clock`. `tecs`
is also set as a global, which makes the require line optional, and engine modules are resolved lazily on first
field access.

## Fields

| Field      | Type                               | Default      | Description                                                                                                                                    |
| ---------- | ---------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `provider` | `function(realDt: number): number` | unset        | Installed by a replay driver. Consulted once per frame with the measured `dt`; returning a number replaces it, `nil` keeps the measurement.    |
| `nominal`  | `number`                           | `1.0 / 60.0` | The loop's nominal frame `dt`, set at boot from the target frame rate. Stepped frames use it, so a step advances identically on every machine. |
| `maxDelta` | `number`                           | `0.25`       | Longest `dt` handed to the world. A frame that stalls, on a breakpoint or a window drag, must not integrate as one step.                       |

## Reading the counter

### now

Reads the monotonic counter in seconds. Not affected by `provider`.

```teal
function clock.now(): number
```

**Returns:** seconds on the platform's performance counter. The frequency is read once, on the first call, and
reused.

This is the clock an event's `arrival` field is expressed in, so the two can be subtracted; see
[`events`](/modules/events#event-fields).

**Example:**

```teal
local started <const> = tecs.clock.now()
buildLevel()
print(("built in %.1f ms"):format((tecs.clock.now() - started) * 1000))
```

### reset

Resets the baseline so the next `step` measures from now.

```teal
function clock.reset()
```

Called after startup so the first frame's `dt` excludes load time, and again after anything that parked the loop.

## Advancing a frame

### step

Advances one frame and returns the `dt` the world should receive.

```teal
function clock.step(): number
```

**Returns:** the interval since the previous `step`, clamped to `maxDelta`, and then offered to `provider`. When
a provider is installed and returns a number, that number is returned instead; when it returns `nil`, the
measurement stands.

::: warning One caller
The application already calls `step` once per iteration. Calling it again moves the baseline, so the frame that
follows measures from your call rather than from the loop's.
:::

## Driving a replay

Install `provider` to decide the frame delta yourself. The measurement is still taken and still passed in, so a
provider can consume the real interval, ignore it, or fall through by returning `nil`.

```teal
local recorded <const>: {number} = loadDeltas()
local frame = 0

tecs.clock.provider = function(realDt: number): number
    frame = frame + 1
    return recorded[frame]    -- nil past the end, so live timing resumes
end
```

Pair it with [`events.source`](/modules/events#replaying-a-stream), which replaces the event stream on the same
terms.

## Design record

- [Porting to a platform SDL does not cover](https://github.com/tecs-dev/tecs/blob/main/README.md#porting-to-a-platform-sdl-does-not-cover)
- [Measuring latency](https://github.com/tecs-dev/tecs/blob/main/README.md#measuring-latency)

---
description: "Capture the presented frame as PNG or read its RGBA pixels"
order: 60
---

# Screenshots

`tecs.gfx.screenshot` captures the next rendered frame, including lighting,
bloom, blended geometry and UI. The Rust host owns the render targets, so
request a capture during an update and use the result in a later update.

```nupp
local capture: tecs.gfx.screenshot.Capture? = nil

world:addSystem({
    name = "game.screenshot",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number, exclusive current: tecs.ecs.World): nil
        if input:keyPressed("F12") and capture == nil then
            capture = tecs.gfx.screenshot.request()
        end
        local ready = capture
        if ready ~= nil and ready.ready then
            local ok, reason = tecs.gfx.screenshot.save(ready, "screenshot.png")
            assert(ok, reason)
            capture = nil
        end
    end
})
```

`save(capture, path)` returns `true` on success, or `false, reason` on failure.
`encode(capture)` returns PNG bytes or `nil, reason`, preserving the original
screenshot helper's encoding and failure conventions.

For pixel access, `pixels(capture)` returns `rgba, width, height, reason`.
Pixels are tightly packed, eight-bit RGBA, in rows from top to bottom. Alpha
is 255, matching the displayed screenshot rather than the render targets'
internal alpha. Width and height are physical pixels, including display scale.

`ready` becomes true on both success and failure. Reading an unfinished capture
returns a pending reason. A skipped frame, unsupported surface readback, GPU
failure or closed host session produces a failure reason. Headless sessions
have no presented image to capture.

Only requested frames allocate readback storage and wait for GPU completion.
Keep captures for as long as needed; releasing your references allows their
pixel and PNG data to be collected. Several requests for one frame share its
GPU readback.

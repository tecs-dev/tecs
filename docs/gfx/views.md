---
title: Views
description: Compose ordered camera viewports for split-screen play and overlays.
---

# Views

A view draws into a rectangle of the frame. Spawn `tecs.gfx.View` to replace the
synthesized full-frame view with explicit cameras:

```nupp
world:spawn(tecs.gfx.View({
    camera2D = tecs.gfx.newCamera2D({x = 320, y = 180}),
    x = 0, y = 0, width = 0.5, height = 1,
}))
world:spawn(tecs.gfx.View({
    camera2D = tecs.gfx.newCamera2D({x = 960, y = 180}),
    x = 0.5, y = 0, width = 0.5, height = 1,
    order = 1,
}))
```

Viewport coordinates are fractions of the frame. Views draw in ascending
`order`; equal orders use entity ID. Disable a view with `enabled = false`.
Having explicit but disabled views draws only the background. Removing all view
entities returns to the active camera's full-frame view.

Each view runs the render graph at its own resolution and keeps its own resident
instances, tile chunks and targets. Moving a camera reculls its retained scene.
It does not upload unchanged world geometry. Screen-space content is projected
relative to that viewport. Screenshots capture the final composed frame.

Run `nupp task ex-views` to see two cameras with different zoom and rotation.

<img src="/images/gfx-views.png" alt="Independent cameras with different zoom and rotation." />

# Tecs examples

Four of the files under `nupp/` are complete game components. Each exports a
`create` function matching the Rust host's managed entry contract, installs its
entities and systems through a plugin, and delegates every platform and
rendering concern to `tecs.host`. The fifth is a script.

Run one from the repository root:

```bash
nupp task flatcolor
nupp task sprites
nupp task lighting --frames 120
```

`--frames N` stops after N frames and exits zero, which is what makes a
graphical example usable as a smoke test. It needs at least two: the first
completed frame renders, and the following turn observes the limit.
`--headless` runs the same component with no window.

`flatcolor.nupp` spawns three tinted, rotating quads. It is the smallest
complete entry, and the one to copy when starting a component of your own.

`sprites.nupp` builds two images in the component rather than loading them,
uploads them through `tecs.gfx.images`, and alternates them across three
layers behind a camera. Generating the pixels keeps the example independent of
the asset pipeline.

`lighting.nupp` is the showcase. It combines deferred lighting, occluder masks,
drop shadows and bloom, and it is what a release installs and
`nupp task test-package` runs from a relocated copy.

`nativesmoke.nupp` requires the audio, gamepad and physics service libraries
directly and raises on the first that will not load. Every other consumer
reaches them through a guarded require, so a host with nothing staged looks
healthy; this one does not. It is a component rather than a script because a
release ships no Nupp compiler, so the only Nupp an install can execute is one
already compiled.

`physicssmoke.nupp` is the script. The test suite drives `tecs.physics` through
a reference simulation and needs no native library, so this is the other half:
it loads `tecs.physics.rapier`, drops a box onto a floor, and exercises the
declarations, the layout self-check and real batched crossings against the
built library. Its own docblock says how to run it.

A new example needs a `kind = "component"` target in `nupp.lua` naming both
`tecs.host` and the module, with `<name>.create` added to the host's exports.

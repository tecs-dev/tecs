# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` registers an indexed cube, spawns it as a 3D entity, and draws it
through `MeshDomain` into the shared deferred G-buffer. It disables the sprite
domain, so the image proves the mesh lane owns its complete extraction,
staging, pipeline, and draw path.

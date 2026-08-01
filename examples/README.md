# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` registers an indexed cube, spawns it as a 3D entity, and draws it
through `MeshDomain` into the shared deferred G-buffer. It disables the sprite
domain, so the image proves the mesh lane owns its complete extraction,
staging, pipeline, and draw path.

`gltf3d.tl` loads a textured glTF 2.0 scene asynchronously, registers its
geometry, image, and alpha-blended metallic-roughness material with a
transparency-enabled mesh domain, then spawns the flattened scene primitives.
It exercises the asset-worker through GPU residency and the sorted forward
lane in one small example.

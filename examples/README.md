# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` registers an indexed cube and floor, then draws their directional
shadow through the mesh domain's opt-in, GPU-culled shadow lane. It disables
the sprite domain, so the image isolates 3D extraction, light-volume culling,
the shadow map, and deferred mesh lighting.

`gltf3d.tl` loads a textured glTF 2.0 scene asynchronously, registers its
geometry, image, and alpha-blended metallic-roughness material with a
transparency-enabled mesh domain, then spawns the flattened scene primitives.
It exercises the asset-worker through GPU residency and the sorted forward
lane in one small example.

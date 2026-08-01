# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
cargo xtask example skinning3d
cargo xtask example animated3d
cargo xtask example morph3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` combines a vertex-colored PBR mesh, an emissive unlit mesh,
directional shadows, fog, and bloom, then draws a translucent, screen-space,
unlit 2D HUD above them. It is the compact mixed-renderer example.

`gltf3d.tl` loads a textured glTF 2.0 scene asynchronously, registers its
geometry, vertex colors, image, and alpha-blended metallic-roughness material with a
transparency-enabled mesh domain, then spawns the flattened scene primitives.
It exercises the asset-worker through GPU residency and the sorted forward
lane in one small example.

`skinning3d.tl` constructs a two-joint procedural strip and updates its palette
directly. It isolates the optional GPU vertex-deformation path from file
loading and clip sampling.

`animated3d.tl` loads a skinned glTF clip, creates an independently posed model
instance, binds its primitive to an ECS entity, and samples the clip into both
the entity transform and the instance-owned GPU palette.

`morph3d.tl` loads a glTF morph target and weight animation, then samples it
into an instance-owned GPU weight vector. Geometry and clip data remain shared;
only the changing weights belong to the instance.

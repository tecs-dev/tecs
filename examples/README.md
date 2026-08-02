# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
cargo xtask example skinning3d
cargo xtask example animated3d
cargo xtask example morph3d
cargo xtask fetch sponza
cargo xtask example sponza3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` draws the same Cook-Torrance scene through two ordered 3D views,
then composes one full-frame 2D HUD view above them. It also combines vertex
colors, an emissive unlit mesh, directional shadows, fog, and bloom.

`gltf3d.tl` loads a textured glTF 2.0 scene asynchronously, registers its
geometry, vertex colors, image, and alpha-blended metallic-roughness material with a
transparency-enabled mesh domain, then spawns the flattened scene primitives.
It exercises the asset-worker through GPU residency and the sorted forward
lane in one small example.

`skinning3d.tl` constructs a two-joint procedural strip and updates its palette
directly. It isolates the optional GPU vertex-deformation path from file
loading and clip sampling.

`animated3d.tl` loads Robin Lamb's CC0 low-poly hero, creates an independently
posed model instance, and cycles authored skeletal clips under a shadowed
Cook-Torrance directional light. It demonstrates public glTF loading, PBR
materials, animation sampling, GPU skinning, and lighting in one scene.

`morph3d.tl` loads a glTF morph target and weight animation, then samples it
into an instance-owned GPU weight vector. Geometry and clip data remain shared;
only the changing weights belong to the instance.

`sponza3d.tl` uses the ignored large-asset cache populated by `cargo xtask
fetch sponza`. The fetch is pinned to one Khronos glTF Sample Assets revision
and retains the upstream notice. It also preprocesses source images into full
BC3 mip chains and writes a derived glTF. The demo keeps those textures
compressed in GPU memory and exercises double-sided materials, independently
GPU-culled primitive chunks, Cook-Torrance point and spot lights, directional
shadows, fog, and bloom. Running the example without that cache fails before
opening a window and reports the fetch command.

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
cargo xtask fetch bistro
cargo xtask example bistro3d
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

`morph3d.tl` loads an indexed 3D cube with two glTF morph targets and cycles it
through tall tapered and low twisted silhouettes. It samples the authored
weight animation into an instance-owned GPU vector. Geometry and clip data
remain shared; only the changing weights belong to the instance. A directional
light and receiving floor make both the changing volume and shadow visible.

`sponza3d.tl` uses the ignored large-asset cache populated by `cargo xtask
fetch sponza`. The fetch is pinned to one Khronos glTF Sample Assets revision
and retains the upstream notice. It also preprocesses source images into full
BC3 mip chains and writes a derived glTF. The demo keeps those textures
compressed in GPU memory and exercises double-sided materials, independently
GPU-culled primitive chunks, Cook-Torrance point and spot lights, directional
shadows, fog, and bloom. Running the example without that cache fails before
opening a window and reports the fetch command. Click the scene to capture the
mouse, use WASD to move, Q and E to change height, hold Shift to sprint, and
press Tab to release the mouse. Escape quits. The window title reports rolling
FPS, and the lower bloom threshold makes bright lit surfaces visibly spread.
Both large scenes default to immediate presentation so this number is uncapped;
set `TECS_PRESENT=vsync` to opt back into synchronized presentation.

`bistro3d.tl` is the large-scene stress test. Its pinned CC BY 4.0 Amazon
Lumberyard exterior is fetched through a reference-Draco preprocessing step,
then retained as 132 MiB of ordinary glTF geometry and 91 MiB of 512px BC3
mip chains. Large-primitive splitting turns 1,591 authored primitives into
1,593 independently GPU-cullable chunks. The demo combines an ambient-cube
probe, Cook-Torrance local lights, directional shadows, fog, and bloom. The
source GLB is removed after a successful import, and running without the cache
reports the fetch command before a window opens.

The Bistro demo uses the same free-fly controls as Sponza. It moves faster to
cover the exterior's larger authored scale. The controller is noclip by
design, so neither scene adds render geometry to Rapier merely for navigation.
Its title reports FPS and its bloom profile is tuned for the exterior's small
emissive lamps and bright Cook-Torrance highlights.

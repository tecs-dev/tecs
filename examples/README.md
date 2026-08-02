# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example shadows3d
cargo xtask example ibl3d
cargo xtask example gltf3d
cargo xtask example skinning3d
cargo xtask example animated3d
cargo xtask example morph3d
cargo xtask fetch sponza
cargo xtask example sponza3d
cargo xtask fetch bistro
cargo xtask example bistro3d
```

Every 3D example uses the same free-fly controls. Click its 3D view to capture
the mouse, use WASD to move, Q and E to change height, hold Shift to sprint,
and press Tab to release the mouse. Escape quits. In `scene3d`, the controller
moves the primary left view while the secondary right view remains fixed for
comparison.

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` draws the same Cook-Torrance scene through two ordered 3D views,
then composes one full-frame 2D HUD view above them. It also combines vertex
colors, an emissive unlit mesh, directional shadows, fog, and bloom.

`shadows3d.tl` places procedural pillars and their receiving ground across all
three stabilized directional-shadow cascades. Walking the long corridor makes
near detail, far coverage, boundary cross-fades, and camera-motion stability
easy to inspect. Its sky uses the repository-owned CC0 environment faces.

`ibl3d.tl` loads six repository-owned CC0 environment faces, generates their
mip chain on the GPU, and compares five roughness levels across metallic and
dielectric Cook-Torrance materials. The same environment is visible as the sky
and in reflections, so face orientation and camera-relative reflection remain
easy to verify while moving.

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
materials, animation sampling, GPU skinning, and lighting in one scene. An
instance-level placement turns the hero toward the camera, and the same scene
places the two-target morph cube beside him with an independent animation.

`morph3d.tl` loads an indexed 3D cube with two glTF morph targets and six
face-local colors, then rotates it while cycling through tall tapered and low
twisted silhouettes. It samples the authored weight animation into an
instance-owned GPU vector. Geometry and clip data remain shared; only the
changing weights belong to the instance. A directional light and receiving
floor make the colors, changing volume, and shadow visible.

`sponza3d.tl` uses the ignored large-asset cache populated by `cargo xtask
fetch sponza`. The fetch is pinned to one Khronos glTF Sample Assets revision
and retains the upstream notice. It also preprocesses source images into full
BC3 mip chains and writes a derived glTF. The demo keeps those textures
compressed in GPU memory and exercises double-sided materials, independently
GPU-culled primitive chunks, Cook-Torrance point and spot lights, directional
shadows, fog, and bloom. Running the example without that cache fails before
opening a window and reports the fetch command. The window title reports rolling
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

The Bistro demo moves faster than Sponza to cover the exterior's larger
authored scale. The controller is noclip by design, so neither scene adds
render geometry to Rapier merely for navigation. Scroll the mouse wheel up
toward day or down toward night; ambient and probe light, the directional sun
or moon, fog, and lamp intensity blend continuously. Its title reports FPS,
and quarter-resolution packed-HDR bloom gives its lamps a wider glow while
reducing the blur targets to one quarter of their former pixel count.

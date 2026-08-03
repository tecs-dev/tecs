---
description: "Build Tecs, return an application from an entry file, and register a first game plugin"
sidebar_order: 10
outline: deep
---

# Getting started

Tecs combines a typed entity component system with a game engine for Teal and
LuaJIT. Game state, rendering, audio, physics, and tools share the same world.

## Install the CLI

The [Tecs CLI](/cli/) carries the engine, project toolchain, template, and
offline reference:

```bash
tecs new my-game
cd my-game
tecs run
```

The generated `tecs.lua` marks the project root and names its entry file.
Project commands work from any directory below it.

## Build this repository

Contributors build the engine through Cargo:

```bash
git clone https://github.com/tecs-dev/tecs.git
cd tecs
cargo xtask deps
cargo xtask build
cargo xtask test
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
cargo xtask example morph3d
```

`cargo xtask deps` installs system development dependencies. The repository
pins Teal, the formatter, and tealdoc revisions for every checkout.

`--preset` selects a target. Development presets use system libraries. Package
presets build pinned dependencies from source:

```bash
cargo xtask presets
cargo xtask test   # run Rust, ABI, and Lua/Teal tests
cargo xtask package --preset macos-arm64
cargo xtask check-package out/package
```

## Entry file

The host owns the loop. The entry file returns an application:

```teal
return tecs.newApplication({
    window = {
        title = "Hello",
        width = 1280,
        height = 960,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        -- Register the game here.
    end,
})
```

The host loads `tecs` before the entry file, so game code uses it as a global.
A headless script or spec loads the same table explicitly:

```teal
local tecs <const> = require("tecs")
```

See [`tecs.Application`](/modules/Application) for lifecycle and configuration.

## First plugin

The entry plugin registers systems, observers, resources, and entities:

```teal
local Transform2D <const> = tecs.Transform2D

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers <const> = world:newQuery({
            include = {Transform2D},
        })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in movers:iter() do
                    local transforms <const> = archetype:getMut(Transform2D)
                    for row = 1, length do
                        transforms[row].rotation =
                            transforms[row].rotation + dt
                    end
                end
            end,
        })

        world:spawn(Transform2D(100, 100))
    end,
})
```

Keep three rules visible when writing systems:

- Create persistent queries during plugin setup.
- Read columns with `get` and mark written columns with `getMut`.
- Break or return from `query:iter()` freely; iteration owns no transaction
  scope or resource that needs cleanup.

The [mutation model](/modules/ecs/mutation-model) covers deferred changes and dirty
tracking.

## Optional transparent meshes

Opaque mesh rendering keeps its original three-pass cull chain. Enable the
separate transparent resources only when a game needs glTF `BLEND` materials
or registers an `ALPHA_BLEND` material itself:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        transparency = true,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        local loaded <const> = tecs.assets.loadGLTF(
            tecs.io.files.assetPath("models/glass.gltf")
        )
        -- Decoded scalar material factors remain caller-writable until the
        -- model is registered. This is useful for legacy converted assets.
        loaded.materials[1].roughness = 0.35
        local instance <const> = app.renderer.meshes
            :registerModel(loaded)
            :newInstance()
        for _, primitive in ipairs(instance.primitives) do
            world:spawn(
                primitive.transform,
                primitive.mesh,
                primitive.bounds,
                primitive.material,
                tecs.gfx.Tint(),
                tecs.gfx.Renderable3D()
            )
        end
    end,
})
```

The mesh domain frustum-culls and depth-sorts complete indexed commands on the
GPU. It draws transparent meshes before the sprite forward lane, so sprites
retain deterministic overlay ordering in a renderer that enables both domains.
The domain exposes registration methods, configuration, and residency counts;
its GPU buffers belong to the internal backend and are not part of the game
API.

## Vertex colors, fog, SSAO, bloom, and a 2D HUD

Enable each expensive lane explicitly and keep the base 2D and rigid-mesh
paths unchanged:

```teal
return tecs.newApplication({
    bloom = {
        scale = 0.5,
        threshold = 0.75,
        knee = 0.1,
        intensity = 0.65,
    },
    meshes = {
        vertexColors = true,
        fog = {
            start = 20,
            finish = 100,
            r = 0.12,
            g = 0.16,
            b = 0.24,
        },
        ssao = {
            scale = 0.5,
            radius = 0.9,
            bias = 0.025,
            intensity = 1.0,
            power = 1.5,
        },
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        tecs.gfx.layers.configure(16, {
            sort = "z",
            screenSpace = true,
            unlit = true,
            overlay = true,
        })

        -- The overlay flag selects the sprite forward lane. It runs after
        -- opaque and transparent meshes and after bloom composition, even
        -- when this tint is fully opaque.
        world:spawn(
            tecs.Transform2D(160, 40, 0, 16, 0, 280, 56),
            tecs.gfx.Tint(0.02, 0.04, 0.08, 1.0),
            tecs.gfx.Renderable2D()
        )
    end,
})
```

`assets.newMesh` accepts linear RGBA through `colors`; `assets.loadGLTF`
decodes normalized integer or float `COLOR_0` values in VEC3 or VEC4 form.
The color multiplies `Tint`, the material base-color factor, and the sampled
base-color texture. Its alpha therefore participates in `ALPHA_MASK` and
`ALPHA_BLEND` material policy. A colored mesh requires
`meshes.vertexColors = true`; omitting the option preserves the 48-byte base
vertex stream and creates no color buffer or shader variant.

Fog is linear camera-distance fog and applies after both metallic-roughness
and unlit material dispatch, in deferred and transparent mesh passes. Its
runtime fields are available on `app.renderer.meshes.fog`. Omitting
`meshes.fog` keeps the fog-free shaders and uniform path.

SSAO reconstructs opaque mesh positions from depth and samples the surrounding
world-space hemisphere. `scale` selects the two R8 target sizes and defaults to
0.5. `radius` and `bias` are world units; `intensity` and `power` control the
amount and contrast. Two edge-aware blur passes preserve depth and normal
boundaries, and linear upsampling avoids block-sized transitions at the default
half resolution. The result multiplies the material's authored occlusion before
lighting, so it affects ambient and environment light but not direct light.
Change the four runtime fields through `app.renderer.meshes.ssao`; changing
`scale` requires recreating the renderer. Omitting `meshes.ssao` allocates no AO
targets, sampler, uniforms, or pipelines. Transparent meshes and sprites remain
outside this opaque G-buffer effect. Run `cargo xtask example animated3d` and
press O to compare it on a CC0 animated character and floor.

Bloom preserves resolved opaque highlights in packed HDR, extracts them into
two scaled blur targets, and adds them before transparent meshes and sprites.
The packed lighting and blur formats retain values above white without using
more bytes per pixel than RGBA8. `threshold` and `knee` are non-negative HDR
brightness values. Omitting `bloom` declares no bloom targets or passes. A
light component has no visible geometry of its own, so it blooms the bright
opaque surfaces it illuminates rather than drawing a halo at its position.
Transparent lamps and UI remain outside this branch. Run `cargo xtask example
scene3d` for the complete mixed-domain setup.

## Multiple cameras

Set `maxViews` when creating the application, then spawn ordered `View`
components. A view may draw either domain or both. Coordinates are fractions
of the frame, so this is a two-player split with a 2D HUD composed last:

```teal
local View <const> = tecs.gfx.View
local left <const> = tecs.gfx.newCamera3D({z = 8})
local right <const> = tecs.gfx.newCamera3D({x = 4, z = 8})

world:spawn(View.new({camera3D = left, width = 0.5, order = 0}))
world:spawn(View.new({camera3D = right, x = 0.5, width = 0.5, order = 1}))
world:spawn(View.new({camera2D = app.renderer.sprites.camera, order = 2}))
```

```teal
return tecs.newApplication({
    maxViews = 3,
    meshes = {},
    plugin = game,
})
```

The renderer extracts scene instances once. Each view then reuses the same
G-buffer, visible lists, light tiles, and transparent intermediate in strict
sequence: cull, shade, composite, then overwrite for the next view. The
original path remains in use when `maxViews` is omitted, so a one-camera game
allocates no multi-camera target and records no extra composition pass.

Opaque and transparent metallic-roughness meshes use the same Cook-Torrance
direct-light function. Opaque meshes reconstruct world position from the
geometry depth target; transparent meshes already carry it from the vertex
stage. Roughness uses GGX, visibility uses Smith-Schlick, and Fresnel uses the
Schlick approximation. Sprite materials keep Lambert diffuse lighting: their
shape normals and one scalar parameter do not define a metallic-roughness PBR
surface, and the cheaper term stays isolated from every mesh shader variant.

## Local 3D lights and imported textures

Point and spot lights are another independently allocated mesh lane:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        lights = {
            capacity = 256,
            shadows = {capacity = 8, size = 256},
        },
        doubleSided = true,
        packTextures = false,
        mipmaps = true,
    },
    plugin = function(world: tecs.World)
        world:spawn(
            tecs.Transform3D.new({x = 2, y = 4, z = 1}),
            tecs.gfx.PointLight3D.new({
                radius = 12,
                r = 1.0,
                g = 0.6,
                b = 0.25,
                intensity = 18,
                flags = tecs.gfx.LIGHT_CASTS_SHADOWS,
            })
        )
        world:spawn(
            tecs.Transform3D.new({x = 0, y = 8, z = 2}),
            tecs.gfx.SpotLight3D.new({
                radius = 20,
                innerAngle = math.rad(18),
                outerAngle = math.rad(32),
                r = 0.7,
                g = 0.85,
                b = 1.0,
                intensity = 28,
                flags = tecs.gfx.LIGHT_CASTS_SHADOWS,
            })
        )
    end,
})
```

`PointLight3D` uses its transform position. `SpotLight3D` also rotates local
negative Z through the transform quaternion. Radius, color, intensity, and cone
angles are fixed-layout FFI fields. The renderer bins enabled lights into a
32-by-32 screen grid for every 3D view. Omitting `meshes.lights` creates no
queries, buffers, binning dispatch, bindings, or local-light shader variants.

Local shadows are a second opt-in under `meshes.lights`. The renderer chooses
the first flagged lights in stable extraction order, up to the configured
shadow capacity. Each selected point light renders six square cells in one
R16 atlas row; a spot light uses the first cell of its row. One conservative
GPU compaction per selected light removes instances outside its reach before
the point light's six faces or the spot cone rasterize. `bias` defaults to
0.002, and `softness` defaults to a 3-by-3 PCF radius of one texel. Omitting
`lights.shadows` allocates no atlas, matrices, indirect commands, sampler, or
shadowed local-light shader variants. Directional cascades remain the separate
`meshes.shadows` option.

An ambient-cube probe adds diffuse environment light without a texture sample:

```teal
meshes = {
    probe = {
        positiveX = {0.10, 0.12, 0.16},
        negativeX = {0.07, 0.08, 0.11},
        positiveY = {0.24, 0.30, 0.42}, -- sky
        negativeY = {0.04, 0.03, 0.02}, -- ground bounce
        positiveZ = {0.13, 0.10, 0.08},
        negativeZ = {0.07, 0.09, 0.12},
        intensity = 0.85,
    },
}
```

The six RGB faces are world-space irradiance and may exceed one. The shader
weights them by the squared components of each mesh normal, adds the result to
`ambientLight`, and applies ambient occlusion and the material's diffuse-metal
split. This is diffuse probe lighting. It remains useful as the lower-cost
option when glossy image-based reflections are unnecessary.
Assign through `app.renderer.meshes.probe` to change it at runtime. Omitting
`meshes.probe` adds no uniform data or fragment work and selects no probe
pipeline in a 2D or ordinary 3D application. Prebuilt releases currently
carry those optional variants in the shared shader pack.

Enable a sampled specular environment independently, then register its six
decoded RGBA8 faces. Each direct load waits appropriately for its context:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        environment = {
            size = 256,
            intensity = 1.4,
            skyboxIntensity = 1.0,
            rotation = 0.0,
        },
    },
    plugin = function(_world: tecs.World, app: tecs.Application)
        local names <const>: {string} = {
            "positive-x.png", "negative-x.png",
            "positive-y.png", "negative-y.png",
            "positive-z.png", "negative-z.png",
        }
        local face: {tecs.assets.Image} = {}
        for index, name in ipairs(names) do
            face[index] = tecs.assets.loadImage(
                tecs.io.files.assetPath("environment/studio/" .. name)
            )
        end
        app.renderer.meshes:registerEnvironment({
            positiveX = face[1], negativeX = face[2],
            positiveY = face[3], negativeY = face[4],
            positiveZ = face[5], negativeZ = face[6],
        })
    end,
})
```

Every face must be square, exactly `environment.size` pixels, and decoded as
RGBA8. Registration validates the complete set before replacing the six GPU
layers, consumes the images, and generates their mip chain. Material roughness
selects among those mips; the skybox always samples the sharpest level.
`app.renderer.meshes.environment` keeps `intensity`, `skyboxIntensity`, and
`rotation` caller-writable. Set `skyboxIntensity` to zero for reflections over
another background. Omitting `meshes.environment` creates no environment
texture, sampler, upload staging, or sampled binding. Run `cargo xtask example
ibl3d` to compare five roughness values on metallic and dielectric spheres
under six repository-owned CC0 faces.

Ordinary glTF images decode to RGBA8. Unpacked mipmapped arrays accept smaller
images by repeating their edge through the rest of the fixed layer before GPU
mip generation, so neighboring texels never bleed into the sampled UV region.
For a large imported scene, select an offline-compressed array instead:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        textureWidth = 1024,
        textureHeight = 1024,
        textureLayers = 72,
        textureFormat = tecs.assets.IMAGE_BC3,
        packTextures = false,
        mipmaps = true,
    },
    plugin = game,
})
```

`cargo xtask fetch sponza` downloads a pinned Khronos scene, retains its
upstream notice, and writes `Sponza.tecs.gltf` plus complete BC3 mip chains in
standard KTX2 containers under the ignored `assets/external` cache. BC3 uses
one quarter of RGBA8 texture memory including equivalent mip chains. Creation
raises if the selected GPU
cannot sample BC3 arrays; it never silently decodes into a larger fallback.
The format option uses an integer constant and affects only the mesh array.

Every authored glTF primitive becomes an independent bounded culling command.
The worker additionally splits any primitive above 65,536 triangles, remaps
only the vertices that each chunk references, and preserves color, skin, and
morph streams. This keeps a million-triangle source primitive from becoming
one all-or-nothing frustum test. Meshoptimizer then improves vertex-cache and
vertex-fetch locality inside each command, remapping every optional vertex
stream together. Alpha-blended commands retain authored triangle order and use
only the lossless fetch remap.
Run `cargo xtask example sponza3d` for double-sided materials, compressed
mipmaps, point and spot lights, shadows, fog, and bloom together. The example
command reports the required fetch command before opening a window when its
ignored scene cache is absent.

Every 3D example installs `tecs.gfx.FlyCamera3D` as an ordinary Update-phase
system. Click to enter relative mouse mode, move with WASD, change height with
Q and E, hold Shift to sprint, press Tab to release the pointer, and press
Escape to quit. The split-screen `scene3d` example moves its primary left
camera and leaves its secondary right camera fixed for comparison. This is
noclip movement with no collision or gravity, which keeps scene navigation
independent from Rapier. Sponza and Bistro additionally set `showFps`, which
refreshes a rolling FPS reading in the window title twice per second without
enabling the sprite domain. They default to immediate presentation and accept
`TECS_PRESENT=vsync` as an override.

`cargo xtask fetch bistro` downloads and verifies the pinned CC BY 4.0 Amazon
Lumberyard exterior, decodes its older Draco stream with the reference codec,
reconstructs two-channel normal maps, downsamples textures into 512px BC3 KTX2
mip chains, and removes the 986 MB source after producing a roughly 227 MB
ignored cache. Run `cargo xtask example bistro3d` to exercise 2.9 million vertices,
8.5 million indices, 1,593 independently culled chunks, the ambient probe,
local lights, shadows, fog, and bloom together.

The Bistro example starts near late afternoon. Scroll the mouse wheel up
toward day or down toward night. The control continuously blends ambient and
probe light, the directional sun or moon, fog, and the four lamp lights
without rebuilding renderer resources.

## Optional mesh shadows

Enable the mesh domain's directional light and shadow resources at renderer
creation:

```teal
return tecs.newApplication({
    ambientLight = {0.12, 0.13, 0.16},
    sprites = false,
    meshes = {
        shadows = {
            scale = 1,
            distance = 40,
            splitLambda = 0.7,
            splitBlend = 0.1,
            depthPadding = 20,
            directionX = -0.45,
            directionY = -1,
            directionZ = -0.3,
            intensity = 1.4,
            strength = 0.85,
            softness = 1.5,
        },
    },
    plugin = function(_world: tecs.World, app: tecs.Application)
        -- Everything except scale remains mutable after creation.
        app.renderer.meshes.shadow.bias = 0.002
    end,
})
```

`scale` fixes all three map sizes and is creation-only. The other fields are
copied to `app.renderer.meshes.shadow` and may change between frames.
`distance` is the maximum camera depth that receives directional shadows.
`splitLambda` distributes resolution between near detail and even depth
coverage, `splitBlend` cross-fades boundaries, and `depthPadding` retains
casters beyond each receiver slice along the light direction. Meshes outside
each stabilized cascade volume are removed by the same ordered GPU mark, scan,
and compact shape used for camera culling. Each light-space center snaps to its
map's texel grid, so translating the camera does not slide shadow samples
across stationary receivers. Culling rejects complete mesh instances; one
surviving mesh still draws its full resident index range. Opaque and masked
materials cast and receive. Blended materials receive but do not cast.

Omitting `meshes.shadows` preserves the shadow-free mesh shaders and allocates
no maps, shadow command buffers, cull pipeline, or graphics pipeline. The 2D
`shadows` application option remains a separate occluder and drop-shadow
system.

## Optional GPU skinning

Enable skeletal deformation separately from rigid mesh rendering:

```teal
local IDENTITY <const>: {number} = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
}

return tecs.newApplication({
    sprites = false,
    meshes = {
        skinning = {jointCapacity = 4096},
    },
    plugin = function(_world: tecs.World, app: tecs.Application)
        local skin <const> = app.renderer.meshes:registerSkin(
            "models/hero#pose",
            IDENTITY
        )
        -- Spawn `skin` beside Mesh, Bounds3D, MeshMaterial, Tint, and
        -- Renderable3D. Call updateSkin with the same matrix count later.
    end,
})
```

`assets.newMesh` accepts four joint indices and four weights per vertex through
its separate `joints` and `weights` arrays. `assets.loadGLTF` decodes
`JOINTS_0`, `WEIGHTS_0`, skins, and inverse bind matrices. `registerModel`
returns shared residency, and each `newInstance` registers independent
palettes. Spawn `primitive.skin` beside the rest of a skinned primitive bundle.

`updateSkin` stages complete column-major palettes into the next frame rather
than submitting a GPU command buffer per call. Joint matrices deform positions,
normals, tangents, and shadow casters. Culling still uses the entity's
`Bounds3D`, so animated content must supply a sphere large enough for every
pose it can reach.

Omitting `meshes.skinning` preserves the rigid vertex and instance layouts and
allocates no skin attributes, palette offsets, joint matrices, or skinned
shader variants. Run `cargo xtask example skinning3d` for a two-joint example
and `cargo xtask bench meshskinning` with `BENCH_MESH_SKINNING=0` and `=1` to
measure the isolated lane.

## Optional GPU morphing

Enable morph deformation independently from rigid meshes and skinning:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        morphing = {
            vertexCapacity = 1048576,
            weightCapacity = 65536,
        },
    },
    plugin = function(_world: tecs.World, app: tecs.Application)
        local morph <const> = app.renderer.meshes:registerMorph(
            "models/face#expression",
            {0, 0, 0}
        )
        -- Spawn `morph` beside a mesh with three registered targets. Later,
        -- update the same three weights with `updateMorph`.
    end,
})
```

`assets.newMesh` accepts target-order position deltas and optional normal and
tangent deltas. `assets.loadGLTF` decodes the equivalent glTF targets, mesh and
node default weights, and linear, step, or cubic-spline weight animation.
`registerModel` gives every `newInstance` private reusable weight vectors; spawn
`primitive.morph` beside each morphed primitive.

When a glTF primitive has texture coordinates but no authored tangents, the
importer generates MikkTSpace tangents. It splits vertices at tangent
discontinuities and remaps color, skin, and morph data with them, so normal-map
seams remain correct without requiring an offline repair step.

Morph deltas are immutable GPU residency. A five-float record locates each
instance's geometry and weights, and complete weight vectors are staged only
when registered or updated. Morphing runs before skinning when both options are
enabled. A domain with both options appends the skin offset to that record,
allowing vertex colors, morphing, and skinning to coexist within the backend's
eight vertex-storage-buffer limit. `newMesh` and the glTF decoder
conservatively enlarge bounds for weights from zero through one; negative or
extrapolated weights require a larger caller-supplied `Bounds3D`.

Omitting `meshes.morphing` preserves the rigid and skin-only layouts and
allocates no target, locator, weight, or morph-shader resources. Run
`cargo xtask example morph3d` for the worker-to-GPU path. The example cycles an
indexed cube between tall tapered and low twisted targets under a directional
light, so its silhouette, highlights, and shadow all expose the deformation.
Compare
`BENCH_MESH_MORPHING=0` with `=1` under
`cargo xtask bench meshmorphing` to measure the isolated lane.

## Animated glTF instances

`loadGLTF` decodes translation, rotation, scale, and morph-weight channels
using core glTF linear, step, and cubic-spline interpolation. A resident
`Model3D` shares that immutable clip data while each instance keeps its own
reusable pose, joint palettes, and morph vectors:

```teal
local loaded <const> = tecs.assets.loadGLTF("models/hero.gltf")
local model <const> = app.renderer.meshes:registerModel(loaded)
local instance <const> = model:newInstance()
for index, primitive in ipairs(instance.primitives) do
    local entity <const> = world:spawn(
        primitive.transform,
        primitive.mesh,
        primitive.bounds,
        primitive.material,
        primitive.skin,
        primitive.morph,
        tecs.gfx.Tint(),
        tecs.gfx.Renderable3D()
    )
    instance:bind(world, index, entity)
end
instance:play("Walk")
```

Call `instance:update(dt)` from a system to advance playback, or
`instance:sample("Walk", time)` for deterministic explicit sampling. Sampling
reuses its tables, composes a caller-writable `instance.transform` after the
authored hierarchy, updates bound `Transform3D` components, and stages complete
joint palettes without submitting a command buffer. Assign a transform to
place, turn, or scale the complete instance without changing its shared model
or clip; its default nil value preserves the authored placement and skips the
composition. The `Bounds3D` component is still caller-owned and must enclose
every pose. Run
`cargo xtask example animated3d` to see a CC0 character cycle skeletal clips
facing the camera beside an independently placed, six-color morph animation
under a shadowed Cook-Torrance directional light, and run
`cargo xtask bench modelanimation` for CPU sampling cost and heap growth.

## Game modules

Split a game into plugins and install them from the entry plugin:

```teal
local movement <const> = require("game.movement")
local enemies <const> = require("game.enemies")

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        world:addPlugin(movement.plugin)
        world:addPlugin(enemies.plugin)
    end,
})
```

The host adds the project content root to `package.path`, so
`require("game.enemies")` loads `game/enemies.lua`.

## Next pages

- [tecs.ecs](/modules/ecs/) introduces worlds, components, queries, and systems.
- [Modules](/modules/) lists every public engine module.
- [Tecs CLI](/cli/) covers project commands and the offline reference.

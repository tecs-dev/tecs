# tecs

Tecs is a typed entity component system and 2D/3D game engine for LuaJIT,
written in Teal and built on SDL3, SDL_GPU, and Rapier. Entities are the
interface: anything that updates or renders belongs to a world.

The Rust host owns the SDL lifecycle. A game entry returns an application:

```lua
return tecs.newApplication({
    window = { title = "game", width = 1280, height = 720 },

    plugin = function(world)
        world:addSystem({
            name = "game.Tick",
            phase = tecs.ecs.phases.Update,
            run = function(dt)
                -- Update game state.
            end,
        })
    end,
})
```

Games can use the global `tecs` table, or `require("tecs")` in headless tools
and specs. The engine is loaded lazily, so simulation code does not need to
start a graphics stack.

## Features

- Typed ECS with archetype queries, plugins, state stacks, snapshots, and
  deterministic random streams.
- GPU-driven 2D rendering with materials, lights, shadows, layers, text,
  sprite animation, and particles.
- Optional 3D rendering with indexed mesh residency, ordered GPU frustum
  culling, texture and PBR material residency, glTF/GLB skinning and animation,
  large-primitive chunking, and independently allocated transparent,
  double-sided, directional-shadow, point/spot-light, skeletal, morph-target,
  vertex-color, fog, ambient-probe, mipmapped-texture, and BC3 texture lanes.
- Optional packed-HDR bloom at a caller-selected scale, composed before
  transparent meshes and the 2D forward lane so a mixed renderer can keep its
  HUD crisp.
- Input, audio, physics, assets, workers, async I/O, HTTP, file watching, and
  a debug server.

General post-processing and tiled maps are not yet built.

## Structural mutation

Tecs uses one deferred structural model. Systems in a phase stage spawns,
despawns, additions, removals, bundles, and batches together; the scheduler
publishes them at the phase boundary. A system can declare `commitBefore` or
`commitAfter` when it unconditionally needs an extra boundary. A conditional
`enqueueCommit` request made during a system is honored only after that system
returns, before the next one runs; outside system dispatch it settles
synchronously for tests and debug tooling. Mutation itself never switches to
an eager path.

Value access stays direct. `getMut` marks and returns a live component because
changing its fields cannot move the entity between archetypes. Replacing an
existing component value through `set` takes the same immediate path. This
keeps the common simulation loop cheap without maintaining a second structural
mutation implementation.

Mesh shadows use one camera-centered directional map, not the 2D occluder-mask
pipeline. Their mark, scan, compact, map, and shader resources exist only when
the mesh domain opts in. Shadow culling reuses the ordered GPU compaction
shape: off-camera casters inside the light volume remain, while instances
outside that volume submit no geometry to the shadow raster pass. A surviving
mesh still submits its complete resident index range; this is instance culling,
not per-triangle culling inside one mesh. The camera center snaps in light
space to the map's texel grid so movement does not slide stationary shadows
between samples.

Mesh skinning follows the same isolation rule. Rigid meshes retain the fixed
48-byte vertex and 64-byte instance records. `meshes.skinning` adds separate
joint/weight, per-instance palette-offset, and joint-matrix buffers and selects
a skinned vertex-shader variant. That costs no additional vertex bandwidth or
shader branch in a domain that omits the option, and it adds nothing to a 2D
renderer.

Mesh morphing is independently optional as well. `meshes.morphing` adds an
immutable position/normal/tangent delta buffer, a five-float per-instance
locator, retained weight vectors, and morph shader variants. The rigid and
skin-only layouts do not change when it is omitted. Morphing runs before
skinning when both lanes are enabled, matching glTF deformation order. A
combined domain appends the skin offset to that locator instead of binding a
second per-instance buffer, keeping vertex colors plus both deformation lanes
inside SDL's eight-storage-buffer vertex-stage limit. Morph-only and skin-only
domains retain their smaller metadata records.

Vertex colors follow the same rule. `meshes.vertexColors = true` adds one
separate RGBA stream and matching geometry and shadow shader variants; rigid
geometry keeps its 48-byte base stride. `meshes.fog` adds linear,
camera-distance fog to mesh variants only. Top-level `bloom` adds two scaled
packed-HDR targets and three fullscreen passes only when configured. Packed
R11G11B10 keeps highlights above white at the same four bytes per pixel as the
ordinary RGBA8 lighting target. None of the three changes the resources or
shaders of a 2D-only renderer.

Mesh images follow that isolation rule too. Unpacked RGBA8 arrays can generate
complete mip chains on the GPU. An explicitly selected BC3 array instead
uploads importer-built chains without expanding them in GPU memory. The
Sponza fetch command is both a pinned cache and a deterministic import step;
it leaves source and derived files ignored while retaining the upstream
notice. The glTF worker also remaps primitives above 65,536 triangles into
independently bounded culling commands, so one oversized source range does not
turn instance culling into an all-or-nothing million-triangle draw.

Mesh residency is intentionally owned below the public domain. Games register
geometry, textures, and materials through `MeshDomain` and observe compact
counts, while only the backend can reach the raw GPU buffers. Draw-resource
handle lists are assembled once with that residency instead of being rebuilt
for the shadow, deferred, and transparent passes every frame.

Point and spot lights also live behind one mesh option. Their component queries,
record buffer, screen-tile lists, compute dispatch, bindings, and Cook-Torrance
shader variants do not exist in a mesh domain that omits `lights`, and no part
of that path enters a 2D-only renderer.

The first environment-lighting lane is an ambient cube rather than a sampled
cubemap. Six world-space irradiance colors preserve broad directional light
without adding a texture, sampler, or shader branch to a domain that omits the
probe. It intentionally covers only the diffuse PBR lobe. Glossy reflections,
local reflection volumes, and authored lightmaps remain separate future lanes
instead of making this baseline probe expensive.

The probe variants are pipeline-isolated but not yet package-isolated. The
shared shader pack carries them even when a 2D application never selects one,
so splitting or lazily decoding shader domains remains packaging work rather
than a steady-frame rendering cost.

A mixed renderer keeps HUD work in the sprite domain. A highest,
screen-space, unlit layer with `overlay = true` routes even fully opaque 2D
content through the existing sorted forward lane after meshes and bloom. It
adds no second sprite renderer and no overlay resources to an ordinary layer.

Animated glTF models keep shared geometry, material, texture, hierarchy, and
clip data in one `Model3D`. Each `newInstance` allocates only its own reusable
CPU pose and fixed GPU joint palettes and morph vectors, so instances can play
different clips.
Sampling supports linear, step, and cubic-spline channels, stages palettes
through the existing skin upload, optionally composes caller-owned instance
placement after the shared authored hierarchy, and writes only explicitly
bound entity transforms. Nil placement retains the direct transform path. It
adds no system or per-frame work to a model that is never sampled.

## Build

Cargo and `xtask` own the build, generated bindings, tests, and packaging.
Run `cargo xtask deps` once to install and stage development dependencies, then:

```bash
cargo xtask build              # Build the host development preset
cargo xtask example ui-demo    # Run the 2D showcase
cargo xtask example scene3d    # Run the split-screen Cook-Torrance example
cargo xtask example gltf3d     # Run the textured 3D example
cargo xtask example skinning3d # Run the GPU skeletal-deformation example
cargo xtask example animated3d # Run the CC0 animated and lit glTF hero
cargo xtask example morph3d    # Run decoded glTF morph-weight animation
cargo xtask fetch sponza       # Cache the pinned large lighting scene
cargo xtask example sponza3d   # Run point and spot lights in Sponza
cargo xtask fetch bistro       # Import the pinned large Bistro stress scene
cargo xtask example bistro3d   # Run Bistro with probe and direct lighting
cargo xtask bench meshshadows  # Measure the optional mesh-shadow lane
cargo xtask bench meshskinning # Measure the optional mesh-skinning lane
cargo xtask bench meshmorphing # Measure the optional mesh-morphing lane
cargo xtask bench modelanimation  # Measure CPU pose and palette sampling
cargo xtask test               # Run the spec suite
cargo xtask check              # Type-check Teal sources
cargo xtask format             # Format sources
cargo xtask docs-check         # Validate the documentation site
cargo xtask package --preset macos-arm64
cargo xtask check-package out/package
```

`--preset` selects a platform and defaults to the host development preset.
Use `cargo xtask presets` to list available targets. Packaged presets build
pinned dependencies for distributable releases; development presets use the
system libraries.

## Documentation

The API reference and guides live in [`docs/`](docs/). Serve them locally with
`cargo xtask docs-dev`. Public API documentation lives beside its Teal
declarations under [`src/tecs/`](src/tecs/).

The source layout and project conventions are documented in
[`AGENTS.md`](AGENTS.md). Design notes live in the adjacent `../tecs-plans`
repository.

## Requirements

Rust/Cargo, LuaJIT, SDL3, SDL3_mixer, shaderc, SPIRV-Cross, zlib, and Teal.
`rust-toolchain.toml` selects the Rust version; `cargo xtask deps` installs the
development dependencies managed by the project.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for dependency notices.

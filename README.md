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
  and independently allocated transparent, directional-shadow, skeletal, and
  morph-target deformation, vertex-color, and fog lanes.
- Optional half-resolution bloom composed before transparent meshes and the
  2D forward lane, so a mixed renderer can keep its HUD crisp.
- Input, audio, physics, assets, workers, async I/O, HTTP, file watching, and
  a debug server.

General post-processing, tiled maps, and multi-camera are not yet built.

Mesh shadows use one camera-centered directional map, not the 2D occluder-mask
pipeline. Their mark, scan, compact, map, and shader resources exist only when
the mesh domain opts in. Shadow culling reuses the ordered GPU compaction
shape: off-camera casters inside the light volume remain, while instances
outside that volume submit no geometry to the shadow raster pass. A surviving
mesh still submits its complete resident index range; this is instance culling,
not per-triangle culling inside one mesh.

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
skinning when both lanes are enabled, matching glTF deformation order.

Vertex colors follow the same rule. `meshes.vertexColors = true` adds one
separate RGBA stream and matching geometry and shadow shader variants; rigid
geometry keeps its 48-byte base stride. `meshes.fog` adds linear,
camera-distance fog to mesh variants only. Top-level `bloom` adds two scaled
targets and three fullscreen passes only when configured. None of the three
changes the resources or shaders of a 2D-only renderer.

A mixed renderer keeps HUD work in the sprite domain. A highest,
screen-space, unlit layer with `overlay = true` routes even fully opaque 2D
content through the existing sorted forward lane after meshes and bloom. It
adds no second sprite renderer and no overlay resources to an ordinary layer.

Animated glTF models keep shared geometry, material, texture, hierarchy, and
clip data in one `Model3D`. Each `newInstance` allocates only its own reusable
CPU pose and fixed GPU joint palettes and morph vectors, so instances can play
different clips.
Sampling supports linear, step, and cubic-spline channels, stages palettes
through the existing skin upload, and writes only explicitly bound entity
transforms. It adds no system or per-frame work to a model that is never
sampled.

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

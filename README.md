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
  vertex-color, fog, ambient-probe, specular-environment, mipmapped-texture,
  KTX2 BC3 texture, and screen-space ambient-occlusion lanes.
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

Development shader compilation is one optional Rust service rather than two
LuaJIT FFI bindings. Cargo owns shaderc and SPIRV-Cross, and the Teal side sees
only compiled code plus reflected SDL_GPU resource counts. Naga cannot replace
that stack while Tecs authors combined `sampler2D` resources: its GLSL frontend
requires separate textures and samplers, and its SPIR-V frontend rejects the
combined sampled-image modules shaderc produces for SDL_GPU's Vulkan binding
contract. Packaged builds compile none of this toolchain and load the generated
shader pack instead.

### Dependency ownership

SDL3 is the only platform and GPU execution layer. It owns windows, events,
input, audio devices, dialogs, storage integration, GPU resources, command
submission, and presentation. A Rust crate must not introduce a second
abstraction for any of those responsibilities.

Maintained Rust crates own published formats and established coarse CPU
algorithms. The `gltf`, `glam`, `bevy_mikktspace`, `meshopt`, and `ktx2` crates
parse and prepare a complete model or texture inside a bounded asset job.
Shaderc and SPIRV-Cross compile one complete shader only in development and
single-file tool builds. No crate is called per entity, vertex, or draw during
a frame.

Tecs owns engine policy and hot data: the ECS and lifecycle, extraction, frame
packets, render domains, pass graph, material dispatch, resource residency,
GPU culling, and ordered scans. Crate-specific owners stay behind flat native
views; the public Teal API describes images, models, materials, and shaders,
not library handles.

The sprite and mesh domains publish one statistics contract and contribute to
one aggregate extraction measurement, while their domain-specific timings,
packets, residency, culling outputs, and draw paths remain separate. Identical
GPU algorithms live in shader includes; a similar-looking dimensional
algorithm stays specialized until its data and output contracts are actually
the same.

Every product build writes its exact resolved Rust graph to
`cargo-dependencies.txt`. Packaged releases install that inventory beside the
third-party notice. `cargo xtask check-package` verifies that every dependency
is named in the notice and that compiler-only crates are absent from release
presets.

Mesh shadows use three camera-frustum directional cascades, not the 2D
occluder-mask pipeline. Their mark, scan, compact, map, and shader resources
exist only when the mesh domain opts in. Each cascade reuses the ordered GPU
compaction shape: off-camera casters inside its light volume remain, while
instances outside it submit no geometry to that shadow raster pass. A
surviving mesh still submits its complete resident index range; this is
instance culling, not per-triangle culling inside one mesh. Every light-space
center snaps to its map's texel grid, and adjacent cascades cross-fade, so
movement does not slide stationary shadows between samples or expose hard
split lines.

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

Mesh screen-space ambient occlusion is another isolated branch. It
reconstructs opaque positions from the existing depth and normal targets,
writes and edge-blurs scaled R8 visibility, then multiplies only the authored
ambient-occlusion channel before lighting. That reuses the existing PBR
contract instead of adding SSAO branches or samplers to every lighting shader.
Its sample rotation is anchored in world space so camera translation does not
rotate the pattern across stationary geometry. Omitting `meshes.ssao` keeps its
two targets, linear upsampling sampler, uniforms, and three pipelines absent.
Sprites, transparent meshes, and direct light are not darkened by it.

Mesh images follow that isolation rule too. Unpacked RGBA8 arrays can generate
complete mip chains on the GPU. An explicitly selected BC3 array instead
uploads KTX2 mip chains without expanding them in GPU memory. KTX2 parsing and
validation belong to the maintained Rust crate; SDL_GPU still owns upload and
sampling. The Sponza fetch command is both a pinned cache and a deterministic
import step;
it leaves source and derived files ignored while retaining the upstream
notice. The glTF crate parses and validates models in Rust on the asset worker,
glam supplies transform math, and the maintained MikkTSpace implementation
generates normal-map tangents when a primitive omits them. Tangent seams split
vertices and remap every optional stream before residency. The worker returns
one opaque native owner, not serialized geometry strings; the main thread
borrows flat vertex and index views until registration finishes. The importer
also remaps primitives above 65,536 triangles into independently bounded
culling commands, so one oversized source range does not turn instance culling
into an all-or-nothing million-triangle draw. Meshoptimizer improves vertex
cache and fetch locality independently inside each command. Alpha-blended
commands preserve authored triangle order because their result is
order-dependent.

Mesh residency is intentionally owned below the public domain. Games register
geometry, textures, and materials through `MeshDomain` and observe compact
counts, while only the backend can reach the raw GPU buffers. Draw-resource
handle lists are assembled once with that residency instead of being rebuilt
for the shadow, deferred, and transparent passes every frame.

Point and spot lights also live behind one mesh option. Their component queries,
record buffer, screen-tile lists, compute dispatch, bindings, and Cook-Torrance
shader variants do not exist in a mesh domain that omits `lights`, and no part
of that path enters a 2D-only renderer. Local shadows are a nested option rather
than a mandatory light cost. Flagged lights occupy stable rows in one R16 atlas:
a point light uses six columns and a spot light uses the first. Each selected
light runs one conservative GPU compaction, then reuses that visible command
across its faces. This avoids six culling passes per point light and binds one
atlas sampler instead of one texture per light. Omitting `lights.shadows` keeps
the atlas, matrices, indirect commands, sampler, and shadowed variants absent.

Environment lighting has two costs rather than one compromise. The ambient
cube keeps six world-space irradiance colors and shades only the diffuse PBR
lobe without allocating a texture or sampler. The independently enabled
specular environment owns six mipmapped RGBA8 faces; roughness selects a mip
and an analytic split-sum BRDF fit supplies the Fresnel response. It can also
draw the same faces as the sky. A domain that omits `environment` allocates and
binds none of those image resources, while the two options share one existing
probe shader family rather than multiplying the variant matrix. Authored GGX
prefiltered mip chains, local reflection volumes, and lightmaps remain later
extensions of the sampled lane instead of making the ambient cube expensive.

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

## Async design

Asynchronous operations return their values directly. A system does not choose
between a callback, a future, and a coroutine API. During `world:update`, Tecs
runs the logical update in one persistent coroutine. An operation that must
wait parks that coroutine at the call site; an operation that is ready returns
inline. The application keeps pumping I/O and may render the last completed
world state until the update resumes in the same system and schedule position.

The coroutine belongs to the world update, not to an entity or an I/O call.
This keeps entity loops from creating a task per spawn and amortizes the
coroutine and scheduler state across frames. Startup, shutdown, and calls made
outside `world:update` use the same direct-value API and block while pumping
the producer. Completion-backed calls retain a finite producer-specific wait
budget and fail at the direct call when it expires; socket reads instead wait
for input or closure, and readiness methods honor caller timeouts. Private
completion state may bridge a native worker queue, but it is not a second
user-facing execution model.

A task that fails reports to whoever owns it, not to whoever eventually asks.
Waiting for a join meant a failed producer was invisible to a parent parked on
the wait that producer was supposed to satisfy, and the program hung with
nothing to read; the failure was there the whole time with no one holding it.
So a child failure is delivered to the owning task at whatever it is parked on.
The one exception is an owner already parked on a join, because it is reading
its children itself and a second delivery would report the same failure twice
and cut across the order it reads them in. `tecs.batch` is that owner: it joins
callbacks in the order the caller gave them, and its first failure still
cancels the rest, waits for them to unwind, and raises. Cancellation stays a
separate outcome from failure, so ending a scope normally still unwinds its
children without failing anything.

A world update that stays suspended says so. `world:update` counts consecutive
suspended updates and, after about five seconds of them, logs what the update
is ultimately parked on and repeats about once a minute. A wait nothing
completes is indistinguishable from a hung process otherwise, and the runtime
already knows the answer.

Resource ownership remains lexical across those waits. Every `tecs.scoped`
callback has a required name, keeps its registered values live while its
system is parked, and closes them in reverse order when it unwinds. The same
name is its profiler zone when profiling is active and costs no zone-stack
mutation when profiling is off, so cleanup failures and suspended work share
one diagnostic identity without taxing the ordinary path.

The producer still matches the work. TCP, UDP, and process pipes try their
syscall first and use a process-wide `mio` readiness reactor only after
`WouldBlock`; no worker thread sits waiting on a handle. A caller that blocks
instead of parking waits on the descriptor in the kernel through `poll` or
`WSAPoll`, so a headless tool, a spec, or a startup path pays one wakeup for
readiness rather than a retry per millisecond, and a timeout still expires when
the caller asked it to. One bounded Tokio
service resolves names and establishes connections. Regular-file transfers
use a bounded SDL AsyncIO queue, uncovered file operations use a separate
bounded blocking lane, and image decoding uses a bounded CPU lane. A file used
as an HTTP request body is already owned by Tokio's transport lifetime, so that
path opens and streams the file there instead of loading it into Lua and then
copying it back across the HTTP boundary. Every path settles onto the same
Lua-thread continuation, so that implementation split does not create a second
game API or let CPU work starve I/O progress.

A worker is the one producer a game writes itself, and it follows the same
rule rather than an exception for user code. `Worker:receive` polls by default,
and a wait suspends the calling system and resumes it from the process pump.
The alternative was the blocking pop the channel already offers, which is what
this replaced: it is correct on the worker's own thread and wrong on the one
SDL drives, and no amount of documentation stops a system from reaching for it.
Cooperative delivery costs up to a frame of latency per message, which is the
same price every other producer here pays and the reason polling stays the
default. The worker closes its outbox when its source ends, because a spawner
parked on a result otherwise cannot tell an idle worker from one that has
already exited, and the difference between those two is a wait that ends and a
wait that does not.

Byte contracts are contextual. Memory Readers, Writers, buffers, and
transforms return inline. A socket or process-pipe endpoint first uses that
same direct call and parks only when the handle is not ready. File endpoints
wait through SDL AsyncIO. HTTP returns at headers and exposes an independently
bounded, one-shot streaming body per transfer, so abandoning one body cannot
obstruct another request's headers or body. Outside a resumable world update
these calls block their caller while advancing only the producer they need.
There is no public runtime pump or nonblocking twin to keep in sync.

A transfer holds its connection slot until its body ends rather than releasing
it once the headers arrive. The slot is what bounds open sockets, and the
socket outlives the headers, so releasing early would leave `maxConnections`
bounding requests in flight while a room full of slow consumers held an
unbounded number of sockets. The cost is that a consumer-paced body occupies a
slot for as long as it reads, and the bound on that is the transfer timeout,
which Reqwest applies from the first connect until the body finishes. The
option documents this so a game can raise the limit rather than discover the
rule.

External input is retained at logical-update boundaries. SDL callbacks append
copied events to a bounded native queue; a new update seals one immutable
batch, folds input once, and dispatches observers from the scheduler-owned
`Ingress` phase. If an observer suspends, later SDL events wait for the next
update. Watcher changes use the same bounded Ingress boundary. The scheduler
therefore commits a phase once and extraction never observes half of an
external batch.

## Build

Cargo and `xtask` own the build, generated bindings, tests, and packaging.
Run `cargo xtask deps` once to install and stage development dependencies, then:

```bash
cargo xtask build              # Build the host development preset
cargo xtask example ui-demo    # Run the 2D showcase
cargo xtask example scene3d    # Run the split-screen Cook-Torrance example
cargo xtask example ibl3d      # Run the CC0 specular-environment comparison
cargo xtask example gltf3d     # Run the textured 3D example
cargo xtask example skinning3d # Run the GPU skeletal-deformation example
cargo xtask example animated3d # Run the CC0 animated and lit glTF hero
cargo xtask example morph3d    # Run decoded glTF morph-weight animation
cargo xtask fetch sponza       # Cache the pinned large lighting scene
cargo xtask example sponza3d   # Run point and spot lights in Sponza
cargo xtask fetch bistro       # Import the pinned large Bistro stress scene
cargo xtask example bistro3d   # Run Bistro with probe and direct lighting
cargo xtask bench meshshadows  # Measure mesh shadows, local lights, and SSAO
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

Rust/Cargo, LuaJIT, SDL3, SDL3_mixer, zlib, and Teal. Cargo owns the
development-only shaderc and SPIRV-Cross crates; packaged builds contain only
their prebuilt shader pack.
`rust-toolchain.toml` selects the Rust version; `cargo xtask deps` installs the
development dependencies managed by the project.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for dependency notices.

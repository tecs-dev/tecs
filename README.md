# tecs2d

A LuaJIT game engine built directly on SDL3, SDL_GPU, and Box2D 3, replacing
the Love2D layer that Tecs previously ran on. Entities are the interface:
anything that renders or updates per frame is an entity in a Tecs world.

Everything below Lua is reached through the FFI. There are no Lua C extensions:
the only native code is a host that owns `main`, and even that is never called
from Lua.

## Status

Working today:

- Generated FFI bindings for SDL3, Box2D 3, shaderc, and SPIRV-Cross, verified
  against the C ABI
- A window, a Metal/Vulkan/D3D12 GPU device, and a swapchain render loop
- GLSL compiled at runtime to SPIR-V and translated to MSL, with resource
  bindings reflected and remapped for the backend
- Immutable graphics pipelines, storage buffers, uniform buffers, and offscreen
  render targets with pixel readback
- Compute pipelines with reflected workgroup size, and GPU-driven drawing: a
  compute pass writes the draw arguments, one indirect draw consumes them
- A declarative pass graph, and a deferred pipeline built on it
- An ECS binding: Transform2D, Tint, Sprite, PointLight, and Renderable
  components,
  with a sync that walks archetype columns straight into mapped GPU staging
- Physics in the world: a RigidBody component holding a Box2D handle, stepped
  in FixedUpdate and synced back to Transform2D
- Input in three tiers behind a layer stack, latched for fixed steps
- Worker threads with serialized channels, and asset loading that decodes on
  one and uploads on the main thread
- Box2D 3 simulation with value-typed body handles
- Frame pacing from the swapchain, with no sleep heuristic

Not built yet: shadows, post-processing, audio, workers, assets, and the MCP
surface.

## Workers and assets

Workers are the only sanctioned way to run work off the main thread. Raw
thread creation stays unexposed: a LuaJIT FFI callback invoked from a thread
the VM did not create is unsafe, and a thread entry written in Lua is exactly
that mistake. The native side starts a thread with a fresh `lua_State` and
moves opaque byte blocks between queues; it never learns what a message
contains, because serialization stays in Lua.

That boundary is not a style choice. LuaJIT has no shared mutable heap across
threads, so a worker cannot see the spawning state's objects at all. What
crosses is what `string.buffer` encodes.

Asset loading rides on that. Decoding a PNG is milliseconds of pure CPU work
with no GPU involvement, so it happens on a worker and the main thread only
uploads. The worker returns the *address* of a decoded surface rather than its
pixels: surfaces live in process memory, so the pointer is valid in either
state, and passing it avoids copying an image through a serialized message
only to copy it again into staging. Ownership transfers with the address.

## Input

Live state answers "is it held". Frame events answer "did it change this
frame". Latched events answer that for fixed-step systems, which is not the
same question: a key pressed and released between two fixed steps is invisible
to frame events, and losing it produces input loss that varies with frame
timing and so cannot be reproduced on demand. Latched sets accumulate across
every frame since the last fixed step and clear when it ends. The run loop
brackets the fixed phases itself, because that bracketing is the entire
mechanism.

Queries are answered relative to a layer. A blocking layer hides input from
everything beneath it, so a menu suppresses gameplay without gameplay code
knowing a menu exists. Code that names no layer reads the base layer, which is
the safe default: it goes quiet when anything is pushed over it.

The state is fed one `SDL_Event` at a time and holds no globals, so a recorded
session replays by feeding the same events back through `events.source`.

## The Tecs binding

Tecs itself is unchanged and consumed as a dependency. What lives here is
tecs2d's own surface on top of it: components, a renderer that syncs from a
world, and a physics plugin.

`Renderer` is the bridge, and the only module that knows about both
archetypes and GPU buffers. Everything below it is renderer; above it is
Tecs.

Images live in one array texture, so the texture is a per-instance layer index
and the whole scene is one draw. That is also what frees the instance layout:
with nothing to sort by, each archetype keeps a contiguous run, and a run whose
components did not change is not rewritten.

That gating is the point. Walking every entity every frame is the cost that
decides whether a large world is affordable, and most frames change very
little. A still scene of half a million entities resyncs nothing.

Layer zero is a white pixel, so an entity with no `Sprite` samples it and
textured and untextured geometry share one shader and one pipeline. An image
smaller than a cell does not reach the cell's edge, so `registerImage` returns
a ready `Sprite` rather than a bare index: a caller guessing the UV range
would sample the undefined remainder.

Its sync reads columns with `get`, never `getMut`. Taking a mutable column to
read would mark those components dirty on every archetype every frame, which
defeats every dirty-gated consumer downstream. That distinction is the single
easiest thing to get wrong here and the hardest to notice.

Syncing runs in `RenderFirst` inside the world's update; rendering happens
afterwards against a frame. The two stay separable because the sync needs no
command buffer and the render needs no world, which also means the swapchain
is held for as little of the frame as possible.

## Buffer writes

SDL_GPU has no mappable device buffer. Data reaches one by being written into
a mapped transfer buffer and copied across in a copy pass, and the transfer
buffer must be unmapped before that copy is encoded. That staged copy is
unavoidable.

What is avoidable is a second one. `Buffer:map` returns the driver's own
address, so a producer walking archetype columns copies straight into it
rather than filling a staging array that then has to be copied again.
`mapAs` gives the same memory as a typed array, for writing struct fields in
place.

Writes are tracked as ranges rather than replacing the whole buffer, because
most frames change very little of what is resident. Adjacent writes merge;
past a fixed number of distinct spans the dirty region collapses to one,
trading bandwidth for bounded bookkeeping but never dropping a range.

The destination is never cycled. Cycling discards a buffer's contents, which
would erase every range a frame did not rewrite, and that failure looks
exactly like a bug in whatever reads the buffer later rather than like an
upload problem. `flush` takes the caller's command buffer so the copy is
ordered against the frame that consumes it instead of racing a separate
submission.

## The pass graph

Passes name the targets they read and write. The graph owns those targets,
resizes them with the frame, begins and ends each pass, and binds each pass's
inputs as fragment samplers, so a pass body only draws.

Execution follows declaration order rather than a topological sort. The order
of a deferred pipeline is a design decision, not something worth rediscovering
every frame, and a graph that silently reorders is harder to reason about than
one that refuses to run. Declared inputs are validated against what earlier
passes produce, so a missing dependency is an error when the graph is built
instead of a black screen later.

The graph knows nothing about entities, archetypes, or dirtiness. A pass that
should be skipped says so through `enabled`, which is where an ECS-side dirty
gate plugs in without the graph learning what dirty means.

`Deferred` assembles the standard pipeline on it: geometry fills a G-buffer,
lighting resolves it against a storage buffer of lights, and composite puts the
result on screen. Geometry is a callback because what to draw is the caller's
problem. Deferred is what makes light count independent of object count:
geometry rasterises once regardless of how many lights touch it, and lighting
runs once per pixel regardless of how many objects overlap it.

## GPU-driven by default

`make run` animates 512 instances and issues exactly one dispatch and one
indirect draw per frame. Per-instance data lives in a storage buffer that a
compute pass updates, and the instance count is written by that same pass into
an `SDL_GPUIndirectDrawCommand`, so the CPU never learns it.

That is the whole reason for the deferred-only decision. There are no vertex
buffers anywhere: shaders index storage buffers by vertex and instance ID.

## The shader pipeline

GLSL goes to SPIR-V through shaderc, then to MSL through SPIRV-Cross. Runtime
compilation is a requirement rather than a convenience: material variants are
assembled from preprocessor defines at load time, so an offline-only bake would
not serve them.

SDL abstracts the whole API across Metal, Vulkan, and D3D12 identically, but
it deliberately does not abstract shaders: `SDL_CreateGPUShader` takes
precompiled bytecode in a backend-specific format and never compiles or
translates. That is the one platform-specific seam, and this is the code that
sits on it. Only MSL and SPIR-V are produced today, so Windows resolves to the
Vulkan backend; D3D12 would need DXC for DXIL.

The fiddly part is bindings. SDL_GPU consumes compiled shaders and is told
separately how many resources of each class they bind, and it fixes the
descriptor sets shaders must be authored against. Those sets differ by stage:

```
 Stage     Textures and storage buffers   Uniform buffers
 ────────  ─────────────────────────────  ───────────────
 vertex    set 0                          set 1
 fragment  set 2                          set 3
 compute   set 0 read-only, 1 read-write  set 2
```

Metal has no descriptor sets, so those bindings are flattened into `[[buffer]]`
and `[[texture]]` indices in the order SDL_GPU's Metal backend expects. Both
the counts and the remapping come from reflecting the SPIR-V, because a wrong
count is not a compile error. It is a silent binding mismatch.

That is also why `spec/render_spec.lua` renders offscreen and asserts on real
pixels. A draw that produces nothing still runs at full frame rate, so "it did
not error" is not evidence that it drew.

## Locked decisions

These shape the seam and are effectively impossible to retrofit, so they were
settled before anything was written.

**Deferred only, no immediate mode.** SDL_GPU bakes blend, depth, and cull into
immutable pipeline objects and has no global state to set. An immediate-mode API
would have to be built in order to then be worked around, so there isn't one.
Every draw goes through a render pass on an explicit frame.

**The command buffer is a value, never a global.** `Device:beginFrame` returns a
`Frame` that carries its own command buffer, and anything recording work takes
that frame explicitly. SDL_GPU permits a command buffer per thread; a module
global would make threaded recording impossible to add later without touching
every drawing site.

**Nondeterminism is injectable.** `platform.clock` and `platform.events` both
read through a provider that defaults to the real source. A replay driver
substitutes recorded dt and recorded input without either subsystem knowing.
Events are delivered as a reused `SDL_Event`, so recording is a 128 byte copy
and replay is the same copy back, with no second representation to keep in sync.

**Resource handles are owned by the platform, not by Lua's collector.** Windows
and devices are released by an explicit `destroy`. Tying GPU-adjacent lifetimes
to finalizers makes hot reload either leak or double-free depending on
collection order.

**Workers will be the only threading path.** LuaJIT FFI callbacks invoked from
threads the VM did not create are unsafe, so raw thread creation will not be
exposed even though the symbols are bound.

## Bindings are generated, never hand-written

`scripts/gencdef.py` runs the system preprocessor over the installed headers,
keeps the declarations that came from the library, and rewrites them into the
subset of C that LuaJIT's parser accepts. Integer `#define` constants are
recovered separately by compiling a program that prints them, because the
preprocessor expands them away before a cdef could see them, and because many
of them (`SDL_WINDOW_RESIZABLE`) hide behind helper macros that pattern
matching misses.

A hand-maintained cdef does not fail to link when it drifts. It reinterprets
memory and surfaces later as corruption far from the cause. `make abi-check`
compares LuaJIT's view of every generated record against the C compiler's:
size, alignment, and the offset of every field. It currently verifies 192
records across the four libraries.

Header-only `static inline` helpers have no symbol to bind and are
reimplemented in Lua. That is usually faster anyway, since the JIT can inline
Lua where it cannot inline across an FFI call. `World.getAngle` converting a
`b2Rot` cosine/sine pair is the current example.

## Layout

```
host/main.c                 process entry: a Lua state and argv, nothing else
scripts/gencdef.py          header -> cdef + constants generator
scripts/abicheck.py         cdef vs C compiler layout verification
src/tecs2d/ffi/             library loading and generated binding wrappers
src/tecs2d/platform/        window, clock, events
src/tecs2d/gpu/             device, frame, passes, shaders, pipelines, buffers
src/tecs2d/components.tl    components the engine renders and simulates
src/tecs2d/Renderer.tl      the world-to-GPU bridge
src/tecs2d/physics/         Box2D binding and its world plugin
spec/                       busted suite
```

## Commands

```
make deps        install SDL3, Box2D, shaderc, SPIRV-Cross, LuaJIT (Homebrew)
make all         generate cdefs, compile Teal, build the host
make run         run the demo
make test        run the spec suite
make check       type-check Teal sources
make abi-check   verify generated cdefs against the C ABI
make spvc        link SPIRV-Cross into a shared library
make cdef        regenerate bindings from installed headers
```

`TECS2D_FRAMES=N make run` exits after N frames, so an automated run can drive
a real window to completion.

## Requirements

LuaJIT, SDL3 (3.4+, for SDL_GPU), Box2D 3.x, shaderc, SPIRV-Cross, and Teal
(`tl`). Library paths are discovered through Homebrew or `/usr/local`, and each
can be overridden with `TECS2D_SDL3_PATH`, `TECS2D_BOX2D_PATH`,
`TECS2D_SHADERC_PATH`, or `TECS2D_SPVC_PATH`.

Homebrew ships SPIRV-Cross as static archives only, so `make spvc` links the
shared object the FFI needs into `build/lib/`.

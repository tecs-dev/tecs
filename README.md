# tecs

Tecs is a typed entity component system and 2D game engine, written in Nupp
against Rust services. Entities are the interface: anything that updates or
renders belongs to a world.

A game is a component. It exports a session constructor, and the Rust host
selects that export by name and drives it one frame at a time:

```nupp
module mygame

local function install(exclusive app: tecs.application.Application): nil
    app.world:addSystem({
        name = "game.Tick",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number): nil
            -- Update game state.
        end,
    })
end

--- Creates the game's host session through its statically linked plugin.
export function create(
    title: string?,
    width: integer?,
    height: integer?,
    debug: boolean?,
    maxFrames: integer?
): tecs.host.Session
    return tecs.host.createWithPlugin(install, title or "My game", width, height, debug, maxFrames)
end
```

`tecs` is available as a typed namespace whenever Tecs is in the Nupp project.
Use `tecs.ecs.newWorld()`, `tecs.gfx.Tint(...)`, and nested modules directly;
no `require` or initialization call is needed. Nupp resolves these paths at
compile time and loads each referenced module once when the caller loads.

The ECS runs with no host at all, so simulation code, a headless tool and a
test suite reach the same world without starting a graphics stack.

## Features

- Typed ECS with archetype queries, plugins, state stacks, relationships,
  bundles, durable entity keys and snapshots.
- GPU-driven 2D rendering with a declared pass and target graph, compiled
  material dispatch, ordered GPU culling, deferred lighting, occluder masks,
  drop shadows and optional bloom.
- Camera, layers with positioning modes, images, clips, sprite sheets with
  animation, and distance-field text.
- Input across keyboard, pointer, gamepad and touch; audio playback, recording
  and device enumeration; General MIDI from a SoundFont; emulated Yamaha FM
  chips, from the OPL2 and OPL3 to the YM2612 and the OPL4; MIDI, VGM, VGZ and
  DRO music played on them; physics over Rapier; sequencing with tweening;
  asset orchestration; file watching; and an MCP debug server.

- [Tiled TMX maps and TSX tilesets](docs/tiled/index.md), animated tile and image
  layers, object factories, runtime tile edits and authored collision outlines.
- [Retained UI backed by Taffy](docs/ui/index.md), intrinsic text and images,
  scrolling, clipping, pointer capture, keyboard focus and controller activation.
- Audio clips decoded from a file or from the bytes of a whole encoded file held
  in memory, for a game that unpacks its own archives.

The 2D shape materials include rectangles, circles, rings, rounded rectangles,
triangles and stars. 3D rendering, custom post-processing and multi-camera
rendering are not available in the current engine.

Run `nupp task ex-tiled` for a map with animation and collision, or `nupp task ex-ui`
for the Compose, Flex, Overlay and Scroll showcase over the animated gradient
field. `nupp task ex-uistandalone --width 960 --height 640` runs the centered panel.

## Build

Nupp owns the development workflow through `nupp.lua`: build targets,
project tasks and the test command share one entry point. Cargo compiles the
Rust host and services underneath those tasks; the Rust packaging helper owns
binary inspection, relocation and native release assembly.

A checkout needs the Rust toolchain `rust-toolchain.toml` pins and a current
[Nupp compiler](https://github.com/nupp-lang/nupp) on `PATH`.
`nupp task deps` installs the two formatters on macOS.

```bash
nupp check --strict           # Type-check every Nupp source, strictly
nupp test                     # Build native services; require every test to pass
nupp task ex-flatcolor           # Open a window and render the example
nupp task ex-lighting --frames 120
nupp task bench shapes        # Run a benchmark from bench/nupp
nupp task bench acceptance    # Three repetitions of fixed CPU workloads
nupp task format              # Format every supported source language
nupp task docs-check          # Validate the documentation site
nupp task verify              # Checks, tests, docs, Rust and headless smokes
nupp task package --preset macos-arm64
nupp task check-package
```

`nupp task presets` lists the release matrix: macOS arm64, Linux x64 and
Windows x64, each with a development preset and a release preset. Windows is
experimental until its Nupp, host and relocated-package gates execute.

### Packaging

A release records its loader-relative run path when it links, rather than being
relocated after. The alternative was to link against the staged Nupp SDK as a
checkout does and then rewrite the result, and it lost on its tools:
`install_name_tool` ships with the Xcode command-line tools that a macOS build
already needs, but the Linux equivalent is `patchelf`, which is a dependency
this tree does not otherwise have and would have to install on every builder.
Passing the packager's run path to the host's build script costs one
environment variable and no tool at all.

One post-link edit survives on macOS, and only there. Cargo gives a `cdylib`
the absolute path it wrote it to as its install name, so a copied service
library still names the Cargo target directory it came from. The obvious fix,
a per-crate `-install_name` link argument, loses because Cargo applies
`RUSTFLAGS` to a whole invocation: three different install names would mean
three builds that each invalidate the last one's cache. Rewriting three
finished files is cheaper than rebuilding the graph three times.

Release licensing is generated rather than curated. The host's resolved graph
is around 150 Cargo packages, and roughly half are named nowhere in
`THIRD_PARTY_NOTICES.md`. Instead of hand-writing entries for them, a package
installs `cargo-licenses.txt` beside `cargo-dependencies.txt`, carrying the
SPDX expression Cargo metadata records for every package in the inventory, and
`check-package` refuses an install where an entry has no answer. Curated prose
says why a dependency is there; this says what it is licensed under, which is
the part that must be complete. MPL-2.0 remains accepted for Symphonia. A package
also carries version-specific covered-source URLs and checksums in
`license-sources.json`; packaging compares covered sources with the locked crate
archives before recording them as unmodified. Patched covered sources need an
actual source package and modification record before they can ship.

A package ships a prebuilt `shaders.tecspack` and no material directory, so a
run that loses the pack cannot fall back, and packaging holds the packed
material names to the builtin list: a mismatch there would draw the wrong
material silently, because a frame packet selects by id.

Packaging is native only. The Nupp toolchain stages an embedding library for
the machine it runs on, so there is nothing to cross-link a Windows release
against on a Mac, and each platform builds its own.

## Documentation

The guides and the generated API reference live in [`docs/`](docs/). Serve them
locally with `nupp task docs-dev`. API contracts live on their declarations
under [`src/tecs/`](src/tecs/), and the reference is rendered from those, so a
signature has no second copy to drift from.

The source layout and project conventions are documented in
[`AGENTS.md`](AGENTS.md). Design notes live in the adjacent `../tecs-plans`
repository.

## Requirements

Rust and Cargo, and a Nupp compiler. `rust-toolchain.toml` selects the Rust
version. Linux additionally needs the development packages `winit`, `wgpu`,
`cpal` and `gilrs` link against: `libasound2-dev`, `libudev-dev`,
`libwayland-dev`, `libxkbcommon-dev`, `libx11-dev`, `libxcursor-dev`,
`libxi-dev` and `libxrandr-dev`.

A Linux release carries the Nupp and Tecs runtime libraries. The distribution
supplies ALSA (`libasound.so.2`) and udev (`libudev.so.1`), plus the C/C++ system
runtime and the window-system/graphics-driver libraries for windowed execution.
Compiler and shader-compiler tools are not needed to run a release.
The Linux host uses a relative `DT_RPATH` so service loads originating in the
shared Nupp runtime also find the packaged `lib/` directory.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for dependency notices.
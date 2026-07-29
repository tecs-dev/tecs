# Third-Party Notices

Tecs includes and links third-party material under licences other than the
repository's MIT-or-Apache-2.0 code licence. Everything named here is
permissive.

Licences below were read from each project's own files at the revision
`cmake/Revisions.cmake` pins, not from what a project is commonly said to be
under. Two of those are worth naming because the common answer is wrong:
**libxmp is MIT**, not the LGPL it is usually called, and **SPIRV-Headers is
MIT**, not the Apache-2.0 that the rest of shaderc's tree is.

## The rule

**No LGPL, ever.** Not as a preference and not per release: a game built on this
engine is one statically linked file per platform, and the LGPL's relinking
obligation cannot be met by one. The same reasoning rules out the GPL and
anything that reaches one, so a dependency whose licence is not permissive is
not adopted, however convenient it is.

That is not left to this document. Three things enforce it, and each is honest
about what it does not cover:

- `cmake/Pinned.cmake` names every decoder option that would fetch an LGPL
  codec instead of accepting a version's defaults. SDL_mixer's defaults are on
  for the LGPL paths, so an unconfigured build is encumbered; this is the file
  that makes it not.
- `spec/licenses_spec.lua` holds those options to their values, fails on an
  option it does not recognise, and fails when a dependency is pinned without
  being named below. It reads a declaration, so it cannot tell an option that
  works from one upstream renamed.
- `scripts/checkpackage.py` holds the libraries an installed tree actually
  links against a list carrying a licence and a reason for each, and fails an
  install missing this file. It reads link tables, so it cannot see a static
  archive and it cannot read a licence out of a binary, because nothing can.

This file installs to `share/tecs` beside the binaries it describes, with
`LICENSE-MIT` and `LICENSE-APACHE`. A package that carried the code and not the
notice is the one compliance failure this engine could commit on its own.

## What actually has to be reproduced

Most of what follows is zlib licensed or public domain and asks nothing of a
binary distribution. These are the ones that do, so a distribution that is short
of time gets these right first:

- **MIT**: lua-cjson, LuaJIT and the PUC-Rio Lua notice inside it,
  SPIRV-Headers, and stb_vorbis if MIT is the arm elected. MIT's "in all
  copies or substantial portions" has no source-only carve-out.
- **BSD-3-Clause**: libogg, Opus, opusfile, WavPack, and SDL3's vendored
  yuv2rgb. Each requires the copyright notice, the list of conditions and the
  disclaimer to appear in the documentation or other materials of a binary
  distribution, which is what this file is.
- **Apache-2.0**: SPIRV-Cross, shaderc, SPIRV-Tools. A distribution carries a
  copy of the licence and keeps the notices; nothing here modifies them.
- **Apache-2.0 and MIT**: the Rust standard library and Cargo graph described
  below. This distribution elects one arm for each dual-licensed crate and
  carries both licence texts.
- **David Gay's notice**, below, which asks for the entire notice rather than a
  line of it.

## Included in this repository

### lua-cjson

`vendor/cjson` carries Mark Pulford's lua-cjson, built both into the engine and
as a loadable module. MIT licensed; `vendor/cjson/LICENSE` is the text, and a
binary distribution has to carry it.

### David Gay's floating-point conversion

`vendor/cjson/dtoa.c` and `vendor/cjson/g_fmt.c` are not lua-cjson's and are not
MIT. They are David M. Gay's, copyright Lucent Technologies 1991, 1996, 2000 and
2001, under a permission notice of their own that asks for something specific:
that the entire notice be included in all copies of any software which is or
includes a copy of it. Both files are compiled into the engine and into the
loadable cjson module, so a shipped binary is such a copy. The notices are
`vendor/cjson/dtoa.c:5-22` and `vendor/cjson/g_fmt.c:1-17`, reproduced here:

> The author of this software is David M. Gay.
>
> Copyright (c) 1991, 1996, 2000, 2001 by Lucent Technologies.
>
> Permission to use, copy, modify, and distribute this software for any purpose
> without fee is hereby granted, provided that this entire notice is included in
> all copies of any software which is or includes a copy or modification of this
> software and in all copies of the supporting documentation for such software.
>
> THIS SOFTWARE IS BEING PROVIDED "AS IS", WITHOUT ANY EXPRESS OR IMPLIED
> WARRANTY. IN PARTICULAR, NEITHER THE AUTHOR NOR LUCENT MAKES ANY
> REPRESENTATION OR WARRANTY OF ANY KIND CONCERNING THE MERCHANTABILITY OF THIS
> SOFTWARE OR ITS FITNESS FOR ANY PARTICULAR PURPOSE.

### JetBrains Mono

`assets/fonts/jetbrainsmono-extrabold-msdf.png` and its metrics are a
signed-distance-field atlas generated from JetBrains Mono ExtraBold 2.304, and
are what text draws with unless a game names another font. Font Software under
the SIL Open Font License 1.1: the licence is
`assets/fonts/JetBrainsMono-OFL.txt` and the provenance, including how the atlas
was generated, is `assets/fonts/JetBrainsMono-NOTICE.md`. Both are installed
with the assets, so a package carries them.

## Linked by a build

These are fetched at configure time rather than checked in, so a source checkout
carries none of them and a packaged build carries all of them. A release
therefore has to ship their notices even though this repository does not contain
their code.

### SDL

**SDL3** and **SDL3_mixer**, both zlib licensed,
copyright Sam Lantinga. The zlib licence binds source distribution rather than
binary, so strictly it asks nothing of a shipped game; the notice is reproduced
anyway.

SDL3 vendors code it did not write, and two entries need a decision rather than
a mention:

- **HIDAPI** (`src/hidapi/`) is offered under GPL-3.0, BSD-3-Clause, or its
  original licence, at the user's choice. **This engine elects BSD-3-Clause**
  (`src/hidapi/LICENSE-bsd.txt`, copyright 2010 Alan Ott, Signal 11 Software).
  That is an election rather than an obligation, and it is the only GPL text
  anywhere in SDL3. Note that HIDAPI's libusb backend is loaded by name rather
  than linked; static-linking libusb would import LGPL-2.1 and is not done.
- **yuv2rgb** (`src/video/yuv2rgb/LICENSE`) is BSD-3-Clause, so its notice,
  conditions and disclaimer travel with a binary.

The rest ask nothing but are named: **fdlibm** from SunPro under its own
preserve-this-notice terms, **dlmalloc** by Doug Lea and a public-domain
`qsort`, and the **Khronos** OpenGL, OpenGL ES and EGL headers (MIT) with the
Vulkan headers (Apache-2.0).

### Rust native build foundation

The static native archive includes `clap` for CLI parsing, `image` for PNG and
JPEG decoding and PNG encoding, `reqwest` with Rustls for HTTP, `rmcp` for the
official MCP protocol and Streamable HTTP server, and `rapier2d` for physics.
It also owns the host lifecycle, worker channels, logging, dialogs, Lua module
registration, LuaJIT's machine-code arena, and the single-file payload loader.
SDL still owns the application loop and LuaJIT still owns game execution.

The exact versions and declared SPDX expressions are pinned in
`native/rust/Cargo.lock` and Cargo metadata. The graph is permissive: MIT,
Apache-2.0, ISC, BSD-3-Clause, Zlib, Unicode-3.0, CDLA-Permissive-2.0,
Unlicense, and 0BSD. The build selects Ring as Rustls' crypto provider; it does
not compile AWS-LC or OpenSSL. `LICENSE-APACHE` and `LICENSE-MIT` travel with
the embedded payload and with an installed package. Crates whose selected
licence has an additional notice retain it below or in their packaged source
metadata.

The complete Cargo package inventory is below. It is generated from the lock
file as part of the notice audit; target-specific entries are named because a
release for that target compiles them:

`adler2`, `allocator-api2`, `anstyle`, `approx`, `arrayvec`,
`async-compression`, `atomic-waker`, `autocfg`, `base64`, `bincode`,
`bitflags`, `bumpalo`, `bytemuck`, `byteorder-lite`, `bytes`, `cc`, `cfg-if`,
`clap`, `clap_builder`, `clap_derive`, `clap_lex`, `combine`,
`compression-codecs`, `compression-core`, `core-foundation`,
`core-foundation-sys`, `crc32fast`, `crossbeam-deque`, `crossbeam-epoch`,
`crossbeam-utils`, `displaydoc`, `downcast-rs`, `either`, `ena`, `equivalent`,
`fdeflate`, `find-msvc-tools`, `flate2`, `foldhash`, `form_urlencoded`,
`futures-channel`, `futures-core`, `futures-io`, `futures-macro`,
`futures-sink`, `futures-task`, `futures-util`, `getrandom`, `glam`, `glamx`,
`hashbrown`, `heck`, `http`, `http-body`, `http-body-util`, `httparse`,
`hyper`, `hyper-rustls`, `hyper-util`, `icu_collections`, `icu_locale_core`,
`icu_normalizer`, `icu_normalizer_data`, `icu_properties`,
`icu_properties_data`, `icu_provider`, `idna`, `idna_adapter`, `image`,
`indexmap`, `ipnet`, `itoa`, `jni`, `jni-macros`, `jni-sys`,
`jni-sys-macros`, `js-sys`, `libc`, `libm`, `litemap`, `log`,
`matrixmultiply`, `memchr`, `miniz_oxide`, `mio`, `moxcms`, `nalgebra`,
`nalgebra-macros`, `num-bigint`, `num-complex`, `num-derive`, `num-integer`,
`num-rational`, `num-traits`, `once_cell`, `openssl-probe`, `ordered-float`,
`parry2d`, `percent-encoding`, `pin-project-lite`, `png`, `potential_utf`,
`proc-macro2`, `profiling`, `profiling-procmacros`, `pxfm`, `quote`,
`rapier2d`, `rawpointer`, `rayon`, `rayon-core`, `reqwest`, `ring`, `robust`,
`rustc_version`, `rustls`, `rustls-native-certs`, `rustls-pki-types`,
`rustls-platform-verifier`, `rustls-platform-verifier-android`,
`rustls-webpki`, `rustversion`, `safe_arch`, `same-file`, `schannel`,
`sdl3-sys`, `security-framework`, `security-framework-sys`, `semver`, `serde`,
`serde_arrays`, `serde_core`, `serde_derive`, `shlex`, `simba`,
`simd-adler32`, `simd_cesu8`, `simdutf8`, `slab`, `smallvec`, `socket2`,
`spade`, `stable_deref_trait`, `static_assertions`, `subtle`, `syn`,
`sync_wrapper`, `synstructure`, `thiserror`, `thiserror-impl`, `tinystr`,
`tokio`, `tokio-rustls`, `tokio-util`, `tower`, `tower-http`, `tower-layer`,
`tower-service`, `tracing`, `tracing-core`, `try-lock`, `typenum`,
`unicode-ident`, `untrusted`, `url`, `utf8_iter`, `walkdir`, `want`, `wasi`,
`wasm-bindgen`, `wasm-bindgen-futures`, `wasm-bindgen-macro`,
`wasm-bindgen-macro-support`, `wasm-bindgen-shared`, `wasm-streams`, `web-sys`,
`webpki-root-certs`, `wide`, `winapi-util`, `windows-link`, `windows-sys`,
`windows-targets`, `windows_aarch64_gnullvm`, `windows_aarch64_msvc`,
`windows_i686_gnu`, `windows_i686_gnullvm`, `windows_i686_msvc`,
`windows_x86_64_gnu`, `windows_x86_64_gnullvm`, `windows_x86_64_msvc`,
`writeable`, `yoke`, `yoke-derive`, `zerofrom`, `zerofrom-derive`, `zeroize`,
`zerotrie`, `zerovec`, `zerovec-derive`, `zune-core`, and `zune-jpeg`.

The official MCP SDK and Streamable HTTP server add `android_system_properties`,
`async-trait`, `axum`, `axum-core`, `chacha20`, `chrono`, `cpufeatures`,
`dyn-clone`, `futures`, `futures-executor`, `httpdate`, `iana-time-zone`,
`iana-time-zone-haiku`, `matchit`, `mime`, `pastey`, `r-efi`, `rand`,
`rand_core`, `ref-cast`, `ref-cast-impl`, `rmcp`, `schemars`,
`schemars_derive`, `serde_derive_internals`, `serde_json`, `sse-stream`,
`tokio-macros`, `tokio-stream`, `tracing-attributes`, `uuid`, `windows-core`,
`windows-implement`, `windows-interface`, `windows-result`, `windows-strings`
and `zmij`.

`unicode-ident` is also under the Unicode License v3, so that notice is required
in addition to the Apache-2.0 arm elected above:

> UNICODE LICENSE V3
>
> COPYRIGHT AND PERMISSION NOTICE
>
> Copyright © 1991-2023 Unicode, Inc.
>
> NOTICE TO USER: Carefully read the following legal agreement. BY DOWNLOADING,
> INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR SOFTWARE, YOU
> UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE TERMS AND
> CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT DOWNLOAD, INSTALL,
> COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of data files and any associated documentation (the "Data Files") or software
> and any associated documentation (the "Software") to deal in the Data Files
> or Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
> Files or Software, and to permit persons to whom the Data Files or Software
> are furnished to do so, provided that either (a) this copyright and permission
> notice appear with all copies of the Data Files or Software, or (b) this
> copyright and permission notice appear in associated Documentation.
>
> THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
> KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD
> PARTY RIGHTS.
>
> IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE
> LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR ANY
> DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
> ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
> CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR SOFTWARE.
>
> Except as contained in this notice, the name of a copyright holder shall not
> be used in advertising or otherwise to promote the sale, use or other dealings
> in these Data Files or Software without prior written authorization of the
> copyright holder.

### What SDL3_mixer decodes

Chosen rather than defaulted, for the licence rather than for the bytes.
Enabled:

- the WAV, AIFF, VOC and AU readers SDL_mixer implements itself, zlib licensed
  with it
- **stb_vorbis** for Ogg Vorbis, MIT or public domain
- **dr_flac** and **dr_mp3**, public domain or MIT-0. dr_mp3 carries a second
  notice of its own, for the upstream minimp3 it derives from, dedicated under
  CC0-1.0.
- **Opus** with **opusfile** and **libogg**, BSD-3-Clause. Opus's notice also
  reproduces the royalty-free patent grants from Xiph, Microsoft and Broadcom;
  they impose no distribution condition, and the paragraph travels with the
  text.
- **WavPack**, BSD-3-Clause

Those four BSD-3-Clause entries are the only hard reproduction obligations among
the decoders.

Disabled: **game-music-emu**, LGPL-2.1-or-later and GPL-2.0-or-later if built
with the MAME YM2612 emulator; **FluidSynth**, LGPL-2.1-or-later, and with it
SDL_mixer's bundled **TiMidity**, which is Artistic-1.0; and **mpg123**,
LGPL-2.1-only with no "or later", for which dr_mp3 stands in. **libxmp** is off
too, but not for its licence: it is MIT, contrary to how it is usually
described, and it is off only because nothing here plays a module.

`SDLMIXER_STRICT` makes a dependency that cannot be found fail the configure
rather than silently drop its format, and `Audio.decoders()` reports what a
running build actually has, which is the answer to check against this list.

### SPIRV-Cross

**SPIRV-Cross**, dual licensed **Apache-2.0 OR MIT** at the recipient's option.
Its `LICENSE` file is Apache-2.0 alone and understates that; the election is
stated per file, in every one of the library sources. Its embedded `spirv.h`,
`spirv.hpp` and `GLSL.std.450.h` are Khronos Free Use, which is MIT-like and
wants its notice in all copies.

### shaderc

**shaderc**, Apache-2.0, and only in a build that compiles shaders at runtime. A
release consumes a prebuilt shader pack and links no compiler, which
`make check-package` enforces, so this section applies to a development build
and to any tool that ships one, not to a shipped game.

shaderc builds in third-party projects of its own, and vendors none of them. It
carries a `DEPS` file naming a commit of each and a `git-sync-deps` script that
clones what that names, so pinning shaderc alone pins the wrapper and leaves the
compiler inside it moving. The three that reach object code are pinned in
`cmake/Revisions.cmake` at the revisions shaderc's own `DEPS` names at the
shaderc revision beside them:

- **SPIRV-Tools**, Apache-2.0
- **SPIRV-Headers**, MIT
- **glslang**, which is not one licence. Its `LICENSE.txt` collects six:
  BSD-3-Clause on the core 3Dlabs and Khronos code, BSD-2-Clause on the C
  interface, MIT on test data, Apache-2.0 on two SPIR-V helpers, an NVIDIA
  licence on the preprocessor, and GPL-3.0-or-later WITH Bison-exception-2.2 on
  the generated parser.
- googletest, abseil, re2 and effcee are shaderc's test dependencies and reach
  no object code in a build with tests skipped.

The GPL entry is the one to read twice, so it is written down rather than
remembered. Two files carry it, `glslang_tab.cpp` and `glslang_tab.cpp.h`, and
they are compiled into libglslang. The Bison exception in their own headers
permits distributing a larger work containing the parser skeleton under terms of
your choice, so long as that work is not itself a parser generator. glslang is
not, so no copyleft propagates; what is required is retaining the FSF notice and
the exception, which shipping glslang's `LICENSE.txt` does. Note also that
shaderc's snapshot copy at `third_party/LICENSE.glslang` is out of date and
describes files the pinned glslang does not have. Reproduce glslang's own
`LICENSE.txt`.

### LuaJIT

**LuaJIT** carries three notices in one `COPYRIGHT` file, and reproducing only
the first is not compliance:

- LuaJIT itself, MIT, copyright 2005-2026 Mike Pall.
- **Lua 5.1/5.2**, MIT, copyright 1994-2012 Lua.org, PUC-Rio, under its own
  grant. This is not decorative: forty-odd LuaJIT sources carry the PUC-Rio
  header and `lua.h` bakes the string into the binary. MIT's "in all copies"
  makes reproducing it mandatory.
- **dlmalloc** by Doug Lea, public domain. No obligation; named for completeness.

### zlib

Compression, under the zlib licence. Reached through the FFI for DEFLATE and
for the Adler-32 a zlib stream carries in its trailer. Nothing is strictly
required of a binary; the notice ships anyway.

    Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler

    This software is provided 'as-is', without any express or implied warranty.

## Where the list comes from

`cmake/Revisions.cmake` is the pinned revision of each dependency and
`cmake/Pinned.cmake` is how each is obtained and configured. Those two are what
to work from when assembling notices for a distribution; this file is checked
against the first of them by `spec/licenses_spec.lua`. Cargo dependencies are
pinned in `native/rust/Cargo.lock` and checked by the same spec.

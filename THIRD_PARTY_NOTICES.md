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

- **MIT**: Box2D, lua-cjson, LuaJIT and the PUC-Rio Lua notice inside it,
  SPIRV-Headers, stb_image and stb_vorbis if MIT is the arm elected. MIT's "in
  all copies or substantial portions" has no source-only carve-out.
- **BSD-3-Clause**: libogg, Opus, opusfile, WavPack, and SDL3's vendored
  yuv2rgb. Each requires the copyright notice, the list of conditions and the
  disclaimer to appear in the documentation or other materials of a binary
  distribution, which is what this file is.
- **Apache-2.0**: SPIRV-Cross, shaderc, SPIRV-Tools. A distribution carries a
  copy of the licence and keeps the notices; nothing here modifies them.
- **The curl licence**, when libcurl lands: "in all copies", again with no
  carve-out.
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

**SDL3**, **SDL3_image**, **SDL3_net** and **SDL3_mixer**, all zlib licensed,
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

SDL3_net vendors nothing.

### What SDL3_image decodes

PNG and JPEG, and nothing else. SDL_image offers eighteen formats and
`cmake/Pinned.cmake` turns off the other sixteen, because each is a codec a
statically linked game carries whether or not it loads one.

Enabled:

- **libpng** with **zlib**, for PNG. libpng is under the PNG Reference Library
  License version 2 and zlib under the zlib licence. Neither compels anything of
  a binary, and both notices are shipped; libpng's names five sets of copyright
  holders (the PNG Reference Library Authors, Cosmin Truta, Glenn
  Randers-Pehrson, Andreas Dilger, and Guy Eric Schalnat with Group 42), and all
  five travel together. libpng is what reads APNG and what `IMG_SavePNG` writes
  through.
- **stb_image**, bundled inside SDL_image as `src/stb_image.h`, for JPEG. MIT or
  public domain at the recipient's choice. Keeping JPEG therefore links no
  libjpeg at all.
- **tiny_jpeg**, bundled as `src/tiny_jpeg.h`, which is what `IMG_SaveJPG`
  writes through. Public domain, so it asks nothing, but it is compiled in and
  is named for that reason.

Disabled, and every one of them on by default upstream: **libavif** with
**dav1d** and **aom** behind it, **libjxl**, **libtiff**, **libwebp** with
libwebpdemux, libwebpmux and libsharpyuv, and SDL_image's own readers for ANI,
BMP, GIF, LBM, PCX, PNM, QOI, SVG, TGA, XCF, XPM and XV. None of them is LGPL;
they are off because they are bytes, and because a format that is enabled is a
format a game ships assets in and every platform port then has to keep working.
The vendored headers behind the disabled ones, `qoi.h` (MIT) and NanoSVG (zlib),
are not compiled in and so need no notice.

Two backend options go with them, and the first is what makes the rest mean
anything. `SDLIMAGE_BACKEND_IMAGEIO` is off because with it on `IMG_Load` is not
SDL_image's function at all on Apple platforms: CoreGraphics answers it and
reads WebP, AVIF, JPEG XL, TIFF, BMP and GIF whatever the format options say.
`SDLIMAGE_BACKEND_WIC` is off for the same reason in the small on Windows.

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

### Box2D

**Box2D 3**, MIT licensed, copyright 2022 Erin Catto. MIT's obligation is not
source-only, so the copyright notice and permission notice travel with a binary.
Box2D's own vendored `glad` and `jsmn` are behind its samples and unit tests,
neither of which this build enables, so neither is here.

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

shaderc builds in third-party projects of its own:

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

## Pending

Two dependencies are being added and one decision goes with them, so the answers
are here rather than found afterwards.

- **zlib**, zlib licensed, on the same footing as the copy libpng already reads
  through. Nothing is strictly required of a binary; the notice ships anyway.
- **libcurl**, under the **curl** licence, which is its own SPDX identifier and
  not MIT. It requires the copyright notice and permission notice in all copies,
  with no source-only carve-out, so a binary distribution reproduces `COPYING`
  in full. It also compiles in ISC-licensed `inet_pton` and `inet_ntop`
  unconditionally, so the ISC notice goes with it.

  How it is built matters more than its own licence, and its defaults are
  against the rule here:

  - **libidn2** is dual GPL-2.0-or-later or LGPL-3.0-or-later, so its better arm
    is still disqualifying, and it is auto-detected on. It has to be refused
    explicitly, not assumed absent.
  - **libpsl** is the quiet one. libpsl is MIT, but curl's configure fails
    without it unless it is refused, and libpsl's own runtime resolves to
    libidn2 and libunistring on Linux, putting back exactly what refusing
    libidn2 removed. Its Public Suffix List data is MPL-2.0 besides.
  - The clean position is to refuse both, and to route international domain
    names through the platform on Windows and Apple if they are needed at all.

- **A TLS backend**, which is the decision. Permissive and therefore available:
  **OpenSSL 3.x** and **BoringSSL** and **AWS-LC** (Apache-2.0), **LibreSSL**
  (ISC with the older OpenSSL and SSLeay terms), **mbedTLS** (Apache-2.0 or
  GPL-2.0-or-later, electing Apache), **Rustls** (Apache-2.0, ISC or MIT), and
  **Schannel** on Windows, which costs nothing to ship because it is part of the
  target. Excluded: **GnuTLS**, LGPL-2.1-or-later and reaching LGPL-3.0 nettle
  and gmp behind it, and **wolfSSL**, GPL-3.0-or-later with no linking
  exception, which would put a whole game under GPLv3 unless a commercial
  licence were bought. `spec/licenses_spec.lua` denies both.

  Apple is worth stating plainly because the obvious answer is stale: Secure
  Transport was removed from curl in 8.15.0 and there is no macOS-native TLS
  backend any more. What remains is platform certificate verification bolted
  onto one of the backends above, so an Apple build still chooses one of them.

## Where the list comes from

`cmake/Revisions.cmake` is the pinned revision of each dependency and
`cmake/Pinned.cmake` is how each is obtained and configured. Those two are what
to work from when assembling notices for a distribution; this file is checked
against the first of them by `spec/licenses_spec.lua`.

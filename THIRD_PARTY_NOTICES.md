# Third-Party Notices

Tecs includes and links third-party material under licenses other than the
repository's MIT-or-Apache-2.0 code license.

## Included in this repository

### lua-cjson

`vendor/cjson` carries Mark Pulford's lua-cjson, built both into the engine
and as a loadable module. MIT licensed; the notice is in the sources there.

## Linked by a build

These are fetched at configure time rather than checked in, so a source
checkout carries none of them and a packaged build carries all of them. A
release therefore has to ship their notices even though this repository does
not contain their code.

- **SDL3**, **SDL3_image**, **SDL3_net**, zlib licensed
- **Box2D 3**, MIT licensed
- **SPIRV-Cross**, Apache-2.0 licensed
- **shaderc**, Apache-2.0 licensed, and only in a build that compiles shaders
  at runtime. A release consumes a prebuilt shader pack and links no compiler,
  which `make check-package` enforces.
- **LuaJIT**, MIT licensed

Pinned revisions are in `cmake/Pinned.cmake`, which is the list to work from
when assembling notices for a distribution.

Text rendering is not ported yet. When it lands it brings a font atlas with
its own license, and that notice belongs here.

# Third-Party Notices

Tecs includes and links third-party material under licenses other than the
repository's MIT-or-Apache-2.0 code license.

## Included in this repository

### lua-cjson

`vendor/cjson` carries Mark Pulford's lua-cjson, built both into the engine
and as a loadable module. MIT licensed; the notice is in the sources there.

### JetBrains Mono

`assets/fonts/jetbrainsmono-extrabold-msdf.png` and its metrics are a
signed-distance-field atlas generated from JetBrains Mono ExtraBold 2.304, and
are what text draws with unless a game names another font. Font Software under
the SIL Open Font License 1.1: the licence is
`assets/fonts/JetBrainsMono-OFL.txt` and the provenance, including how the
atlas was generated, is `assets/fonts/JetBrainsMono-NOTICE.md`. Both are
installed with the assets, so a package carries them.

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

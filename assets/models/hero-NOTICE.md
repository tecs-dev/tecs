# Animated low-poly hero

`hero.glb` is adapted from `character.glb` in Robin Lamb's "Animated Low
Poly Hero with Sword and Shield" pack:

- Source: https://opengameart.org/content/animated-low-poly-hero-with-sword-and-shield
- Original archive: https://opengameart.org/sites/default/files/hero_1.zip
- Original archive SHA-256:
  `26eac1b512bb2d5074f135d152e52fc1c9e993c055845d9a550ce960ed15e603`
- Original `character.glb` SHA-256:
  `d611bc2ccd01a797fcf1b4f6fd2239c8acd6f34e51d5ded8c148369b7880388d`
- Author: Robin Lamb
- License: CC0 1.0 Universal,
  https://creativecommons.org/publicdomain/zero/1.0/

The checked-in GLB removes the seven material `doubleSided` keys and fills the
vacated JSON chunk bytes with whitespace, preserving every GLB chunk offset.
The character uses closed low-poly surfaces, and this makes the asset exercise
Tecs' back-face-culled mesh lane. Geometry, PBR factors, the 14-joint skin, and
all nine animation clips are unchanged. Its adapted SHA-256 is
`b0202ebba37163b60cf22e78eddd19c3574a0745ca6b22089af8602b8bd9a0aa`.

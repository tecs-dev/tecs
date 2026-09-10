---
description: "Material selection, shader authoring, built-ins, and reload rules."
---

# Materials

Material selection, shader authoring, built-ins, and reload rules.

A material decides a fragment's color, coverage, surface normal, and lighting
response. Resolve its id by name when creating a
[`Material`](tecs.gfx.Material) component:

```nupp
tecs.gpu.materials.addRoot("assets/materials/")

world:spawn(
    tecs.ecs.Transform2D(120, 80, 0, 1, 0, 64, 64),
    tecs.gfx.Material(tecs.gpu.materials.id("rounded"), 0.25),
    tecs.gfx.Tint(0.2, 0.6, 1.0, 1.0),
    tecs.gfx.Renderable2D
)
```

Add game roots before loading shaders or resolving ids. An entity without a
[`Material`](tecs.gfx.Material) uses `textured` at id zero. Remaining ids follow
sorted material names. Adding or removing a file may renumber them, so
persisted state stores a name and resolves it again.

`Material.param` supplies one scalar from zero to one. Built-ins use it as
follows:

- `ellipse` uses the height fraction.
- `ring` uses the inner-radius fraction.
- `rounded` uses the corner-radius fraction.
- `frame` and `line` use a thickness fraction.
- `capsule` uses a height fraction.
- `pie` uses a full-turn sweep fraction.
- `star` uses valley depth.
- `glyph` uses the distance-field range.
- `textured`, `circle`, and `triangle` ignore it.

## Shader contract

A `.wgsl` file under a material root defines one `material` function:

```wgsl
fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    let radius = mix(0.02, 0.20, frag.param);

    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;
    result.coverage = -sdRoundedBox(
        frag.local,
        vec2<f32>(0.5),
        radius
    );
    result.lit = 1.0;
    return result;
}
```

`frag.local` runs from -0.5 to 0.5 inside the quad. `frag.uv`, `frag.color`,
and `frag.param` carry the image coordinates, tint, and instance parameter.
`frag.blended` says whether the fragment reaches a pass that blends it. Start
from `materialDefaults`, then set `albedo`, `normal`, `orm`, `lit`, `emission`,
and `coverage`.

Coverage above zero keeps a fragment; zero or below discards it. The deferred
lane does not blend partial coverage. A tint alpha below one routes the
instance to the blended lane instead, and an overlay layer does the same. A material that resolves an edge by discarding should
put the edge in alpha where `frag.blended` is set, which is what `textured` does.

## Surface properties

`orm` carries ambient occlusion, roughness, and metallic in RGB. Alpha is
reserved. `materialDefaults` returns `vec4<f32>(1.0, 0.5, 0.0, 1.0)`: fully
unoccluded, medium roughness, and non-metallic.

Ambient occlusion multiplies ambient lighting only. A point light is a known
directional contribution and keeps its own brightness; shadow components
control whether that light reaches a fragment. Roughness and metallic are
stored in the shared G-buffer. Sprite pixels use Lambert diffuse lighting and therefore ignore those two
channels.

```wgsl
fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;
    result.coverage = 1.0;
    // The instance parameter controls authored ambient occlusion.
    result.orm = vec4<f32>(frag.param, 0.8, 0.0, 1.0);
    return result;
}
```

The ORM attachment is eight bits a channel, so values outside zero to one are
clamped when geometry writes them.

## Emission

`emission` is light the surface gives off: `rgb` its color and `a` how much of
it. The renderer adds `rgb * a` to the resolved pixel after the lighting, so an
emissive surface is as bright in total darkness as under a lamp and an occluder's
shadow does not dim it. This differs from `lit = 0.0`, which replaces the
lighting with the albedo; a surface may take light and emit at the same time,
which is what a lit lamp with a glowing filament is.

```wgsl
fn material(frag: MaterialInput) -> MaterialOutput {
    var result = materialDefaults();
    result.albedo = textureSample(image, imageSampler, frag.uv) * frag.color;
    result.coverage = 1.0;
    // A warm glow at the strength the instance asked for.
    result.emission = vec4<f32>(1.0, 0.6, 0.2, frag.param);
    return result;
}
```

The `emissive` material uses tint for the emitted color and `param` for its
strength. Other shapes emit nothing unless a custom material says otherwise. Per-entity strength and color come from `frag.param` and
`frag.color`, which a material reads as it chooses.

The emission attachment is eight bits a channel, so a value above one is clamped
to one. Keep the color in range and vary the strength.

An entity in the blended lane adds its own emission to its own color and reaches
the emission attachment not at all, because the forward pass runs after the
G-buffer has been resolved. It therefore glows, and it does not reach a later
pass that reads the attachment.

## Building materials

Material bodies are WGSL. The host assembles the material directory in a
development build; a package carries the prebuilt shader pack. Restart after
changing the directory or material bodies. Resolve material IDs by name again
when adding or removing files, because the sorted set determines numbering.

See [Shapes](shapes.md) for the built-in geometry and [the material reference](tecs.gpu.materials)
for registration and lookup.

## Image material maps

The default `textured` material can read normal, emission and packed ORM maps
alongside its albedo image. This restores the tileset material channels from
the original renderer, and works for both sprites and TileChunks.

```nupp
const atlas = tecs.gfx.images.load("assets/terrain.png")
const normal = tecs.gfx.images.load("assets/terrain_n.png")
const emission = tecs.gfx.images.load("assets/terrain_e.png")
const orm = tecs.gfx.images.load("assets/terrain_orm.png")
tecs.gfx.images.setMaterialMaps(atlas, {
    normalMap = normal,
    emissionMap = emission,
    ormMap = orm
})
```

Maps share the albedo image's dimensions, UVs and sampler. Normals and ORM are
sampled as linear data; albedo and emission are sampled as sRGB colors. ORM
stores ambient occlusion, roughness and metallic in red, green and blue.
Emission alpha scales the emitted color. Omitted maps use a flat normal,
zero emission, full occlusion visibility, medium roughness and no metallic.
Calling `setMaterialMaps(atlas, {})` clears all three associations.

Replacing an image keeps its associations and invalidates the affected GPU
bindings. Releasing a companion image restores that channel's fallback;
uploading it again restores the map. `failureOf(atlas)` reports backend errors.
Tiled detects the `_n.png`, `_e.png` and `_orm.png` companions automatically.

Custom shaders can sample `normalMap`, `emissionMap`, and `ormMap` using
`imageSampler` and `frag.uv`. Procedural built-in shapes retain their own
material response.

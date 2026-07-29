---
url: /modules/gfx/materials.md
description: >-
  How a material is authored, how a name becomes an id, and the module that
  reads materials and publishes the dispatch
---

# tecs.gfx.materials

A material is what a fragment is, decided per instance. It is a `.glsl` file under `materials/`
implementing the contract in `shaders/include/material.glsl`. Every material found is compiled into
the same fragment shader, its `material` function renamed, and a generated dispatch selects between
them by an id the instance carries.

One shader rather than one per material, because the alternative is a pipeline and a draw call per
material, and the whole point of the unified batch is that the scene is one draw. What it costs is
fragment divergence where adjacent instances differ, which archetype-contiguous layout already keeps
small: entities of a kind cluster.

`tecs.gfx.materials` is the host half of that: it finds the files, assigns the ids, builds the dispatch
and hands it to the shader loader.

## Selecting a material on an entity

An entity with no `Material` component draws as the default, which samples the image array and covers
the whole quad, so an entity with neither a `Sprite` nor a `Material` still draws. Present, the
component selects one of the materials found under `materials/`:

```teal
world:spawn(
    Transform(x, y),
    Renderable,
    Tint(0.2, 0.6, 1.0, 1.0),
    Material(materials.id("rounded"), 0.35)
)
```

`Material` carries an `id` and a `param` from zero to one; see [components](/modules/gfx/).
Resolve the id by name rather than writing a number: the numbering depends on which material files
exist, and a literal would break the moment a material was added ahead of it alphabetically.

The parameter is one number because the instance packs the id and the parameter into a single float,
the integer part selecting and the fraction carrying. So each material spends it on the one thing the
transform cannot say, and a material that genuinely needed two would mean growing every instance in
the scene.

## The materials the engine ships

| Name       | What it draws                          | What `param` means                                             |
| ---------- | -------------------------------------- | -------------------------------------------------------------- |
| `textured` | The image's own silhouette             | Nothing                                                        |
| `circle`   | A circle inscribed in the quad         | Nothing                                                        |
| `ellipse`  | An ellipse filling the quad's width    | Its height as a fraction of the quad's                         |
| `ring`     | A circle with a hole                   | The hole's radius as a fraction of the outer one               |
| `rounded`  | A rectangle with rounded corners       | The corner radius as a fraction of the quad                    |
| `frame`    | The quad's outline                     | The border's thickness as a fraction of the quad's half extent |
| `capsule`  | A bar with semicircular caps           | Its thickness as a fraction of the quad's height               |
| `line`     | A thick line along the quad's diagonal | Its thickness as a fraction of the quad                        |
| `pie`      | A wedge of a circle, opening upwards   | The sweep as a fraction of a full turn                         |
| `star`     | A five-pointed star, tip upwards       | How deep the valleys between the tips cut                      |
| `triangle` | A triangle, apex upwards               | Nothing                                                        |
| `glyph`    | A multi-channel distance-field glyph   | The field's range as a fraction of an atlas cell               |

`textured` takes its coverage from the texel's alpha at a threshold of a half, which is what makes a
cut-out sprite a cut-out: the pass writes depth and does not blend, so a quad that covered its whole
rectangle would hide whatever stood behind the transparent part of the image as well as painting over it.
The test is on the texture's own alpha rather than on the product with the tint, so an entity with no
`Sprite` samples the opaque white layer and draws at whatever tint alpha it carries. A half rather than any
nonzero alpha because coverage here is a yes or a no: a texel kept at low alpha lands at full strength as a
dark fringe rather than as a soft edge. An image authored with a soft edge therefore gets a hard one, cut
where the artwork crosses half alpha.

`glyph` is the material [text](/modules/gfx/) selects, and it is unlit, so a caption draws at its own
colour rather than being left in the dark by a scene's lights.

Only three of them claim a shape to the lighting pass: `circle` and `ellipse` return a dome, `capsule`
returns a cylinder with hemispherical caps, and everything else is flat and facing the viewer. That is
per material rather than per texture, so a sprite that wants a normal per texel wants a normal map, which
is a sidecar image and is not built.

`line` is the one whose parameterisation is worth stating: it runs along the quad's diagonal, so
placing it at the midpoint of two points and scaling it by their signed difference draws the segment
joining them. A negative scale mirrors the quad and takes the diagonal with it, so either direction
works without the material knowing which.

## Authoring one

A material file defines one function, `material`, taking a `MaterialInput` and answering a
`MaterialOutput`. It decides what colour a fragment is and whether the fragment exists at all; it
does not decide where the geometry is, which is the instance's transform and the same for every
material.

**What it is handed:**

| Field   | Type    | What it is                                                     |
| ------- | ------- | -------------------------------------------------------------- |
| `local` | `vec2`  | Position within the quad, -0.5 to 0.5 on both axes             |
| `uv`    | `vec3`  | Atlas coordinates and array layer, for a material that samples |
| `color` | `vec4`  | The instance's tint                                            |
| `param` | `float` | The instance's material parameter, zero to one                 |

**What it answers with:**

| Field      | Type    | What it is                                                                                    |
| ---------- | ------- | --------------------------------------------------------------------------------------------- |
| `albedo`   | `vec4`  | The fragment's colour                                                                         |
| `normal`   | `vec3`  | Which way the surface faces, in the quad's own space: X and Y along its axes and +Z out of it |
| `lit`      | `float` | Zero leaves the fragment out of the lighting pass entirely, so it draws at its own colour     |
| `coverage` | `float` | At or below zero the fragment is discarded                                                    |

Coverage rather than alpha, because the G-buffer pass writes with replace rather than blend: a partly
covered fragment would overwrite what is behind it instead of blending into it. Each shape material
answers with a signed distance rather than a yes or a no, positive inside, in the quad's own
coordinates, so an edge is as exact at five hundred pixels as at five.

Every material starts from `materialDefaults()` rather than declaring a bare `MaterialOutput`, which
is what lets the contract grow a field without every material in every root having to learn about it
on the same day. The default normal is flat and facing the viewer, because a 2D sprite genuinely has
no normal, and a material claims a shape only where its own silhouette is one.

A normal is carried into the world by the instance's rotation and by whichever axes its scale mirrored,
and not by the scale itself, so writing a dome on an entity stretched to ten by one still gives a dome
rather than something read as flat. A shape is taken to swell with itself: a 2D transform says how wide
and how tall a thing is drawn and nothing about how far it stands out of the plane. A negative scale does
flip the normal with the quad, which is what a mirrored surface facing the other way means.

Two helpers come with the contract: `domeNormal(rim)`, the normal of a dome over a flat field, and
`sdRoundedBox(p, extent, radius)`, the signed distance to a rounded box. The shared image array is
bound as `images`, sampled nearest.

```glsl
// A rectangle with rounded corners. `param` is the radius, as a fraction of
// the quad, so half of it is a circle.

MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -sdRoundedBox(frag.local, vec2(0.5), frag.param);
    result.lit = 1.0;
    return result;
}
```

The file's name without its extension is the material's name, and that is how a game asks for it. The
function is renamed rather than namespaced on the way into the dispatch, because GLSL has no
namespaces and two materials both defining `material` would collide.

## Names and ids

The default material always takes id zero, because an entity with no `Material` component writes a
zero and that has to mean something specific. The rest are numbered from one by sorted name, so the
same files always produce the same numbering.

### defaultName

```teal
materials.defaultName: string
```

Name of the material an entity with no `Material` component draws as. It is `textured`.

### id

The id a material is dispatched by, resolved from its name.

```teal
function materials.id(name: string): integer
```

**Returns:** the id. A name no material was found under raises, and the message lists what was found.
Calling this installs the materials if they are not installed already.

### find

The same lookup, answering nil instead of raising.

```teal
function materials.find(name: string): integer
```

**Returns:** the id, or nil when nothing has that name. What `id` is built on, for a caller with somewhere
better to put the refusal than an error raised from here.

### name

The material an id dispatches to.

```teal
function materials.name(id: integer): string
```

**Returns:** the name, or nil when nothing has that id.

### names

Every material name, in id order.

```teal
function materials.names(): {string}
```

**Returns:** a fresh list the caller owns. The default first at id zero, then the rest
alphabetically. It is not sorted as a whole: the default's place is fixed by what a zero on an
instance has to mean, wherever its own name would otherwise fall.

::: warning Ids are not stable across a rebuild
Adding a material renumbers the ones after it alphabetically. That matters only for something that
stored an id across a rebuild, which is why `Material` components are built from `materials.id(name)`
and never from a literal.
:::

That is also why a `Material` crosses a snapshot as its material's name rather than as its id, the way a
`Sprite` carries its image's name. A snapshot outlives the process, and a build with one more material file
would read an id that means a different shader and render the scene wrong without saying so. `name` writes
it and `find` resolves it again; a name this build does not have raises and says which one, since falling
back to the default or dropping the component are the same silent wrong shader by another route.

## Adding your own

### addRoot

Adds a directory to search before the ones already known, so a game's materials are found alongside
the engine's.

```teal
function materials.addRoot(path: string)
```

The default root is `materials/` under the asset root. A nearer root wins a name, and roots added
later are searched first. Adding a root puts the dispatch back to being unbuilt, so the next shader
load rebuilds it.

### define

Supplies a material from memory rather than a file.

```teal
function materials.define(name: string, source: string)
```

For a spec, and for a game that generates one at build time. A definition beats a file of the same
name in any root, and renumbers the set on the next `install` exactly as adding a file would.

### install

Reads the materials and publishes the dispatch. Idempotent.

```teal
function materials.install()
```

Called by shader loading rather than by a game, so a fragment shader cannot be built before the
materials it dispatches to are known. Adding a root or defining a material puts this back on.

### reset

Forgets everything read, so a spec can start from the files again.

```teal
function materials.reset()
```

## Re-reading materials

```teal
function materials.reload(): boolean, string
```

**Returns:** whether the dispatch was rebuilt, then why not.

Re-reads every material in every root and republishes the dispatch. Materials supplied through
`define` are kept as they are: those came from memory rather than a root, and nothing on disk has an
opinion about them.

Refused when the set of materials has changed, and that refusal is the whole reason there is a rule
here rather than a plain re-read. Ids come from sorted name order, so a file appearing or
disappearing renumbers every material after it alphabetically, while a `Material` component in a live
world holds a number that was resolved before the change. Editing a body reloads; adding or removing
one is a restart. A refusal puts back exactly what was dispatched before, ids included.

The [debug server](/modules/mcp) exposes this as its `reload_shaders` tool, together with the shader half of the
reload. A build that links no compiler cannot reload at all, because a pack decided the shader format
the device claimed when it was created.

## Where a material ends up

The dispatch is published to the shader loader as a generated include named `materials.glsl`, which
the instance fragment shader includes; it has no file of its own. GLSL goes to SPIR-V through
shaderc, then to MSL through SPIRV-Cross.

A release compiles nothing. `make shaders` walks the shader registry and writes a pack, and the
builder installs the materials before it enumerates anything, so the packaged dispatch knows about
exactly the material files that were present at build time and cannot drift from what a development
build would have compiled. `assets/materials/` is globbed when the tree is assembled, so a material
file added there is in the build the next time it runs.

## Reference

Every function and type this module carries, rendered from `src/tecs/gpu/materials.tl`.

### tecs.gfx.materials.Material

One material: its name, the id this build gave it, and its source.


### tecs.gfx.materials.Material.name

The file's name without its extension, and how a game asks for it.


### tecs.gfx.materials.Material.id

What an instance carries to select this material. Assigned by
`install` from sorted order, so it holds only for the set of files
that were present when the dispatch was built.


### tecs.gfx.materials.Material.source

The material's GLSL, as read. Renamed on the way into the dispatch
rather than here, so this is still the text the file holds.


### tecs.gfx.materials.addRoot

Adds a directory to search before the ones already known, so a game's
materials are found alongside the engine's.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                                                                               |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| string | path | Searched ahead of every root already added, so a game's file of a given name beats the engine's. A trailing slash is added when it is missing. The directory is not read here: this only puts the next `install` back on. |

### tecs.gfx.materials.defaultName

Name of the material an entity with no Material component draws as.


### tecs.gfx.materials.define

Supplies a material from memory rather than a file.

For a spec, and for a game that generates one at build time. Beats a
file of the same name in any root, and renumbers the set on the next
`install` as adding a file would.

#### Parameters

| Type                      | Name                      | Description                                                                             |
| ------------------------- | ------------------------- | --------------------------------------------------------------------------------------- |
| string | name   | The name a game asks for, and what a file would have been called without its extension. |
| string | source | The material's GLSL, taken as given and renamed only on the way into the dispatch.      |

### tecs.gfx.materials.find

The id a material is dispatched by, or nil when nothing has that name.

What `id` is built on, for a caller with somewhere better to put the
refusal than an error raised from here. Reading a `Material` back out of
a snapshot is that caller: the name it holds is a fact about the file
rather than about the call site, and the message says so.

#### Parameters

| Type                      | Name                    | Description                                     |
| ------------------------- | ----------------------- | ----------------------------------------------- |
| string | name | The material's file name without its extension. |

#### Returns

| Type                       | Description                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | The id, or nil for a name nothing has. Installs first, so a name is resolved against the materials on disk rather than against whatever had been read so far. |

### tecs.gfx.materials.id

The id a material is dispatched by, or an error naming what was found.

Resolved by name so a game never writes a number: the numbering depends
on which files exist, and hard-coding one would break the moment a
material was added ahead of it alphabetically.

#### Parameters

| Type                      | Name                    | Description                                     |
| ------------------------- | ----------------------- | ----------------------------------------------- |
| string | name | The material's file name without its extension. |

#### Returns

| Type                       | Description                                                                                                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | The id an instance carries to select it. Raises on a name nothing has, listing what there was, because a misspelled material is a build mistake rather than a runtime condition. |

### tecs.gfx.materials.install

Reads the materials and publishes the dispatch. Idempotent.

Called by shader loading rather than by a game, so a fragment shader
cannot be built before the materials it dispatches to are known. Adding
a root or defining a material puts this back on, and the next load
rebuilds.


### tecs.gfx.materials.name

The material an id dispatches to, or nil when nothing has that id.

The reverse of `id`, and what a snapshot writes in place of the number.
Nothing is kept in step to answer it: `order` already holds the names at
their ids, counting from one, so this is the lookup the numbering was
assigned from rather than a second copy of it.

#### Parameters

| Type                       | Name                  | Description                                                                                                                     |
| -------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| integer | id | An id as an instance carries it. Nil answers nil rather than raising, so a component read back with no material needs no guard. |

#### Returns

| Type                      | Description                                           |
| ------------------------- | ----------------------------------------------------- |
| string | The material's name, or nil when nothing has that id. |

### tecs.gfx.materials.names

Every material name, in id order.

The default first at id zero, then the rest alphabetically. Not sorted
as a whole: the default's place is fixed by what a zero on an instance
has to mean, wherever its own name would otherwise fall.

#### Returns

| Type                        | Description                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------ |
| {string} | A fresh list the caller owns, indexed from one while the ids it describes count from zero. |

### tecs.gfx.materials.reload

Re-reads every material and republishes the dispatch.

Refused when the set of materials has changed, and this is the whole
reason there is a rule rather than a re-read. Ids come from sorted name
order, so a file appearing or disappearing renumbers every material
after it alphabetically, and a `Material` component in a live world
holds a number that was resolved before the change. Editing a body
reloads; adding or removing one is a restart.

Materials supplied through `define` are kept as they are: those came
from memory rather than a root, and nothing on disk has an opinion about
them.

#### Returns

| Type                       | Description                                         |
| -------------------------- | --------------------------------------------------- |
| boolean | Whether the dispatch was rebuilt.                   |
| string  | Why not, and nil whenever the first answer is true. |

### tecs.gfx.materials.reset

Forgets everything read, so a spec can start from the files again.

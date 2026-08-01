--[=[
Material selection, shader authoring, built-ins, and reload rules.

A material decides a fragment's color, coverage, surface normal, and lighting
response. Resolve its id by name when creating a
[`Material`](tealdoc:tecs.components.Material) component:

```teal
tecs.gfx.materials.addRoot("game/materials/")

world:spawn(
    tecs.Transform2D(120, 80, 0, 1, 0, 64, 64),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0.25),
    tecs.gfx.Tint(0.2, 0.6, 1.0, 1.0),
    tecs.gfx.Renderable2D()
)
```

Add game roots before loading shaders or resolving ids. An entity without a
[`Material`](tealdoc:tecs.components.Material) uses `textured` at id zero. Remaining ids follow
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

A `.glsl` file under a material root defines one `material` function:

```glsl
MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    float radius = mix(0.02, 0.20, frag.param);

    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = -sdRoundedBox(
        frag.local,
        vec2(0.5),
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
instance to the blended lane instead, and so does a particle effect whose
`render.blend` asks for it. A material that resolves an edge by discarding should
put the edge in alpha where `frag.blended` is set, which is what `textured` does.

## Surface properties

`orm` carries ambient occlusion, roughness, and metallic in RGB. Alpha is
reserved. `materialDefaults` returns `vec4(1.0, 0.5, 0.0, 1.0)`: fully
unoccluded, medium roughness, and non-metallic.

Ambient occlusion multiplies ambient lighting only. A point light is a known
directional contribution and keeps its own brightness; shadow components
control whether that light reaches a fragment. Roughness and metallic are
stored in the G-buffer for the physically based light term. The current Lambert
term does not consume them yet.

```glsl
MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = 1.0;
    // The instance parameter controls authored ambient occlusion.
    result.orm = vec4(frag.param, 0.8, 0.0, 1.0);
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

```glsl
MaterialOutput material(MaterialInput frag) {
    MaterialOutput result = materialDefaults();
    result.albedo = texture(images, frag.uv) * frag.color;
    result.coverage = 1.0;
    // A warm glow at the strength the instance asked for.
    result.emission = vec4(1.0, 0.6, 0.2, frag.param);
    return result;
}
```

Every built-in material emits nothing, so a scene glows only where a material
says it does. Per-entity strength and color come from `frag.param` and
`frag.color`, which a material reads as it chooses.

The emission attachment is eight bits a channel, so a value above one is clamped
to one. Keep the color in range and vary the strength.

An entity in the blended lane adds its own emission to its own color and reaches
the emission attachment not at all, because the forward pass runs after the
G-buffer has been resolved. It therefore glows, and it does not reach a later
pass that reads the attachment.

## Reloads

`reload` accepts edits to existing material bodies. It refuses additions,
removals, and renames because those changes can renumber live components. A
refusal restores the previous set. Packaged builds cannot compile changed
material source at runtime.
]=]
-- Implementation details:
-- Every material function is renamed and folded into one generated fragment
-- shader dispatch. One dispatch preserves the renderer's single indirect draw
-- but may diverge when adjacent fragments select different materials.
-- Archetype-contiguous instance layout keeps similar entities clustered.
--
-- Shader-pack construction installs the same sorted material set before
-- compiling release shaders. Development reload rebuilds the dispatch and
-- renderer pipelines together.

local sdl <const> = require("tecs.ffi.sdl3")
local content <const> = require("tecs.platform.content")
local loader <const> = require("tecs.ffi.loader")
local shaders <const> = require("tecs.gpu.shaders")

local C <const> = sdl.C

--- The include the fragment shader pulls in. Generated, so it has no file.
local DISPATCH <const> = "materials.glsl"

--- Takes id zero. An entity with no Material component writes a zero, so this
--- is what "no material" draws as.
local DEFAULT <const> = "textured"

local record materials
    --- Describes one material by name, build-local id, and source.
    record Material
        --- Read-only. Reports the file name without its extension, which a
        --- game uses to request the material.
        name: string
        --- Read-only. Reports the id an instance carries to select this material. Assigned by
        --- `install` from sorted order, so it holds only for the set of files
        --- that were present when the dispatch was built.
        id: integer
        --- Read-only. Contains the material's GLSL as read. Renamed on the way into the dispatch
        --- rather than here, so this is still the text the file holds.
        source: string
    end

    --- Read-only. Reports the material name used by entities without a
    --- Material component.
    defaultName: string

    --- Adds a directory to search before the ones already known, so a game's
    --- materials are found alongside the engine's.
    ---
    --- @param path The function searches this directory before every existing
    ---     root, so a game's file of a given name beats the engine's. It adds a
    ---     trailing slash when needed. This call does not read the directory;
    ---     it schedules the next `install`.
    addRoot: function(path: string)

    --- Supplies a material from memory rather than a file.
    ---
    --- For a spec, and for a game that generates one at build time. Beats a
    --- file of the same name in any root, and renumbers the set on the next
    --- `install` as adding a file would.
    ---
    --- @param name The name a game asks for, matching a file stem.
    --- @param source The material's GLSL, taken as given and renamed only on
    ---     the way into the dispatch.
    define: function(name: string, source: string)

    --- Reads the materials and publishes the dispatch. Idempotent.
    ---
    --- Called by shader loading rather than by a game, so a fragment shader
    --- cannot be built before the materials it dispatches to are known. Adding
    --- a root or defining a material puts this back on, and the next load
    --- rebuilds.
    install: function()

    --- Re-reads every material and republishes the dispatch.
    ---
    --- This function refuses a changed material set. Ids come from sorted name
    --- order, so a file appearing or disappearing renumbers every later
    --- material. A live [`Material`](tealdoc:tecs.components.Material) component still holds
    --- the number resolved before that change. Editing a body reloads; adding
    --- or removing one requires a restart.
    ---
    --- The module retains materials supplied through `define` because they came
    --- from memory rather than a root.
    ---
    --- @return Returns true when the function rebuilds the dispatch.
    --- @return Returns the refusal reason, or nil after a rebuild.
    reload: function(): boolean, string

    --- Returns a material id or raises an error that names the available
    --- materials.
    ---
    --- Resolve by name because the file set determines numbering. Adding an
    --- earlier material may change later ids.
    ---
    --- @param name The material's file name without its extension.
    --- @return The id an instance carries to select it. Raises on a name
    ---     nothing has. The error lists available names because a misspelled
    ---     material indicates a build mistake, not a runtime condition.
    id: function(name: string): integer

    --- Returns a material id, or nil when no material has that name.
    ---
    --- What `id` is built on, for a caller with somewhere better to put the
    --- refusal than an error raised from here. Reading a
    --- [`Material`](tealdoc:tecs.components.Material) back out of a snapshot is that
    --- caller: the name it holds is a fact about the file
    --- rather than about the call site, and the message says so.
    ---
    --- @param name The material's file name without its extension.
    --- @return Returns the id, or nil for an unknown name. The function
    ---     installs first and resolves against the complete on-disk set.
    find: function(name: string): integer

    --- Returns the material name represented by an id, or nil.
    ---
    --- The reverse of `id`, and what a snapshot writes in place of the number.
    --- Nothing is kept in step to answer it: `order` already holds the names at
    --- their ids, counting from one, so this is the lookup the numbering was
    --- assigned from rather than a second copy of it.
    ---
    --- @param id An id as an instance carries it. Nil answers nil rather than
    ---     raising, so a component read back with no material needs no guard.
    --- @return The material's name, or nil when nothing has that id.
    name: function(id: integer): string

    --- Returns every material name in id order.
    ---
    --- The default occupies id zero, followed by the other names
    --- alphabetically. The module fixes the default's position because zero on
    --- an instance must select it.
    ---
    --- @return A fresh list the caller owns, indexed from one while the ids it
    ---     describes count from zero.
    names: function(): {string}

    --- Forgets everything read, so a spec can start from the files again.
    reset: function()
end

materials.defaultName = DEFAULT

local byName <const>: {string: materials.Material} = {}
--- Names supplied from memory rather than read from a root. Held apart so a
--- re-read can drop what came from a file without dropping these, which beat
--- a file of the same name.
local defined <const>: {string: boolean} = {}
local order: {string} = {}
local roots: {string} = nil
local built = false

local function searchRoots(): {string}
    if roots == nil then
        roots = {content.assetPath("materials/")}
    end
    return roots
end

function materials.addRoot(path: string)
    local list = searchRoots()
    table.insert(list, 1, path:sub(-1) == "/" and path or path .. "/")
    built = false
end

--- Turns a material name into something that can be a GLSL identifier.
local function mangle(name: string): string
    return "material_" .. (name:gsub("[^%w]", "_"))
end

function materials.define(name: string, source: string)
    byName[name] = {name = name, id = 0, source = source}
    defined[name] = true
    built = false
end

--- Reads every material in every root and assigns ids.
local function collect()
    for _, root in ipairs(searchRoots()) do
        local count = loader.newArray("int[1]")
        local found = C.SDL_GlobDirectory(root, "*.glsl", 0, count)
        if found ~= nil then
            local list = found as loader.CArray
            for index = 0, (tonumber(count[0]) as integer) - 1 do
                local file = loader.toString(list[index] as loader.CValue)
                local name = (file:gsub("%.glsl$", ""))
                -- A nearer root wins, and a definition beats both.
                if byName[name] == nil then
                    local source = content.read(root .. file)
                    if source ~= nil then
                        byName[name] = {name = name, id = 0, source = source}
                    end
                end
            end
            C.SDL_free(found as loader.CValue)
        end
    end

    local rest: {string} = {}
    for name in pairs(byName) do
        if name ~= DEFAULT then
            rest[#rest + 1] = name
        end
    end
    table.sort(rest)

    order = {}
    if byName[DEFAULT] ~= nil then
        order[1] = DEFAULT
    end
    for _, name in ipairs(rest) do
        order[#order + 1] = name
    end
    for index, name in ipairs(order) do
        byName[name].id = index - 1
    end
end

--- Builds the dispatch and hands it to the shader loader as an include.
local function assemble(): string
    local parts: {string} = {
        "// Generated from materials/. Do not edit.",
        "",
    }

    for _, name in ipairs(order) do
        local material = byName[name]
        -- Renamed rather than namespaced, because GLSL has no namespaces and
        -- two materials both defining `material` would collide.
        local renamed = material.source:gsub("%f[%w]material%s*%(", mangle(name) .. "(")
        parts[#parts + 1] = ("// %s (id %d)"):format(name, material.id)
        parts[#parts + 1] = renamed
        parts[#parts + 1] = ""
    end

    parts[#parts + 1] = "MaterialOutput materialDispatch(int id, MaterialInput frag) {"
    for _, name in ipairs(order) do
        local material = byName[name]
        parts[#parts + 1] = ("    if (id == %d) { return %s(frag); }"):format(material.id, mangle(name))
    end
    -- An unknown id is a bug rather than a state to render, so it is loud:
    -- magenta at full coverage is visible in any scene. Built from the
    -- defaults for the same reason every material is, so the fields this path
    -- has no opinion about are answers rather than whatever the stack held.
    parts[#parts + 1] = "    MaterialOutput unknown = materialDefaults();"
    parts[#parts + 1] = "    unknown.albedo = vec4(1.0, 0.0, 1.0, 1.0);"
    parts[#parts + 1] = "    return unknown;"
    parts[#parts + 1] = "}"
    parts[#parts + 1] = ""

    return table.concat(parts, "\n")
end

function materials.install()
    if built then
        return
    end
    built = true
    collect()
    shaders.provide(DISPATCH, assemble())
end

function materials.id(name: string): integer
    local id = materials.find(name)
    if id == nil then
        error(("tecs: no material named '%s'; found %s"):format(name, table.concat(materials.names(), ", ")), 2)
    end
    return id
end

function materials.find(name: string): integer
    materials.install()
    local material = byName[name]
    if material == nil then
        return nil
    end
    return material.id
end

function materials.name(id: integer): string
    materials.install()
    if id == nil then
        return nil
    end
    return order[id + 1]
end

function materials.names(): {string}
    materials.install()
    local list: {string} = {}
    for index, name in ipairs(order) do
        list[index] = name
    end
    return list
end

function materials.reload(): boolean, string
    materials.install()

    local previousOrder = order
    local previousByName: {string: materials.Material} = {}
    for name, material in pairs(byName) do
        previousByName[name] = material
    end

    for name in pairs(byName) do
        if not defined[name] then
            byName[name] = nil
        end
    end
    collect()

    local changed = #order ~= #previousOrder
    if not changed then
        for index, name in ipairs(order) do
            if name ~= previousOrder[index] then
                changed = true
            end
        end
    end
    if not changed then
        shaders.provide(DISPATCH, assemble())
        return true
    end

    -- Put back exactly what was dispatched before, ids included: the re-read
    -- renumbered whatever it kept, and a refusal has to leave nothing changed.
    local found = table.concat(order, ", ")
    for name in pairs(byName) do
        byName[name] = nil
    end
    for name, material in pairs(previousByName) do
        byName[name] = material
    end
    order = previousOrder
    for index, name in ipairs(order) do
        byName[name].id = index - 1
    end
    return false,
        (
            "the material set changed from [%s] to [%s]; ids are "
            .. "assigned by name order, so reloading would change what every "
            .. "Material component in the world means"
        ):format(table.concat(previousOrder, ", "), found)
end

function materials.reset()
    for name in pairs(byName) do
        byName[name] = nil
    end
    for name in pairs(defined) do
        defined[name] = nil
    end
    order = {}
    roots = nil
    built = false
end

return materials

--- Materials: what a fragment is, decided per instance.
---
--- A material is a `.glsl` file under `materials/` implementing the contract in
--- `shaders/include/material.glsl`. Every material found is compiled into the
--- same fragment shader, its `material` function renamed, and a generated
--- dispatch selects between them by an id carried on the instance.
---
--- One shader rather than one per material, because the alternative is a
--- pipeline and a draw call per material, and the whole point of the unified
--- batch is that the scene is one draw. What it costs is fragment divergence
--- where adjacent instances differ, which archetype-contiguous layout already
--- keeps small: entities of a kind cluster.
---
--- The default material always takes id zero, because an entity with no
--- Material component writes a zero and has to mean something specific. The
--- rest are numbered by sorted name, so the same files always produce the same
--- numbering. Adding a material renumbers the ones after it alphabetically,
--- which is why an id is a within-a-build answer and nothing stores one: a
--- name is what a material is identified by anywhere the number has to
--- outlive the set of files it was assigned from.

local sdl <const> = require("tecs.ffi.sdl3")
local filesystem <const> = require("tecs.platform.filesystem")
local loader <const> = require("tecs.ffi.loader")
local paths <const> = require("tecs.platform.paths")
local shaders <const> = require("tecs.gpu.shaders")

local C <const> = sdl.C

--- The include the fragment shader pulls in. Generated, so it has no file.
local DISPATCH <const> = "materials.glsl"

--- Takes id zero. An entity with no Material component writes a zero, so this
--- is what "no material" draws as.
local DEFAULT <const> = "textured"

--- The material set and the dispatch compiled from it.
---
--- Reads `materials/` in every root and publishes one generated include that
--- the fragment shader selects through. A game names a material and asks `id`
--- for the number an instance carries; the number itself is a within-a-build
--- answer and nothing should store one.
local record materials
    --- One material: its name, the id this build gave it, and its source.
    record Material
        --- The file's name without its extension, and how a game asks for it.
        name: string
        --- What an instance carries to select this material. Assigned by
        --- `install` from sorted order, so it holds only for the set of files
        --- that were present when the dispatch was built.
        id: integer
        --- The material's GLSL, as read. Renamed on the way into the dispatch
        --- rather than here, so this is still the text the file holds.
        source: string
    end

    --- Name of the material an entity with no Material component draws as.
    defaultName: string

    --- Adds a directory to search before the ones already known.
    addRoot: function(path: string)
    --- Supplies a material from memory rather than a file.
    define: function(name: string, source: string)
    --- Reads the materials and publishes the dispatch. Idempotent.
    install: function()
    --- Re-reads every material and republishes the dispatch, or refuses.
    reload: function(): boolean, string
    --- The id a material is dispatched by, resolved from its name.
    id: function(name: string): integer
    --- The same, answering nil rather than raising on a name nothing has.
    find: function(name: string): integer
    --- The material an id dispatches to, or nil when nothing has that id.
    name: function(id: integer): string
    --- Every material name, in id order.
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
        roots = {paths.asset("materials/")}
    end
    return roots
end

--- Adds a directory to search before the ones already known, so a game's
--- materials are found alongside the engine's.
function materials.addRoot(path: string)
    local list = searchRoots()
    table.insert(list, 1, path:sub(-1) == "/" and path or path .. "/")
    built = false
end

--- Turns a material name into something that can be a GLSL identifier.
local function mangle(name: string): string
    return "material_" .. (name:gsub("[^%w]", "_"))
end

--- Supplies a material from memory rather than a file.
---
--- For a spec, and for a game that generates one at build time. Beats a file
--- of the same name in any root, and renumbers the set on the next `install`
--- as adding a file would.
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
                    local source = filesystem.read(root .. file)
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

--- Reads the materials and publishes the dispatch. Idempotent.
---
--- Called by shader loading rather than by a game, so a fragment shader cannot
--- be built before the materials it dispatches to are known. Adding a root or
--- defining a material puts this back on, and the next load rebuilds.
function materials.install()
    if built then
        return
    end
    built = true
    collect()
    shaders.provide(DISPATCH, assemble())
end

--- The id a material is dispatched by, or an error naming what was found.
---
--- Resolved by name so a game never writes a number: the numbering depends on
--- which files exist, and hard-coding one would break the moment a material was
--- added ahead of it alphabetically.
function materials.id(name: string): integer
    local id = materials.find(name)
    if id == nil then
        error(("tecs: no material named '%s'; found %s"):format(name, table.concat(materials.names(), ", ")), 2)
    end
    return id
end

--- The id a material is dispatched by, or nil when nothing has that name.
---
--- What `id` is built on, for a caller with somewhere better to put the
--- refusal than an error raised from here. Reading a `Material` back out of a
--- snapshot is that caller: the name it holds is a fact about the file rather
--- than about the call site, and the message says so.
function materials.find(name: string): integer
    materials.install()
    local material = byName[name]
    if material == nil then
        return nil
    end
    return material.id
end

--- The material an id dispatches to, or nil when nothing has that id.
---
--- The reverse of `id`, and what a snapshot writes in place of the number.
--- Nothing is kept in step to answer it: `order` already holds the names at
--- their ids, counting from one, so this is the lookup the numbering was
--- assigned from rather than a second copy of it.
function materials.name(id: integer): string
    materials.install()
    if id == nil then
        return nil
    end
    return order[id + 1]
end

--- Every material name, in id order.
---
--- The default first at id zero, then the rest alphabetically. Not sorted as a
--- whole: the default's place is fixed by what a zero on an instance has to
--- mean, wherever its own name would otherwise fall.
--- @return A fresh list the caller owns.
function materials.names(): {string}
    materials.install()
    local list: {string} = {}
    for index, name in ipairs(order) do
        list[index] = name
    end
    return list
end

--- Re-reads every material and republishes the dispatch.
---
--- Refused when the set of materials has changed, and this is the whole reason
--- there is a rule rather than a re-read. Ids come from sorted name order, so a
--- file appearing or disappearing renumbers every material after it
--- alphabetically, and a `Material` component in a live world holds a number
--- that was resolved before the change. Editing a body reloads; adding or
--- removing one is a restart.
---
--- Materials supplied through `define` are kept as they are: those came from
--- memory rather than a root, and nothing on disk has an opinion about them.
--- @return Whether the dispatch was rebuilt.
--- @return Why not, and nil whenever the first answer is true.
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
    return false, (
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

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
--- which matters only for something that stored an id across a rebuild.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local paths <const> = require("tecs.platform.paths")
local shaders <const> = require("tecs.gpu.shaders")

local C <const> = sdl.C

--- The include the fragment shader pulls in. Generated, so it has no file.
local DISPATCH <const> = "materials.glsl"

--- Takes id zero. An entity with no Material component writes a zero, so this
--- is what "no material" draws as.
local DEFAULT <const> = "textured"

local record materials
    record Material
        name: string
        id: integer
        source: string
    end

    --- Name of the material an entity with no Material component draws as.
    defaultName: string

    addRoot: function(path: string)
    define: function(name: string, source: string)
    install: function()
    id: function(name: string): integer
    --- Every material name, sorted, which is also id order.
    names: function(): {string}
    reset: function()
end

materials.defaultName = DEFAULT

local byName <const>: {string: materials.Material} = {}
local order: {string} = {}
local roots: {string} = nil
local built = false

local function searchRoots(): {string}
    if roots == nil then roots = { paths.asset("materials/") } end
    return roots
end

--- Adds a directory to search before the ones already known, so a game's
--- materials are found alongside the engine's.
function materials.addRoot(path: string)
    local list = searchRoots()
    table.insert(list, 1, path:sub(-1) == "/" and path or path .. "/")
    built = false
end

local function readFile(path: string): string
    local size = loader.newArray("size_t[1]")
    local data = C.SDL_LoadFile(path, size)
    if data == nil then return nil end
    local text = loader.toBytes(data, tonumber(size[0]) as integer)
    C.SDL_free(data)
    return text
end

--- Turns a material name into something that can be a GLSL identifier.
local function mangle(name: string): string
    return "material_" .. (name:gsub("[^%w]", "_"))
end

--- Supplies a material from memory rather than a file. For a spec, and for a
--- game that generates one at build time.
function materials.define(name: string, source: string)
    byName[name] = { name = name, id = 0, source = source }
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
                    local source = readFile(root .. file)
                    if source ~= nil then
                        byName[name] = { name = name, id = 0, source = source }
                    end
                end
            end
            C.SDL_free(found as loader.CValue)
        end
    end

    local rest: {string} = {}
    for name in pairs(byName) do
        if name ~= DEFAULT then rest[#rest + 1] = name end
    end
    table.sort(rest)

    order = {}
    if byName[DEFAULT] ~= nil then order[1] = DEFAULT end
    for _, name in ipairs(rest) do order[#order + 1] = name end
    for index, name in ipairs(order) do byName[name].id = index - 1 end
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
        local renamed = material.source:gsub("%f[%w]material%s*%(",
            mangle(name) .. "(")
        parts[#parts + 1] = ("// %s (id %d)"):format(name, material.id)
        parts[#parts + 1] = renamed
        parts[#parts + 1] = ""
    end

    parts[#parts + 1] = "MaterialOutput materialDispatch(int id, MaterialInput frag) {"
    for _, name in ipairs(order) do
        local material = byName[name]
        parts[#parts + 1] = ("    if (id == %d) { return %s(frag); }")
            :format(material.id, mangle(name))
    end
    -- An unknown id is a bug rather than a state to render, so it is loud:
    -- magenta at full coverage is visible in any scene.
    parts[#parts + 1] = "    MaterialOutput unknown;"
    parts[#parts + 1] = "    unknown.albedo = vec4(1.0, 0.0, 1.0, 1.0);"
    parts[#parts + 1] = "    unknown.coverage = 1.0;"
    parts[#parts + 1] = "    return unknown;"
    parts[#parts + 1] = "}"
    parts[#parts + 1] = ""

    return table.concat(parts, "\n")
end

--- Reads the materials and publishes the dispatch. Idempotent.
function materials.install()
    if built then return end
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
    materials.install()
    local material = byName[name]
    if material == nil then
        error(("tecs2d: no material named '%s'; found %s")
            :format(name, table.concat(materials.names(), ", ")), 2)
    end
    return material.id
end

function materials.names(): {string}
    materials.install()
    local list: {string} = {}
    for index, name in ipairs(order) do list[index] = name end
    return list
end

--- Forgets everything read, so a spec can start from the files again.
function materials.reset()
    for name in pairs(byName) do byName[name] = nil end
    order = {}
    roots = nil
    built = false
end

return materials

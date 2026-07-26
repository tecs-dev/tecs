--- Finds shader sources, resolves their includes, and reads their variants.
---
--- GLSL lives in `.glsl` files under `shaders/` in an asset root, not in Lua
--- strings. The packaging step has to enumerate every shader the engine can
--- ask for, and a directory glob does that without a device, a window, a world,
--- or Lua running at all. Files also get syntax highlighting, a language server
--- and a formatter, which a long string does not.
---
--- A console having no filesystem does not argue against this: files are read
--- at build time on a developer's machine, and a release reads only the pack.
---
--- Stage is in the filename rather than a directory, because a shared include
--- has no home under `fragment/` or `vertex/` and is included by both.
---
---   shaders/instance.frag.glsl        fragment
---   shaders/instance.cull.comp.glsl   compute
---   shaders/include/depth.glsl        included, never compiled alone

local bit <const> = require("bit")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local paths <const> = require("tecs.platform.paths")

local C <const> = sdl.C

--- Filename suffix to stage.
local STAGES <const>: {string: string} = {
    vert = "vertex",
    frag = "fragment",
    comp = "compute",
}

--- Includes may nest this deep. Past it, the graph has a cycle.
local MAX_INCLUDE_DEPTH <const> = 16

local record shaders
    --- One shader source, resolved.
    record Entry
        --- Name without the `.glsl` extension, e.g. `instance.frag`. This is
        --- the key a packaged artifact is found under, so renaming a file
        --- invalidates any pack built before the rename.
        name: string
        --- "vertex", "fragment", or "compute".
        stage: string
        --- Source with every include already expanded.
        source: string
        --- Define sets declared by the file, beyond the empty one.
        variants: {{string: string}}
    end

    --- A source and one define set, with the key the pair is stored under.
    record Variant
        key: string
        name: string
        stage: string
        source: string
        defines: {string: string}
    end
end

--- Sources substituted in memory, which only specs do.
local overrides <const>: {string: string} = {}
--- Includes generated rather than read from disk. Materials are assembled
--- from many files into one dispatch, and that result has no file of its own.
local provided <const>: {string: string} = {}
--- Resolved entries, keyed by name.
local cache <const>: {string: shaders.Entry} = {}

--- Directories searched, nearest first. A game's own root goes ahead of the
--- engine's, so a game can replace an engine shader by name.
local roots: {string} = nil

local function searchRoots(): {string}
    if roots == nil then roots = { paths.asset("shaders/") } end
    return roots
end

--- Adds a directory to search before the ones already known.
function shaders.addRoot(path: string)
    local list = searchRoots()
    table.insert(list, 1, path:sub(-1) == "/" and path or path .. "/")
    for key in pairs(cache) do cache[key] = nil end
end

--- Reads a file through SDL, so this works wherever content lives.
local function readFile(path: string): string
    local size = loader.newArray("size_t[1]")
    local data = C.SDL_LoadFile(path, size)
    if data == nil then return nil end
    local text = loader.toBytes(data, tonumber(size[0]) as integer)
    C.SDL_free(data)
    return text
end

--- Locates `relative` in the first root that has it.
local function find(relative: string): string
    local generated = provided[relative]
    if generated ~= nil then return generated end
    for _, root in ipairs(searchRoots()) do
        local text = readFile(root .. relative)
        if text ~= nil then return text end
    end
    return nil
end

--- FNV-1a over the bytes, as eight hex digits.
---
--- Identifies a source so a pack built from different text is detected rather
--- than trusted. Hashed after includes are expanded, which is the whole reason
--- they are expanded here rather than left to the compiler: a hash of the
--- top-level file alone would not change when an include did, and a stale pack
--- would pass its own check.
function shaders.hash(text: string): string
    local h = 0x811c9dc5
    for i = 1, #text do
        h = bit.bxor(h, text:byte(i))
        h = bit.bor(0, bit.lshift(h, 24) + bit.lshift(h, 8)
            + bit.lshift(h, 7) + bit.lshift(h, 4) + bit.lshift(h, 1) + h)
    end
    return bit.tohex(h)
end

--- Expands `#include "name"` against the include directory.
---
--- Textual, and deliberately so. The compiler's own include callbacks resolve
--- after this point, which would leave the hash blind to an include changing,
--- and they would need a filesystem that only the packaging step has.
local function expand(text: string, depth: integer, seen: {string: boolean}): string
    if depth > MAX_INCLUDE_DEPTH then
        error("tecs2d: shader includes nest too deeply; check for a cycle", 0)
    end

    local result = text:gsub('#include%s+"([^"]+)"', function(name: string): string
        if seen[name] then
            error(("tecs2d: shader include cycle through '%s'"):format(name), 0)
        end
        -- Under `include/` first, then as given, so an include may carry its
        -- own extension or sit in a subdirectory.
        local included = find("include/" .. name) or find(name)
        if included == nil then
            error(("tecs2d: no shader include named '%s'"):format(name), 0)
        end
        seen[name] = true
        local expanded = expand(included, depth + 1, seen)
        seen[name] = nil
        return expanded
    end)
    return result
end

--- Reads `#pragma tecs2d variants A=1 B=2` lines into define sets.
---
--- Declared in the file rather than a manifest beside it, so the two cannot
--- disagree about what a shader needs. Each pragma line is one variant, and its
--- assignments are that variant's defines.
local function readVariants(text: string): {{string: string}}
    local list: {{string: string}} = {}
    for line in text:gmatch("#pragma%s+tecs2d%s+variants([^\n]*)") do
        local defines: {string: string} = {}
        local any = false
        for macro, value in line:gmatch("([%w_]+)=([^%s]+)") do
            defines[macro] = value
            any = true
        end
        if any then list[#list + 1] = defines end
    end
    return list
end

--- Substitutes a source in memory, for a spec probing a pass in isolation.
--- Pass nil to restore the file.
function shaders.override(name: string, source: string)
    overrides[name] = source
    cache[name] = nil
end

--- Supplies an include that has no file, resolved before any root is searched.
---
--- Everything cached is dropped, because a shader already resolved may have
--- included an older version of this one and its hash would no longer describe
--- what it would compile to.
function shaders.provide(name: string, source: string)
    provided[name] = source
    for key in pairs(cache) do cache[key] = nil end
end

--- The key a name and define set are stored under.
---
--- Defines are sorted so the key does not depend on table order, which in Lua
--- is not the order they were written in.
function shaders.key(name: string, defines?: {string: string}): string
    if defines == nil then return name end
    local parts: {string} = {}
    for macro, value in pairs(defines) do
        parts[#parts + 1] = macro .. "=" .. value
    end
    if #parts == 0 then return name end
    table.sort(parts)
    return name .. "|" .. table.concat(parts, ",")
end

--- Stage implied by a name's suffix, or nil if it has none.
local function stageOf(name: string): string
    local suffix = name:match("%.([^.]+)$")
    return suffix ~= nil and STAGES[suffix] or nil
end

--- Returns the entry named `name`, reading and resolving it once.
function shaders.get(name: string): shaders.Entry
    local cached = cache[name]
    if cached ~= nil then return cached end

    local stage = stageOf(name)
    if stage == nil then
        error(("tecs2d: '%s' does not name a stage; expected a .vert, .frag or "
            .. ".comp suffix"):format(name), 2)
    end

    local text = overrides[name]
    if text == nil then
        text = find(name .. ".glsl")
        if text == nil then
            error(("tecs2d: no shader file for '%s' under %s")
                :format(name, table.concat(searchRoots(), ", ")), 2)
        end
    end

    local entry: shaders.Entry = {
        name = name,
        stage = stage,
        source = expand(text, 0, {}),
        variants = readVariants(text),
    }
    cache[name] = entry
    return entry
end

--- Returns the resolved GLSL for `name`.
function shaders.source(name: string): string
    return shaders.get(name).source
end

--- Every shader in every root, by name, sorted.
---
--- `include/` is not searched: those are fragments meant to be pasted into a
--- stage, and compiling one alone would fail. A file whose name carries no
--- stage suffix is skipped for the same reason.
function shaders.list(): {shaders.Entry}
    local names: {string: boolean} = {}
    for name in pairs(overrides) do names[name] = true end

    for _, root in ipairs(searchRoots()) do
        local count = loader.newArray("int[1]")
        local found = C.SDL_GlobDirectory(root, "*.glsl", 0, count)
        if found ~= nil then
            local list = found as loader.CArray
            for index = 0, (tonumber(count[0]) as integer) - 1 do
                local file = loader.toString(list[index] as loader.CValue)
                names[(file:gsub("%.glsl$", ""))] = true
            end
            C.SDL_free(found as loader.CValue)
        end
    end

    local sorted: {string} = {}
    for name in pairs(names) do
        if stageOf(name) ~= nil then sorted[#sorted + 1] = name end
    end
    table.sort(sorted)

    local list: {shaders.Entry} = {}
    for index, name in ipairs(sorted) do list[index] = shaders.get(name) end
    return list
end

--- Every variant of every shader that a pack must contain.
---
--- The empty define set always counts, since that is what the engine asks for
--- unless it is assembling a material.
function shaders.buildList(): {shaders.Variant}
    local list: {shaders.Variant} = {}
    for _, entry in ipairs(shaders.list()) do
        local sets: {{string: string}} = { {} }
        for _, defines in ipairs(entry.variants) do
            sets[#sets + 1] = defines
        end
        for _, defines in ipairs(sets) do
            list[#list + 1] = {
                key = shaders.key(entry.name, defines),
                name = entry.name,
                stage = entry.stage,
                source = entry.source,
                defines = defines,
            }
        end
    end
    return list
end

return shaders

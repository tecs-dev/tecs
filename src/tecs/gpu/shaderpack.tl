--[=[
A built shader pack: what a release ships instead of a compiler.

SDL_GPU does not compile shaders. It takes bytecode in a backend-specific
format and is told, separately, how many resources of each class the shader
binds. So a pack has to carry more than code: it carries the reflection
too, because that is not recoverable from the translated output.

This module knows nothing about compiling. That is deliberate: it is loaded
by builds that link no compiler at all.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local content <const> = require("tecs.platform.content")

local K <const> = sdl.K

--- Identifies the file and its layout. The magic is checked so a wrong or
--- truncated file is reported as such rather than surfacing as a decode error
--- from somewhere inside the deserializer.
local MAGIC <const> = "TECSSP"

--- The shader pack format, and reading and writing it.
---
--- Encoding and decoding only: nothing here compiles, so a build that links no
--- compiler still loads this module. `shaderbuild` produces a pack and
--- `shadercompiler` consumes one.
local record shaderpack
    --- Resources a shader binds, as SDL_GPU counts them.
    ---
    --- This record lives here rather than in the compiler because it is part
    --- of the serialized layout: changing it changes the file format.
    record ResourceCounts
        --- Combined image samplers. SDL counts a texture and the sampler bound
        --- with it as one, so this is not textures plus samplers.
        samplers: integer
        --- Storage textures the shader only reads.
        readOnlyStorageTextures: integer
        --- Storage buffers the shader only reads, which is every storage buffer
        --- a graphics stage binds.
        readOnlyStorageBuffers: integer
        --- Zero outside compute: graphics storage bindings are read-only, and
        --- SDL's graphics shader creation has no field to put these in.
        readWriteStorageTextures: integer
        --- Storage buffers a compute shader writes, and what a caller must
        --- declare to `ComputePass.begin`. Zero outside compute.
        readWriteStorageBuffers: integer
        --- Uniform blocks the stage declares, which are pushed rather than
        --- bound.
        uniformBuffers: integer
    end

    --- One compiled shader variant.
    record Shader
        --- Name and define set, as `shaders.key` produces it. Unique within a
        --- pack, and what a lookup is by.
        key: string
        --- The source's name, which several keys share when it has variants.
        name: string
        --- "vertex", "fragment", or "compute".
        stage: string
        --- SDL shader format the code is in.
        format: integer
        --- Entry point name, which is not always `main`: MSL reserves that,
        --- so the translation renames it.
        entrypoint: string
        --- Hash of the GLSL this was built from, so a pack built before the
        --- source changed is detected rather than trusted.
        sourceHash: string
        --- What this variant binds, reflected when it was compiled. Carried
        --- because SDL needs the counts and translated output does not yield
        --- them.
        counts: ResourceCounts
        --- Declared workgroup size for compute, `{1, 1, 1}` otherwise.
        threadCount: {integer}
        --- Bytecode or backend source. Binary for SPIR-V, text for MSL.
        code: string
    end

    --- A whole pack: every variant a build produced, in one format.
    record Pack
        --- Layout this pack was written in. Checked against `VERSION` on read,
        --- so a build refuses a file it would misinterpret.
        version: integer
        --- Platform the pack was built for, as SDL names it. Informational:
        --- the format is what decides usability.
        target: string
        --- SDL shader format every entry is in. A pack is single-format,
        --- because the build knows which backend it is shipping for.
        format: integer
        --- Every variant, keyed as `shaders.key` produces it. A name the
        --- engine asks for that is missing from here is an error rather than a
        --- fallback, on a build that cannot compile.
        shaders: {string: Shader}
    end

    --- Layout this build writes and the only one it reads. Bumping it is what
    --- makes an older pack fail loudly instead of decoding into the wrong
    --- fields.
    ---
    --- Version 2 is version 1's fields with `sourceHash` computed differently.
    --- Version 3 replaces LuaJIT's architecture-dependent table serializer
    --- with an explicitly little-endian layout, so a host may build a pack
    --- for another architecture of the same shader backend.
    VERSION: integer
end

shaderpack.VERSION = 3

local FORMAT_NAMES <const>: {string} = {
    "private",
    "spirv",
    "dxbc",
    "dxil",
    "msl",
    "metallib",
}

--- Name of an SDL shader format, for diagnostics and for the manifest.
---
--- Falls back to the hexadecimal value rather than raising, since this is
--- reached from error paths and a name lookup that fails there would replace
--- the message the caller was trying to produce.
function shaderpack.formatName(format: integer): string
    local names: {integer: string} = {}
    names[K.SDL_GPU_SHADERFORMAT_PRIVATE] = "private"
    names[K.SDL_GPU_SHADERFORMAT_SPIRV] = "spirv"
    names[K.SDL_GPU_SHADERFORMAT_DXBC] = "dxbc"
    names[K.SDL_GPU_SHADERFORMAT_DXIL] = "dxil"
    names[K.SDL_GPU_SHADERFORMAT_MSL] = "msl"
    names[K.SDL_GPU_SHADERFORMAT_METALLIB] = "metallib"
    return names[format] or ("0x%x"):format(format)
end

--- The SDL shader format a name refers to.
--- @param name One of "private", "spirv", "dxbc", "dxil", "msl" or
---     "metallib", as `formatName` spells them. Anything else raises, which is
---     the difference from `formatName`.
function shaderpack.formatValue(name: string): integer
    for _, candidate in ipairs(FORMAT_NAMES) do
        if candidate == name then
            return K[("SDL_GPU_SHADERFORMAT_%s"):format(candidate:upper())]
        end
    end
    error(("tecs: '%s' is not a shader format"):format(tostring(name)), 2)
end

--- Serializes a pack.
---
--- The magic and a version byte, followed by length-prefixed strings and
--- little-endian unsigned integers. Map keys are sorted, so the same pack
--- produces the same bytes on every architecture.
function shaderpack.encode(pack: shaderpack.Pack): string
    if pack.version ~= shaderpack.VERSION then
        error(
            ("tecs: cannot write a version %s shader pack with version %d"):format(
                tostring(pack.version), shaderpack.VERSION
            ),
            2
        )
    end

    local parts: {string} = {MAGIC, string.char(shaderpack.VERSION)}

    local function uint32(value: number, field: string)
        if value < 0 or value > 0xffffffff or value ~= math.floor(value) then
            error(("tecs: shader pack %s is not an unsigned 32-bit integer"):format(field), 2)
        end
        parts[#parts + 1] = string.char(
            (value % 0x100) as integer,
            (math.floor(value / 0x100) % 0x100) as integer,
            (math.floor(value / 0x10000) % 0x100) as integer,
            (math.floor(value / 0x1000000) % 0x100) as integer
        )
    end

    local function bytes(value: string, field: string)
        uint32(#value, field .. " length")
        parts[#parts + 1] = value
    end

    bytes(pack.target, "target")
    uint32(pack.format, "format")

    local keys: {string} = {}
    for key in pairs(pack.shaders) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    uint32(#keys, "shader count")

    for _, key in ipairs(keys) do
        local shader = pack.shaders[key]
        if shader.key ~= key then
            error(("tecs: shader pack key '%s' contains shader '%s'"):format(key, tostring(shader.key)), 2)
        end
        bytes(shader.key, "shader key")
        bytes(shader.name, "shader name")
        bytes(shader.stage, "shader stage")
        uint32(shader.format, "shader format")
        bytes(shader.entrypoint, "shader entrypoint")
        bytes(shader.sourceHash, "shader source hash")
        uint32(shader.counts.samplers, "shader sampler count")
        uint32(shader.counts.readOnlyStorageTextures, "shader read-only storage texture count")
        uint32(shader.counts.readOnlyStorageBuffers, "shader read-only storage buffer count")
        uint32(shader.counts.readWriteStorageTextures, "shader read-write storage texture count")
        uint32(shader.counts.readWriteStorageBuffers, "shader read-write storage buffer count")
        uint32(shader.counts.uniformBuffers, "shader uniform buffer count")
        if #shader.threadCount ~= 3 then
            error(("tecs: shader '%s' does not have a three-dimensional thread count"):format(key), 2)
        end
        uint32(shader.threadCount[1], "shader thread count x")
        uint32(shader.threadCount[2], "shader thread count y")
        uint32(shader.threadCount[3], "shader thread count z")
        bytes(shader.code, "shader code")
    end

    return table.concat(parts)
end

local function decodeBody(bytes: string, offset: integer, origin: string): shaderpack.Pack
    local function uint32(field: string): integer
        if offset + 3 > #bytes then
            error(("%s ends inside %s"):format(origin, field), 0)
        end
        local a, b, c, d = bytes:byte(offset, offset + 3)
        offset = offset + 4
        return a + b * 0x100 + c * 0x10000 + d * 0x1000000
    end

    local function readBytes(field: string): string
        local length = uint32(field .. " length")
        if length > #bytes - offset + 1 then
            error(("%s ends inside %s"):format(origin, field), 0)
        end
        local value = bytes:sub(offset, offset + length - 1)
        offset = offset + length
        return value
    end

    local pack: shaderpack.Pack = {
        version = shaderpack.VERSION,
        target = readBytes("target"),
        format = uint32("format"),
        shaders = {},
    }
    local shaderCount = uint32("shader count")
    if shaderCount > #bytes - offset + 1 then
        error(("%s has an impossible shader count"):format(origin), 0)
    end

    for _ = 1, shaderCount do
        local key = readBytes("shader key")
        if pack.shaders[key] ~= nil then
            error(("%s contains shader '%s' twice"):format(origin, key), 0)
        end
        local shader: shaderpack.Shader = {
            key = key,
            name = readBytes("shader name"),
            stage = readBytes("shader stage"),
            format = uint32("shader format"),
            entrypoint = readBytes("shader entrypoint"),
            sourceHash = readBytes("shader source hash"),
            counts = {
                samplers = uint32("shader sampler count"),
                readOnlyStorageTextures = uint32("shader read-only storage texture count"),
                readOnlyStorageBuffers = uint32("shader read-only storage buffer count"),
                readWriteStorageTextures = uint32("shader read-write storage texture count"),
                readWriteStorageBuffers = uint32("shader read-write storage buffer count"),
                uniformBuffers = uint32("shader uniform buffer count"),
            },
            threadCount = {
                uint32("shader thread count x"),
                uint32("shader thread count y"),
                uint32("shader thread count z"),
            },
            code = readBytes("shader code"),
        }
        pack.shaders[key] = shader
    end

    if offset ~= #bytes + 1 then
        error(("%s has %d trailing bytes"):format(origin, #bytes - offset + 1), 0)
    end
    return pack
end

--- Deserializes a pack, raising if it is not one or is a layout this build
--- does not read.
--- @param origin What to name in an error, usually the path the bytes came
---     from. Defaults to "<memory>".
function shaderpack.decode(bytes: string, origin?: string): shaderpack.Pack
    origin = origin or "<memory>"
    if #bytes < #MAGIC + 1 or bytes:sub(1, #MAGIC) ~= MAGIC then
        error(("tecs: %s is not a shader pack"):format(origin), 2)
    end
    local version = bytes:byte(#MAGIC + 1)
    if version ~= shaderpack.VERSION then
        error(
            ("tecs: %s is a version %d shader pack, this build reads %d"):format(origin, version, shaderpack.VERSION), 2
        )
    end
    local ok, decoded = pcall(decodeBody, bytes, #MAGIC + 2, origin)
    if not ok then
        error(("tecs: %s is a corrupt shader pack: %s"):format(origin, tostring(decoded)), 2)
    end
    return decoded as shaderpack.Pack
end

--- Writes a pack to `path`.
---
--- Build-time only, and the only thing here that touches stdio: writing beside
--- the executable is not permitted on the targets a pack exists for.
function shaderpack.write(path: string, pack: shaderpack.Pack)
    local file, reason = io.open(path, "wb")
    if file == nil then
        error(("tecs: cannot write %s: %s"):format(path, tostring(reason)), 2)
    end
    file:write(shaderpack.encode(pack))
    file:close()
end

--- Reads a pack from `path`, or nil if there is no file there.
function shaderpack.read(path: string): shaderpack.Pack
    local bytes = content.read(path)
    if bytes == nil then
        return nil
    end
    return shaderpack.decode(bytes, path)
end

return shaderpack

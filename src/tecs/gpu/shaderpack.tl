--- A built shader pack: what a release ships instead of a compiler.
---
--- SDL_GPU does not compile shaders. It takes bytecode in a backend-specific
--- format and is told, separately, how many resources of each class the shader
--- binds. So a pack has to carry more than code: it carries the reflection
--- too, because that is not recoverable from the translated output.
---
--- This module knows nothing about compiling. That is deliberate: it is loaded
--- by builds that link no compiler at all, so it depends only on SDL and the
--- loader.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K
local buffer <const> = require("string.buffer")

--- Identifies the file and its layout. The magic is checked so a wrong or
--- truncated file is reported as such rather than surfacing as a decode error
--- from somewhere inside the deserializer.
local MAGIC <const> = "TECSSP"

local record shaderpack
    --- Resources a shader binds, as SDL_GPU counts them.
    ---
    --- This record lives here rather than in the compiler because it is part
    --- of the serialized layout: changing it changes the file format.
    record ResourceCounts
        samplers: integer
        readOnlyStorageTextures: integer
        readOnlyStorageBuffers: integer
        readWriteStorageTextures: integer
        readWriteStorageBuffers: integer
        uniformBuffers: integer
    end

    --- One compiled shader variant.
    record Shader
        --- Name and define set, as `shaders.key` produces it.
        key: string
        name: string
        stage: string
        --- SDL shader format the code is in.
        format: integer
        --- Entry point name, which is not always `main`: MSL reserves that,
        --- so the translation renames it.
        entrypoint: string
        --- Hash of the GLSL this was built from, so a pack built before the
        --- source changed is detected rather than trusted.
        sourceHash: string
        counts: ResourceCounts
        --- Declared workgroup size for compute, `{1, 1, 1}` otherwise.
        threadCount: {integer}
        --- Bytecode or backend source. Binary for SPIR-V, text for MSL.
        code: string
    end

    record Pack
        version: integer
        --- Platform the pack was built for, as SDL names it. Informational:
        --- the format is what decides usability.
        target: string
        --- SDL shader format every entry is in. A pack is single-format,
        --- because the build knows which backend it is shipping for.
        format: integer
        shaders: {string: Shader}
    end

    VERSION: integer
end

shaderpack.VERSION = 1

local FORMAT_NAMES <const>: {string} = {
    "private", "spirv", "dxbc", "dxil", "msl", "metallib",
}

--- Name of an SDL shader format, for diagnostics and for the manifest.
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
function shaderpack.formatValue(name: string): integer
    for _, candidate in ipairs(FORMAT_NAMES) do
        if candidate == name then
            return K[("SDL_GPU_SHADERFORMAT_%s"):format(candidate:upper())]
        end
    end
    error(("tecs: '%s' is not a shader format"):format(tostring(name)), 2)
end

--- Serializes a pack.
function shaderpack.encode(pack: shaderpack.Pack): string
    return MAGIC .. string.char(shaderpack.VERSION)
        .. buffer.encode(pack as string) as string
end

--- Deserializes a pack, raising if it is not one or is a layout this build
--- does not read.
function shaderpack.decode(bytes: string, origin?: string): shaderpack.Pack
    origin = origin or "<memory>"
    if #bytes < #MAGIC + 1 or bytes:sub(1, #MAGIC) ~= MAGIC then
        error(("tecs: %s is not a shader pack"):format(origin), 2)
    end
    local version = bytes:byte(#MAGIC + 1)
    if version ~= shaderpack.VERSION then
        error(("tecs: %s is a version %d shader pack, this build reads %d")
            :format(origin, version, shaderpack.VERSION), 2)
    end
    local ok, decoded = pcall(function(): any
        return buffer.decode(bytes:sub(#MAGIC + 2)) as any
    end)
    if not ok then
        error(("tecs: %s is a corrupt shader pack: %s")
            :format(origin, tostring(decoded)), 2)
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
---
--- Read through SDL rather than stdio, because on Android content lives inside
--- the package and only SDL's IO reaches it.
function shaderpack.read(path: string): shaderpack.Pack
    local size = loader.newArray("size_t[1]")
    local data = C.SDL_LoadFile(path, size)
    if data == nil then return nil end
    local bytes = loader.toBytes(data, tonumber(size[0]) as integer)
    C.SDL_free(data)
    return shaderpack.decode(bytes, path)
end

return shaderpack

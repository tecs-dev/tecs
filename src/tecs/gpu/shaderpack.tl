--- A built shader pack: what a release ships instead of a compiler.
---
--- SDL_GPU does not compile shaders. It takes bytecode in a backend-specific
--- format and is told, separately, how many resources of each class the shader
--- binds. So a pack has to carry more than code: it carries the reflection
--- too, because that is not recoverable from the translated output.
---
--- This module knows nothing about compiling. That is deliberate: it is loaded
--- by builds that link no compiler at all.

local sdl <const> = require("tecs.ffi.sdl3")
local content <const> = require("tecs.platform.content")

local K <const> = sdl.K
local buffer <const> = require("string.buffer")

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
    --- The layout did not change, so a version 1 pack still decodes; what
    --- changed is that every hash in it now describes nothing this build
    --- computes, and every entry would be reported as built from source that
    --- has since been edited. That message would be wrong about why. Bumping
    --- the version replaces it with the true one.
    VERSION: integer
end

shaderpack.VERSION = 2

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
--- The magic and a version byte, then the pack itself. Not portable across
--- architectures: the body is LuaJIT's own serialization, which is what makes
--- it cheap to read, and a pack is built for one target anyway.
function shaderpack.encode(pack: shaderpack.Pack): string
    return MAGIC .. string.char(shaderpack.VERSION) .. buffer.encode(pack as string) as string
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
    local ok, decoded = pcall(function(): any return buffer.decode(bytes:sub(#MAGIC + 2)) as any end)
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

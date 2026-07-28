--- Builds a shader pack from the registry.
---
--- This runs at build time and needs the compiler, which is the point: it is
--- how a target that has no compiler gets shaders. It compiles through
--- `shadercompiler`, the same path a development build takes, so the packaged
--- reflection is produced by the same code that would have produced it at run
--- time rather than by a second implementation that can drift.
---
--- The manifest it emits alongside is for people. A pack is opaque, and
--- packaging that cannot be inspected is packaging that gets trusted when it
--- should be checked.

local shaders <const> = require("tecs.gpu.shaders")
local materials <const> = require("tecs.gpu.materials")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")

local C <const> = sdl.C

--- Compiles the registry into a pack, and writes it with a manifest beside it.
---
--- Build-time only: `build` and `writeTo` raise without a shader compiler, and
--- only `manifest` works without one. Reading a pack back is `shaderpack`,
--- which needs no compiler at all.
local record shaderbuild
end

--- Compiles every registered variant into a pack.
---
--- Every entry ends up in one format, because a build ships for one backend.
--- Building a pack for a backend this host cannot compile for is not possible
--- here and is not pretended to be: cross-compiling MSL needs Metal's tooling.
--- @return A pack holding every variant, keyed as `shaders.key` produces the
---     key. Raises without a compiler, and raises again if any variant came
---     back in a format other than the pack's.
function shaderbuild.build(): shaderpack.Pack
    if not shadercompiler.available() then
        error("tecs: building a shader pack needs a shader compiler", 2)
    end

    -- Materials are compiled into the fragment shader, so they have to be read
    -- before anything is enumerated or the pack would bake a dispatch that
    -- knows about none of them.
    materials.install()

    local pack: shaderpack.Pack = {
        version = shaderpack.VERSION,
        target = loader.toString(C.SDL_GetPlatform()),
        format = shadercompiler.format(),
        shaders = {},
    }

    for _, variant in ipairs(shaders.buildList()) do
        local compiled = shadercompiler.compile(
            variant.source,
            variant.stage,
            {
                name = variant.key,
                defines = variant.defines,
            }
        )
        if compiled.format ~= pack.format then
            error(
                ("tecs: '%s' compiled to %s but the pack is %s"):format(
                    variant.key, shaderpack.formatName(compiled.format), shaderpack.formatName(pack.format)
                ),
                2
            )
        end
        pack.shaders[variant.key] = {
            key = variant.key,
            name = variant.name,
            stage = variant.stage,
            format = compiled.format,
            entrypoint = compiled.entrypoint,
            sourceHash = shaders.hash(variant.source),
            counts = compiled.counts,
            threadCount = compiled.threadCount,
            -- Byte-exact what SDL reads, terminator included where the format
            -- is text, so loading a pack is a copy and not a reinterpretation.
            code = loader.toBytes(compiled.code as loader.CValue, compiled.codeSize),
        }
    end

    return pack
end

--- A readable listing of what a pack contains.
---
--- Sorted by key, so two builds of the same tree produce the same text and a
--- diff between them is the change rather than the ordering.
--- @param pack Read only, and readable without a compiler, so a pack decoded
---     from disk lists as well as one just built.
--- @return Plain text, newline separated, ending in a blank line.
function shaderbuild.manifest(pack: shaderpack.Pack): string
    local keys: {string} = {}
    for key in pairs(pack.shaders) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local lines: {string} = {}
    lines[#lines + 1] = ("tecs shader pack version %d"):format(pack.version)
    lines[#lines + 1] = ("target %s, format %s, %d shaders"):format(
        pack.target, shaderpack.formatName(pack.format), #keys
    )
    lines[#lines + 1] = ""
    lines[#lines + 1] = "key                          stage     bytes  entry  " .. "source            resources"
    lines[#lines + 1] = ("-"):rep(104)

    for _, key in ipairs(keys) do
        local entry = pack.shaders[key]
        local counts = entry.counts
        local resources = ("sam %d, ro %d/%d, rw %d/%d, uni %d"):format(
            counts.samplers,
            counts.readOnlyStorageTextures,
            counts.readOnlyStorageBuffers,
            counts.readWriteStorageTextures,
            counts.readWriteStorageBuffers,
            counts.uniformBuffers
        )
        local threads = ""
        if entry.stage == "compute" then
            threads = (" threads %dx%dx%d"):format(entry.threadCount[1], entry.threadCount[2], entry.threadCount[3])
        end
        lines[#lines + 1] = ("%-28s %-9s %6d  %-6s %-17s %s%s"):format(
            key, entry.stage, #entry.code, entry.entrypoint, entry.sourceHash, resources, threads
        )
    end

    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

--- Builds a pack, writes it to `path`, and writes its manifest beside it.
---
--- The manifest takes the same path with `.txt` appended, so the two travel
--- together and a pack in a tree is never there without its listing.
--- @return The pack that was written, so a caller can inspect what it built
---     without reading the file back.
function shaderbuild.writeTo(path: string): shaderpack.Pack
    local pack = shaderbuild.build()
    shaderpack.write(path, pack)

    local manifest, reason = io.open(path .. ".txt", "w")
    if manifest == nil then
        error(("tecs: cannot write %s.txt: %s"):format(path, tostring(reason)), 2)
    end
    manifest:write(shaderbuild.manifest(pack))
    manifest:close()

    return pack
end

return shaderbuild

-- Packaged shaders.
--
-- A target that forbids a shader compiler has to be handed compiled bytecode
-- and the reflection that goes with it, because SDL_GPU takes the resource
-- counts as arguments and cannot recover them from the code. So the thing
-- worth testing is not that a pack round-trips: it is that a build consuming
-- one renders the same pixels as a build that compiled the shaders itself, and
-- that a build with neither says so instead of opening a black window.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Renderer = require("tecs.Renderer")
local assets = require("tecs.assets")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local shaders = require("tecs.gpu.shaders")
local shaderpack = require("tecs.gpu.shaderpack")
local shaderbuild = require("tecs.gpu.shaderbuild")
local materials = require("tecs.gpu.materials")
local shadercompiler = require("tecs.gpu.shadercompiler")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform2D = tecs.Transform2D
local Tint = components.Tint
local Renderable2D = components.Renderable2D

describe("shaders", function()
    -- The fragment shader includes the material dispatch, which is generated
    -- rather than read from a file, so resolving one means reading the other.
    setup(function()
        assert(C.SDL_Init(0))
        materials.install()
    end)
    teardown(function()
        C.SDL_Quit()
    end)

    it("finds every shader the engine loads by globbing", function()
        -- The glob is what a packaging step enumerates, so a shader the engine
        -- asks for at run time but that no root contains is one no pack can
        -- hold.
        local names = {}
        for _, entry in ipairs(shaders.list()) do
            names[entry.name] = entry
        end

        for _, expected in ipairs({
            "instance.mark.comp",
            "instance.scan.comp",
            "instance.compact.comp",
            "instance.vert",
            "instance.frag",
            "deferred.fullscreen.vert",
            "deferred.lighting.frag",
            "deferred.composite.frag",
        }) do
            assert.is_not_nil(names[expected], expected .. " must be found")
        end
    end)

    it("takes the stage from the filename", function()
        assert.are.equal("fragment", shaders.get("instance.frag").stage)
        assert.are.equal("vertex", shaders.get("instance.vert").stage)
        assert.are.equal("compute", shaders.get("instance.mark.comp").stage)
    end)

    it("refuses a name with no stage in it", function()
        -- Otherwise an include would be compiled on its own, which fails much
        -- further along and much less clearly.
        assert.has_error(function()
            shaders.get("instance")
        end)
    end)

    it("says which directories it looked in when a file is missing", function()
        local ok, reason = pcall(shaders.get, "nothing.frag")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("shaders/", 1, true))
    end)

    it("expands an include into the source it hashes", function()
        -- The ordering is the point. The pack detects staleness by hashing
        -- source, so an include resolved later by the compiler would leave the
        -- hash unchanged when the include changed, and a stale pack would pass
        -- its own check.
        local mark = shaders.get("instance.mark.comp")
        assert.is_truthy(
            mark.source:find("const uint CULLED", 1, true),
            "the include's text must be present, not its directive"
        )
        assert.is_falsy(mark.source:find("#include", 1, true))

        -- And the same include reaches the pass on the other side of it, which
        -- is why it is an include rather than two copies.
        local compact = shaders.get("instance.compact.comp")
        assert.is_truthy(compact.source:find("const uint CULLED", 1, true))
    end)

    it("hashes what the include expanded to", function()
        local before = shaders.hash(shaders.get("instance.mark.comp").source)
        shaders.override("spec.probe.frag", '#version 450\n#include "cull.glsl"\n')
        local probe = shaders.get("spec.probe.frag")
        assert.is_truthy(probe.source:find("CULLED", 1, true))
        shaders.override("spec.probe.frag", nil)
        -- Unchanged by the probe, so the hash is of content and not of state.
        assert.are.equal(before, shaders.hash(shaders.get("instance.mark.comp").source))
    end)

    it("reads variants declared in the file", function()
        shaders.override(
            "spec.variants.frag",
            table.concat({
                "#version 450",
                "#pragma tecs variants LIGHTS=1",
                "#pragma tecs variants LIGHTS=4 SHADOWS=1",
                "void main() {}",
            }, "\n")
        )

        local entry = shaders.get("spec.variants.frag")
        assert.are.equal(2, #entry.variants)
        assert.are.equal("1", entry.variants[1].LIGHTS)
        assert.are.equal("4", entry.variants[2].LIGHTS)
        assert.are.equal("1", entry.variants[2].SHADOWS)

        -- The empty set always counts too, so the file yields three entries.
        local keys = {}
        for _, variant in ipairs(shaders.buildList()) do
            keys[variant.key] = true
        end
        assert.is_true(keys["spec.variants.frag"])
        assert.is_true(keys["spec.variants.frag|LIGHTS=1"])
        assert.is_true(keys["spec.variants.frag|LIGHTS=4,SHADOWS=1"])

        shaders.override("spec.variants.frag", nil)
    end)

    it("stops on an include cycle rather than recursing", function()
        shaders.override("spec.cycle.frag", '#version 450\n#include "spec.cycle.frag"\n')
        assert.has_error(function()
            shaders.get("spec.cycle.frag")
        end)
        shaders.override("spec.cycle.frag", nil)
    end)

    it("names an include it cannot find", function()
        shaders.override("spec.missing.frag", '#version 450\n#include "no-such-include.glsl"\n')
        local ok, reason = pcall(shaders.get, "spec.missing.frag")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("no-such-include", 1, true))
        shaders.override("spec.missing.frag", nil)
    end)

    it("keys a variant by its defines, not by table order", function()
        -- Lua does not iterate a table in insertion order, so a key built by
        -- walking one would differ between runs and miss its own pack entry.
        assert.are.equal("a.frag", shaders.key("a.frag"))
        assert.are.equal("a.frag", shaders.key("a.frag", {}))
        assert.are.equal(
            shaders.key("a.frag", { LIGHTS = "4", SHADOWS = "1" }),
            shaders.key("a.frag", { SHADOWS = "1", LIGHTS = "4" })
        )
    end)

    it("hashes source so a changed shader is detectable", function()
        local one = shaders.hash("#version 450\nvoid main() {}\n")
        assert.are.equal(16, #one)
        assert.are.equal(one, shaders.hash("#version 450\nvoid main() {}\n"))
        assert.are_not.equal(one, shaders.hash("#version 450\nvoid main(){}\n"))
    end)

    it("refuses a name it does not know", function()
        assert.has_error(function()
            shaders.get("nothing.frag")
        end)
    end)
end)

describe("shaderpack", function()
    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
    end)
    teardown(function()
        C.SDL_Quit()
    end)

    it("round-trips a pack through its container", function()
        local built = shaderbuild.build()
        local pack = shaderpack.decode(shaderpack.encode(built))

        assert.are.equal(built.version, pack.version)
        assert.are.equal(built.format, pack.format)
        for key, entry in pairs(built.shaders) do
            local other = pack.shaders[key]
            assert.is_not_nil(other, key .. " survived encoding")
            -- Code is compared by bytes: MSL is text but SPIR-V is not, and a
            -- container that mangled either would still decode.
            assert.are.equal(entry.code, other.code)
            assert.are.equal(entry.entrypoint, other.entrypoint)
            assert.are.equal(entry.sourceHash, other.sourceHash)
            assert.are.equal(entry.counts.samplers, other.counts.samplers)
            assert.are.equal(entry.counts.readOnlyStorageBuffers, other.counts.readOnlyStorageBuffers)
            assert.are.equal(entry.counts.uniformBuffers, other.counts.uniformBuffers)
        end
    end)

    it("encodes deterministically without LuaJIT's native serializer", function()
        local built = shaderbuild.build()
        local encoded = shaderpack.encode(built)

        local reversed = {
            version = built.version,
            target = built.target,
            format = built.format,
            shaders = {},
        }
        local keys = {}
        for key in pairs(built.shaders) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(left, right)
            return left > right
        end)
        for _, key in ipairs(keys) do
            reversed.shaders[key] = built.shaders[key]
        end

        assert.are.equal(encoded, shaderpack.encode(reversed))
        -- The first body field is the target. Its length is an explicit
        -- little-endian uint32, rather than a native-size LuaJIT table field.
        assert.are.equal(string.char(#built.target, 0, 0, 0) .. built.target, encoded:sub(8, 11 + #built.target))
    end)

    it("matches the portable format's golden bytes", function()
        local fixture = {
            version = shaderpack.VERSION,
            target = "T",
            format = 5,
            shaders = {
                k = {
                    key = "k",
                    name = "n",
                    stage = "v",
                    format = 5,
                    entrypoint = "e",
                    sourceHash = "h",
                    counts = {
                        samplers = 1,
                        readOnlyStorageTextures = 2,
                        readOnlyStorageBuffers = 3,
                        readWriteStorageTextures = 4,
                        readWriteStorageBuffers = 5,
                        uniformBuffers = 6,
                    },
                    threadCount = { 7, 8, 9 },
                    code = string.char(0, 65, 255, 66),
                },
            },
        }
        local golden = table.concat({
            "TECSSP",
            string.char(3),
            string.char(1, 0, 0, 0),
            "T",
            string.char(5, 0, 0, 0),
            string.char(1, 0, 0, 0),
            string.char(1, 0, 0, 0),
            "k",
            string.char(1, 0, 0, 0),
            "n",
            string.char(1, 0, 0, 0),
            "v",
            string.char(5, 0, 0, 0),
            string.char(1, 0, 0, 0),
            "e",
            string.char(1, 0, 0, 0),
            "h",
            string.char(1, 0, 0, 0),
            string.char(2, 0, 0, 0),
            string.char(3, 0, 0, 0),
            string.char(4, 0, 0, 0),
            string.char(5, 0, 0, 0),
            string.char(6, 0, 0, 0),
            string.char(7, 0, 0, 0),
            string.char(8, 0, 0, 0),
            string.char(9, 0, 0, 0),
            string.char(4, 0, 0, 0),
            string.char(0, 65, 255, 66),
        })

        assert.are.equal(golden, shaderpack.encode(fixture))
        local decoded = shaderpack.decode(golden)
        assert.are.equal(string.char(0, 65, 255, 66), decoded.shaders.k.code)
        assert.are.equal(6, decoded.shaders.k.counts.uniformBuffers)
        assert.are.same({ 7, 8, 9 }, decoded.shaders.k.threadCount)
    end)

    it("carries the reflection SDL_GPU cannot recover from code", function()
        local pack = shaderbuild.build()
        -- The lighting pass binds four G-buffer samplers for albedo, the normal,
        -- ORM and emission, three storage buffers for the lights and the two halves
        -- of the tile grid, and one uniform block. Those numbers are arguments to
        -- shader creation, so a pack that dropped them would create a shader that
        -- binds nothing and draws black.
        local lighting = pack.shaders["deferred.lighting.frag"]
        assert.are.equal(4, lighting.counts.samplers)
        assert.are.equal(3, lighting.counts.readOnlyStorageBuffers)
        assert.are.equal(1, lighting.counts.uniformBuffers)

        local shadowed = pack.shaders["deferred.lighting.frag|SHADOWS=1"]
        assert.are.equal(6, shadowed.counts.samplers)
        assert.are.equal(3, shadowed.counts.readOnlyStorageBuffers)

        -- Workgroup size is declared in GLSL and is a pipeline argument, so it
        -- has to survive too.
        local mark = pack.shaders["instance.mark.comp"]
        assert.are.equal(256, mark.threadCount[1])
        assert.are.equal(1, mark.threadCount[2])

        local fragment = pack.shaders["instance.frag"]
        assert.are.same({ 1, 1, 1 }, fragment.threadCount)

        local mesh = pack.shaders["mesh.vert"]
        local skinned = pack.shaders["mesh.vert|MESH_SKINNING=1"]
        local morphed = pack.shaders["mesh.vert|MESH_MORPHING=1"]
        local combined = pack.shaders["mesh.vert|MESH_MORPHING=1,MESH_SKINNING=1"]
        local coloredCombined = pack.shaders["mesh.vert|MESH_MORPHING=1,MESH_SKINNING=1,MESH_VERTEX_COLORS=1"]
        assert.are.equal(2, mesh.counts.readOnlyStorageBuffers)
        assert.are.equal(5, skinned.counts.readOnlyStorageBuffers)
        assert.are.equal(5, morphed.counts.readOnlyStorageBuffers)
        assert.are.equal(7, combined.counts.readOnlyStorageBuffers)
        assert.are.equal(8, coloredCombined.counts.readOnlyStorageBuffers)
    end)

    it("rejects a file that is not a pack", function()
        assert.has_error(function()
            shaderpack.decode("not a pack at all")
        end)
        assert.has_error(function()
            shaderpack.decode("")
        end)
    end)

    it("rejects a pack whose layout this build does not read", function()
        local encoded = shaderpack.encode(shaderbuild.build())
        -- Same magic, a version this build does not know. The offset is taken
        -- from the magic rather than written as a literal, since a magic of a
        -- different length would otherwise move the version byte and leave
        -- this patching payload bytes while still reading as a pass.
        local MAGIC = "TECSSP"
        assert.are.equal(MAGIC, encoded:sub(1, #MAGIC))
        local wrong = encoded:sub(1, #MAGIC) .. string.char(99) .. encoded:sub(#MAGIC + 2)
        local ok, reason = pcall(shaderpack.decode, wrong, "wrong.tsp")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("version 99"))
    end)

    it("rejects truncated and trailing pack data", function()
        local encoded = shaderpack.encode(shaderbuild.build())
        assert.has_error(function()
            shaderpack.decode(encoded:sub(1, #encoded - 1), "truncated.tsp")
        end)
        assert.has_error(function()
            shaderpack.decode(encoded .. "extra", "trailing.tsp")
        end)
    end)

    it("returns nil for a path with no pack", function()
        assert.is_nil(shaderpack.read("/tmp/tecs-no-such-pack.tsp"))
    end)

    it("names the formats it can carry", function()
        assert.are.equal("msl", shaderpack.formatName(shaderpack.formatValue("msl")))
        assert.are.equal("spirv", shaderpack.formatName(shaderpack.formatValue("spirv")))
        assert.has_error(function()
            shaderpack.formatValue("hlsl")
        end)
    end)
end)

describe("rendering from a pack", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "pack", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
        assets.install()
    end)

    teardown(function()
        shadercompiler.usePack(nil)
        assets.shutdown()
        if screen then
            screen:destroy()
        end
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    -- One red quad covering the target, so a shader that failed to build or
    -- bound the wrong resources reads back as something other than red.
    local function renderQuad()
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            sprites = { capacity = 64 },
        })
        renderer:install(world)
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable2D()
        )

        world:update(1 / 60)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        renderer:render({
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        local pixels = screen:readback()
        local center = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
        renderer:destroy()
        return center
    end

    it("renders the same pixels as a build that compiled the shaders", function()
        shadercompiler.usePack(nil)
        local compiled = renderQuad()

        shadercompiler.usePack(shaderbuild.build())
        local packed = renderQuad()

        assert.are.equal(255, compiled.r, "the compiled path must draw red")
        assert.are.equal(compiled.r, packed.r)
        assert.are.equal(compiled.g, packed.g)
        assert.are.equal(compiled.b, packed.b)
        assert.are.equal(compiled.a, packed.a)
    end)

    it("takes the pack's format as the one the device may claim", function()
        -- A pack holds one format and a packaged build can produce no other,
        -- so this is what SDL is told, and telling it otherwise selects a
        -- backend that fails at shader creation rather than at startup.
        local pack = shaderbuild.build()
        shadercompiler.usePack(pack)
        assert.are.equal(pack.format, shadercompiler.format())

        shadercompiler.usePack(nil)
        assert.are.equal(sdl.K.SDL_GPU_SHADERFORMAT_MSL, shadercompiler.format())
    end)

    it("recompiles rather than using an entry built from other source", function()
        local pack = shaderbuild.build()
        pack.shaders["instance.frag"].sourceHash = "deadbeef"
        shadercompiler.usePack(pack)

        -- This host has a compiler, so a stale entry is a recompile and the
        -- frame is still correct.
        assert.is_true(shadercompiler.isSupported())
        assert.are.equal(255, renderQuad().r)
    end)
end)

describe("where a shader is allowed to come from", function()
    -- The rule that decides a packaged build, tested as a rule. A process
    -- cannot unlink its compiler, so `plan` takes that as an argument: every
    -- combination of "is it in the pack" and "can this build compile" is
    -- checked here, including the two that must fail.

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
    end)
    teardown(function()
        shadercompiler.usePack(nil)
        C.SDL_Quit()
    end)

    it("compiles when nothing is packaged and a compiler exists", function()
        shadercompiler.usePack(nil)
        assert.are.equal("compile", shadercompiler.plan("instance.frag", nil, true))
    end)

    it("raises when nothing is packaged and nothing can compile", function()
        shadercompiler.usePack(nil)
        local ok, reason = pcall(shadercompiler.plan, "instance.frag", nil, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("no shader pack"))
        assert.is_truthy(tostring(reason):find("instance.frag"), "the message must name the shader")
    end)

    it("uses the pack when the entry matches its source", function()
        shadercompiler.usePack(shaderbuild.build())
        assert.are.equal("pack", shadercompiler.plan("instance.frag", nil, false))
        assert.are.equal(
            "pack",
            shadercompiler.plan("instance.frag", nil, true),
            "a packaged entry is preferred even where compiling is possible"
        )
    end)

    it("raises for a shader missing from the pack with no compiler", function()
        local pack = shaderbuild.build()
        pack.shaders["instance.frag"] = nil
        shadercompiler.usePack(pack)

        local ok, reason = pcall(shadercompiler.plan, "instance.frag", nil, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("not in the pack"))
        -- Naming the key is what makes the packaging step fixable.
        assert.is_truthy(tostring(reason):find("instance.frag"))
    end)

    it("raises for a stale entry with no compiler", function()
        -- The dangerous case: an entry is present, so nothing is obviously
        -- wrong, but it was built from source that has since changed. Drawing
        -- with it would produce a frame no one can explain.
        local pack = shaderbuild.build()
        pack.shaders["instance.vert"].sourceHash = "deadbeef"
        shadercompiler.usePack(pack)

        local ok, reason = pcall(shadercompiler.plan, "instance.vert", nil, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("different source"))
        assert.is_truthy(tostring(reason):find("deadbeef"))

        assert.are.equal("compile", shadercompiler.plan("instance.vert", nil, true))
    end)

    it("treats a variant as its own entry", function()
        -- A material assembled from defines at run time is a different shader,
        -- so it has to be declared and baked. One that was not is missing, and
        -- on a packaged build that is a failure rather than a compile.
        shadercompiler.usePack(shaderbuild.build())
        local ok, reason = pcall(shadercompiler.plan, "instance.frag", { LIGHTS = "4" }, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("instance.frag|LIGHTS=4"))
    end)
end)

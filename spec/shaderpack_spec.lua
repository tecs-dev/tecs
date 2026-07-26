-- Packaged shaders.
--
-- A target that forbids a shader compiler has to be handed compiled bytecode
-- and the reflection that goes with it, because SDL_GPU takes the resource
-- counts as arguments and cannot recover them from the code. So the thing
-- worth testing is not that a pack round-trips: it is that a build consuming
-- one renders the same pixels as a build that compiled the shaders itself, and
-- that a build with neither says so instead of opening a black window.

local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs2d.ffi.sdl3")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local Texture = require("tecs2d.gpu.Texture")
local Renderer = require("tecs2d.Renderer")
local assets = require("tecs2d.assets")
local components = require("tecs2d.components")
local shaders = require("tecs2d.gpu.shaders")
local shaderpack = require("tecs2d.gpu.shaderpack")
local shaderbuild = require("tecs2d.gpu.shaderbuild")
local shadercompiler = require("tecs2d.gpu.shadercompiler")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform2D = components.Transform2D
local Tint = components.Tint
local Renderable = components.Renderable

describe("shaders registry", function()
    it("names every shader the engine loads", function()
        -- The registry is what a packaging step enumerates, so a shader the
        -- engine asks for at run time but that is not listed here is one no
        -- pack can contain.
        local names = {}
        for _, entry in ipairs(shaders.list()) do names[entry.name] = entry end

        for _, expected in ipairs({
            "instance.reset.comp", "instance.cull.comp",
            "instance.vert", "instance.frag",
            "deferred.fullscreen.vert", "deferred.lighting.frag",
            "deferred.composite.frag",
        }) do
            assert.is_not_nil(names[expected], expected .. " must be registered")
        end
    end)

    it("keys a variant by its defines, not by table order", function()
        -- Lua does not iterate a table in insertion order, so a key built by
        -- walking one would differ between runs and miss its own pack entry.
        assert.are.equal("a.frag", shaders.key("a.frag"))
        assert.are.equal("a.frag", shaders.key("a.frag", {}))
        assert.are.equal(
            shaders.key("a.frag", { LIGHTS = "4", SHADOWS = "1" }),
            shaders.key("a.frag", { SHADOWS = "1", LIGHTS = "4" }))
    end)

    it("hashes source so a changed shader is detectable", function()
        local one = shaders.hash("#version 450\nvoid main() {}\n")
        assert.are.equal(8, #one)
        assert.are.equal(one, shaders.hash("#version 450\nvoid main() {}\n"))
        assert.are_not.equal(one, shaders.hash("#version 450\nvoid main(){}\n"))
    end)

    it("refuses a name it does not know", function()
        assert.has_error(function() shaders.get("nothing.frag") end)
    end)
end)

describe("shaderpack", function()
    setup(function() assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO)) end)
    teardown(function() C.SDL_Quit() end)

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
            assert.are.equal(entry.counts.readOnlyStorageBuffers,
                other.counts.readOnlyStorageBuffers)
            assert.are.equal(entry.counts.uniformBuffers,
                other.counts.uniformBuffers)
        end
    end)

    it("carries the reflection SDL_GPU cannot recover from code", function()
        local pack = shaderbuild.build()
        -- The lighting pass binds two G-buffer samplers, a light buffer, and
        -- one uniform block. Those numbers are arguments to shader creation,
        -- so a pack that dropped them would create a shader that binds
        -- nothing and draws black.
        local lighting = pack.shaders["deferred.lighting.frag"]
        assert.are.equal(2, lighting.counts.samplers)
        assert.are.equal(1, lighting.counts.readOnlyStorageBuffers)
        assert.are.equal(1, lighting.counts.uniformBuffers)

        -- Workgroup size is declared in GLSL and is a pipeline argument, so it
        -- has to survive too.
        local cull = pack.shaders["instance.cull.comp"]
        assert.are.equal(64, cull.threadCount[1])
        assert.are.equal(1, cull.threadCount[2])
    end)

    it("rejects a file that is not a pack", function()
        assert.has_error(function() shaderpack.decode("not a pack at all") end)
        assert.has_error(function() shaderpack.decode("") end)
    end)

    it("rejects a pack whose layout this build does not read", function()
        local encoded = shaderpack.encode(shaderbuild.build())
        -- Same magic, a version this build does not know.
        local wrong = encoded:sub(1, 8) .. string.char(99) .. encoded:sub(10)
        local ok, reason = pcall(shaderpack.decode, wrong, "wrong.tsp")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("version 99"))
    end)

    it("returns nil for a path with no pack", function()
        assert.is_nil(shaderpack.read("/tmp/tecs2d-no-such-pack.tsp"))
    end)

    it("names the formats it can carry", function()
        assert.are.equal("msl", shaderpack.formatName(
            shaderpack.formatValue("msl")))
        assert.are.equal("spirv", shaderpack.formatName(
            shaderpack.formatValue("spirv")))
        assert.has_error(function() shaderpack.formatValue("hlsl") end)
    end)
end)

describe("rendering from a pack", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "pack", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle,
            { width = SIZE, height = SIZE, format = FORMAT })
        assets.install()
    end)

    teardown(function()
        shadercompiler.usePack(nil)
        assets.shutdown()
        if screen then screen:destroy() end
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    -- One red quad covering the target, so a shader that failed to build or
    -- bound the wrong resources reads back as something other than red.
    local function renderQuad()
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 64,
        })
        renderer:install(world)
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
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
        local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
        renderer:destroy()
        return centre
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
        assert.is_true(shadercompiler.available())
        assert.are.equal(255, renderQuad().r)
    end)
end)

describe("where a shader is allowed to come from", function()
    -- The rule that decides a packaged build, tested as a rule. A process
    -- cannot unlink its compiler, so `plan` takes that as an argument: every
    -- combination of "is it in the pack" and "can this build compile" is
    -- checked here, including the two that must fail.

    setup(function() assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO)) end)
    teardown(function()
        shadercompiler.usePack(nil)
        C.SDL_Quit()
    end)

    it("compiles when nothing is packaged and a compiler exists", function()
        shadercompiler.usePack(nil)
        assert.are.equal("compile",
            shadercompiler.plan("instance.frag", nil, true))
    end)

    it("raises when nothing is packaged and nothing can compile", function()
        shadercompiler.usePack(nil)
        local ok, reason = pcall(shadercompiler.plan, "instance.frag", nil, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("no shader pack"))
        assert.is_truthy(tostring(reason):find("instance.frag"),
            "the message must name the shader")
    end)

    it("uses the pack when the entry matches its source", function()
        shadercompiler.usePack(shaderbuild.build())
        assert.are.equal("pack",
            shadercompiler.plan("instance.frag", nil, false))
        assert.are.equal("pack",
            shadercompiler.plan("instance.frag", nil, true),
            "a packaged entry is preferred even where compiling is possible")
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

        assert.are.equal("compile",
            shadercompiler.plan("instance.vert", nil, true))
    end)

    it("treats a variant as its own entry", function()
        -- A material assembled from defines at run time is a different shader,
        -- so it has to be declared and baked. One that was not is missing, and
        -- on a packaged build that is a failure rather than a compile.
        shadercompiler.usePack(shaderbuild.build())
        local ok, reason = pcall(shadercompiler.plan, "instance.frag",
            { LIGHTS = "4" }, false)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("instance.frag|LIGHTS=4"))
    end)
end)

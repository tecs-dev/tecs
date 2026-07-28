-- Names carried to SDL so a graphics capture shows what a resource is.
--
-- What cannot be asserted here: that a capture tool then displays the name.
-- SDL has no getter for it, the driver keeps it only when the device was
-- created in debug mode, and reading it back would mean driving a capture
-- tool. So the claim under test is the half this side owns, that a resource
-- created with a name hands that name to SDL and one created without a name
-- makes no such call. Everything past that is SDL's and the driver's.
--
-- Observing the call means substituting the C namespace, which the modules
-- capture when they load, so they are reloaded around the substitution and
-- put back afterwards.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")

-- Loaded here so that reloading them below re-runs only these three: whatever
-- they require is already resolved and comes back from `package.loaded`
-- holding the real namespace.
require("tecs.gpu.Texture")
require("tecs.gpu.Buffer")
require("tecs.gpu.PassGraph")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 16

local WRAPPED = { "tecs.gpu.Texture", "tecs.gpu.Buffer", "tecs.gpu.PassGraph" }

--- Runs `body` against modules whose SDL namespace records the naming calls.
---
--- Returns the names given to SDL, in the order they were given, as two
--- lists. The recording namespace forwards everything, so the resources are
--- created for real and a name SDL rejects still fails the test.
local function recording(body)
    local named = { textures = {}, buffers = {} }
    local proxy = setmetatable({
        SDL_SetGPUTextureName = function(device, texture, name)
            named.textures[#named.textures + 1] = name
            C.SDL_SetGPUTextureName(device, texture, name)
        end,
        SDL_SetGPUBufferName = function(device, buffer, name)
            named.buffers[#named.buffers + 1] = name
            C.SDL_SetGPUBufferName(device, buffer, name)
        end,
    }, { __index = C })

    local saved = {}
    for _, name in ipairs(WRAPPED) do
        saved[name] = package.loaded[name]
        package.loaded[name] = nil
    end
    sdl.C = proxy

    local modules = {}
    local ok, reason = pcall(function()
        for _, name in ipairs(WRAPPED) do
            modules[name] = require(name)
        end
        body(modules)
    end)

    sdl.C = C
    for _, name in ipairs(WRAPPED) do
        package.loaded[name] = saved[name]
    end
    if not ok then
        error(reason, 0)
    end
    return named
end

describe("gpu debug names", function()
    local window, device

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "names", width = SIZE, height = SIZE })
        -- Debug mode, since that is the only mode in which SDL keeps a name at
        -- all, and the only one in which a wrong call is complained about.
        device = Device.create(window, { debug = true })
    end)

    teardown(function()
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("hands SDL the name a texture was created with", function()
        local named = recording(function(modules)
            local Texture = modules["tecs.gpu.Texture"]
            local labeled = Texture.create(device.handle, {
                width = SIZE,
                height = SIZE,
                format = FORMAT,
                name = "readback",
            })
            assert.are.equal("readback", labeled.name)
            labeled:destroy()

            local anonymous = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
            assert.is_nil(anonymous.name)
            anonymous:destroy()
        end)

        assert.are.same({ "readback" }, named.textures, "the named texture, and no call for the one without a name")
    end)

    it("hands SDL the name a buffer was created with", function()
        local named = recording(function(modules)
            local Buffer = modules["tecs.gpu.Buffer"]
            local labeled = Buffer.create(device.handle, { usage = { "storage" }, size = 256, name = "instances" })
            assert.are.equal("instances", labeled.name)
            labeled:destroy()

            local anonymous = Buffer.create(device.handle, { usage = { "storage" }, size = 256 })
            assert.is_nil(anonymous.name)
            anonymous:destroy()
        end)

        assert.are.same({ "instances" }, named.buffers)
    end)

    it("names every target the pass graph owns, and the depth attachment", function()
        -- The graph is what plainly expects this: a capture of a deferred
        -- frame with four unnamed targets in it says nothing about which
        -- is which.
        local named = recording(function(modules)
            local PassGraph = modules["tecs.gpu.PassGraph"]
            local graph = PassGraph.create(device.handle, FORMAT)
            graph:target({ name = "albedo", format = FORMAT })
            graph:target({ name = "normal", format = FORMAT })
            graph:pass({
                name = "geometry",
                outputs = { "albedo", "normal" },
                depth = { test = true, write = true },
                -- Gated off: the targets are allocated by the resize the
                -- graph does before running anything, so nothing has to
                -- draw for them to exist.
                enabled = function()
                    return false
                end,
                execute = function() end,
            })

            local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
            graph:execute({
                width = SIZE,
                height = SIZE,
                commandBuffer = commandBuffer,
            })
            assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
            graph:destroy()
        end)

        assert.are.same(
            { "albedo", "normal", "depth" },
            named.textures,
            "every target by its declared name, then the depth attachment"
        )
    end)
end)

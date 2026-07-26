-- Asset roots and capabilities.
--
-- Both exist because the alternative is guessing. A working directory happens
-- to be right when a desktop build is launched from a project root and is
-- meaningless on a device; `ffi.os` cannot tell a build that linked a shader
-- compiler from one that did not.

local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local paths = require("tecs.platform.paths")
local capabilities = require("tecs.platform.capabilities")

describe("platform.paths", function()
    setup(function() assert(sdl.C.SDL_Init(sdl.K.SDL_INIT_VIDEO)) end)
    teardown(function() sdl.C.SDL_Quit() end)

    it("reports a writable directory the platform chose", function()
        local writable = paths.pref()
        assert.is_string(writable)
        assert.are.equal("/", writable:sub(-1),
            "a root must end in a separator so joining is plain concatenation")
        -- Not the working directory, which is not writable on every target.
        assert.is_truthy(writable:find("tecs"))
    end)

    it("resolves relative paths against each root", function()
        paths.setAssets("/tmp/content")
        assert.are.equal("/tmp/content/art/hero.png", paths.asset("art/hero.png"))
        assert.is_truthy(paths.writable("save.json"):find("save.json"))
    end)

    it("takes an override, so a dev run reads from a source tree", function()
        paths.setAssets("/tmp/one")
        assert.are.equal("/tmp/one/", paths.assets())
        paths.setAssets("/tmp/two/")
        assert.are.equal("/tmp/two/", paths.assets(),
            "a trailing separator must not be doubled")
    end)
end)

describe("platform.capabilities", function()
    setup(function() assert(sdl.C.SDL_Init(sdl.K.SDL_INIT_VIDEO)) end)
    teardown(function() sdl.C.SDL_Quit() end)

    it("reports the target rather than inferring it", function()
        local caps = capabilities.get()
        assert.is_string(caps.target)
        assert.is_string(caps.architecture)
        assert.is_true(caps.cores >= 1)
    end)

    it("requires the FFI and treats the JIT as separate", function()
        local caps = capabilities.get()
        -- The engine has no path that avoids the FFI, so a build without it
        -- does not run rather than running degraded. Machine-code generation
        -- is a different question and is allowed to be absent.
        assert.is_true(caps.ffi)
        assert.is_boolean(caps.jit)
    end)

    it("reports runtime shaders as a property of the build", function()
        -- A release links no compiler and consumes packaged artifacts, so this
        -- cannot be derived from the platform. The two are independent: a
        -- development build has a compiler and may also have a pack.
        local caps = capabilities.get()
        assert.is_boolean(caps.runtimeShaders)
        assert.is_boolean(caps.packagedShaders)
        assert.are.equal(1, #caps.shaderFormats,
            "one format, the one the shader pipeline supplies")
    end)

    it("reports touch by asking the platform", function()
        -- Not inferred from the OS: a desktop with a touchscreen has one and a
        -- simulator may not, so neither answer follows from the platform name.
        assert.is_boolean(capabilities.get().touch)
    end)

    it("reports dynamic loading as the inverse of a linked registry", function()
        local caps = capabilities.get()
        local loader = require("tecs.ffi.loader")
        assert.are.equal(not loader.isStatic("sdl3"), caps.dynamicLibraries)
    end)
end)

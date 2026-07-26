-- Binding-layer invariants: the generated cdefs load, resolve real symbols,
-- and expose the constants that the preprocessor would otherwise have eaten.

-- Our build first, so it wins over the ECS repo's own engine tree.
package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local loader = require("tecs2d.ffi.loader")

describe("ffi.loader", function()
    it("resolves SDL3 and reports the satisfying path", function()
        local sdl = require("tecs2d.ffi.sdl3")
        assert.is_string(sdl.path)
        assert.is_not_nil(sdl.C.SDL_GetError)
    end)

    it("caches a library across repeated loads", function()
        local first = loader.library("SDL3", "sdl3", "TECS2D_SDL3_PATH")
        local second = loader.library("SDL3", "sdl3", "TECS2D_SDL3_PATH")
        assert.are.equal(first, second)
    end)

    it("raises a directed error for a library that does not exist", function()
        local ok, err = pcall(loader.library,
            "definitely-not-a-real-library", "nope", "TECS2D_NOPE_PATH")
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("cannot load"))
    end)

    it("recovers integer #define constants that never reach the cdef", function()
        local sdl = require("tecs2d.ffi.sdl3")
        -- SDL_INIT_VIDEO is a #define, so it is absent from the cdef and can
        -- only come from the separately extracted constants table.
        assert.are.equal(32, sdl.K.SDL_INIT_VIDEO)
        -- Macro-wrapped through SDL_UINT64_C, which a regex extractor misses.
        assert.are.equal(32, sdl.K.SDL_WINDOW_RESIZABLE)
    end)

    it("exposes enum constants through the C namespace", function()
        local sdl = require("tecs2d.ffi.sdl3")
        -- Enums survive preprocessing, so these resolve through the library.
        assert.are.equal(0x100, tonumber(sdl.C.SDL_EVENT_QUIT))
    end)

    it("agrees with the C compiler on SDL_Event's size", function()
        local ffi = require("ffi")
        require("tecs2d.ffi.sdl3")
        -- A drifted cdef would change this silently; make abi-check verifies
        -- every record, this pins the one the event loop depends on.
        assert.are.equal(128, ffi.sizeof("SDL_Event"))
    end)
end)

-- Binding-layer invariants: the generated cdefs load, resolve real symbols,
-- and expose the constants that the preprocessor would otherwise have eaten.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local loader = require("tecs.ffi.loader")

describe("ffi.loader", function()
    it("resolves SDL3 and reports the satisfying path", function()
        local sdl = require("tecs.ffi.sdl3")
        assert.is_string(sdl.path)
        assert.is_not_nil(sdl.C.SDL_GetError)
    end)

    it("caches a library across repeated loads", function()
        local first = loader.library("SDL3", "sdl3", "TECS_SDL3_PATH")
        local second = loader.library("SDL3", "sdl3", "TECS_SDL3_PATH")
        assert.are.equal(first, second)
    end)

    it("raises a directed error for a library that does not exist", function()
        local ok, err = pcall(loader.library, "definitely-not-a-real-library", "nope", "TECS_NOPE_PATH")
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("cannot load"))
    end)

    it("recovers integer #define constants that never reach the cdef", function()
        local sdl = require("tecs.ffi.sdl3")
        -- SDL_INIT_VIDEO is a #define, so it is absent from the cdef and can
        -- only come from the separately extracted constants table.
        assert.are.equal(32, sdl.K.SDL_INIT_VIDEO)
        -- Macro-wrapped through SDL_UINT64_C, which a regex extractor misses.
        assert.are.equal(32, sdl.K.SDL_WINDOW_RESIZABLE)
    end)

    it("exposes enum constants through the C namespace", function()
        local sdl = require("tecs.ffi.sdl3")
        -- Enums survive preprocessing, so these resolve through the library.
        assert.are.equal(0x100, tonumber(sdl.C.SDL_EVENT_QUIT))
    end)

    it("resolves the two libraries that carry no SDL prefix", function()
        -- zlib and libcurl are named nothing like the rest and are found the
        -- same way regardless: the registry when a host installed one, then
        -- the soname, then each known prefix. A library reached by any other
        -- route would work in development and fail where dlopen is forbidden.
        local zlib = require("tecs.ffi.zlib")
        local curl = require("tecs.ffi.curl")
        assert.is_string(zlib.path)
        assert.is_string(curl.path)
        assert.is_not_nil(zlib.C.adler32_z)
        assert.is_not_nil(curl.C.curl_multi_perform)
        -- Both report the revision that actually answered, which a development
        -- preset and a packaged one are not obliged to agree on.
        assert.is_truthy(zlib.version():match("^%d+%.%d+"))
        assert.is_truthy(curl.version():find("libcurl/", 1, true))
    end)

    it("recovers constants for libraries whose values are computed", function()
        local curl = require("tecs.ffi.curl")
        local zlib = require("tecs.ffi.zlib")
        -- CURL_GLOBAL_SSL is `(1 << 0)` behind a #define, so it exists only in
        -- the recovered table; CURLOPT_URL is an enumerator whose value is
        -- written as an expression, so it exists only through the namespace.
        assert.are.equal(1, curl.K.CURL_GLOBAL_SSL)
        assert.are.equal(10002, tonumber(curl.C.CURLOPT_URL))
        -- zlib's flush values are enumerator-free #defines throughout.
        assert.are.equal(0, zlib.K.Z_NO_FLUSH)
        assert.are.equal(4, zlib.K.Z_FINISH)
    end)

    it("agrees with the C compiler on SDL_Event's size", function()
        local ffi = require("ffi")
        require("tecs.ffi.sdl3")
        -- A drifted cdef would change this silently; make abi-check verifies
        -- every record, this pins the one the event loop depends on.
        assert.are.equal(128, ffi.sizeof("SDL_Event"))
    end)
end)

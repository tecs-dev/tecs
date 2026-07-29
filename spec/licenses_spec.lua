-- No LGPL, ever.
--
-- That is a standing constraint on what this engine links, and a constraint
-- written only in a document lasts until the first person who has not read it.
-- The realistic way it breaks is small and plausible: someone wants an mp3
-- decoder that handles a file dr_mp3 chokes on, finds `SDLMIXER_MP3_MPG123`
-- sitting in `cmake/Pinned.cmake` set to OFF, flips it, and nothing anywhere
-- says no. So the options that decide a license are declared here, each with
-- the license behind it, and this holds `Pinned.cmake` to the declaration.
--
-- Five checks, in increasing order of what they are good for:
--
--  * Every option in the declaration is set in `Pinned.cmake` to the value the
--    declaration requires. Flipping one fails here.
--  * Every `SDLMIXER_` option `Pinned.cmake` sets appears in
--    the declaration. This is the family where one option decides
--    which codec gets linked, so adding one means writing down its license
--    rather than only its value.
--  * A denylist of option names that must never appear enabled, whichever
--    dependency introduces them. This one is forward-looking: it names the
--    LGPL-capable options of libraries this repository does not build yet, so
--    the answer is in place before one lands rather than after.
--  * Every dependency pinned in `cmake/Revisions.cmake` is named in
--    `THIRD_PARTY_NOTICES.md`. Pinning a new one fails this until its notice
--    is written, because a package that ships the code and not the notice is
--    the one compliance failure this engine is capable of committing.
--  * Every package pinned in Cargo.lock is named there too. Cargo is a second
--    dependency graph, not an exception to the notice rule.
--
-- What this cannot catch, stated plainly, because a guard that overstates
-- itself is worse than none:
--
--  * It reads a declaration, not a build. Setting an option upstream renamed
--    creates an unused cache variable
--    and configures cleanly, and this check is exactly as happy with it. Only
--    configuring the real thing and reading what it produced tells those
--    apart, which is what `make check-package` does to binaries.
--  * It cannot read a license out of a binary, because nothing can. The
--    licenses below are what a person read in each project's own license file
--    at the pinned revision. A revision bump that changed the terms passes
--    this untouched.
--  * It says nothing about a development build. Those resolve dependencies
--    from the machine, and a packager's SDL_mixer may well have every LGPL
--    decoder available; `Audio.decoders()` is what reports that. Only a
--    packaged build is held to this.
--  * It is about what gets linked. An LGPL asset, or a tool invoked as a
--    separate process, is outside everything here.

local function readFile(path)
    local handle = assert(io.open(path, "r"), "cannot read " .. path)
    local contents = handle:read("*a")
    handle:close()
    return contents
end

-- Each option that decides a license or a shipped byte: the value it has to
-- hold, the license that hangs on it, and why. The reason is the point of the
-- table, because a value with no reason beside it is the one that gets flipped.
local REQUIRED = {
    -- SDL_mixer. Four of these are LGPL; the permissive alternates beside them
    -- are what make turning those four off cost nothing.
    SDLMIXER_GME = { "OFF", "LGPL-2.1-or-later", "game-music-emu, and nothing permissive behind it" },
    SDLMIXER_MOD = { "OFF", "MIT", "libxmp, which is MIT; off because nothing needs it" },
    SDLMIXER_MIDI = { "OFF", "LGPL-2.1-or-later", "FluidSynth, and TiMidity's Artistic-1.0 with it" },
    SDLMIXER_MP3_MPG123 = { "OFF", "LGPL-2.1-only", "mpg123; dr_mp3 reads the same files permissively" },
    SDLMIXER_MP3_DRMP3 = { "ON", "Unlicense OR MIT-0", "what stands in for mpg123" },
    SDLMIXER_FLAC_LIBFLAC = { "OFF", "BSD-3-Clause", "permissive, but redundant beside dr_flac" },
    SDLMIXER_FLAC_DRFLAC = { "ON", "Unlicense OR MIT-0", "what stands in for libFLAC" },
    SDLMIXER_VORBIS_VORBISFILE = { "OFF", "BSD-3-Clause", "redundant beside stb_vorbis" },
    SDLMIXER_VORBIS_TREMOR = { "OFF", "BSD-3-Clause", "likewise" },
    SDLMIXER_VORBIS_STB = { "ON", "MIT OR Unlicense", "what stands in for vorbisfile" },
    SDLMIXER_OPUS = { "ON", "BSD-3-Clause", "libogg, opus and opusfile, all permissive" },
    SDLMIXER_WAVPACK = { "ON", "BSD-3-Clause", "WavPack, permissive" },
    SDLMIXER_VENDORED = { "ON", "n/a", "builds them from pinned sources, not from the machine" },
    SDLMIXER_STRICT = { "ON", "n/a", "a missing dependency fails the configure" },
    SDLMIXER_DEPS_SHARED = { "OFF", "n/a", "links them rather than loading them by name" },
    SDLMIXER_TESTS = { "OFF", "n/a", "not shipped" },
    SDLMIXER_EXAMPLES = { "OFF", "n/a", "not shipped" },
}

-- Options that must never appear enabled, whoever introduces them. Most belong
-- to libraries this repository does not build yet, and they are here so that
-- whoever adds one meets the answer rather than finding it afterwards.
--
-- For any future native client, GnuTLS is LGPL,
-- and nettle and gmp behind it are LGPLv3-or-GPLv2 again. wolfSSL is GPL-3.0
-- with no linking exception, so linking it without the commercial license puts
-- the whole game under GPLv3. libidn2 is dual GPL-2.0-or-later or
-- LGPL-3.0-or-later, which means its best arm is still disqualifying, and it is
-- auto-detected on, so it links wherever the build host happens to have it.
-- libpsl is the quiet one: it is MIT, but it may resolve to libidn2 and
-- libunistring on Linux, putting those non-permissive dependencies back.
--
-- SDL's own is `SDL_LIBICONV`, which prefers GNU libiconv over the C library's.
-- It is off upstream and stays off.
local NEVER_ENABLED = {
    SDL_LIBICONV = "LGPL-2.1-or-later",
    SDLMIXER_GME = "LGPL-2.1-or-later",
    SDLMIXER_MIDI = "LGPL-2.1-or-later, and Artistic-1.0 for TiMidity",
    SDLMIXER_MP3_MPG123 = "LGPL-2.1-only",
    CURL_USE_GNUTLS = "LGPL-2.1-or-later, over LGPL-3.0 nettle and gmp",
    CURL_USE_WOLFSSL = "GPL-3.0-or-later, with no linking exception",
    USE_LIBIDN2 = "GPL-2.0-or-later OR LGPL-3.0-or-later",
    CURL_USE_LIBPSL = "MIT itself, but it resolves to libidn2 at run time",
    CURL_USE_LIBSSH = "GPL-2.0-or-later",
}

-- What each pinned revision is called in the notices. Kept explicit rather than
-- derived from the variable name, because `TECS_SPVC_TAG` is SPIRV-Cross and no
-- rule turns one into the other.
local NOTICE_NAMES = {
    SDL3 = "SDL3",
    SDL3_MIXER = "SDL3_mixer",
    LUAJIT = "LuaJIT",
    SHADERC = "shaderc",
    -- shaderc's own three, pinned here rather than left to the script that
    -- clones whatever its DEPS file names.
    GLSLANG = "glslang",
    SPIRV_TOOLS = "SPIRV-Tools",
    SPIRV_HEADERS = "SPIRV-Headers",
    SPVC = "SPIRV-Cross",
    ZLIB = "zlib",
}

describe("the license position", function()
    local pinned = readFile("cmake/Pinned.cmake")
    local revisions = readFile("cmake/Revisions.cmake")
    local cargoLock = readFile("native/rust/Cargo.lock")
    local notices = readFile("THIRD_PARTY_NOTICES.md")

    -- What Pinned.cmake sets: option to value, read from the forced cache sets
    -- rather than from anything that merely names an option.
    local settings = {}
    for option, value in pinned:gmatch("set%(%s*([%w_]+)%s+([%w_]+)%s+CACHE%s+BOOL") do
        settings[option] = value
    end

    it("sets every option a license hangs on, to the value it has to hold", function()
        for option, entry in pairs(REQUIRED) do
            local wanted, license, why = entry[1], entry[2], entry[3]
            local actual = settings[option]
            assert.is_true(
                actual ~= nil,
                ("cmake/Pinned.cmake does not set %s, and it has to: %s (%s)"):format(option, why, license)
            )
            assert.is_true(
                actual == wanted,
                ("%s is %s and must be %s: %s (%s)"):format(option, tostring(actual), wanted, why, license)
            )
        end
    end)

    it("declares every decoder option it sets", function()
        for option in pairs(settings) do
            if option:match("^SDLMIXER_") then
                assert.is_true(
                    REQUIRED[option] ~= nil,
                    ("cmake/Pinned.cmake sets %s, which this file does not declare. "):format(option)
                        .. "Add it with the license it decides and the reason for the value, "
                        .. "or this declaration has stopped describing the build."
                )
            end
        end
    end)

    it("enables nothing on the denylist", function()
        -- Read from the whole file rather than from the parsed sets above, so
        -- an option enabled in some other form than a forced cache set is
        -- caught too.
        for option, license in pairs(NEVER_ENABLED) do
            assert.is_true(
                pinned:match("set%(%s*" .. option .. "%s+ON") == nil,
                ("cmake/Pinned.cmake enables %s, which is %s. This engine brings in no LGPL."):format(option, license)
            )
        end
    end)

    it("names every pinned dependency in the notices", function()
        local missing = {}
        for tag in revisions:gmatch("set%(TECS_([%w_]+)_TAG") do
            local name = NOTICE_NAMES[tag]
            assert.is_true(
                name ~= nil,
                ("cmake/Revisions.cmake pins TECS_%s_TAG, which this file cannot name. "):format(tag)
                    .. "Add it to NOTICE_NAMES and write its notice."
            )
            if not notices:find(name, 1, true) then
                table.insert(missing, name)
            end
        end
        assert.is_true(
            #missing == 0,
            "THIRD_PARTY_NOTICES.md does not name "
                .. table.concat(missing, ", ")
                .. ". A dependency whose notice is not written is a package that ships code without it."
        )
    end)

    it("names every pinned Rust dependency in the notices", function()
        local missing = {}
        for name in cargoLock:gmatch('%[%[package%]%]%s+name = "([^"]+)"') do
            if name ~= "tecs-native" and not notices:find("`" .. name .. "`", 1, true) then
                table.insert(missing, name)
            end
        end
        assert.is_true(
            #missing == 0,
            "THIRD_PARTY_NOTICES.md does not name "
                .. table.concat(missing, ", ")
                .. ". A Rust dependency whose notice is not written is a package that ships code without it."
        )
    end)
end)

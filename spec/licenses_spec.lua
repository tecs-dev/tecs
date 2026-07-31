-- No LGPL, ever.
--
-- That is a standing constraint on what this engine links, and a constraint
-- written only in a document lasts until the first person who has not read it.
-- The realistic way it breaks is small and plausible: someone wants an mp3
-- decoder that handles a file dr_mp3 chokes on, finds `SDLMIXER_MP3_MPG123`
-- sitting in the native dependency builder set to OFF, flips it, and nothing
-- anywhere says no. So the options that decide a license are declared here,
-- each with the license behind it, and this holds the builder to the
-- declaration.
--
-- Eight checks, in increasing order of what they are good for:
--
--  * Every option in the declaration is set in the Cargo builder to the value the
--    declaration requires. Flipping one fails here.
--  * Every `SDLMIXER_` option the builder sets appears in
--    the declaration. This is the family where one option decides
--    which codec gets linked, so adding one means writing down its license
--    rather than only its value.
--  * A denylist of option names that must never appear enabled, whichever
--    dependency introduces them. This one is forward-looking: it names the
--    LGPL-capable options of libraries this repository does not build yet, so
--    the answer is in place before one lands rather than after.
--  * Every native dependency revision in the build-support crate is named in
--    `THIRD_PARTY_NOTICES.md`. Pinning a new one fails this until its notice
--    is written, because a package that ships the code and not the notice is
--    the one compliance failure this engine is capable of committing.
--  * Every package pinned in Cargo.lock is named there too. Cargo is a second
--    dependency graph, not an exception to the notice rule.
--  * Every dependency the notices are written for is still pinned. The four
--    above all read the source of truth and ask the notices about it, so a
--    notice outlives the pin it describes and nothing notices: the entry costs
--    nothing to keep and reads as current for as long as it survives.
--  * Every crate the notices name is still in the lockfile, which is the same
--    question asked of Cargo.
--  * Every exception is still true. This is the one worth having, because a
--    wrong exception is worse than a missing notice: `TOOLING_ONLY` and
--    `BUILD_ONLY_CRATES` each turn a check off, so an entry that has stopped
--    being true suppresses the check it was written to skip. The Cargo half
--    walks the lockfile out from `tecs-native` and fails on an excluded package
--    a product reaches.
--
-- What this cannot catch, stated plainly, because a guard that overstates
-- itself is worse than none:
--
--  * It reads a declaration, not a build. Setting an option upstream renamed
--    creates an unused cache variable
--    and configures cleanly, and this check is exactly as happy with it. Only
--    configuring the real thing and reading what it produced tells those
--    apart, which is what `cargo xtask check-package` does to binaries.
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
--  * The reverse checks read the notices at the granularity a pin has: a
--    section under "Linked by a build" and a crate name in the Cargo inventory.
--    Everything the notices name inside a pinned project, HIDAPI inside SDL3
--    and glslang's six licenses inside glslang, is prose a person wrote from
--    that project's own files, and a revision bump that drops one leaves the
--    paragraph standing.

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

-- Revisions that pin development tooling rather than anything a product ships,
-- so no notice covers them and this check skips them. `staging.rs` is what
-- decides that, and it enumerates rather than globs: teal and cerulean do ship,
-- as the Lua a packaged CLI compiles with, and it copies their own license files
-- beside them into `tecstools/licenses` rather than describing them here.
-- Tealdoc and Scintillua ship nothing at all, no code and no license, because
-- both run only while this repository builds its documentation site.
local TOOLING_ONLY = {
    TEAL = true,
    CERULEAN = true,
    TEALDOC = true,
    SCINTILLUA = true,
}

-- What each pinned revision is called in the notices. Kept explicit rather than
-- derived from the variable name, because `TECS_SPVC_TAG` is SPIRV-Cross and no
-- rule turns one into the other.
local NOTICE_NAMES = {
    SDL3 = "SDL3",
    SDL3_MIXER = "SDL3_mixer",
    SDL3_TTF = "SDL3_ttf",
    FREETYPE = "FreeType",
    HARFBUZZ = "HarfBuzz",
    LUAJIT = "LuaJIT",
    SHADERC = "shaderc",
    -- shaderc's own three, pinned here rather than left to the script that
    -- clones whatever its DEPS file names.
    GLSLANG = "glslang",
    SPIRV_TOOLS = "SPIRV-Tools",
    SPIRV_HEADERS = "SPIRV-Headers",
    SPIRV_CROSS = "SPIRV-Cross",
    ZLIB = "zlib",
}

-- These are Cargo build dependencies, not code linked into a product. The
-- lockfile is workspace-wide, so the runtime-only check has to name the
-- packages that enter through build-support and xtask.
--
-- Every entry here is an assertion that the package ships nothing, and the
-- reverse check below holds it to that by walking the lockfile out from
-- `tecs-native`. An entry the walk reaches is the failure this table can cause:
-- a shipped dependency whose notice nothing asks for.
local BUILD_ONLY_CRATES = {
    anyhow = true,
    fastrand = true,
    ["linux-raw-sys"] = true,
    rustix = true,
    serde_spanned = true,
    tempfile = true,
    toml = true,
    toml_datetime = true,
    toml_parser = true,
    toml_writer = true,
    winnow = true,
}

-- The sections of `THIRD_PARTY_NOTICES.md` under "Linked by a build" that
-- describe more than one pinned revision, so a heading of their own answers to
-- no single one. Every other heading there names something the build pins, and
-- the reverse check holds it to that.
--
-- This covers only that part of the file. The notices also name material
-- vendored inside a pinned project, HIDAPI inside SDL3 and dr_mp3 inside
-- SDL3_mixer, and material checked into this repository, and neither is a pin
-- for anything here to look for.
local AGGREGATE_SECTIONS = {
    ["SDL"] = true,
    ["Rust native build foundation"] = true,
    ["What SDL3_mixer decodes"] = true,
}

-- The workspace's own crates, which no notice covers. `tecs-native` is the one
-- a product links, so it is also the root the lockfile is walked from.
local RUNTIME_CRATE = "tecs-native"
local WORKSPACE_CRATES = {
    [RUNTIME_CRATE] = true,
    ["tecs-build-support"] = true,
    ["tecs-xtask"] = true,
}

describe("the license position", function()
    local product = readFile("native/rust/build-support/src/product.rs")
    local cargoLock = readFile("Cargo.lock")
    local notices = readFile("THIRD_PARTY_NOTICES.md")

    -- What the native dependency builder passes to SDL_mixer.
    local settings = {}
    for option, value in product:gmatch('"%s*-D([%w_]+)=([%w_]+)"') do
        settings[option] = value
    end

    -- Every native dependency the builder pins, under the name its constant
    -- carries. Both directions read this, so it is parsed once.
    local pins = {}
    for tag in product:gmatch("pub const ([%w_]+)_REVISION") do
        pins[tag] = true
    end

    -- Every package the lockfile resolves, and the dependency edges between
    -- them, so a package can be asked whether a product reaches it at all.
    local packages = {}
    local edges = {}
    do
        local current = nil
        local readingDependencies = false
        for line in cargoLock:gmatch("[^\n]+") do
            local name = line:match('^name = "([^"]+)"')
            if line == "[[package]]" then
                current = nil
                readingDependencies = false
            elseif name then
                packages[name] = true
                current = {}
                edges[name] = current
            elseif line == "dependencies = [" then
                readingDependencies = true
            elseif readingDependencies then
                if line == "]" then
                    readingDependencies = false
                elseif current then
                    -- An entry is `"name"` or `"name version"` when the name
                    -- alone is ambiguous.
                    local dependency = line:match('^%s*"([^" ]+)')
                    if dependency then
                        table.insert(current, dependency)
                    end
                end
            end
        end
    end

    -- What a product's own crate reaches through the lockfile. The edges are
    -- recorded whatever target or feature selects them, so this is every
    -- package a release of some target compiles, which is what the notices
    -- have to cover.
    local reachable = {}
    do
        local frontier = { RUNTIME_CRATE }
        while #frontier > 0 do
            local name = table.remove(frontier)
            if not reachable[name] then
                reachable[name] = true
                for _, dependency in ipairs(edges[name] or {}) do
                    table.insert(frontier, dependency)
                end
            end
        end
    end

    it("sets every option a license hangs on, to the value it has to hold", function()
        for option, entry in pairs(REQUIRED) do
            local wanted, license, why = entry[1], entry[2], entry[3]
            local actual = settings[option]
            assert.is_true(
                actual ~= nil,
                ("the Cargo builder does not set %s, and it has to: %s (%s)"):format(option, why, license)
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
                    ("the Cargo builder sets %s, which this file does not declare. "):format(option)
                        .. "Add it with the license it decides and the reason for the value, "
                        .. "or this declaration has stopped describing the build."
                )
            end
        end
    end)

    it("enables nothing on the denylist", function()
        -- Read the whole builder so an option enabled outside the expected
        -- table is caught too.
        for option, license in pairs(NEVER_ENABLED) do
            assert.is_true(
                product:match("%-D" .. option .. "=ON") == nil,
                ("the Cargo builder enables %s, which is %s. This engine brings in no LGPL."):format(option, license)
            )
        end
    end)

    it("names every pinned dependency in the notices", function()
        local missing = {}
        for tag in pairs(pins) do
            if not TOOLING_ONLY[tag] then
                local name = NOTICE_NAMES[tag]
                assert.is_true(
                    name ~= nil,
                    ("the Cargo builder pins %s_REVISION, which this file cannot name. "):format(tag)
                        .. "Add it to NOTICE_NAMES and write its notice."
                )
                if not notices:find(name, 1, true) then
                    table.insert(missing, name)
                end
            end
        end
        table.sort(missing)
        assert.is_true(
            #missing == 0,
            "THIRD_PARTY_NOTICES.md does not name "
                .. table.concat(missing, ", ")
                .. ". A dependency whose notice is not written is a package that ships code without it."
        )
    end)

    it("names every pinned Rust dependency in the notices", function()
        local missing = {}
        for name in pairs(packages) do
            if
                not WORKSPACE_CRATES[name]
                and not BUILD_ONLY_CRATES[name]
                and not notices:find("`" .. name .. "`", 1, true)
            then
                table.insert(missing, name)
            end
        end
        table.sort(missing)
        assert.is_true(
            #missing == 0,
            "THIRD_PARTY_NOTICES.md does not name "
                .. table.concat(missing, ", ")
                .. ". A Rust dependency whose notice is not written is a package that ships code without it."
        )
    end)

    it("writes a notice only for something the build still pins", function()
        for tag, name in pairs(NOTICE_NAMES) do
            assert.is_true(
                pins[tag] ~= nil,
                ("NOTICE_NAMES calls %s_REVISION %s, and the Cargo builder no longer pins it. "):format(tag, name)
                    .. "Drop the entry and the notice with it: a notice for a dependency this engine "
                    .. "does not build describes something a package cannot contain."
            )
        end

        local pinned = {}
        for tag in pairs(pins) do
            local name = NOTICE_NAMES[tag]
            if name then
                pinned[name] = true
            end
        end

        local linked = notices:match("\n## Linked by a build\n(.-)\n## ")
        assert.is_true(
            linked ~= nil,
            "THIRD_PARTY_NOTICES.md has no 'Linked by a build' section, so this check reads nothing. "
                .. "Either the heading moved, in which case fix the pattern, or the section went, "
                .. "in which case the notices no longer describe what a package links."
        )
        for heading in linked:gmatch("\n### ([^\n]+)") do
            assert.is_true(
                pinned[heading] ~= nil or AGGREGATE_SECTIONS[heading] ~= nil,
                ("THIRD_PARTY_NOTICES.md carries a '%s' section under 'Linked by a build', "):format(heading)
                    .. "and nothing pinned answers to that name. Drop the section, or add it to "
                    .. "AGGREGATE_SECTIONS if it describes several pins at once."
            )
        end
    end)

    it("names no Rust package the lockfile has dropped", function()
        local rust = notices:match("\n### Rust native build foundation\n(.-)\n### ")
        assert.is_true(
            rust ~= nil,
            "THIRD_PARTY_NOTICES.md has no 'Rust native build foundation' section, "
                .. "so the Cargo inventory this checks is not where it was."
        )
        local stale = {}
        for name in rust:gmatch("`([^`]+)`") do
            -- A crate name is lowercase with dashes or underscores, which is
            -- what separates one from the paths and macro names around it.
            if name:match("^[%l%d][%l%d_%-]*$") and not packages[name] then
                table.insert(stale, name)
            end
        end
        table.sort(stale)
        assert.is_true(
            #stale == 0,
            "THIRD_PARTY_NOTICES.md names "
                .. table.concat(stale, ", ")
                .. ", which Cargo.lock no longer resolves. An inventory that outlives the lockfile "
                .. "tells a distributor to reproduce a license for code it does not carry."
        )
    end)

    it("keeps every exception it declares true", function()
        for tag in pairs(TOOLING_ONLY) do
            assert.is_true(
                pins[tag] ~= nil,
                ("TOOLING_ONLY skips %s_REVISION, which the Cargo builder no longer pins. "):format(tag)
                    .. "Drop the entry: an exception for a dependency that is gone is one that will "
                    .. "silently cover the next dependency pinned under that name."
            )
        end

        for name in pairs(BUILD_ONLY_CRATES) do
            assert.is_true(
                packages[name] ~= nil,
                ("BUILD_ONLY_CRATES excuses %s, which Cargo.lock no longer resolves. "):format(name)
                    .. "Drop the entry, for the same reason: it excuses whatever arrives under that name next."
            )
            assert.is_true(
                reachable[name] == nil,
                ("BUILD_ONLY_CRATES calls %s a build dependency, and %s reaches it through the lockfile. "):format(
                    name,
                    RUNTIME_CRATE
                ) .. "It ships, so drop the entry and name it in the notices."
            )
        end
    end)
end)

-- Noticing that a content file changed.
--
-- SDL has no change notification, so this is a poll, and a poll has exactly one
-- interesting failure: landing on a file part way through being written. An
-- editor saving commonly truncates and rewrites, so a naive watcher hands a
-- reloader zero bytes or half a PNG. That is what most of this file is about,
-- and it is driven a poll at a time rather than by sleeping, because settling
-- is counted in polls: `watch.scan` is one look at every watched path, so a
-- half-written file can be produced deliberately between two of them.
--
-- The rest is routing. A changed `.glsl` is not a changed `.png`, the kind
-- comes from how the file was loaded rather than from its name alone, and a
-- file nothing has opened is not watched at all.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local assets = require("tecs.assets")
local adapter = require("tecs.platform.adapter")
local filesystem = require("tecs.platform.filesystem")
local storagebackend = require("tecs.platform.storagebackend")
local watch = require("tecs.platform.watch")
local system = require("tecs.platform.system")

local FIRST = "#version 450\n// FIRST\n"
local SECOND = "#version 450\n// SECOND, and longer than the first\n"

local function tempDir()
    local path = os.tmpname()
    os.remove(path)
    os.execute("mkdir -p '" .. path .. "'")
    return path .. "/"
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

--- Truncates a file to nothing, which is the state an editor's save passes
--- through and the one a reloader must never be handed.
local function truncate(path)
    local file = assert(io.open(path, "wb"))
    file:close()
end

--- A handler that records every change it was given, and what the file held
--- at the moment it was called.
local function recorder()
    local seen = {}
    return seen,
        function(change)
            seen[#seen + 1] = {
                path = change.path,
                kind = change.kind,
                contents = read(change.path),
            }
        end
end

describe("the file watcher", function()
    local dir

    before_each(function()
        dir = tempDir()
    end)

    after_each(function()
        watch.uninstall()
        watch.on("shader", nil)
        watch.on("image", nil)
        watch.on("sound", nil)
        watch.on("font", nil)
        watch.on("document", nil)
        adapter.reset()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("watches what was loaded rather than what is in the tree", function()
        write(dir .. "opened.glsl", FIRST)
        write(dir .. "never.glsl", FIRST)
        assert.is_string(filesystem.read(dir .. "opened.glsl"))

        watch.install({ root = dir })

        assert.are.same({ dir .. "opened.glsl" }, watch.watching())
    end)

    it("keeps a neighboring path out when the root has no trailing separator", function()
        local contentRoot = dir .. "content"
        local neighbor = dir .. "content-old"
        assert.is_true(filesystem.createDirectory(contentRoot))
        assert.is_true(filesystem.createDirectory(neighbor))
        write(contentRoot .. "/inside.glsl", FIRST)
        write(neighbor .. "/outside.glsl", FIRST)
        filesystem.read(contentRoot .. "/inside.glsl")
        filesystem.read(neighbor .. "/outside.glsl")

        watch.install({ root = contentRoot })

        assert.are.same({ contentRoot .. "/inside.glsl" }, watch.watching())
    end)

    it("asks the installed storage backend whether a watched path changed", function()
        local path = dir .. "virtual.glsl"
        local version = 1
        local calls = 0
        local storage = setmetatable({
            name = "watch-spec",
            info = function(asked)
                assert.are.equal(path, asked)
                calls = calls + 1
                return {
                    kind = "file",
                    size = version,
                    createdAt = 1,
                    modifiedAt = version,
                    accessedAt = 1,
                }
            end,
        }, { __index = storagebackend.sdl })
        local platform = setmetatable({
            name = "watch-spec",
            storage = storage,
        }, { __index = adapter.current() })
        adapter.install(platform)
        filesystem.note(path, "shader")
        local seen = 0
        watch.on("shader", function()
            seen = seen + 1
        end)

        watch.install({ root = dir })
        version = 2
        watch.scan()
        watch.scan()

        assert.are.equal(1, seen)
        assert.is_true(calls >= 3, "the watcher did not ask the installed backend")
    end)

    it("takes a loaded file as it reads and reports no change for it", function()
        write(dir .. "quiet.glsl", FIRST)
        filesystem.read(dir .. "quiet.glsl")

        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        assert.are.equal(0, watch.scan())
        assert.are.equal(0, watch.scan())
        assert.are.equal(0, #seen, "a file nobody edited was reloaded")
    end)

    it("hands an edited file to the reloader that owns its kind", function()
        write(dir .. "edited.glsl", FIRST)
        filesystem.read(dir .. "edited.glsl")
        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        write(dir .. "edited.glsl", SECOND)

        -- Settling is one poll by default, so the change is seen on the first
        -- look and acted on when the second look agrees with it.
        assert.are.equal(0, watch.scan(), "a change was acted on before it settled")
        assert.are.same({ dir .. "edited.glsl" }, watch.unsettled())
        assert.are.equal(1, watch.scan())

        assert.are.equal(1, #seen)
        assert.are.equal(dir .. "edited.glsl", seen[1].path)
        assert.are.equal("shader", seen[1].kind, "a .glsl document is a shader, not a document")
        assert.are.equal(SECOND, seen[1].contents)
    end)

    it("reloads an edited file once and not again", function()
        write(dir .. "once.glsl", FIRST)
        filesystem.read(dir .. "once.glsl")
        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        write(dir .. "once.glsl", SECOND)
        watch.scan()
        watch.scan()
        watch.scan()
        watch.scan()

        assert.are.equal(1, #seen, "an accepted change fired again on a later poll")
        assert.are.equal(1, watch.dispatched())
    end)

    -- The one that matters. A save that truncates and rewrites is two states,
    -- and neither the empty one nor the partial one may reach a reloader.
    it("never hands over a file that is being written", function()
        write(dir .. "saving.glsl", FIRST)
        filesystem.read(dir .. "saving.glsl")
        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        truncate(dir .. "saving.glsl")
        assert.are.equal(0, watch.scan(), "an empty file was reloaded")
        assert.are.equal(0, watch.scan(), "an empty file settled and was reloaded")
        assert.are.same({}, watch.unsettled(), "an empty file is refused outright, not held pending")

        -- The first half of the rewrite. It is a real length and a real
        -- modification time, so only the settle rule keeps it out.
        write(dir .. "saving.glsl", SECOND:sub(1, 12))
        assert.are.equal(0, watch.scan(), "half a file was reloaded")
        assert.are.same({ dir .. "saving.glsl" }, watch.unsettled())

        -- The rest of it, landing before the half had settled.
        write(dir .. "saving.glsl", SECOND)
        assert.are.equal(0, watch.scan(), "a file still growing was reloaded")
        assert.are.equal(1, watch.scan())

        assert.are.equal(1, #seen, "a save in two steps reloaded more than once")
        assert.are.equal(SECOND, seen[1].contents, "the reloader was handed a partial file")
    end)

    it("keeps watching a file whose save it refused", function()
        write(dir .. "again.glsl", FIRST)
        filesystem.read(dir .. "again.glsl")
        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        truncate(dir .. "again.glsl")
        watch.scan()
        write(dir .. "again.glsl", SECOND)
        watch.scan()
        watch.scan()

        assert.are.equal(1, #seen, "a file that was empty once stopped being watched")
        assert.are.equal(SECOND, seen[1].contents)
    end)

    it("stays up when a reloader raises", function()
        write(dir .. "broken.glsl", FIRST)
        filesystem.read(dir .. "broken.glsl")
        watch.install({ root = dir })
        local calls = 0
        watch.on("shader", function()
            calls = calls + 1
            error("this shader does not compile", 0)
        end)

        write(dir .. "broken.glsl", SECOND)
        watch.scan()
        assert.are.equal(0, watch.scan(), "a reloader that raised was counted as a reload")
        assert.are.equal(1, calls)

        -- Still running, and still willing to try the next save.
        assert.is_true(watch.installed())
        write(dir .. "broken.glsl", FIRST)
        watch.scan()
        watch.scan()
        assert.are.equal(2, calls)
    end)

    it("does nothing for a kind nothing reloads", function()
        write(dir .. "level.json", "{}")
        filesystem.read(dir .. "level.json")
        watch.install({ root = dir })

        write(dir .. "level.json", '{"rooms":2}')
        watch.scan()
        assert.are.equal(0, watch.scan())

        -- Accepted all the same, or an unclaimed file would be seen changing
        -- on every poll for the rest of the run.
        assert.are.same({}, watch.unsettled())
        assert.are.equal(0, watch.scan())
    end)

    it("routes by how a file was loaded, not by its name alone", function()
        write(dir .. "art.png", FIRST)
        write(dir .. "voice.wav", FIRST)
        write(dir .. "level.json", "{}")
        assets.install()

        -- Neither of these will decode, which is beside the point: what is
        -- being asserted is that asking for a path as an image is what makes
        -- it an image here.
        assets.loadImage(dir .. "art.png")
        assets.loadSound(dir .. "voice.wav", "auto", 10000)
        filesystem.read(dir .. "level.json")
        assets.waitAll(500)

        watch.install({ root = dir })
        local kinds = {}
        for _, kind in ipairs({ "image", "sound", "document" }) do
            watch.on(kind, function(change)
                kinds[change.path] = change.kind
            end)
        end

        write(dir .. "art.png", SECOND)
        write(dir .. "voice.wav", SECOND)
        write(dir .. "level.json", '{"rooms":2}')
        watch.scan()
        watch.scan()

        assert.are.equal("image", kinds[dir .. "art.png"])
        assert.are.equal("sound", kinds[dir .. "voice.wav"])
        assert.are.equal("document", kinds[dir .. "level.json"])
        assets.shutdown()
    end)

    -- A font's metrics and a level are both JSON, and one of them has a
    -- reloader. The suffix cannot tell them apart, and neither can `read`, which
    -- answers bytes; what can is the call that asked for the bytes, which is the
    -- one that knows it wanted a font.
    it("routes a font's metrics by what read them, not by the .json on the end", function()
        local text = require("tecs.gfx.text")
        local metrics = require("cjson").encode({
            pages = { "specwatch.png" },
            info = { size = 32 },
            common = { lineHeight = 40, base = 32, scaleW = 256, scaleH = 128 },
            distanceField = { distanceRange = 4 },
            chars = { { id = 72, x = 0, y = 0, width = 20, height = 24, xoffset = 0, yoffset = 2, xadvance = 30 } },
        })

        write(dir .. "level.json", "{}")
        write(dir .. "specwatchfont.json", metrics)
        filesystem.read(dir .. "level.json")
        text.loadFont({ metrics = dir .. "specwatchfont.json", atlas = dir .. "specwatch.png" })

        watch.install({ root = dir })
        local kinds = {}
        for _, kind in ipairs({ "font", "document" }) do
            watch.on(kind, function(change)
                kinds[change.path] = change.kind
            end)
        end

        write(dir .. "level.json", '{"rooms":2}')
        write(dir .. "specwatchfont.json", metrics .. "\n")
        watch.scan()
        watch.scan()

        assert.are.equal("font", kinds[dir .. "specwatchfont.json"], "the metrics were read as a font")
        assert.are.equal("document", kinds[dir .. "level.json"], "and a level is still a level")
    end)

    it("stops looking once it is uninstalled", function()
        write(dir .. "stopped.glsl", FIRST)
        filesystem.read(dir .. "stopped.glsl")
        watch.install({ root = dir })
        local seen, handler = recorder()
        watch.on("shader", handler)

        watch.uninstall()
        assert.is_false(watch.installed())
        assert.are.same({}, watch.watching())

        write(dir .. "stopped.glsl", SECOND)
        assert.are.equal(0, watch.scan())
        assert.are.equal(0, #seen)
    end)

    it("dispatches the first sighting when settling is turned off", function()
        write(dir .. "eager.glsl", FIRST)
        filesystem.read(dir .. "eager.glsl")
        watch.install({ root = dir, settle = 0 })
        local seen, handler = recorder()
        watch.on("shader", handler)

        write(dir .. "eager.glsl", SECOND)
        assert.are.equal(1, watch.scan())
        assert.are.equal(1, #seen)
    end)

    it("refuses a build with no hot-reload capability", function()
        local real = system.capabilities
        system.capabilities = function()
            local answered = real()
            return setmetatable({ hotReload = false }, { __index = answered })
        end

        local ok, failure = pcall(watch.install, { root = dir })
        system.capabilities = real

        assert.is_false(ok)
        assert.is_truthy(
            tostring(failure):find("no hot-reload support", 1, true),
            "unexpected refusal: " .. tostring(failure)
        )
        assert.is_false(watch.installed())
    end)
end)

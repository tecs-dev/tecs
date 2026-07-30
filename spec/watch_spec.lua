-- Noticing that a content file changed.
--
-- SDL has no change notification, so this is a poll, and a poll has exactly one
-- interesting failure: landing on a file part way through being written. An
-- editor saving commonly truncates and rewrites, so a naive watcher hands a
-- reloader zero bytes or half a PNG. That is what most of this file is about,
-- and it is driven a poll at a time rather than by sleeping, because settling
-- is counted in polls: `watcher.scan` is one look at every watched path, so a
-- half-written file can be produced deliberately between two of them.
--
-- The rest is routing. A changed `.glsl` is not a changed `.png`, the kind
-- comes from how the file was loaded rather than from its name alone, and a
-- file nothing has opened is not watched at all.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local assets = require("tecs.assets")
local adapter = require("tecs.platform.adapter")
local files = require("tecs.io.files")
local storagebackend = require("tecs.platform.storagebackend")
local watcher = require("tecs.io.watcher")
local platformOS = require("tecs.platform.os")

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
        watcher.uninstall()
        watcher.on("shader", nil)
        watcher.on("image", nil)
        watcher.on("sound", nil)
        watcher.on("font", nil)
        watcher.on("document", nil)
        adapter.reset()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("watches what was loaded rather than what is in the tree", function()
        write(dir .. "opened.glsl", FIRST)
        write(dir .. "never.glsl", FIRST)
        assert.is_string(files.read(dir .. "opened.glsl"))

        watcher.install({ root = dir })

        assert.are.same({ dir .. "opened.glsl" }, watcher.watching())
    end)

    it("keeps a neighboring path out when the root has no trailing separator", function()
        local contentRoot = dir .. "content"
        local neighbor = dir .. "content-old"
        assert.is_true(files.createDirectory(contentRoot))
        assert.is_true(files.createDirectory(neighbor))
        write(contentRoot .. "/inside.glsl", FIRST)
        write(neighbor .. "/outside.glsl", FIRST)
        files.read(contentRoot .. "/inside.glsl")
        files.read(neighbor .. "/outside.glsl")

        watcher.install({ root = contentRoot })

        assert.are.same({ contentRoot .. "/inside.glsl" }, watcher.watching())
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
        files.note(path, "shader")
        local seen = 0
        watcher.on("shader", function()
            seen = seen + 1
        end)

        watcher.install({ root = dir })
        version = 2
        watcher.scan()
        watcher.scan()

        assert.are.equal(1, seen)
        assert.is_true(calls >= 3, "the watcher did not ask the installed backend")
    end)

    it("takes a loaded file as it reads and reports no change for it", function()
        write(dir .. "quiet.glsl", FIRST)
        files.read(dir .. "quiet.glsl")

        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        assert.are.equal(0, watcher.scan())
        assert.are.equal(0, watcher.scan())
        assert.are.equal(0, #seen, "a file nobody edited was reloaded")
    end)

    it("hands an edited file to the reloader that owns its kind", function()
        write(dir .. "edited.glsl", FIRST)
        files.read(dir .. "edited.glsl")
        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        write(dir .. "edited.glsl", SECOND)

        -- Settling is one poll by default, so the change is seen on the first
        -- look and acted on when the second look agrees with it.
        assert.are.equal(0, watcher.scan(), "a change was acted on before it settled")
        assert.are.same({ dir .. "edited.glsl" }, watcher.unsettled())
        assert.are.equal(1, watcher.scan())

        assert.are.equal(1, #seen)
        assert.are.equal(dir .. "edited.glsl", seen[1].path)
        assert.are.equal("shader", seen[1].kind, "a .glsl document is a shader, not a document")
        assert.are.equal(SECOND, seen[1].contents)
    end)

    it("reloads an edited file once and not again", function()
        write(dir .. "once.glsl", FIRST)
        files.read(dir .. "once.glsl")
        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        write(dir .. "once.glsl", SECOND)
        watcher.scan()
        watcher.scan()
        watcher.scan()
        watcher.scan()

        assert.are.equal(1, #seen, "an accepted change fired again on a later poll")
        assert.are.equal(1, watcher.dispatched())
    end)

    -- The one that matters. A save that truncates and rewrites is two states,
    -- and neither the empty one nor the partial one may reach a reloader.
    it("never hands over a file that is being written", function()
        write(dir .. "saving.glsl", FIRST)
        files.read(dir .. "saving.glsl")
        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        truncate(dir .. "saving.glsl")
        assert.are.equal(0, watcher.scan(), "an empty file was reloaded")
        assert.are.equal(0, watcher.scan(), "an empty file settled and was reloaded")
        assert.are.same({}, watcher.unsettled(), "an empty file is refused outright, not held pending")

        -- The first half of the rewrite. It is a real length and a real
        -- modification time, so only the settle rule keeps it out.
        write(dir .. "saving.glsl", SECOND:sub(1, 12))
        assert.are.equal(0, watcher.scan(), "half a file was reloaded")
        assert.are.same({ dir .. "saving.glsl" }, watcher.unsettled())

        -- The rest of it, landing before the half had settled.
        write(dir .. "saving.glsl", SECOND)
        assert.are.equal(0, watcher.scan(), "a file still growing was reloaded")
        assert.are.equal(1, watcher.scan())

        assert.are.equal(1, #seen, "a save in two steps reloaded more than once")
        assert.are.equal(SECOND, seen[1].contents, "the reloader was handed a partial file")
    end)

    it("keeps watching a file whose save it refused", function()
        write(dir .. "again.glsl", FIRST)
        files.read(dir .. "again.glsl")
        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        truncate(dir .. "again.glsl")
        watcher.scan()
        write(dir .. "again.glsl", SECOND)
        watcher.scan()
        watcher.scan()

        assert.are.equal(1, #seen, "a file that was empty once stopped being watched")
        assert.are.equal(SECOND, seen[1].contents)
    end)

    it("stays up when a reloader raises", function()
        write(dir .. "broken.glsl", FIRST)
        files.read(dir .. "broken.glsl")
        watcher.install({ root = dir })
        local calls = 0
        watcher.on("shader", function()
            calls = calls + 1
            error("this shader does not compile", 0)
        end)

        write(dir .. "broken.glsl", SECOND)
        watcher.scan()
        assert.are.equal(0, watcher.scan(), "a reloader that raised was counted as a reload")
        assert.are.equal(1, calls)

        -- Still running, and still willing to try the next save.
        assert.is_true(watcher.installed())
        write(dir .. "broken.glsl", FIRST)
        watcher.scan()
        watcher.scan()
        assert.are.equal(2, calls)
    end)

    it("does nothing for a kind nothing reloads", function()
        write(dir .. "level.json", "{}")
        files.read(dir .. "level.json")
        watcher.install({ root = dir })

        write(dir .. "level.json", '{"rooms":2}')
        watcher.scan()
        assert.are.equal(0, watcher.scan())

        -- Accepted all the same, or an unclaimed file would be seen changing
        -- on every poll for the rest of the run.
        assert.are.same({}, watcher.unsettled())
        assert.are.equal(0, watcher.scan())
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
        files.read(dir .. "level.json")
        assets.waitAll(500)

        watcher.install({ root = dir })
        local kinds = {}
        for _, kind in ipairs({ "image", "sound", "document" }) do
            watcher.on(kind, function(change)
                kinds[change.path] = change.kind
            end)
        end

        write(dir .. "art.png", SECOND)
        write(dir .. "voice.wav", SECOND)
        write(dir .. "level.json", '{"rooms":2}')
        watcher.scan()
        watcher.scan()

        assert.are.equal("image", kinds[dir .. "art.png"])
        assert.are.equal("sound", kinds[dir .. "voice.wav"])
        assert.are.equal("document", kinds[dir .. "level.json"])
        assets.shutdown()
    end)

    -- The content kind comes from the load that requested the bytes, rather
    -- than from a filename suffix.
    it("routes source bytes as a font when newTTF reads them", function()
        local text = require("tecs.gfx.text")
        local source = assert(files.read(files.assetPath("fonts/JetBrainsMono-ExtraBold.ttf")))

        write(dir .. "level.json", "{}")
        write(dir .. "specwatchfont.ttf", source)
        files.read(dir .. "level.json")
        text.newTTF({ source = dir .. "specwatchfont.ttf" }):wait()

        watcher.install({ root = dir })
        local kinds = {}
        for _, kind in ipairs({ "font", "document" }) do
            watcher.on(kind, function(change)
                kinds[change.path] = change.kind
            end)
        end

        write(dir .. "level.json", '{"rooms":2}')
        write(dir .. "specwatchfont.ttf", source .. "\0")
        watcher.scan()
        watcher.scan()

        assert.are.equal("font", kinds[dir .. "specwatchfont.ttf"], "the source was read as a font")
        assert.are.equal("document", kinds[dir .. "level.json"], "and a level is still a level")
    end)

    it("stops looking once it is uninstalled", function()
        write(dir .. "stopped.glsl", FIRST)
        files.read(dir .. "stopped.glsl")
        watcher.install({ root = dir })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        watcher.uninstall()
        assert.is_false(watcher.installed())
        assert.are.same({}, watcher.watching())

        write(dir .. "stopped.glsl", SECOND)
        assert.are.equal(0, watcher.scan())
        assert.are.equal(0, #seen)
    end)

    it("dispatches the first sighting when settling is turned off", function()
        write(dir .. "eager.glsl", FIRST)
        files.read(dir .. "eager.glsl")
        watcher.install({ root = dir, settle = 0 })
        local seen, handler = recorder()
        watcher.on("shader", handler)

        write(dir .. "eager.glsl", SECOND)
        assert.are.equal(1, watcher.scan())
        assert.are.equal(1, #seen)
    end)

    it("refuses a build with no hot-reload capability", function()
        local real = platformOS.capabilities
        platformOS.capabilities = function()
            local answered = real()
            return setmetatable({ hotReload = false }, { __index = answered })
        end

        local ok, failure = pcall(watcher.install, { root = dir })
        platformOS.capabilities = real

        assert.is_false(ok)
        assert.is_truthy(
            tostring(failure):find("no hot-reload support", 1, true),
            "unexpected refusal: " .. tostring(failure)
        )
        assert.is_false(watcher.installed())
    end)
end)

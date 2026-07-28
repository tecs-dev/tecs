-- Logging.
--
-- There is almost nothing here to test, which is the point: SDL owns the
-- levels, the formatting and the destination. What is worth pinning is that
-- the guard really does come before the formatting, that a name survives into
-- the file, and that the file is the structured one while the platform keeps
-- getting the readable one.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local log = require("tecs.log")

local C = sdl.C
local PATH = "/tmp/tecs-log-spec.jsonl"
local FIRST = "/tmp/tecs-log-spec-first.jsonl"
local SECOND = "/tmp/tecs-log-spec-second.jsonl"

local function readLines(path)
    local file = io.open(path, "r")
    if file == nil then
        return {}
    end
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = line
    end
    file:close()
    return lines
end

describe("log", function()
    setup(function()
        assert(C.SDL_Init(0))
    end)
    teardown(function()
        log.closeFile()
        os.remove(PATH)
        os.remove(FIRST)
        os.remove(SECOND)
        C.SDL_Quit()
    end)

    local function contains(path, text)
        for _, line in ipairs(readLines(path)) do
            if line:find(text, 1, true) then
                return true
            end
        end
        return false
    end

    it("gives the same logger back for a name", function()
        local one = log.get("spec.same")
        assert.are.equal(one, log.get("spec.same"))
        assert.are_not.equal(one.category, log.get("spec.other").category)
    end)

    it("keeps levels in SDL rather than mirroring them", function()
        -- Nothing here caches a level, so setting it through SDL directly is
        -- seen immediately. That is what makes a debugger command possible
        -- with no state to keep in sync.
        local logger = log.get("spec.levels")
        logger:setLevel(log.WARN)
        assert.are.equal(log.WARN, logger:level())

        C.SDL_SetLogPriority(logger.category, log.DEBUG)
        assert.are.equal(log.DEBUG, logger:level())
        assert.is_true(logger:enabled(log.INFO))
        assert.is_false(logger:enabled(log.TRACE))
    end)

    it("does not format a message it will not emit", function()
        -- The whole reason the guard is on this side. A formatter that raises
        -- proves the arguments were never touched.
        local logger = log.get("spec.guard")
        logger:setLevel(log.ERROR)

        local exploded = setmetatable({}, {
            __tostring = function()
                error("formatted a filtered message")
            end,
        })
        assert.has_no.errors(function()
            logger:debug("%s", exploded)
        end)

        logger:setLevel(log.DEBUG)
        assert.has_error(function()
            logger:debug("%s", exploded)
        end)
    end)

    it("writes the file as JSON Lines with the logger's name", function()
        assert.is_true(log.openFile(PATH))
        local logger = log.get("spec.file")
        logger:setLevel(log.INFO)
        logger:info("hello %d", 42)
        logger:warn("careful")
        logger:debug("filtered out")

        local lines = readLines(PATH)
        assert.is_true(#lines >= 2)

        local emitted = {}
        for _, line in ipairs(lines) do
            if line:find("spec.file", 1, true) then
                emitted[#emitted + 1] = line
            end
        end
        assert.are.equal(2, #emitted, "the debug line must be filtered")
        assert.is_truthy(emitted[1]:find('"logger":"spec.file"', 1, true))
        assert.is_truthy(emitted[1]:find('"level":"INFO"', 1, true))
        assert.is_truthy(emitted[1]:find('"message":"hello 42"', 1, true))
        assert.is_truthy(emitted[2]:find('"level":"WARN"', 1, true))
    end)

    it("escapes what would otherwise break a line", function()
        assert.is_true(log.openFile(PATH))
        local logger = log.get("spec.escape")
        logger:setLevel(log.INFO)
        logger:info('a "quoted" \\ backslash\nand a newline')

        for _, line in ipairs(readLines(PATH)) do
            if line:find("spec.escape", 1, true) then
                -- One line, and the embedded newline did not end it early.
                assert.is_truthy(line:find('\\"quoted\\"', 1, true))
                assert.is_truthy(line:find("\\\\", 1, true))
                assert.is_truthy(line:find("\\n", 1, true))
                assert.is_truthy(line:sub(-1) == "}")
                return
            end
        end
        error("the escaped line was never written")
    end)

    it("captures SDL's own diagnostics in the same stream", function()
        -- The reason to funnel SDL through here rather than keep a separate
        -- logger: driver and GPU messages land beside the game's own.
        assert.is_true(log.openFile(PATH))
        C.SDL_SetLogPriority(sdl.C.SDL_LOG_CATEGORY_VIDEO, log.INFO)
        C.SDL_LogInfo(sdl.C.SDL_LOG_CATEGORY_VIDEO, "%s", "from sdl")

        local found = false
        for _, line in ipairs(readLines(PATH)) do
            if line:find("sdl.video", 1, true) then
                found = true
            end
        end
        assert.is_true(found, "SDL's own categories must be named too")
    end)

    it("moves to the second file rather than reporting one it did not open", function()
        -- `get_logs` hands `filePath` to whoever is reading the log, so a call
        -- that answers true and names a path the sink is not writing to sends
        -- that reader to an empty file and tells them the game is silent.
        assert.is_true(log.openFile(FIRST))
        local logger = log.get("spec.switch")
        logger:setLevel(log.INFO)
        logger:info("before the switch")

        assert.is_true(log.openFile(SECOND))
        assert.are.equal(SECOND, log.filePath())
        logger:info("after the switch")

        assert.is_true(contains(SECOND, "after the switch"), "the line went to the file that was left behind")
        assert.is_false(contains(SECOND, "before the switch"))

        -- The first file is closed rather than abandoned mid-line, so what it
        -- already had is on disk and nothing arrived in it afterwards.
        assert.is_true(contains(FIRST, "before the switch"))
        assert.is_false(contains(FIRST, "after the switch"))
    end)

    it("keeps writing to the file it has when a path cannot be opened", function()
        assert.is_true(log.openFile(FIRST))
        local logger = log.get("spec.refused")
        logger:setLevel(log.INFO)

        assert.is_false(log.openFile("/tmp/tecs-log-spec-missing-directory/log.jsonl"))
        assert.are.equal(FIRST, log.filePath(), "a refused path must not be reported as open")

        logger:info("still the first file")
        assert.is_true(contains(FIRST, "still the first file"))
    end)
end)

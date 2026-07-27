-- Reading and writing the system clipboard.
--
-- Round-tripped for real rather than mocked: setting and getting are both
-- available, so a mock would only prove that the mock agrees with itself.
--
-- Which makes this one of the few specs that can reach outside the process and
-- take something away from whoever is running it. So the clipboard's text and
-- the primary selection are both saved before the first write and put back
-- after the last one. A clipboard holding something that is not text cannot be
-- saved that way and is not preserved: putting arbitrary bytes back would need
-- the offer side of `SDL_SetClipboardData`, which is deliberately not part of
-- the module, so the honest limit of the restore is the limit of the surface.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local clipboard = require("tecs.platform.clipboard")

local TEXT_MIME = "text/plain;charset=utf-8"

-- Resident bytes right now, not the high-water mark. `getrusage` reports the
-- peak, and by the time this file runs the suite has already been half a
-- gigabyte, so a leak underneath that peak would not move it and the test
-- would pass while leaking.
ffi.cdef([[
    typedef unsigned int tecsMachPort;
    typedef struct {
        uint64_t virtualSize; uint64_t residentSize; uint64_t residentSizeMax;
        int32_t userTime[2]; int32_t systemTime[2];
        int32_t policy; int32_t suspendCount;
    } tecsTaskBasicInfo;
    tecsMachPort mach_task_self(void);
    int task_info(tecsMachPort task, unsigned int flavor, int32_t *info, unsigned int *count);
]])

local MACH_TASK_BASIC_INFO = 20
local taskInfo = ffi.new("tecsTaskBasicInfo")
local taskInfoCount = ffi.new("unsigned int[1]")

local function residentBytes()
    if ffi.os == "OSX" then
        taskInfoCount[0] = ffi.sizeof("tecsTaskBasicInfo") / 4
        local answered = ffi.C.task_info(
            ffi.C.mach_task_self(),
            MACH_TASK_BASIC_INFO,
            ffi.cast("int32_t *", taskInfo),
            taskInfoCount
        )
        if answered ~= 0 then return nil end
        return tonumber(taskInfo.residentSize)
    end
    local statm = io.open("/proc/self/statm", "r")
    if statm == nil then return nil end
    local line = statm:read("*l")
    statm:close()
    local pages = tonumber(line:match("%d+%s+(%d+)"))
    return pages and pages * 4096 or nil
end

--- Resident bytes with the Lua garbage already collected, so what is left is
--- what the C side is still holding.
local function settled()
    collectgarbage("collect")
    collectgarbage("collect")
    return assert(residentBytes(), "this platform needs a reader for resident bytes")
end

-- A leak of the text, the primary selection and the blob is one payload per
-- read, so the read loop leaks 192 MB and the list loop another 46 MB. Both
-- are far enough above what the same loops cost when everything is freed that
-- the threshold does not have to be tuned.
local PAYLOAD = 256 * 1024
local READS = 256
local LISTS = 1000000
local ALLOWED_GROWTH = 32 * 1024 * 1024

describe("platform.clipboard on the public surface", function()
    it("resolves by name rather than being held", function()
        -- The clipboard reaches SDL, so putting it on the eager half of the
        -- surface would make a tool that only wanted the ECS find a graphics
        -- stack. `headless_spec` proves that in a fresh process; what is
        -- observable here is the wiring that keeps it true, which is that the
        -- surface has no value for the name until something asks for one.
        local tecs = require("tecs")
        assert.is_nil(rawget(tecs, "clipboard"), "nothing may hold the module before it is asked for")
        assert.are.equal(clipboard, tecs.clipboard)
        assert.is_not_nil(rawget(tecs, "clipboard"), "and the resolved module is kept, not re-required")
    end)
end)

-- The whole suite shares one SDL, so this block cannot assume video is down;
-- it takes it down and puts the count back. SDL counts inits per subsystem, so
-- a matching number of quits is what down means and the same number of inits
-- restores exactly what was there.
describe("platform.clipboard with no video", function()
    local held = 0

    setup(function()
        for _ = 1, 8 do
            if sdl.C.SDL_WasInit(sdl.K.SDL_INIT_VIDEO) == 0 then break end
            sdl.C.SDL_QuitSubSystem(sdl.K.SDL_INIT_VIDEO)
            held = held + 1
        end
    end)

    teardown(function()
        for _ = 1, held do
            assert(sdl.C.SDL_InitSubSystem(sdl.K.SDL_INIT_VIDEO))
        end
    end)

    it("reports that there is no clipboard", function()
        -- The one answer that separates "no clipboard" from "empty clipboard".
        -- Without it every other return value here reads as an empty clipboard.
        assert.is_false(clipboard.available())
    end)

    it("answers empty and false instead of failing", function()
        -- A headless tool is a supported way to run, so asking is allowed and
        -- gets an answer. Nothing raises and nothing claims to have worked.
        assert.are.equal("", clipboard.text())
        assert.is_false(clipboard.hasText())
        assert.is_false(clipboard.hasData(TEXT_MIME))
        assert.is_nil(clipboard.data(TEXT_MIME))
        assert.are.same({}, clipboard.mimeTypes())
        assert.are.equal("", clipboard.primary())
        assert.is_false(clipboard.hasPrimary())
    end)

    it("reports a write as failed rather than pretending", function()
        assert.is_false(clipboard.setText("into the void"))
        assert.is_false(clipboard.setPrimary("into the void"))
        assert.is_false(clipboard.clear())
    end)

    it("leaves SDL's error alone, having asked SDL nothing", function()
        -- Every clipboard entry point in SDL sets "Video subsystem has not
        -- been initialized" when video is down. Short-circuiting means an
        -- unrelated failure reported later is still the one that happened.
        local asked = {
            function() clipboard.text() end,
            function() clipboard.hasText() end,
            function() clipboard.setText("ignored") end,
            function() clipboard.clear() end,
            function() clipboard.mimeTypes() end,
            function() clipboard.hasData(TEXT_MIME) end,
            function() clipboard.data(TEXT_MIME) end,
            function() clipboard.primary() end,
            function() clipboard.setPrimary("ignored") end,
            function() clipboard.hasPrimary() end,
        }
        for index, ask in ipairs(asked) do
            sdl.C.SDL_SetError("sentinel")
            ask()
            assert.are.equal("sentinel", sdl.error(), "entry point " .. index .. " reached SDL with no video")
        end
        sdl.C.SDL_ClearError()
    end)
end)

describe("platform.clipboard", function()
    local savedText = ""
    local savedPrimary = ""

    --- Reads a clipboard string through SDL directly, so the spec's own
    --- housekeeping does not depend on the module it is testing.
    local function readAndFree(pointer)
        local text = loader.toString(pointer)
        sdl.C.SDL_free(pointer)
        return text
    end

    setup(function()
        assert(sdl.C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        savedText = readAndFree(sdl.C.SDL_GetClipboardText())
        savedPrimary = readAndFree(sdl.C.SDL_GetPrimarySelectionText())
    end)

    teardown(function()
        sdl.C.SDL_SetClipboardText(savedText)
        sdl.C.SDL_SetPrimarySelectionText(savedPrimary)
        sdl.C.SDL_Quit()
    end)

    it("reports that there is a clipboard", function()
        assert.is_true(clipboard.available())
    end)

    it("round-trips text", function()
        assert.is_true(clipboard.setText("copied"))
        assert.are.equal("copied", clipboard.text())
    end)

    it("answers whether there is any without reading it", function()
        clipboard.setText("something")
        assert.is_true(clipboard.hasText())
    end)

    it("passes bytes through unchanged", function()
        -- UTF-8 that is not ASCII, an embedded newline, CRLF from a Windows
        -- producer, and whitespace at both ends. None of it is normalised and
        -- none of it is trimmed: what went in is what comes back.
        local awkward = "  caf\195\169 \240\159\142\174 line\r\nline\ntail\t"
        clipboard.setText(awkward)
        assert.are.equal(awkward, clipboard.text())
    end)

    it("keeps text that is genuinely empty distinguishable", function()
        -- Empty text is a real clipboard state and not the same as no
        -- clipboard, which is why `available` exists separately.
        assert.is_true(clipboard.setText(""))
        assert.are.equal("", clipboard.text())
        assert.is_true(clipboard.available())
    end)

    it("refuses a write with nothing to write", function()
        -- SDL reads a null string as empty, so a nil that reached it would
        -- clear the clipboard and report success.
        clipboard.setText("intact")
        clipboard.setPrimary("also intact")
        assert.has_error(function()
            clipboard.setText(nil)
        end, "tecs: clipboard.setText needs a string")
        assert.has_error(function()
            clipboard.setPrimary(nil)
        end, "tecs: clipboard.setPrimary needs a string")
        assert.are.equal("intact", clipboard.text())
        assert.are.equal("also intact", clipboard.primary())
    end)

    it("refuses a read with no mime type to read", function()
        -- SDL answers a null mime type with an invalid-parameter failure,
        -- which reads from here as a clipboard that simply holds nothing.
        assert.has_error(function()
            clipboard.data(nil)
        end, "tecs: clipboard.data needs a string")
        assert.has_error(function()
            clipboard.hasData(nil)
        end, "tecs: clipboard.hasData needs a string")
    end)

    it("lists the mime types on offer", function()
        -- The same list `clipboardUpdate` carries, which is what makes the
        -- event's payload something a caller can act on.
        clipboard.setText("listed")
        local offered = clipboard.mimeTypes()
        local found = false
        for _, mime in ipairs(offered) do
            if mime == TEXT_MIME then found = true end
        end
        assert.is_true(found, "text on the clipboard is offered as " .. TEXT_MIME)
    end)

    it("reads the bytes behind a mime type", function()
        clipboard.setText("by mime")
        assert.is_true(clipboard.hasData(TEXT_MIME))
        assert.are.equal("by mime", clipboard.data(TEXT_MIME))
    end)

    it("answers nil for a mime type the clipboard does not offer", function()
        clipboard.setText("only text")
        assert.is_false(clipboard.hasData("application/x-tecs-nothing"))
        assert.is_nil(clipboard.data("application/x-tecs-nothing"))
    end)

    it("withdraws what it put there", function()
        clipboard.setText("temporary")
        assert.is_true(clipboard.clear())
        assert.is_false(clipboard.hasText())
        assert.are.same({}, clipboard.mimeTypes())
    end)

    it("round-trips the primary selection", function()
        -- A separate clipboard, not a view of the one above: X11 and Wayland
        -- fill it from the selection itself. Where there is no such concept
        -- SDL keeps the value in this process, so the round trip holds
        -- everywhere and only its reach differs.
        assert.is_true(clipboard.setPrimary("selected"))
        assert.is_true(clipboard.hasPrimary())
        assert.are.equal("selected", clipboard.primary())
    end)

    it("keeps the primary selection independent of the clipboard", function()
        clipboard.setText("clipboard side")
        clipboard.setPrimary("selection side")
        assert.are.equal("clipboard side", clipboard.text())
        assert.are.equal("selection side", clipboard.primary())
    end)

    it("frees the text, the selection and the blob SDL allocated", function()
        -- SDL hands back its own allocation for every read, and answers a
        -- failed read with an allocated empty string rather than nothing, so
        -- the free is owed on every path. Forgetting it leaks once per paste,
        -- which nobody attributes to the clipboard.
        clipboard.setText(string.rep("x", PAYLOAD))
        clipboard.setPrimary(string.rep("y", PAYLOAD))

        local before = settled()
        for _ = 1, READS do
            clipboard.text()
            clipboard.primary()
            clipboard.data(TEXT_MIME)
        end
        local grew = settled() - before
        assert.is_true(
            grew < ALLOWED_GROWTH,
            ("reading text, the primary selection and a blob %d times grew the process by %.0f MB")
                :format(READS, grew / 1048576)
        )
    end)

    it("frees the mime list, which is one allocation and not one per entry", function()
        -- SDL puts the array and the strings it points at in a single block,
        -- so one free releases all of it and freeing an entry would be a
        -- double free. The list is small, hence the count: a leak of it is
        -- only visible in bulk.
        clipboard.setText("listed")
        local before = settled()
        for _ = 1, LISTS do
            clipboard.mimeTypes()
        end
        local grew = settled() - before
        assert.is_true(
            grew < ALLOWED_GROWTH,
            ("reading the mime list %d times grew the process by %.0f MB"):format(LISTS, grew / 1048576)
        )
    end)
end)

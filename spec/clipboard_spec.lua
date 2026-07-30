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
local platformOS = require("tecs.platform.os")

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
        if answered ~= 0 then
            return nil
        end
        return tonumber(taskInfo.residentSize)
    end
    local statm = io.open("/proc/self/statm", "r")
    if statm == nil then
        return nil
    end
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
        assert.is_nil(rawget(tecs, "os"), "the removed root alias must remain empty")
        assert.is_nil(tecs.system, "the removed public name must not remain as an alias")
        assert.are.equal(platformOS.clipboardText, tecs.platform.os.clipboardText)
        assert.is_true(rawequal(tecs.platform.os, platformOS), "the child must resolve once")
        assert.is_nil(rawget(tecs.platform, "os"), "the lazy namespace must remain empty")
        assert.is_nil(rawget(tecs, "os"), "resolving the child must not restore the root alias")
        assert.is_nil(tecs.system, "resolving tecs.platform.os must not restore the removed name")
    end)

    it("is reached under tecs.platform.os with its names qualified", function()
        -- Four modules answer one name, so a bare `text`, `data` or `clear`
        -- would mean nothing on it.
        local tecs = require("tecs")
        assert.are.equal(platformOS.setClipboardText, tecs.platform.os.setClipboardText)
        assert.are.equal(platformOS.clipboardData, tecs.platform.os.clipboardData)
        assert.are.equal(platformOS.primarySelection, tecs.platform.os.primarySelection)
        assert.is_nil(tecs.platform.os.text)
        assert.is_nil(tecs.platform.os.data)
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
            if sdl.C.SDL_WasInit(sdl.K.SDL_INIT_VIDEO) == 0 then
                break
            end
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
        assert.is_false(platformOS.clipboardAvailable())
    end)

    it("answers empty and false instead of failing", function()
        -- A headless tool is a supported way to run, so asking is allowed and
        -- gets an answer. Nothing raises and nothing claims to have worked.
        assert.are.equal("", platformOS.clipboardText())
        assert.is_false(platformOS.hasClipboardText())
        assert.is_false(platformOS.hasClipboardData(TEXT_MIME))
        assert.is_nil(platformOS.clipboardData(TEXT_MIME))
        assert.are.same({}, platformOS.clipboardMimeTypes())
        assert.are.equal("", platformOS.primarySelection())
        assert.is_false(platformOS.hasPrimarySelection())
    end)

    it("reports a write as failed rather than pretending", function()
        assert.is_false(platformOS.setClipboardText("into the void"))
        assert.is_false(platformOS.setPrimarySelection("into the void"))
        assert.is_false(platformOS.clearClipboard())
    end)

    it("leaves SDL's error alone, having asked SDL nothing", function()
        -- Every clipboard entry point in SDL sets "Video subsystem has not
        -- been initialized" when video is down. Short-circuiting means an
        -- unrelated failure reported later is still the one that happened.
        local asked = {
            function()
                platformOS.clipboardText()
            end,
            function()
                platformOS.hasClipboardText()
            end,
            function()
                platformOS.setClipboardText("ignored")
            end,
            function()
                platformOS.clearClipboard()
            end,
            function()
                platformOS.clipboardMimeTypes()
            end,
            function()
                platformOS.hasClipboardData(TEXT_MIME)
            end,
            function()
                platformOS.clipboardData(TEXT_MIME)
            end,
            function()
                platformOS.primarySelection()
            end,
            function()
                platformOS.setPrimarySelection("ignored")
            end,
            function()
                platformOS.hasPrimarySelection()
            end,
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
        assert.is_true(platformOS.clipboardAvailable())
    end)

    it("round-trips text", function()
        assert.is_true(platformOS.setClipboardText("copied"))
        assert.are.equal("copied", platformOS.clipboardText())
    end)

    it("answers whether there is any without reading it", function()
        platformOS.setClipboardText("something")
        assert.is_true(platformOS.hasClipboardText())
    end)

    it("passes bytes through unchanged", function()
        -- UTF-8 that is not ASCII, an embedded newline, CRLF from a Windows
        -- producer, and whitespace at both ends. None of it is normalized and
        -- none of it is trimmed: what went in is what comes back.
        local awkward = "  caf\195\169 \240\159\142\174 line\r\nline\ntail\t"
        platformOS.setClipboardText(awkward)
        assert.are.equal(awkward, platformOS.clipboardText())
    end)

    it("keeps text that is genuinely empty distinguishable", function()
        -- Empty text is a real clipboard state and not the same as no
        -- clipboard, which is why `available` exists separately.
        assert.is_true(platformOS.setClipboardText(""))
        assert.are.equal("", platformOS.clipboardText())
        assert.is_true(platformOS.clipboardAvailable())
    end)

    it("refuses a write with nothing to write", function()
        -- SDL reads a null string as empty, so a nil that reached it would
        -- clear the clipboard and report success.
        platformOS.setClipboardText("intact")
        platformOS.setPrimarySelection("also intact")
        assert.has_error(function()
            platformOS.setClipboardText(nil)
        end, "tecs: os.setClipboardText needs a string")
        assert.has_error(function()
            platformOS.setPrimarySelection(nil)
        end, "tecs: os.setPrimarySelection needs a string")
        assert.are.equal("intact", platformOS.clipboardText())
        assert.are.equal("also intact", platformOS.primarySelection())
    end)

    it("refuses a read with no mime type to read", function()
        -- SDL answers a null mime type with an invalid-parameter failure,
        -- which reads from here as a clipboard that simply holds nothing.
        assert.has_error(function()
            platformOS.clipboardData(nil)
        end, "tecs: os.clipboardData needs a string")
        assert.has_error(function()
            platformOS.hasClipboardData(nil)
        end, "tecs: os.hasClipboardData needs a string")
    end)

    it("lists the mime types on offer", function()
        -- The same list `clipboardUpdate` carries, which is what makes the
        -- event's payload something a caller can act on.
        platformOS.setClipboardText("listed")
        local offered = platformOS.clipboardMimeTypes()
        local found = false
        for _, mime in ipairs(offered) do
            if mime == TEXT_MIME then
                found = true
            end
        end
        assert.is_true(found, "text on the clipboard is offered as " .. TEXT_MIME)
    end)

    it("reads the bytes behind a mime type", function()
        platformOS.setClipboardText("by mime")
        assert.is_true(platformOS.hasClipboardData(TEXT_MIME))
        assert.are.equal("by mime", platformOS.clipboardData(TEXT_MIME))
    end)

    it("answers nil for a mime type the clipboard does not offer", function()
        platformOS.setClipboardText("only text")
        assert.is_false(platformOS.hasClipboardData("application/x-tecs-nothing"))
        assert.is_nil(platformOS.clipboardData("application/x-tecs-nothing"))
    end)

    it("withdraws what it put there", function()
        platformOS.setClipboardText("temporary")
        assert.is_true(platformOS.clearClipboard())
        assert.is_false(platformOS.hasClipboardText())
        assert.are.same({}, platformOS.clipboardMimeTypes())
    end)

    it("round-trips the primary selection", function()
        -- A separate clipboard, not a view of the one above: X11 and Wayland
        -- fill it from the selection itself. Where there is no such concept
        -- SDL keeps the value in this process, so the round trip holds
        -- everywhere and only its reach differs.
        assert.is_true(platformOS.setPrimarySelection("selected"))
        assert.is_true(platformOS.hasPrimarySelection())
        assert.are.equal("selected", platformOS.primarySelection())
    end)

    it("keeps the primary selection independent of the clipboard", function()
        platformOS.setClipboardText("clipboard side")
        platformOS.setPrimarySelection("selection side")
        assert.are.equal("clipboard side", platformOS.clipboardText())
        assert.are.equal("selection side", platformOS.primarySelection())
    end)

    it("frees the text, the selection and the blob SDL allocated", function()
        -- SDL hands back its own allocation for every read, and answers a
        -- failed read with an allocated empty string rather than nothing, so
        -- the free is owed on every path. Forgetting it leaks once per paste,
        -- which nobody attributes to the clipboard.
        platformOS.setClipboardText(string.rep("x", PAYLOAD))
        platformOS.setPrimarySelection(string.rep("y", PAYLOAD))

        local before = settled()
        for _ = 1, READS do
            platformOS.clipboardText()
            platformOS.primarySelection()
            platformOS.clipboardData(TEXT_MIME)
        end
        local grew = settled() - before
        assert.is_true(
            grew < ALLOWED_GROWTH,
            ("reading text, the primary selection and a blob %d times grew the process by %.0f MB"):format(
                READS,
                grew / 1048576
            )
        )
    end)

    it("frees the mime list, which is one allocation and not one per entry", function()
        -- SDL puts the array and the strings it points at in a single block,
        -- so one free releases all of it and freeing an entry would be a
        -- double free. The list is small, hence the count: a leak of it is
        -- only visible in bulk.
        platformOS.setClipboardText("listed")
        local before = settled()
        for _ = 1, LISTS do
            platformOS.clipboardMimeTypes()
        end
        local grew = settled() - before
        assert.is_true(
            grew < ALLOWED_GROWTH,
            ("reading the mime list %d times grew the process by %.0f MB"):format(LISTS, grew / 1048576)
        )
    end)
end)

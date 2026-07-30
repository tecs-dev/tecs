-- Listing, creating, removing, renaming, copying and stat-ing real paths.
--
-- Everything here runs against the real filesystem rather than a mock, because
-- the whole point of the module is that it is SDL's semantics and not a
-- reimplementation of them; a mock would only prove that the mock agrees with
-- itself. So every test writes inside one temporary directory created in
-- `setup` and emptied in `teardown`, and nothing writes anywhere else. The
-- teardown is itself a recursive glob and a loop, which is the composition the
-- module documents instead of offering.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local filesystem = require("tecs.io.filesystem")
local assets = require("tecs.assets")
local workers = require("tecs.workers")

local C = sdl.C

-- Resident bytes right now, not the high-water mark, for the same reason
-- `clipboard_spec` reads it this way: by the time this file runs the suite has
-- already peaked well above anything a leak here would add, so a peak reading
-- would not move and the test would pass while leaking. The type names carry
-- their own prefix because the whole suite shares one FFI state and a second
-- `typedef` of a name already declared is an error.
ffi.cdef([[
    typedef unsigned int tecsFsMachPort;
    typedef struct {
        uint64_t virtualSize; uint64_t residentSize; uint64_t residentSizeMax;
        int32_t userTime[2]; int32_t systemTime[2];
        int32_t policy; int32_t suspendCount;
    } tecsFsTaskBasicInfo;
    tecsFsMachPort mach_task_self(void);
    int task_info(tecsFsMachPort task, unsigned int flavor, int32_t *info, unsigned int *count);
]])

local MACH_TASK_BASIC_INFO = 20
local taskInfo = ffi.new("tecsFsTaskBasicInfo")
local taskInfoCount = ffi.new("unsigned int[1]")

local function residentBytes()
    if ffi.os == "OSX" then
        taskInfoCount[0] = ffi.sizeof("tecsFsTaskBasicInfo") / 4
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

local function settled()
    collectgarbage("collect")
    collectgarbage("collect")
    return assert(residentBytes(), "this platform needs a reader for resident bytes")
end

local temp

--- Sorted, so an assertion is about what is there rather than about the order
--- the platform happened to report, which the module deliberately does not fix.
local function sorted(list)
    table.sort(list)
    return list
end

--- Empties and removes a tree, deepest entry first.
---
--- The composition the module documents rather than providing: a recursive
--- glob answers every descendant, longest paths are deepest, and `remove`
--- takes an empty directory once its contents are gone. A path that is not a
--- directory globs as nil and is simply removed.
local function removeTree(path)
    local entries = filesystem.glob(path)
    if entries ~= nil then
        table.sort(entries, function(a, b)
            return #a > #b
        end)
        for _, entry in ipairs(entries) do
            filesystem.remove(path .. "/" .. entry)
        end
    end
    filesystem.remove(path)
end

--- A path inside the temporary directory.
local function at(relative)
    return temp .. "/" .. relative
end

describe("io.filesystem on the public surface", function()
    it("resolves by name rather than being held", function()
        -- The module reaches SDL, so holding it on the eager half of the
        -- surface would make a tool that only wanted the ECS find a graphics
        -- stack. `headless_spec` proves that property in a fresh process; the
        -- wiring that keeps it true is observable here.
        local tecs = require("tecs")
        local binaryIO = tecs.io
        assert.is_nil(rawget(binaryIO, "filesystem"), "nothing may hold the module before it is asked for")
        assert.are.equal(filesystem.read, tecs.io.filesystem.read)
        assert.is_not_nil(rawget(binaryIO, "filesystem"), "and the resolved namespace is kept, not rebuilt")
    end)

    it("is the module itself, not a table standing in front of it", function()
        -- The path half and the operations are one file under one name, so
        -- the public name needs nothing built for it: `tecs.io.filesystem` is the
        -- table `require` answers with, and everything on it is reached
        -- directly rather than through a proxy that has to restate it.
        local tecs = require("tecs")
        assert.is_true(rawequal(filesystem, tecs.io.filesystem))
    end)

    it("takes a write on the value that reads it back", function()
        -- `organization` is a value a game assigns and `preferencePath` reads
        -- back. Being the module is what makes that plain: the write lands
        -- where the read looks, with nothing in between to route it.
        local tecs = require("tecs")
        local previous = filesystem.organization
        tecs.io.filesystem.organization = "Ex Nihilo"
        assert.are.equal("Ex Nihilo", filesystem.organization)
        assert.are.equal("Ex Nihilo", tecs.io.filesystem.organization)
        tecs.io.filesystem.organization = previous
        assert.are.equal(previous, filesystem.organization)
    end)

    it("does not carry the sibling watcher", function()
        local tecs = require("tecs")
        assert.are.equal(require("tecs.io.watcher"), tecs.io.watcher)
        assert.is_nil(tecs.io.filesystem.watch)
    end)
end)

describe("io.filesystem", function()
    setup(function()
        -- A unique name under the system temporary directory, taken rather
        -- than invented so two runs at once cannot collide. `tmpnam` may leave
        -- a file behind it, so the name is cleared before it becomes a
        -- directory.
        temp = os.tmpname()
        os.remove(temp)
        assert(filesystem.createDirectory(temp))
    end)

    teardown(function()
        removeTree(temp)
        assert.is_false(filesystem.exists(temp), "the spec left files behind")
    end)

    before_each(function()
        for _, entry in ipairs(filesystem.list(temp)) do
            removeTree(at(entry))
        end
        assert.are.same({}, filesystem.list(temp))
    end)

    describe("asking what is there", function()
        it("reports a file's kind, size and modification time", function()
            filesystem.write(at("body.txt"), "twelve bytes")
            local info = filesystem.info(at("body.txt"))
            assert.are.equal("file", info.kind)
            assert.are.equal(12, info.size)
            -- Nanoseconds since the epoch, which is what `watch` reads out of
            -- the same struct. Anything in seconds would be nine orders out.
            assert.is_true(info.modifiedAt > 1.5e18, "modifiedAt is nanoseconds since the epoch")
            assert.is_true(info.accessedAt > 1.5e18)
        end)

        it("reports a directory as one, with no size", function()
            filesystem.createDirectory(at("sub"))
            local info = filesystem.info(at("sub"))
            assert.are.equal("directory", info.kind)
            assert.are.equal(0, info.size)
        end)

        it("answers nil and the reason for a path with nothing at it", function()
            -- Nil rather than an Info whose kind is some "none": there is
            -- nothing to describe, and the reason is the operating system's.
            local info, reason = filesystem.info(at("absent"))
            assert.is_nil(info)
            assert.is_string(reason)
            assert.is_true(#reason > 0, "SDL's error reaches the caller")
        end)

        it("agrees with the size that was written, including an empty file", function()
            filesystem.write(at("empty.bin"), "")
            assert.are.equal(0, filesystem.info(at("empty.bin")).size)
        end)

        it("separates a file from a directory from nothing at all", function()
            filesystem.write(at("one.txt"), "x")
            filesystem.createDirectory(at("dir"))

            assert.is_true(filesystem.exists(at("one.txt")))
            assert.is_true(filesystem.isFile(at("one.txt")))
            assert.is_false(filesystem.isDirectory(at("one.txt")))

            assert.is_true(filesystem.exists(at("dir")))
            assert.is_true(filesystem.isDirectory(at("dir")))
            assert.is_false(filesystem.isFile(at("dir")))

            assert.is_false(filesystem.exists(at("nothing")))
            assert.is_false(filesystem.isFile(at("nothing")))
            assert.is_false(filesystem.isDirectory(at("nothing")))
        end)

        it("follows a symbolic link, and reports a broken one as absent", function()
            -- SDL stats rather than lstats, so a link is never a kind of its
            -- own. Documented rather than worked around, because a caller
            -- resolving links itself would need a call SDL does not offer.
            filesystem.write(at("target.txt"), "pointed at")
            os.execute(("ln -s %q %q"):format(at("target.txt"), at("link.txt")))
            os.execute(("ln -s %q %q"):format(at("nowhere"), at("broken.txt")))

            assert.is_true(filesystem.isFile(at("link.txt")))
            assert.are.equal(10, filesystem.info(at("link.txt")).size)
            assert.is_nil(filesystem.info(at("broken.txt")))
            assert.is_false(filesystem.exists(at("broken.txt")))
        end)
    end)

    describe("enumerating", function()
        local function tree()
            filesystem.createDirectory(at("a/b"))
            filesystem.write(at("top.txt"), "1")
            filesystem.write(at("a/mid.txt"), "2")
            filesystem.write(at("a/b/deep.txt"), "3")
        end

        it("lists one level, as names rather than paths", function()
            tree()
            assert.are.same({ "a", "top.txt" }, sorted(filesystem.list(temp)))
            assert.are.same({ "b", "mid.txt" }, sorted(filesystem.list(at("a"))))
        end)

        it("walks the whole tree when no pattern stops it", function()
            -- The surprise the module leads with. `SDL_GlobDirectory` with a
            -- null pattern is recursive, and answers descendants as paths
            -- relative to the root, joined with '/'.
            tree()
            assert.are.same({
                "a",
                "a/b",
                "a/b/deep.txt",
                "a/mid.txt",
                "top.txt",
            }, sorted(filesystem.glob(temp)))
        end)

        it("confines a wildcard to one level, because it never matches a separator", function()
            tree()
            assert.are.same({ "a", "top.txt" }, sorted(filesystem.glob(temp, "*")))
            assert.are.same({ "top.txt" }, sorted(filesystem.glob(temp, "*.txt")))
            assert.are.same({ "a/mid.txt" }, sorted(filesystem.glob(temp, "*/*.txt")))
            assert.are.same({ "a/b/deep.txt" }, sorted(filesystem.glob(temp, "*/*/*.txt")))
        end)

        it("includes directories beside files, unmarked", function()
            tree()
            local entries = filesystem.glob(temp, "*")
            local kinds = {}
            for _, entry in ipairs(entries) do
                kinds[entry] = filesystem.info(at(entry)).kind
            end
            assert.are.same({ ["a"] = "directory", ["top.txt"] = "file" }, kinds)
        end)

        it("matches without regard to case only when asked", function()
            filesystem.write(at("Mixed.PNG"), "x")
            assert.are.same({}, filesystem.glob(temp, "*.png"))
            assert.are.same({ "Mixed.PNG" }, filesystem.glob(temp, "*.png", { caseInsensitive = true }))
        end)

        it("keeps an empty directory apart from one it could not open", function()
            -- The reason the answer is nil rather than an empty list. A caller
            -- that cannot tell these apart retries forever or gives up wrongly.
            filesystem.createDirectory(at("hollow"))
            assert.are.same({}, filesystem.list(at("hollow")))

            local entries, reason = filesystem.list(at("absent"))
            assert.is_nil(entries)
            assert.is_string(reason)
            assert.is_true(#reason > 0)
        end)

        it("refuses a file, since a file is not a directory", function()
            filesystem.write(at("plain.txt"), "x")
            local entries, reason = filesystem.list(at("plain.txt"))
            assert.is_nil(entries)
            assert.is_true(#reason > 0)
        end)
    end)

    describe("creating and writing", function()
        it("creates missing parents in one call", function()
            assert.is_true(filesystem.createDirectory(at("deep/deeper/deepest")))
            assert.is_true(filesystem.isDirectory(at("deep/deeper")))
            assert.is_true(filesystem.isDirectory(at("deep/deeper/deepest")))
        end)

        it("succeeds on a directory that is already there", function()
            filesystem.createDirectory(at("twice"))
            assert.is_true(filesystem.createDirectory(at("twice")))
        end)

        it("writes bytes rather than text", function()
            -- A NUL in the middle is a byte like any other, which is what
            -- makes this usable for a binary save.
            local blob = "head\0\255\1tail"
            assert.is_true(filesystem.write(at("blob.bin"), blob))
            assert.are.equal(#blob, filesystem.info(at("blob.bin")).size)
            assert.are.equal(blob, filesystem.read(at("blob.bin")))
        end)

        it("pairs with the read beside it", function()
            -- One pair in one module, and the record of what was opened kept
            -- with them, because that record is what `watch` polls.
            local save = at("slot1.json")
            assert.is_true(filesystem.write(save, '{"score":41}'))
            assert.are.equal('{"score":41}', filesystem.read(save))
            assert.are.equal("document", filesystem.loaded()[save], "the read is recorded for the watcher")
        end)

        it("replaces what was there rather than appending", function()
            filesystem.write(at("over.txt"), "the longer original")
            filesystem.write(at("over.txt"), "short")
            assert.are.equal("short", filesystem.read(at("over.txt")))
        end)

        it("does not create the parent it is written into", function()
            local ok, reason = filesystem.write(at("nowhere/x.txt"), "x")
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_false(filesystem.exists(at("nowhere")))
        end)
    end)

    describe("removing", function()
        it("removes a file", function()
            filesystem.write(at("doomed.txt"), "x")
            assert.is_true(filesystem.remove(at("doomed.txt")))
            assert.is_false(filesystem.exists(at("doomed.txt")))
        end)

        it("removes an empty directory and refuses one with anything in it", function()
            filesystem.createDirectory(at("full"))
            filesystem.write(at("full/held.txt"), "x")

            local ok, reason = filesystem.remove(at("full"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_true(filesystem.exists(at("full/held.txt")), "a refused remove takes nothing with it")

            assert.is_true(filesystem.remove(at("full/held.txt")))
            assert.is_true(filesystem.remove(at("full")))
        end)

        it("succeeds when there was nothing to remove", function()
            -- SDL reports that the path is gone, not that this call is what
            -- removed it. Documented rather than turned into a failure,
            -- because turning it into one would be inventing a semantic.
            assert.is_false(filesystem.exists(at("never")))
            assert.is_true(filesystem.remove(at("never")))
        end)
    end)

    describe("renaming and copying", function()
        it("moves a file", function()
            filesystem.write(at("from.txt"), "carried")
            assert.is_true(filesystem.rename(at("from.txt"), at("to.txt")))
            assert.is_false(filesystem.exists(at("from.txt")))
            assert.are.equal("carried", filesystem.read(at("to.txt")))
        end)

        it("overwrites an existing destination without asking", function()
            filesystem.write(at("new.txt"), "new")
            filesystem.write(at("old.txt"), "old")
            assert.is_true(filesystem.rename(at("new.txt"), at("old.txt")))
            assert.are.equal("new", filesystem.read(at("old.txt")))
        end)

        it("moves a directory, contents and all", function()
            filesystem.createDirectory(at("before/inner"))
            filesystem.write(at("before/inner/leaf.txt"), "leaf")
            assert.is_true(filesystem.rename(at("before"), at("after")))
            assert.are.equal("leaf", filesystem.read(at("after/inner/leaf.txt")))
        end)

        it("reports a move of something that is not there", function()
            local ok, reason = filesystem.rename(at("ghost.txt"), at("somewhere.txt"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
        end)

        it("copies a file, leaving the original", function()
            filesystem.write(at("source.txt"), "duplicated")
            assert.is_true(filesystem.copy(at("source.txt"), at("dest.txt")))
            assert.are.equal("duplicated", filesystem.read(at("source.txt")))
            assert.are.equal("duplicated", filesystem.read(at("dest.txt")))
        end)

        it("refuses to copy a directory", function()
            -- SDL_CopyFile is named for what it copies. A recursive copy would
            -- be this module inventing an operation SDL does not have.
            filesystem.createDirectory(at("adir"))
            local ok, reason = filesystem.copy(at("adir"), at("bdir"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_false(filesystem.exists(at("bdir")))
        end)

        it("does not create the destination's parent", function()
            filesystem.write(at("solo.txt"), "x")
            local ok, reason = filesystem.copy(at("solo.txt"), at("gone/solo.txt"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
        end)
    end)

    describe("streaming reads", function()
        it("treats a non-positive count as one byte through SDL", function()
            assert.is_true(filesystem.write(at("stream.txt"), "abcdef"))
            local reader = assert(filesystem.openRead(at("stream.txt")))

            assert.are.equal("a", reader:read(0))
            assert.are.equal("b", reader:read(-8))
            assert.are.equal("cde", reader:read(3))
            assert.are.equal("f", reader:read(3))
            assert.are.equal("", reader:read(3))
            reader:close()
        end)
    end)

    describe("where the process and the user are", function()
        it("answers the working directory with a trailing separator", function()
            local cwd = filesystem.currentDirectory()
            assert.is_string(cwd)
            assert.are.equal("/", cwd:sub(-1), "SDL answers with a trailing separator, as filesystem.basePath does")
            assert.are.equal("/", cwd:sub(1, 1), "and an absolute path")
        end)

        it("answers a well-known folder, or says the platform has none", function()
            -- Both outcomes are correct answers. macOS has no saved-games,
            -- screenshots or templates folder, and SDL says so rather than
            -- inventing one; a caller that assumed a string would index nil.
            local home = filesystem.userFolder("home")
            assert.is_string(home)
            assert.are.equal("/", home:sub(-1))

            for _, which in ipairs({
                "home",
                "desktop",
                "documents",
                "downloads",
                "music",
                "pictures",
                "publicShare",
                "savedGames",
                "screenshots",
                "templates",
                "videos",
            }) do
                local folder, reason = filesystem.userFolder(which)
                if folder == nil then
                    assert.is_true(#reason > 0, which .. " answered nil with no reason")
                else
                    assert.is_true(#folder > 0, which .. " answered an empty path")
                end
            end
        end)

        it("refuses a folder name it does not know", function()
            assert.has_error(function()
                filesystem.userFolder("downloadz")
            end, "tecs: io.filesystem.userFolder does not know 'downloadz'")
        end)
    end)

    describe("arguments", function()
        it("refuses a call with no path", function()
            -- LuaJIT hands a Lua nil to a `const char *` as a null pointer, so
            -- one that reached SDL would be a call against an invalid path
            -- with nothing pointing back at the caller that made it. Checked
            -- once here rather than in a backend, so a port inherits it, and
            -- named after the function the caller actually called.
            local calls = {
                { "info", filesystem.info },
                { "exists", filesystem.exists },
                { "isFile", filesystem.isFile },
                { "isDirectory", filesystem.isDirectory },
                { "list", filesystem.list },
                { "glob", filesystem.glob },
                { "createDirectory", filesystem.createDirectory },
                { "remove", filesystem.remove },
                { "write", filesystem.write },
                { "read", filesystem.read },
            }
            for _, call in ipairs(calls) do
                assert.has_error(function()
                    call[2](nil)
                end, ("tecs: io.filesystem.%s needs a path"):format(call[1]))
            end

            assert.has_error(function()
                filesystem.rename(nil, at("x"))
            end, "tecs: io.filesystem.rename needs a path")
            assert.has_error(function()
                filesystem.rename(at("x"), nil)
            end, "tecs: io.filesystem.rename needs a path")
            assert.has_error(function()
                filesystem.copy(nil, at("x"))
            end, "tecs: io.filesystem.copy needs a path")
            assert.has_error(function()
                filesystem.copy(at("x"), nil)
            end, "tecs: io.filesystem.copy needs a path")
            assert.has_error(function()
                filesystem.write(at("x"), nil)
            end, "tecs: io.filesystem.write needs bytes to write")
        end)
    end)

    describe("what SDL allocated", function()
        -- Each loop below leaks well over this threshold if its free is
        -- dropped, and costs a small fraction of it when the free is there, so
        -- neither count needs tuning. The two differ because a leaked entry
        -- list is kilobytes and a leaked path is a hundred bytes.
        local ALLOWED_GROWTH = 32 * 1024 * 1024
        local GLOBS = 40000
        local PATHS = 400000

        it("frees the entry list, which is one allocation and not one per entry", function()
            -- SDL puts the array and every string it points at in a single
            -- block, exactly as it does for the clipboard's mime list, so one
            -- free releases all of it and freeing an entry would be a double
            -- free.
            filesystem.createDirectory(at("many"))
            for index = 1, 64 do
                filesystem.write(at(("many/entry-%02d-%s.txt"):format(index, ("p"):rep(24))), "x")
            end

            local before = settled()
            for _ = 1, GLOBS do
                filesystem.list(at("many"))
            end
            local grew = settled() - before
            assert.is_true(
                grew < ALLOWED_GROWTH,
                ("listing 64 entries %d times grew the process by %.0f MB"):format(GLOBS, grew / 1048576)
            )
        end)

        it("frees the working directory, which SDL hands over rather than lends", function()
            -- `SDL_GetCurrentDirectory` returns `char *` and the caller frees
            -- it, while `SDL_GetUserFolder` returns `const char *` that
            -- belongs to SDL. Freeing the second would be a crash rather than
            -- a leak, so both halves of the rule are walked here together.
            local before = settled()
            for _ = 1, PATHS do
                filesystem.currentDirectory()
                filesystem.userFolder("home")
            end
            local grew = settled() - before
            assert.is_true(
                grew < ALLOWED_GROWTH,
                ("reading the working directory %d times grew the process by %.0f MB"):format(PATHS, grew / 1048576)
            )
        end)
    end)

    describe("off the main thread", function()
        it("walks a tree on a worker and answers with data", function()
            -- The escape hatch the module offers instead of an asynchronous
            -- API: every function takes a path and returns a value, so nothing
            -- crosses a thread that must not, and a walk that would block a
            -- frame runs somewhere else. Asserted rather than claimed.
            filesystem.createDirectory(at("wide/inner"))
            for index = 1, 8 do
                filesystem.write(at("wide/file" .. index .. ".txt"), "x")
                filesystem.write(at("wide/inner/file" .. index .. ".txt"), "x")
            end

            local worker = workers.spawn({
                source = [==[
                    local workers = require("tecs.workers")
                    local filesystem = require("tecs.io.filesystem")
                    local self = workers.current()
                    local job = self:receive(5000)
                    local entries = filesystem.glob(job.root)
                    self:send({ count = #entries })
                ]==],
                luaPath = package.path,
            })
            worker:send({ root = at("wide") })
            local reply = worker:receive(5000)
            worker:stop()

            assert.is_not_nil(reply, "the worker answered")
            -- The directory, sixteen files, and nothing else.
            assert.are.equal(17, reply.count)
        end)
    end)
end)

-- The whole suite shares one SDL, so this block cannot assume video is down; it
-- takes it down and puts the count back, exactly as `clipboard_spec` does.
describe("platform.filesystem with no video", function()
    local held = 0
    local base

    setup(function()
        for _ = 1, 8 do
            if C.SDL_WasInit(sdl.K.SDL_INIT_VIDEO) == 0 then
                break
            end
            C.SDL_QuitSubSystem(sdl.K.SDL_INIT_VIDEO)
            held = held + 1
        end
        base = os.tmpname()
        os.remove(base)
    end)

    teardown(function()
        removeTree(base)
        for _ = 1, held do
            assert(C.SDL_InitSubSystem(sdl.K.SDL_INIT_VIDEO))
        end
    end)

    it("does every one of its jobs with no video initialized", function()
        -- This is one of the few subsystems that is more useful without a
        -- window than with one, so it has no `available()` and no gate: with
        -- nothing initialized it answers for real rather than answering empty.
        assert.are.equal(0, tonumber(C.SDL_WasInit(sdl.K.SDL_INIT_VIDEO)))

        assert.is_true(filesystem.createDirectory(base .. "/nested/deeper"))
        assert.is_true(filesystem.write(base .. "/nested/one.txt", "headless"))
        assert.is_true(filesystem.copy(base .. "/nested/one.txt", base .. "/nested/two.txt"))
        assert.is_true(filesystem.rename(base .. "/nested/two.txt", base .. "/nested/three.txt"))

        assert.are.same({ "deeper", "one.txt", "three.txt" }, sorted(filesystem.list(base .. "/nested")))
        assert.are.equal(8, filesystem.info(base .. "/nested/one.txt").size)
        assert.is_true(filesystem.isDirectory(base .. "/nested/deeper"))
        assert.is_string(filesystem.currentDirectory())
        assert.is_string(filesystem.userFolder("home"))

        assert.is_true(filesystem.remove(base .. "/nested/three.txt"))
        assert.is_false(filesystem.exists(base .. "/nested/three.txt"))
    end)

    it("initializes no subsystem of its own", function()
        -- A gate that brought video up to answer a question about a path would
        -- make a headless tool open a display server. Nothing here calls
        -- SDL_Init, so the mask is the same on both sides of a full sweep.
        local before = tonumber(C.SDL_WasInit(0))

        filesystem.createDirectory(base .. "/sweep")
        filesystem.write(base .. "/sweep/x.txt", "x")
        filesystem.info(base .. "/sweep/x.txt")
        filesystem.exists(base .. "/sweep")
        filesystem.isFile(base .. "/sweep/x.txt")
        filesystem.isDirectory(base .. "/sweep")
        filesystem.list(base .. "/sweep")
        filesystem.glob(base .. "/sweep")
        filesystem.copy(base .. "/sweep/x.txt", base .. "/sweep/y.txt")
        filesystem.rename(base .. "/sweep/y.txt", base .. "/sweep/z.txt")
        filesystem.remove(base .. "/sweep/z.txt")
        filesystem.currentDirectory()
        filesystem.userFolder("home")

        assert.are.equal(before, tonumber(C.SDL_WasInit(0)))
    end)
end)

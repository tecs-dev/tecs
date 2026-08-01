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
local tecsIO = require("tecs.io")
local files = require("tecs.io.files")
local buffer = require("tecs.io.buffer")
local content = require("tecs.platform.content")
local adapter = require("tecs.platform.adapter")
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

--- Collects the relative paths from a glob when a test needs an eager comparison.
local function globPaths(path, pattern, options)
    local stream, reason = files.glob(path, pattern, options)
    if stream == nil then
        return nil, reason
    end
    local found
    found, reason = stream:toArray()
    if found == nil then
        return nil, reason
    end
    local entries = {}
    for _, entry in ipairs(found) do
        entries[#entries + 1] = assert(entry.path:relativeTo(path)):toString()
    end
    return entries
end

--- Empties and removes a tree, deepest entry first.
---
--- The composition the module documents rather than providing: a recursive
--- glob answers every descendant, longest paths are deepest, and `remove`
--- takes an empty directory once its contents are gone. A path that is not a
--- directory globs as nil and is simply removed.
local function removeTree(path)
    local entries = globPaths(path)
    if entries ~= nil then
        table.sort(entries, function(a, b)
            return #a > #b
        end)
        for _, entry in ipairs(entries) do
            files.remove(path .. "/" .. entry)
        end
    end
    files.remove(path)
end

--- A path inside the temporary directory.
local function at(relative)
    return temp .. "/" .. relative
end

describe("io.files on the public surface", function()
    it("resolves by name rather than being held", function()
        -- The module reaches SDL, so holding it on the eager half of the
        -- surface would make a tool that only wanted the ECS find a graphics
        -- stack. `headless_spec` proves that property in a fresh process; the
        -- wiring that keeps it true is observable here.
        local tecs = require("tecs")
        local tecsIO = tecs.io
        assert.is_nil(rawget(tecsIO, "files"), "nothing may hold the module before it is asked for")
        assert.are.equal(files.read, tecs.io.files.read)
        assert.is_not_nil(rawget(tecsIO, "files"), "and the resolved namespace is kept, not rebuilt")
    end)

    it("is the module itself, not a table standing in front of it", function()
        -- The path half and the operations are one file under one name, so
        -- the public name needs nothing built for it: `tecs.io.files` is the
        -- table `require` answers with, and everything on it is reached
        -- directly rather than through a proxy that has to restate it.
        local tecs = require("tecs")
        assert.is_true(rawequal(files, tecs.io.files))
    end)

    it("configures the preference identity through the public module", function()
        local tecs = require("tecs")
        local previousOrganization, previousApplication = tecs.io.files.preferenceIdentity()
        tecs.io.files.setPreferenceIdentity("Ex Nihilo", "Starfarer")
        assert.are.same({ "Ex Nihilo", "Starfarer" }, { tecs.io.files.preferenceIdentity() })
        local configured = tecs.io.files.preferencePath()
        assert.are.equal(files.preferencePath(), configured)
        assert.are.equal(files.cachePath, tecs.io.files.cachePath)
        tecs.io.files.setPreferenceIdentity(previousOrganization, previousApplication)
        assert.are_not.equal(configured, files.preferencePath())
        assert.is_nil(tecs.io.files.organization)
        assert.is_nil(tecs.io.files.application)
    end)

    it("rejects an empty preference identity", function()
        assert.has_error(function()
            files.setPreferenceIdentity("", "Starfarer")
        end)
        assert.has_error(function()
            files.setPreferenceIdentity("Ex Nihilo", "")
        end)
    end)

    it("does not carry the sibling watcher", function()
        local tecs = require("tecs")
        assert.are.equal(require("tecs.io.watcher"), tecs.io.watcher)
        assert.is_nil(tecs.io.files.watch)
    end)
end)

describe("io.files", function()
    setup(function()
        -- A unique name under the system temporary directory, taken rather
        -- than invented so two runs at once cannot collide. `tmpnam` may leave
        -- a file behind it, so the name is cleared before it becomes a
        -- directory.
        temp = os.tmpname()
        os.remove(temp)
        assert(files.createDirectory(temp))
    end)

    teardown(function()
        removeTree(temp)
        assert.is_false(files.exists(temp), "the spec left files behind")
    end)

    before_each(function()
        for _, entry in ipairs(globPaths(temp, "*")) do
            removeTree(at(entry))
        end
        assert.are.same({}, globPaths(temp, "*"))
    end)

    describe("asking what is there", function()
        it("reports a file's kind, size and modification time", function()
            files.write(at("body.txt"), "twelve bytes")
            local info = files.info(at("body.txt"))
            assert.are.equal("file", info.kind)
            assert.are.equal(12, info.size)
            -- Nanoseconds since the epoch, which is what `watch` reads out of
            -- the same struct. Anything in seconds would be nine orders out.
            assert.is_true(info.modifiedAt > 1.5e18, "modifiedAt is nanoseconds since the epoch")
            assert.is_true(info.accessedAt > 1.5e18)
        end)

        it("reports a directory as one, with no size", function()
            files.createDirectory(at("sub"))
            local info = files.info(at("sub"))
            assert.are.equal("directory", info.kind)
            assert.are.equal(0, info.size)
        end)

        it("answers nil and the reason for a path with nothing at it", function()
            -- Nil rather than an Info whose kind is some "none": there is
            -- nothing to describe, and the reason is the operating system's.
            local info, reason = files.info(at("absent"))
            assert.is_nil(info)
            assert.is_string(reason)
            assert.is_true(#reason > 0, "SDL's error reaches the caller")
        end)

        it("agrees with the size that was written, including an empty file", function()
            files.write(at("empty.bin"), "")
            assert.are.equal(0, files.info(at("empty.bin")).size)
        end)

        it("separates a file from a directory from nothing at all", function()
            files.write(at("one.txt"), "x")
            files.createDirectory(at("dir"))

            assert.is_true(files.exists(at("one.txt")))
            assert.is_true(files.isFile(at("one.txt")))
            assert.is_false(files.isDirectory(at("one.txt")))

            assert.is_true(files.exists(at("dir")))
            assert.is_true(files.isDirectory(at("dir")))
            assert.is_false(files.isFile(at("dir")))

            assert.is_false(files.exists(at("nothing")))
            assert.is_false(files.isFile(at("nothing")))
            assert.is_false(files.isDirectory(at("nothing")))
        end)

        it("inspects a link itself while ordinary metadata follows it", function()
            -- SDL stats rather than lstats, while the Rust path operation asks
            -- about the final object itself. The two answers are deliberately
            -- different and a broken link remains a link.
            files.write(at("target.txt"), "pointed at")
            os.execute(("ln -s %q %q"):format(at("target.txt"), at("link.txt")))
            os.execute(("ln -s %q %q"):format(at("nowhere"), at("broken.txt")))

            assert.is_false(files.isSymlink(at("target.txt")))
            assert.is_true(files.isSymlink(at("link.txt")))
            assert.is_true(files.isSymlink(at("broken.txt")))
            assert.is_false(files.isSymlink(at("nothing")))
            assert.is_true(files.isFile(at("link.txt")))
            assert.are.equal(10, files.info(at("link.txt")).size)
            assert.is_nil(files.info(at("broken.txt")))
            assert.is_false(files.exists(at("broken.txt")))
        end)

        it("follows links in parents when inspecting the final path", function()
            files.createDirectory(at("real"))
            files.write(at("real/inside.txt"), "inside")
            os.execute(("ln -s %q %q"):format(at("real"), at("linked")))

            assert.is_true(files.isSymlink(at("linked")))
            assert.is_false(files.isSymlink(at("linked/inside.txt")))
        end)

        it("creates and reads file and directory symbolic links", function()
            files.write(at("target.txt"), "target")
            files.createDirectory(at("target-dir"))

            assert.is_true(files.createSymlink("target.txt", at("file-link"), "file"))
            assert.is_true(files.createSymlink("target-dir", at("dir-link"), "directory"))
            assert.are.equal("target.txt", files.readLink(at("file-link")):toString())
            assert.are.equal("target-dir", files.readLink(at("dir-link")):toString())
            assert.is_true(files.isFile(at("file-link")))
            assert.is_true(files.isDirectory(at("dir-link")))
        end)

        it("reports and changes the portable read-only state", function()
            local path = at("permissions.txt")
            files.write(path, "kept")
            assert.is_false(files.info(path).readOnly)
            assert.is_true(files.setReadOnly(path, true))
            assert.is_true(files.info(path).readOnly)
            assert.is_true(files.setReadOnly(path, false))
            assert.is_false(files.info(path).readOnly)
        end)
    end)

    describe("enumerating", function()
        local function tree()
            files.createDirectory(at("a/b"))
            files.write(at("top.txt"), "1")
            files.write(at("a/mid.txt"), "2")
            files.write(at("a/b/deep.txt"), "3")
        end

        it("collects one level from the same stream", function()
            tree()
            assert.are.same({ "a", "top.txt" }, sorted(globPaths(temp, "*")))
            assert.are.same({ "b", "mid.txt" }, sorted(globPaths(at("a"), "*")))
        end)

        it("walks the whole tree when no pattern stops it", function()
            -- Nil leaves the public stream unconstrained, so it recursively
            -- answers every descendant relative to the requested root.
            tree()
            assert.are.same({
                "a",
                "a/b",
                "a/b/deep.txt",
                "a/mid.txt",
                "top.txt",
            }, sorted(globPaths(temp)))
        end)

        it("limits recursive traversal depth without another constructor", function()
            tree()
            assert.are.same({}, globPaths(temp, nil, { maxDepth = 0 }))
            assert.are.same({ "a", "top.txt" }, sorted(globPaths(temp, nil, { maxDepth = 1 })))
            assert.are.same({
                "a",
                "a/b",
                "a/mid.txt",
                "top.txt",
            }, sorted(globPaths(temp, nil, { maxDepth = 2 })))
        end)

        it("confines a wildcard to one level, because it never matches a separator", function()
            tree()
            assert.are.same({ "a", "top.txt" }, sorted(globPaths(temp, "*")))
            assert.are.same({ "top.txt" }, sorted(globPaths(temp, "*.txt")))
            assert.are.same({ "a/mid.txt" }, sorted(globPaths(temp, "*/*.txt")))
            assert.are.same({ "a/b/deep.txt" }, sorted(globPaths(temp, "*/*/*.txt")))
        end)

        it("includes directories beside files with their kinds", function()
            tree()
            local stream = assert(files.glob(temp, "*"))
            local kinds = {}
            while true do
                local entry = stream:next()
                if entry == nil then
                    break
                end
                kinds[entry.name] = entry.kind
            end
            assert.are.same({ ["a"] = "directory", ["top.txt"] = "file" }, kinds)
        end)

        it("matches without regard to case only when asked", function()
            files.write(at("Mixed.PNG"), "x")
            assert.are.same({}, globPaths(temp, "*.png"))
            assert.are.same({ "Mixed.PNG" }, globPaths(temp, "*.png", { caseInsensitive = true }))
        end)

        it("matches one UTF-8 codepoint with a question mark", function()
            files.write(at("café.txt"), "x")
            assert.are.same({ "café.txt" }, globPaths(temp, "caf?.txt"))
        end)

        it("keeps an empty directory apart from one it could not open", function()
            -- The reason the answer is nil rather than an empty list. A caller
            -- that cannot tell these apart retries forever or gives up wrongly.
            files.createDirectory(at("hollow"))
            assert.are.same({}, globPaths(at("hollow"), "*"))

            local entries, reason = files.glob(at("absent"), "*")
            assert.is_nil(entries)
            assert.is_string(reason)
            assert.is_true(#reason > 0)
        end)

        it("refuses a file, since a file is not a directory", function()
            files.write(at("plain.txt"), "x")
            local entries, reason = files.glob(at("plain.txt"), "*")
            assert.is_nil(entries)
            assert.is_true(#reason > 0)
        end)

        it("streams one directory and closes idempotently", function()
            tree()
            local stream = assert(files.glob(temp, "*"))
            local entries = {}
            while true do
                local entry, reason = stream:next()
                assert.is_nil(reason)
                if entry == nil then
                    break
                end
                entries[#entries + 1] = entry.name
                assert.are.equal(1, entry.depth)
            end
            assert.are.same({ "a", "top.txt" }, sorted(entries))
            stream:close()
            assert.is_nil(stream:next())
        end)

        it("collects only the entries remaining in a stream", function()
            tree()
            local stream = assert(files.glob(temp, "*"))
            assert.is_not_nil(stream:next())
            local remaining = assert(stream:toArray())
            assert.are.equal(1, #remaining)
            assert.is_nil(stream:next())
        end)

        it("walks depth first without following symbolic links", function()
            tree()
            assert.is_true(files.createSymlink("a", at("linked-a"), "directory"))
            local stream = assert(files.glob(temp))
            local entries = {}
            while true do
                local entry, reason = stream:next()
                assert.is_nil(reason)
                if entry == nil then
                    break
                end
                local relative = entry.path:relativeTo(temp):toString()
                entries[relative] = { depth = entry.depth, symlink = entry.symlink }
            end
            assert.are.same({ depth = 3, symlink = false }, entries["a/b/deep.txt"])
            assert.are.same({ depth = 1, symlink = true }, entries["linked-a"])
            assert.is_nil(entries["linked-a/mid.txt"])
        end)

        it("prunes the directory returned by the preceding next call", function()
            tree()
            local stream = assert(files.glob(temp))
            local paths = {}
            while true do
                local entry = stream:next()
                if entry == nil then
                    break
                end
                local relative = assert(entry.path:relativeTo(temp)):toString()
                paths[#paths + 1] = relative
                if relative == "a" then
                    assert.is_true(stream:skipDirectory())
                    assert.is_false(stream:skipDirectory())
                else
                    assert.is_false(stream:skipDirectory())
                end
            end
            assert.are.same({ "a", "top.txt" }, sorted(paths))
        end)
    end)

    describe("creating and writing", function()
        it("creates missing parents in one call", function()
            assert.is_true(files.createDirectory(at("deep/deeper/deepest")))
            assert.is_true(files.isDirectory(at("deep/deeper")))
            assert.is_true(files.isDirectory(at("deep/deeper/deepest")))
        end)

        it("succeeds on a directory that is already there", function()
            files.createDirectory(at("twice"))
            assert.is_true(files.createDirectory(at("twice")))
        end)

        it("writes bytes rather than text", function()
            -- A NUL in the middle is a byte like any other, which is what
            -- makes this usable for a binary save.
            local blob = "head\0\255\1tail"
            assert.is_true(files.write(at("blob.bin"), blob))
            assert.are.equal(#blob, files.info(at("blob.bin")).size)
            assert.are.equal(blob, files.read(at("blob.bin")))
        end)

        it("atomically creates and replaces complete binary contents", function()
            local path = at("atomic.bin")
            assert.is_true(files.writeAtomic(path, "first\0value"))
            assert.are.equal("first\0value", files.read(path))

            assert.is_true(files.writeAtomic(path, "short"))
            assert.are.equal("short", files.read(path))
        end)

        it("borrows buffers and views without a string conversion", function()
            local source = buffer.new("buffer contents")
            local view = source:view(7)

            assert.is_true(files.writeAtomic(at("buffer.bin"), source))
            assert.are.equal("buffer contents", files.read(at("buffer.bin")))
            assert.is_true(files.writeAtomic(at("view.bin"), view))
            assert.are.equal("contents", files.read(at("view.bin")))

            view:close()
            source:close()
        end)

        it("atomically writes copied bytes on a worker", function()
            local source = buffer.new("before")
            local future = files.writeAtomicAsync(at("async.bin"), source)
            source:setString("after")
            source:close()

            future:wait(5000)
            assert.are.equal("ready", future.status)
            assert.is_true(future.value)
            assert.are.equal("before", files.read(at("async.bin")))
        end)

        it("settles an asynchronous write failure as failed", function()
            files.createDirectory(at("async-occupied"))
            local future = files.writeAtomicAsync(at("async-occupied"), "replacement")
            future:wait(5000)
            assert.are.equal("failed", future.status)
            assert.is_string(future.error)
            assert.is_true(#future.error > 0)
        end)

        it("leaves no temporary file when atomic replacement fails", function()
            local destination = at("occupied")
            assert.is_true(files.createDirectory(destination))
            assert.is_true(files.write(destination .. "/kept", "original"))

            local ok, reason = files.writeAtomic(destination, "replacement")
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.are.equal("original", files.read(destination .. "/kept"))
            assert.are.same({ "occupied", "occupied/kept" }, sorted(globPaths(temp)))
        end)

        it("pairs with the read beside it", function()
            -- One pair in one module, and the record of what was opened kept
            -- with them, because that record is what `watch` polls.
            local save = at("slot1.json")
            assert.is_true(files.write(save, '{"score":41}'))
            assert.are.equal('{"score":41}', files.read(save))
            assert.are.equal("document", content.loaded()[save], "the read is recorded for the watcher")
        end)

        it("replaces what was there rather than appending", function()
            files.write(at("over.txt"), "the longer original")
            files.write(at("over.txt"), "short")
            assert.are.equal("short", files.read(at("over.txt")))
        end)

        it("appends binary bytes and creates an absent file", function()
            local path = at("journal.bin")
            assert.is_true(files.append(path, "first\0"))
            assert.is_true(files.append(path, "\255last"))
            assert.are.equal("first\0\255last", files.read(path))

            assert.is_true(files.append(at("empty.bin"), ""))
            assert.are.equal(0, files.info(at("empty.bin")).size)
        end)

        it("does not create the parent it is written into", function()
            local ok, reason = files.write(at("nowhere/x.txt"), "x")
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_false(files.exists(at("nowhere")))

            ok, reason = files.append(at("still-nowhere/x.txt"), "x")
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_false(files.exists(at("still-nowhere")))
        end)
    end)

    describe("temporary resources", function()
        it("removes a temporary file when its scope ends", function()
            local path
            require("tecs").scoped(function(scope)
                local temporary = scope:own(files.createTemporaryFile({
                    directory = temp,
                    prefix = "save-",
                    suffix = ".tmp",
                }))
                path = temporary.path:toString()
                assert.is_true(files.isFile(path))
                assert.is_true(files.write(path, "draft"))
            end)
            assert.is_false(files.exists(path))
        end)

        it("recursively removes a temporary directory", function()
            local temporary = assert(files.createTemporaryDirectory({ directory = temp }))
            local path = temporary.path:toString()
            assert.is_true(files.createDirectory(path .. "/nested"))
            assert.is_true(files.write(path .. "/nested/file", "content"))
            assert.is_true(temporary:close())
            assert.is_false(files.exists(path))
            assert.is_true(temporary:close())
        end)

        it("persists a temporary resource to an absent destination", function()
            local temporary = assert(files.createTemporaryFile({ directory = temp }))
            assert.is_true(files.write(temporary.path, "complete"))
            assert.is_true(temporary:persist(at("kept.bin")))
            assert.are.equal("complete", files.read(at("kept.bin")))
            assert.is_true(temporary:close())
        end)
    end)

    describe("reading documents", function()
        it("iterates LF and CRLF lines without retaining an open file", function()
            local path = at("lines.txt")
            files.write(path, "first\r\nsecond\n\nlast\n")
            local nextLine = assert(files.lines(path))
            local found = {}
            for line in nextLine do
                found[#found + 1] = line
            end

            assert.are.same({ "first", "second", "", "last" }, found)
            assert.are.equal("document", content.loaded()[path])
        end)

        it("distinguishes an empty file from one empty line", function()
            files.write(at("empty.txt"), "")
            assert.is_nil(assert(files.lines(at("empty.txt")))())

            files.write(at("one-empty-line.txt"), "\n")
            local nextLine = assert(files.lines(at("one-empty-line.txt")))
            assert.are.equal("", nextLine())
            assert.is_nil(nextLine())
        end)

        it("reports a file it cannot read before returning an iterator", function()
            local nextLine, reason = files.lines(at("missing.txt"))
            assert.is_nil(nextLine)
            assert.is_true(reason:find(at("missing.txt"), 1, true) ~= nil)
        end)

        it("compiles through the watched read and installs an environment", function()
            local path = at("script.lua")
            files.write(path, "calls = (calls or 0) + 1\nreturn answer + ...")
            local environment = { answer = 40 }
            local chunk, reason = files.load(path, environment)

            assert.is_function(chunk)
            assert.is_nil(reason)
            assert.is_nil(environment.calls, "compiling the chunk ran it")
            assert.are.equal(42, chunk(2))
            assert.are.equal(1, environment.calls)
            assert.are.equal("document", content.loaded()[path])
        end)

        it("attributes compiler errors to the file and reports missing input", function()
            local path = at("broken.lua")
            files.write(path, "local =")
            local chunk, reason = files.load(path)
            assert.is_nil(chunk)
            assert.is_true(reason:find(path, 1, true) ~= nil)

            chunk, reason = files.load(at("missing.lua"))
            assert.is_nil(chunk)
            assert.is_true(reason:find(at("missing.lua"), 1, true) ~= nil)
        end)
    end)

    describe("removing", function()
        it("removes a file", function()
            files.write(at("doomed.txt"), "x")
            assert.is_true(files.remove(at("doomed.txt")))
            assert.is_false(files.exists(at("doomed.txt")))
        end)

        it("removes an empty directory and refuses one with anything in it", function()
            files.createDirectory(at("full"))
            files.write(at("full/held.txt"), "x")

            local ok, reason = files.remove(at("full"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_true(files.exists(at("full/held.txt")), "a refused remove takes nothing with it")

            assert.is_true(files.remove(at("full/held.txt")))
            assert.is_true(files.remove(at("full")))
        end)

        it("succeeds when there was nothing to remove", function()
            -- SDL reports that the path is gone, not that this call is what
            -- removed it. Documented rather than turned into a failure,
            -- because turning it into one would be inventing a semantic.
            assert.is_false(files.exists(at("never")))
            assert.is_true(files.remove(at("never")))
        end)
    end)

    describe("renaming and copying", function()
        it("moves a file", function()
            files.write(at("from.txt"), "carried")
            assert.is_true(files.rename(at("from.txt"), at("to.txt")))
            assert.is_false(files.exists(at("from.txt")))
            assert.are.equal("carried", files.read(at("to.txt")))
        end)

        it("overwrites an existing destination without asking", function()
            files.write(at("new.txt"), "new")
            files.write(at("old.txt"), "old")
            assert.is_true(files.rename(at("new.txt"), at("old.txt")))
            assert.are.equal("new", files.read(at("old.txt")))
        end)

        it("moves a directory, contents and all", function()
            files.createDirectory(at("before/inner"))
            files.write(at("before/inner/leaf.txt"), "leaf")
            assert.is_true(files.rename(at("before"), at("after")))
            assert.are.equal("leaf", files.read(at("after/inner/leaf.txt")))
        end)

        it("reports a move of something that is not there", function()
            local ok, reason = files.rename(at("ghost.txt"), at("somewhere.txt"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
        end)

        it("copies a file, leaving the original", function()
            files.write(at("source.txt"), "duplicated")
            assert.is_true(files.copy(at("source.txt"), at("dest.txt")))
            assert.are.equal("duplicated", files.read(at("source.txt")))
            assert.are.equal("duplicated", files.read(at("dest.txt")))
        end)

        it("refuses to copy a directory", function()
            -- SDL_CopyFile is named for what it copies. A recursive copy would
            -- be this module inventing an operation SDL does not have.
            files.createDirectory(at("adir"))
            local ok, reason = files.copy(at("adir"), at("bdir"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
            assert.is_false(files.exists(at("bdir")))
        end)

        it("does not create the destination's parent", function()
            files.write(at("solo.txt"), "x")
            local ok, reason = files.copy(at("solo.txt"), at("gone/solo.txt"))
            assert.is_false(ok)
            assert.is_true(#reason > 0)
        end)
    end)

    describe("streaming reads", function()
        it("treats a non-positive count as one byte through SDL", function()
            assert.is_true(files.write(at("stream.txt"), "abcdef"))
            local reader = assert(files.openRead(at("stream.txt")))

            assert.are.equal("a", reader:read(0))
            assert.are.equal("b", reader:read(-8))
            assert.are.equal("cde", reader:read(3))
            assert.are.equal("f", reader:read(3))
            assert.are.equal("", reader:read(3))
            reader:close()
        end)

        it("reports and repositions the file cursor from every origin", function()
            assert.is_true(files.write(at("seek.bin"), "0123456789"))
            local reader = assert(files.openRead(at("seek.bin")))

            assert.are.equal(10, reader:size())
            assert.are.equal(0, reader:tell())
            assert.are.equal(4, reader:seek("start", 4))
            assert.are.equal("45", reader:read(2))
            assert.are.equal(4, reader:seek("current", -2))
            assert.are.equal("456", reader:read(3))
            assert.are.equal(8, reader:seek("end", -2))
            assert.are.equal("89", reader:read(8))
            assert.are.equal(10, reader:tell())

            reader:close()
        end)

        it("allows the EOF position and rejects positions outside the file", function()
            assert.is_true(files.write(at("bounds.bin"), "abcd"))
            local reader = assert(files.openRead(at("bounds.bin")))

            assert.are.equal(4, reader:seek("end"))
            assert.are.equal("", reader:read(1))
            assert.are.equal(4, reader:tell())
            local position, reason = reader:seek("start", 9)

            assert.is_nil(position)
            assert.is_string(reason)
            assert.is_true(#reason > 0)
            assert.are.equal(4, reader:tell())

            position, reason = reader:seek("current", -5)
            assert.is_nil(position)
            assert.is_string(reason)
            assert.are.equal(4, reader:tell())

            reader:close()
        end)

        it("reads directly into a buffer at a caller-selected offset", function()
            assert.is_true(files.write(at("direct.bin"), "abcdefgh"))
            local reader = assert(files.openRead(at("direct.bin")))
            local destination = tecsIO.newBuffer("prefix")

            assert.are.equal(3, reader:seek("start", 3))
            assert.are.equal(4, reader:readInto(destination, 6, 4))
            assert.are.equal("prefixdefg", destination:getString())
            assert.are.equal(7, reader:tell())

            destination:close()
            reader:close()
        end)

        it("raises for invalid seeks and closes idempotently", function()
            assert.is_true(files.write(at("closed.bin"), "abc"))
            local reader = assert(files.openRead(at("closed.bin")))

            assert.has_error(function()
                reader:seek("middle", 0)
            end, "tecs: SeekableReader:seek origin must be 'start', 'current', or 'end'")
            assert.has_error(function()
                reader:seek("start", 0.5)
            end, "tecs: SeekableReader:seek offset must be an integer")

            reader:close()
            reader:close()
            local bytes, readReason = reader:read(1)
            local size, sizeReason = reader:size()
            local position, seekReason = reader:seek("start")

            assert.is_nil(bytes)
            assert.are.equal("the reader is closed", readReason)
            assert.is_nil(size)
            assert.are.equal("the reader is closed", sizeReason)
            assert.is_nil(position)
            assert.are.equal("the reader is closed", seekReason)
        end)
    end)

    describe("streaming writes", function()
        it("replaces by default and appends when requested", function()
            local path = at("stream-write.txt")
            assert.is_true(files.write(path, "existing"))
            local replacement = assert(files.openWrite(path))

            assert.is_true(replacement:write("replacement"))
            assert.is_true(replacement:close())
            assert.are.equal("replacement", files.read(path))

            local append = assert(files.openWrite(path, "append"))

            assert.is_true(append:write(" one"))
            assert.is_true(append:flush())
            assert.is_true(append:write(" two"))
            assert.is_true(append:close())
            assert.are.equal("replacement one two", files.read(path))
        end)

        it("rejects an unknown write mode", function()
            assert.has_error(function()
                files.openWrite(at("mode.txt"), "unknown")
            end, "tecs: io.files.openWrite mode must be 'replace' or 'append'")
        end)

        it("patches a replacement file through a seekable writer", function()
            local path = at("seek-write.bin")
            local writer = assert(files.openSeekableWrite(path))

            assert.are.equal(0, writer:size())
            assert.are.equal(0, writer:tell())
            assert.is_true(writer:write("HEADpayload"))
            assert.are.equal(11, writer:size())
            assert.are.equal(11, writer:tell())
            assert.are.equal(0, writer:seek("start"))
            assert.is_true(writer:write("PACK"))
            assert.are.equal(7, writer:seek("end", -4))
            assert.is_true(writer:write("data"))

            assert.is_true(writer:close())

            assert.are.equal("PACKpaydata", files.read(path))
        end)

        it("updates an existing file without truncating it", function()
            local path = at("seek-update.bin")
            assert.is_true(files.write(path, "0123456789"))
            local writer = assert(files.openSeekableWrite(path, "update"))

            assert.are.equal(10, writer:size())
            assert.are.equal(4, writer:seek("start", 4))
            assert.is_true(writer:write("AB"))
            assert.are.equal(6, writer:tell())

            assert.is_true(writer:close())

            assert.are.equal("0123AB6789", files.read(path))
        end)

        it("keeps seekable writes inside the current destination", function()
            local writer = assert(files.openSeekableWrite(at("seek-bounds.bin")))
            assert.is_true(writer:write("abcd"))

            local position, reason = writer:seek("start", 5)

            assert.is_nil(position)
            assert.is_string(reason)
            assert.are.equal(4, writer:tell())
            assert.has_error(function()
                writer:seek("middle", 0)
            end, "tecs: SeekableWriter:seek origin must be 'start', 'current', or 'end'")
            assert.has_error(function()
                writer:seek("start", 0.5)
            end, "tecs: SeekableWriter:seek offset must be an integer")

            assert.is_true(writer:close())
            assert.is_true(writer:close())

            position, reason = writer:seek("start")
            assert.is_nil(position)
            assert.are.equal("the writer is closed", reason)
        end)

        it("rejects an unknown seekable write mode", function()
            assert.has_error(function()
                files.openSeekableWrite(at("seek-mode.txt"), "append")
            end, "tecs: io.files.openSeekableWrite mode must be 'replace' or 'update'")
        end)
    end)

    describe("where the process and the user are", function()
        it("answers the working directory with a trailing separator", function()
            local cwd = files.currentDirectory()
            assert.is_string(cwd)
            assert.are.equal("/", cwd:sub(-1), "SDL answers with a trailing separator, as files.basePath does")
            assert.are.equal("/", cwd:sub(1, 1), "and an absolute path")
        end)

        it("answers a well-known folder, or says the platform has none", function()
            -- Both outcomes are correct answers. macOS has no saved-games,
            -- screenshots or templates folder, and SDL says so rather than
            -- inventing one; a caller that assumed a string would index nil.
            local home = files.userFolder("home")
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
                local folder, reason = files.userFolder(which)
                if folder == nil then
                    assert.is_true(#reason > 0, which .. " answered nil with no reason")
                else
                    assert.is_true(#folder > 0, which .. " answered an empty path")
                end
            end
        end)

        it("refuses a folder name it does not know", function()
            assert.has_error(function()
                files.userFolder("downloadz")
            end, "tecs: io.files.userFolder does not know 'downloadz'")
        end)
    end)

    describe("arguments", function()
        it("refuses an invalid glob depth before enumeration", function()
            for _, maxDepth in ipairs({ -1, 1.5, "one" }) do
                assert.has_error(function()
                    files.glob(temp, nil, { maxDepth = maxDepth })
                end, "tecs: io.files.glob maxDepth must be a non-negative integer")
            end
        end)

        it("refuses a call with no path", function()
            -- LuaJIT hands a Lua nil to a `const char *` as a null pointer, so
            -- one that reached SDL would be a call against an invalid path
            -- with nothing pointing back at the caller that made it. Checked
            -- once here rather than in a backend, so a port inherits it, and
            -- named after the function the caller actually called.
            local calls = {
                { "info", files.info },
                { "exists", files.exists },
                { "isFile", files.isFile },
                { "isDirectory", files.isDirectory },
                { "isSymlink", files.isSymlink },
                { "glob", files.glob },
                { "createDirectory", files.createDirectory },
                { "remove", files.remove },
                { "write", files.write },
                { "writeAtomic", files.writeAtomic },
                { "append", files.append },
                { "read", files.read },
                { "lines", files.lines },
                { "load", files.load },
            }
            for _, call in ipairs(calls) do
                assert.has_error(function()
                    call[2](nil)
                end, ("tecs: io.files.%s needs a path"):format(call[1]))
            end

            assert.has_error(function()
                files.rename(nil, at("x"))
            end, "tecs: io.files.rename needs a path")
            assert.has_error(function()
                files.rename(at("x"), nil)
            end, "tecs: io.files.rename needs a path")
            assert.has_error(function()
                files.copy(nil, at("x"))
            end, "tecs: io.files.copy needs a path")
            assert.has_error(function()
                files.copy(at("x"), nil)
            end, "tecs: io.files.copy needs a path")
            assert.has_error(function()
                files.write(at("x"), nil)
            end, "tecs: io.files.write needs bytes to write")
            assert.has_error(function()
                files.writeAtomic(at("x"), nil)
            end, "tecs: io.files.writeAtomic needs bytes to write")
            assert.has_error(function()
                files.append(at("x"), nil)
            end, "tecs: io.files.append needs bytes to append")
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
            files.createDirectory(at("many"))
            for index = 1, 64 do
                files.write(at(("many/entry-%02d-%s.txt"):format(index, ("p"):rep(24))), "x")
            end

            local before = settled()
            for _ = 1, GLOBS do
                adapter.storage().list(at("many"))
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
                files.currentDirectory()
                files.userFolder("home")
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
            files.createDirectory(at("wide/inner"))
            for index = 1, 8 do
                files.write(at("wide/file" .. index .. ".txt"), "x")
                files.write(at("wide/inner/file" .. index .. ".txt"), "x")
            end

            local worker = workers.spawn({
                source = [==[
                    local workers = require("tecs.workers")
                    local files = require("tecs.io.files")
                    local self = workers.current()
                    local job = self:receive(5000)
                    local stream = assert(files.glob(job.root))
                    local count = 0
                    while stream:next() ~= nil do
                        count = count + 1
                    end
                    stream:close()
                    self:send({ count = count })
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
describe("io.files with no video", function()
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

        assert.is_true(files.createDirectory(base .. "/nested/deeper"))
        assert.is_true(files.write(base .. "/nested/one.txt", "headless"))
        assert.is_true(files.copy(base .. "/nested/one.txt", base .. "/nested/two.txt"))
        assert.is_true(files.rename(base .. "/nested/two.txt", base .. "/nested/three.txt"))

        assert.are.same({ "deeper", "one.txt", "three.txt" }, sorted(globPaths(base .. "/nested", "*")))
        assert.are.equal(8, files.info(base .. "/nested/one.txt").size)
        assert.is_true(files.isDirectory(base .. "/nested/deeper"))
        assert.is_string(files.currentDirectory())
        assert.is_string(files.userFolder("home"))

        assert.is_true(files.remove(base .. "/nested/three.txt"))
        assert.is_false(files.exists(base .. "/nested/three.txt"))
    end)

    it("initializes no subsystem of its own", function()
        -- A gate that brought video up to answer a question about a path would
        -- make a headless tool open a display server. Nothing here calls
        -- SDL_Init, so the mask is the same on both sides of a full sweep.
        local before = tonumber(C.SDL_WasInit(0))

        files.createDirectory(base .. "/sweep")
        files.write(base .. "/sweep/x.txt", "x")
        files.info(base .. "/sweep/x.txt")
        files.exists(base .. "/sweep")
        files.isFile(base .. "/sweep/x.txt")
        files.isDirectory(base .. "/sweep")
        assert(files.glob(base .. "/sweep", "*")):toArray()
        files.copy(base .. "/sweep/x.txt", base .. "/sweep/y.txt")
        files.rename(base .. "/sweep/y.txt", base .. "/sweep/z.txt")
        files.remove(base .. "/sweep/z.txt")
        files.currentDirectory()
        files.userFolder("home")

        assert.are.equal(before, tonumber(C.SDL_WasInit(0)))
    end)
end)

-- Immutable platform-native paths and their file/process interoperability.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")

local function temporaryPath()
    return tecs.io.newPath(os.tmpname())
end

describe("filesystem paths", function()
    it("constructs paths from components without mutating their base", function()
        local base = tecs.io.newPath("assets")
        local joined = base:join("shaders", "sprite.glsl")
        local constructed = tecs.io.newPath("assets", "shaders", "sprite.glsl")

        assert.are.equal("assets", tostring(base))
        assert.are.equal(constructed:toString(), joined:toString())
        assert.is_true(constructed == joined)
        assert.is_true(joined:isRelative())
        assert.is_false(joined:isAbsolute())
    end)

    it("normalizes lexically and exposes file-name components", function()
        local path = tecs.io.newPath("alpha", ".", "beta", "..", "archive.tar.gz")
        local normalized = path:normalize()

        assert.are.equal(tecs.io.newPath("alpha", "archive.tar.gz"), normalized)
        assert.are.equal("archive.tar.gz", normalized:fileName())
        assert.are.equal("archive.tar", normalized:stem())
        assert.are.equal("gz", normalized:extension())
        assert.are.equal(tecs.io.newPath("alpha"), normalized:parent())
        assert.are.equal("renamed.bin", normalized:withFileName("renamed.bin"):fileName())
        assert.are.equal("archive.tar.pack", normalized:withExtension("pack"):fileName())
        assert.are.equal("archive.tar", normalized:withExtension(""):fileName())
    end)

    it("resolves absolute and relative paths without requiring them to exist", function()
        local current, currentReason = tecs.io.path.currentDirectory()
        local destination, resolveReason = tecs.io.newPath("alpha", "file.txt"):resolve()
        local relative, relativeReason = destination:relativeTo(current)

        assert.is_not_nil(current, currentReason)
        assert.is_not_nil(destination, resolveReason)
        assert.is_true(destination:isAbsolute())
        assert.is_not_nil(relative, relativeReason)
        assert.are.equal(tecs.io.newPath("alpha", "file.txt"), relative)
    end)

    it("canonicalizes existing filesystem objects", function()
        local path = temporaryPath()
        local ok, writeReason = tecs.io.files.write(path, "path bytes")
        local canonical, canonicalReason = path:canonicalize()

        assert.is_true(ok, writeReason)
        assert.is_not_nil(canonical, canonicalReason)
        assert.is_true(canonical:isAbsolute())
        assert.are.equal("path bytes", tecs.io.files.read(canonical))

        tecs.io.files.remove(path)
    end)

    it("accepts paths throughout file operations", function()
        local source = temporaryPath()
        local renamed = source:withExtension("moved")
        local ok, writeReason = tecs.io.files.writeAtomic(source, "saved")
        local moved, moveReason = tecs.io.files.rename(source, renamed)

        assert.is_true(ok, writeReason)
        assert.is_true(moved, moveReason)
        assert.is_true(tecs.io.files.exists(renamed))
        assert.are.equal("saved", tecs.io.files.read(renamed))

        tecs.io.files.remove(renamed)
    end)

    it("rejects values that cannot be represented as paths", function()
        assert.has_error(function()
            tecs.io.newPath("bad\0path")
        end)
        assert.has_error(function()
            tecs.io.newPath("file.txt"):withFileName("two/components")
        end)
    end)
end)

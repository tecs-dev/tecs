require("busted")

local luassert <const> = require("luassert")

-- The module caches the manifest on first read, so each scenario re-requires
-- a fresh instance and installs its manifest through package.preload.
local type Buildinfo = require("tecs2d.buildinfo")

local function freshBuildinfo(): Buildinfo
    (package.loaded as {string: any})["tecs2d.buildinfo"] = nil
    return require("tecs2d.buildinfo")
end

local function installManifest(manifest: {string: any})
    (package.preload as {string: any})["tecs_buildinfo"] = function(): {string: any}
        return manifest
    end
end

describe("tecs2d.buildinfo", function()
    after_each(function()
        local loaded = package.loaded as {string: any}
        local preload = package.preload as {string: any}
        loaded["tecs_buildinfo"] = nil
        preload["tecs_buildinfo"] = nil
        loaded["tecs2d.buildinfo"] = nil
    end)

    it("treats a missing manifest as a dev build", function()
        local buildinfo = freshBuildinfo()
        luassert.is_true(buildinfo.isDev())
        luassert.is_nil(buildinfo.get())
    end)

    it("reads a distributed-build manifest", function()
        installManifest({dev = false, name = "my-game", cli = "0.6.0"})
        local buildinfo = freshBuildinfo()
        luassert.is_false(buildinfo.isDev())
        luassert.equal("my-game", buildinfo.get().name)
        luassert.equal("0.6.0", buildinfo.get().cli)
    end)

    it("treats a dev manifest as a dev build", function()
        installManifest({dev = true, name = "my-game"})
        local buildinfo = freshBuildinfo()
        luassert.is_true(buildinfo.isDev())
        luassert.equal("my-game", buildinfo.get().name)
    end)

    it("fresh() sees a manifest swapped after get() cached", function()
        -- Hot reload replaces the manifest file under the running process;
        -- the cached get() reports boot-time metadata, fresh() must re-read
        -- (the MCP ping's staleness check is only truthful if it does).
        installManifest({dev = true, name = "my-game", built = "2026-01-01T00:00:00Z"})
        local buildinfo = freshBuildinfo()
        luassert.equal("2026-01-01T00:00:00Z", buildinfo.get().built)

        installManifest({dev = true, name = "my-game", built = "2026-02-02T00:00:00Z"})
        luassert.equal("2026-01-01T00:00:00Z", buildinfo.get().built)
        luassert.equal("2026-02-02T00:00:00Z", buildinfo.fresh().built)
        -- fresh() repairs the cache for later get() calls too.
        luassert.equal("2026-02-02T00:00:00Z", buildinfo.get().built)
    end)
end)

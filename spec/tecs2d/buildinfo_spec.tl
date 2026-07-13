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
end)

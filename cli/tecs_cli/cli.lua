-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local fileSystem = require("tecs_cli.cliFileSystem")

local VERSION = "0.10.9-dev"
local isLoveCli = rawget(_G, "TECS_LOVE_CLI") == true
local loveApi = rawget(_G, "love")

-- Platform traits detected from the OS path separator. Held in mutable locals
-- so specs can substitute another platform via M._internal.setPlatform.
local isWindows

local detectPlatform = fileSystem.detectPlatform

local function setPlatform(platform)
    isWindows = platform.isWindows or false
    fileSystem.setPlatform(platform)
end

setPlatform(detectPlatform())

-- TECS_DIR opts into copying framework sources from a local checkout.
local tecsDir = os.getenv("TECS_DIR")
-- TECS_TEAL_DIR opts into loading the Teal compiler from a local
-- teal-language/tl checkout instead of the embedded copy.
local tealDir = os.getenv("TECS_TEAL_DIR")
local vendorLua = "src/vendor/share/lua/5.1"

-- Source-only asset extensions to exclude from build output and mtime checks.
local excludeAssets = {
    ["ase"] = true,
    ["aseprite"] = true,
}

-- The same extensions as glob patterns, for copyDir exclusion lists.
local function excludeAssetPatterns()
    local patterns = {}
    for ext in pairs(excludeAssets) do
        patterns[#patterns + 1] = "*." .. ext
    end
    table.sort(patterns)
    return patterns
end

local colorEnabled
local quiet = false

local function envFlag(name)
    local value = os.getenv(name)
    return value ~= nil and value ~= "" and value ~= "0"
end

local function supportsColor()
    if colorEnabled ~= nil then return colorEnabled end
    local term = os.getenv("TERM")
    if os.getenv("NO_COLOR") ~= nil then
        colorEnabled = false
    elseif envFlag("FORCE_COLOR") or envFlag("CLICOLOR_FORCE") then
        colorEnabled = true
    elseif term == "dumb" then
        colorEnabled = false
    elseif isWindows then
        -- Plain cmd.exe consoles may not render ANSI codes, but ANSI-capable
        -- Windows environments (Windows Terminal, Git Bash) advertise
        -- themselves through these variables.
        colorEnabled = os.getenv("WT_SESSION") ~= nil or term ~= nil
    else
        colorEnabled = true
    end
    return colorEnabled
end

local function color(spec, text)
    if not supportsColor() then return text end
    return ansicolors("%{" .. spec .. "}" .. text .. "%{reset}")
end

-- Print a progress message to stderr (stdout is reserved for echoed commands).
local function status(message)
    if quiet then return end
    io.stderr:write(color("cyan", "==> ") .. message .. "\n")
end

local function fail(message)
    error({tecsExit = true, message = message}, 0)
end


-- Quote a path so it survives as a single shell argument. cmd.exe expects
-- doubled quotes inside a quoted string; POSIX shells use backslash escapes.
local q = fileSystem.q
local sourcePath = fileSystem.sourcePath
local normalize = fileSystem.normalize
local luaModulePath = fileSystem.luaModulePath
local pathJoin = fileSystem.pathJoin
local pathFromBuild = fileSystem.pathFromBuild

local HOT_RELOAD_STAMP = pathJoin("build", ".tecs-reload-stamp")

-- Directory portion of a path, or "." when there is no parent.
local dirname = fileSystem.dirname
local basename = fileSystem.basename
local exists = fileSystem.exists

-- Echo and run a shell command, raising on failure. Handles both the
-- LuaJIT/Lua 5.1 (numeric) and 5.2+ (boolean) os.execute return conventions.
local function run(cmd)
    if not quiet then
        io.stderr:write(color("black", cmd) .. "\n")
    end
    local a, _, c = os.execute(cmd)
    if a == true or a == 0 then return end
    local code = c or a or 1
    error("command failed with exit code " .. tostring(code), 0)
end

local mkdir = fileSystem.mkdir
local writeFile = fileSystem.writeFile
local isDir = fileSystem.isDir
local isEmptyDir = fileSystem.isEmptyDir
local remove = fileSystem.remove
local shouldExclude = fileSystem.shouldExclude
local copyFile = fileSystem.copyFile
local walkFiles = fileSystem.walkFiles
local relativeTo = fileSystem.relativeTo
local copyDir = fileSystem.copyDir

local function copyLoveDir(src, dst, depth)
    assert(loveApi, "embedded copy requires LÖVE")
    depth = (depth or 0) + 1
    if depth > 32 then
        error("embedded directory nests too deep (malformed payload?): " .. src, 0)
    end
    mkdir(dst)
    for _, entry in ipairs(loveApi.filesystem.getDirectoryItems(src)) do
        -- Guard against self-referential or path-shaped entries from
        -- malformed zip archives, which would otherwise recurse forever.
        local plain = entry ~= "" and entry ~= "." and entry ~= ".."
            and not entry:match("[/\\]")
        if plain then
            local source = src .. "/" .. entry
            local target = pathJoin(dst, entry)
            local info = loveApi.filesystem.getInfo(source)
            if info and info.type == "directory" then
                copyLoveDir(source, target, depth)
            elseif info and info.type == "file" then
                local content, err = loveApi.filesystem.read(source)
                if not content then
                    error("could not read embedded file " .. source .. ": " .. tostring(err), 0)
                end
                writeFile(target, content)
            end
        end
    end
end

local function templateDir()
    local candidates = {}
    local modulePath = sourcePath()
    if modulePath then
        local moduleDir = dirname(modulePath)
        candidates[#candidates + 1] = pathJoin(moduleDir, "templates/default")
        candidates[#candidates + 1] = pathJoin(moduleDir, "../tecs_cli/templates/default")
    end
    if arg and arg[0] then
        local binDir = dirname(arg[0])
        candidates[#candidates + 1] = pathJoin(binDir, "../tecs_cli/templates/default")
        candidates[#candidates + 1] = pathJoin(binDir, "../templates/default")
    end
    for _, candidate in ipairs(candidates) do
        if isDir(candidate) then
            return candidate
        end
    end
    error("could not find embedded default template", 0)
end

-- Per-user data directory where `tecs agent path` materializes bundled docs.
local dataDirOverride
local function userDataDir()
    if dataDirOverride then return dataDirOverride end
    if isWindows then
        local base = os.getenv("LOCALAPPDATA")
        if not base or base == "" then
            base = pathJoin(os.getenv("USERPROFILE") or ".", "AppData/Local")
        end
        return pathJoin(base, "tecs")
    end
    local xdg = os.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then
        return pathJoin(xdg, "tecs")
    end
    return pathJoin(os.getenv("HOME") or ".", ".local/share/tecs")
end

-- Per-user cache directory, matching the launchers' TECS_CACHE_DIR handling.
local function cacheRoot()
    local override = os.getenv("TECS_CACHE_DIR")
    if override and override ~= "" then return normalize(override) end
    if isWindows then
        local base = os.getenv("LOCALAPPDATA")
        if not base or base == "" then
            base = pathJoin(os.getenv("USERPROFILE") or ".", "AppData/Local")
        end
        return pathJoin(base, "tecs")
    end
    local xdg = os.getenv("XDG_CACHE_HOME")
    if xdg and xdg ~= "" then
        return pathJoin(xdg, "tecs")
    end
    return pathJoin(os.getenv("HOME") or ".", ".cache/tecs")
end

local cliDocs = require("tecs_cli.cliDocs").new({
    fileSystem = fileSystem,
    isLoveCli = isLoveCli,
    loveApi = loveApi,
})
local agentDocDescription = cliDocs.agentDocDescription
local listAgentDocs = cliDocs.listAgentDocs
local readDocBundle = cliDocs.readDocBundle
local docPagesByUrl = cliDocs.docPagesByUrl

-- Modification time of a path (platform-specific units), or 0 if it is missing.
local function fileMtime(path)
    return fileSystem.fileMtime(path)
end

-- True if output is missing or older than any input (incremental rebuild gate).
local function needsUpdate(output, ...)
    if not exists(output) then return true end
    local outTime = fileMtime(output)
    local inputs = {...}
    for i = 1, #inputs do
        if fileMtime(inputs[i]) > outTime then
            return true
        end
    end
    return false
end

-- Current working directory, normalized.
local function cwd()
    return fileSystem.cwd()
end

-- All files under dir ending in suffix, as paths relative to the cwd.
local function listFiles(dir, suffix)
    local files = {}
    for _, file in ipairs(walkFiles(dir, {})) do
        if file:sub(-#suffix) == suffix then
            files[#files + 1] = relativeTo(file, cwd())
        end
    end
    table.sort(files)
    return files
end

-- Every file under dir (follows symlinks), as paths relative to the cwd.
local function listAllFiles(dir)
    local files = {}
    for _, file in ipairs(walkFiles(dir, {})) do
        files[#files + 1] = relativeTo(file, cwd())
    end
    table.sort(files)
    return files
end

-- Newest mtime anywhere under dir, ignoring source-only assets (e.g. .ase).
local function treeMtime(dir)
    local latest = fileMtime(dir)
    for _, file in ipairs(listAllFiles(dir)) do
        local ext = file:match("%.([^%.]+)$")
        if not excludeAssets[ext or ""] then
            latest = math.max(latest, fileMtime(file))
        end
    end
    return latest
end

-- Buildable Teal sources under src/, excluding vendored code and .d.tl decls.
local function listTealSources()
    local files = listFiles("src", ".tl")
    local out = {}
    for _, file in ipairs(files) do
        local n = normalize(file)
        if not n:match("src[/\\]vendor[/\\]") and not n:match("%.d%.tl$") then
            out[#out + 1] = n
        end
    end
    return out
end

-- LUA_PATH entries letting `tl` resolve type defs and the vendored modules.
local function luaPath()
    local paths = {
        vendorLua .. "/?.tl",
        vendorLua .. "/?/init.tl",
        vendorLua .. "/?.lua",
        vendorLua .. "/?/init.lua",
        "",
    }
    if tecsDir then
        table.insert(paths, 1, luaModulePath(tecsDir) .. "/src/?.tl")
        table.insert(paths, 2, luaModulePath(tecsDir) .. "/src/?/init.tl")
    end
    return table.concat(paths, ";")
end

-- When TECS_TEAL_DIR points at a teal-language/tl checkout, resolve the
-- compiler modules from that checkout ahead of the copy embedded in the
-- payload. The loader only claims teal/tlcli/compat53 module names and only
-- when the checkout provides the file, so everything else is untouched.
local tealOverrideInstalled = false
local function installTealOverride()
    if not tealDir or tealOverrideInstalled then return end
    tealOverrideInstalled = true
    local loaders = package.loaders or package.searchers
    table.insert(loaders, 1, function(name)
        if not (name:match("^teal$") or name:match("^teal%.")
            or name:match("^tlcli%.")
            or name:match("^compat53$") or name:match("^compat53%.")) then
            return nil
        end
        local base = luaModulePath(tealDir)
        local rel = name:gsub("%.", "/")
        for _, candidate in ipairs({base .. "/" .. rel .. ".lua", base .. "/" .. rel .. "/init.lua"}) do
            local file = io.open(candidate, "rb")
            if file then
                local content = file:read("*a")
                file:close()
                local chunk, err = loadstring(content, "@" .. candidate)
                if not chunk then
                    error("TECS_TEAL_DIR module " .. candidate .. " failed to load: " .. tostring(err), 0)
                end
                return chunk
            end
        end
        return nil
    end)
end

-- Run fn with the embedded (or TECS_TEAL_DIR) Teal compiler importable and
-- os.exit trapped, restoring both afterwards. Returns the trapped exit code.
local function withTealEnv(fn)
    if not isLoveCli then
        error("embedded Teal compiler unavailable; run tecs through its installed launcher", 0)
    end

    installTealOverride()
    local previousPath = package.path
    local previousExit = os.exit
    local exitSignal = {}
    package.path = luaPath() .. ";" .. package.path
    rawset(os, "exit", function(code)
        exitSignal.code = tonumber(code) or 0
        error(exitSignal, 0)
    end)

    local ok, err = pcall(fn)
    rawset(os, "exit", previousExit)
    package.path = previousPath
    if not ok and err ~= exitSignal then error(err, 0) end
    return exitSignal.code or 0
end

local function runTl(args)
    local code = withTealEnv(function()
        return require("tlcli.main")(args)
    end)
    if code ~= 0 then
        error("Teal failed with exit code " .. tostring(code), 0)
    end
end

-- Teal compiler API, importable from both the LÖVE payload and a source
-- checkout (specs); a TECS_TEAL_DIR checkout wins through the loader above.
local tealApi
local function loadTealApi()
    if tealApi then return tealApi end
    installTealOverride()
    if not isLoveCli then
        local modulePath = sourcePath()
        local runtime = modulePath and pathJoin(dirname(modulePath), "runtime/teal")
        if runtime and isDir(runtime) then
            local base = luaModulePath(runtime)
            package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path
        end
    end
    local ok, api = pcall(require, "teal.api.v2")
    if not ok then
        error("Teal compiler unavailable: " .. tostring(api), 0)
    end
    tealApi = api
    return tealApi
end

-- Read a framework module's Teal source from TECS_DIR or the embedded payload.
local function readFrameworkSource(name)
    local rel = name:gsub("%.", "/")
    for _, candidate in ipairs({rel .. ".tl", rel .. "/init.tl"}) do
        if tecsDir then
            local file = io.open(pathJoin(tecsDir, "src", candidate), "rb")
            if file then
                local content = file:read("*a")
                file:close()
                return content, pathJoin(tecsDir, "src", candidate)
            end
        end
        if isLoveCli and loveApi then
            local path = "payload/framework/" .. candidate
            local info = loveApi.filesystem.getInfo(path)
            if info and info.type == "file" then
                return (loveApi.filesystem.read(path)), path
            end
        end
    end
    return nil
end

-- Let require() resolve tecs.*/tecs2d.* by compiling framework Teal sources
-- in memory, so the CLI reuses framework modules (e.g. tecs.utils.json)
-- instead of shipping second implementations.
local frameworkLoaderInstalled = false
local function installFrameworkLoader()
    if frameworkLoaderInstalled then return end
    frameworkLoaderInstalled = true
    local loaders = package.loaders or package.searchers
    loaders[#loaders + 1] = function(name)
        if not (name == "tecs" or name:match("^tecs%.")
            or name == "tecs2d" or name:match("^tecs2d%.")) then
            return nil
        end
        local source, origin = readFrameworkSource(name)
        if not source then
            return "\n\tno framework source for '" .. name
                .. "' (set TECS_DIR or run tecs through its installed launcher)"
        end
        local luaCode = loadTealApi().gen(source)
        if not luaCode then
            error("framework module " .. name .. " failed to compile", 0)
        end
        local chunk, err = loadstring(luaCode, "@" .. luaModulePath(origin))
        if not chunk then
            error("framework module " .. name .. " failed to load: " .. tostring(err), 0)
        end
        return chunk
    end
end

-- The framework's JSON module backs all --json output.
local function jsonModule()
    installFrameworkLoader()
    local ok, json = pcall(require, "tecs.utils.json")
    if not ok then
        error("JSON output unavailable: " .. tostring(json), 0)
    end
    return json
end

-- Diagnostics collection (Teal compiler -> flat list) and remediation hints
-- live in tecs_cli/diagnostics.lua.
local diagnosticsModule = require("tecs_cli.diagnostics").new({
    withTealEnv = withTealEnv,
    luaModulePath = luaModulePath,
})
local attachRemediation = diagnosticsModule.attachRemediation
local collectCheckDiagnostics = diagnosticsModule.collectCheckDiagnostics

local function loveBin()
    local supplied = os.getenv("TECS_LOVE_BIN")
    if supplied and supplied ~= "" then return normalize(supplied) end
    error("LÖVE runtime unavailable; run tecs through its installed launcher", 0)
end

local function embeddedDependenciesComplete()
    return exists(pathJoin(vendorLua, "tecs2d/init.tl"))
        and exists(pathJoin(vendorLua, "love2d.d.tl"))
        and exists(pathJoin(vendorLua, "ffi.d.tl"))
        and exists(pathJoin(vendorLua, "socket.d.tl"))
        and exists(pathJoin(vendorLua, "tecs2d/assets/fonts/tiny-font.fnt"))
        and exists(pathJoin(vendorLua, "tecs2d/assets/fonts/tiny-font.png"))
end

local function copyLocalFramework()
    if not tecsDir then return false end
    local tecsSource = pathJoin(tecsDir, "src/tecs")
    local tecs2dSource = pathJoin(tecsDir, "src/tecs2d")
    local fonts = pathJoin(tecsDir, "examples/shared/assets")
    if not exists(pathJoin(tecsSource, "init.tl"))
        or not exists(pathJoin(tecs2dSource, "init.tl"))
        or not exists(pathJoin(fonts, "tiny-font.fnt"))
        or not exists(pathJoin(fonts, "tiny-font.png")) then
        error("TECS_DIR is not a complete Tecs checkout: " .. tecsDir, 0)
    end

    copyDir(tecsSource, pathJoin(vendorLua, "tecs"))
    copyDir(tecs2dSource, pathJoin(vendorLua, "tecs2d"))
    copyFile(pathJoin(fonts, "tiny-font.fnt"),
        pathJoin(vendorLua, "tecs2d/assets/fonts/tiny-font.fnt"))
    copyFile(pathJoin(fonts, "tiny-font.png"),
        pathJoin(vendorLua, "tecs2d/assets/fonts/tiny-font.png"))
    return true
end

local function ensureVendor()
    if not isLoveCli then
        error("embedded dependencies unavailable; run tecs through its installed launcher", 0)
    end
    if not tecsDir and embeddedDependenciesComplete() then return end

    status(tecsDir and "Preparing local Tecs dependencies..." or "Preparing embedded Tecs dependencies...")
    mkdir(vendorLua)
    if not copyLocalFramework() then
        copyLoveDir("payload/framework/tecs", pathJoin(vendorLua, "tecs"))
        copyLoveDir("payload/framework/tecs2d", pathJoin(vendorLua, "tecs2d"))
    end
    copyLoveDir("payload/types", vendorLua)
end

-- Compile each changed Teal source to build/, mirroring the src/ layout.
local function compileSources()
    local compiled = 0
    local pending = {}
    for _, src in ipairs(listTealSources()) do
        local rel = src:gsub("^src[/\\]", "")
        local luaFile = rel:gsub("%.tl$", ".lua")
        local out = pathJoin("build", luaFile)
        if needsUpdate(out, src, "tlconfig.lua") then
            if compiled == 0 then status("Compiling Teal...") end
            mkdir(dirname(out))
            if isLoveCli then
                pending[#pending + 1] = src
            else
                runTl({"gen", src, "-o", out})
            end
            compiled = compiled + 1
        end
    end
    if #pending > 0 then
        local args = {"-q", "gen", "--root", "src", "--output-dir", "build"}
        for _, src in ipairs(pending) do args[#args + 1] = src end
        runTl(args)
    end
    if compiled == 0 then status("Teal output is up to date.") end
    return compiled
end

-- Compile vendored Tecs/Tecs2D sources after staging them into build/. This
-- keeps the starter working with Teal releases that do not support `gen --root`.
local function compileVendorTecsSources()
    local root = pathJoin("build/vendor/share/lua/5.1")
    local compiled = 0
    local pending = {}
    for _, src in ipairs(listFiles(root, ".tl")) do
        local n = normalize(src)
        if (n:match("[/\\]tecs[/\\]") or n:match("[/\\]tecs2d[/\\]")) and not n:match("%.d%.tl$") then
            local out = n:gsub("%.tl$", ".lua")
            if needsUpdate(out, n, "tlconfig.lua") then
                if compiled == 0 then status("Compiling vendored Tecs...") end
                if isLoveCli then
                    pending[#pending + 1] = n
                else
                    runTl({"gen", n, "-o", out})
                end
                compiled = compiled + 1
            end
        end
    end
    if #pending > 0 then
        local args = {"-q", "gen", "--root", root, "--output-dir", root}
        for _, src in ipairs(pending) do args[#args + 1] = src end
        runTl(args)
        -- Teal's readers can remain pending finalization after an in-process
        -- compile. Windows will not delete those source files while their
        -- handles are open, so finalize them before pruning compiler inputs.
        collectgarbage("collect")
    end
end

-- Keep runtime modules and native libraries, but discard compiler inputs,
-- LuaRocks bookkeeping, and duplicate framework copies from the game bundle.
local function pruneRuntimeVendor()
    local vendor = pathJoin("build", "vendor")
    local luaRoot = pathJoin(vendor, "share/lua/5.1")

    remove(pathJoin(vendor, "bin"))
    remove(pathJoin(vendor, "lib/luarocks"))
    remove(pathJoin(vendor, "rocks.lua"))
    remove(pathJoin(luaRoot, "teal"))
    remove(pathJoin(luaRoot, "tlcli"))
    remove(pathJoin(luaRoot, "tl.lua"))
    remove(pathJoin(luaRoot, "tecs"))
    remove(pathJoin(luaRoot, "tecs2d"))

    for _, source in ipairs(listFiles("build", ".tl")) do
        remove(source)
    end
end

-- Copy assets/ into build/, skipping source-only files; stamp guards reruns.
-- Returns true when anything was copied.
local function copyAssets()
    if not exists("assets") then return false end
    local stamp = pathJoin("build/assets/.copy-stamp")
    if exists(stamp) and fileMtime(stamp) >= treeMtime("assets") then
        status("Assets are up to date.")
        return false
    end
    status("Copying assets...")
    copyDir("assets", "build/assets", excludeAssetPatterns())
    writeFile(stamp, tostring(os.time()) .. "\n")
    return true
end

-- Stage the runtime Lua tree into build/ and compile framework sources.
-- Returns true when anything was staged.
local function copyVendor()
    local required = pathJoin("build/tecs2d/init.lua")
    local stamp = pathJoin("build/.vendor-copy-stamp")
    local vendorTime = treeMtime("src/vendor")
    if exists(required) and exists(stamp) and fileMtime(stamp) >= vendorTime then
        status("Runtime vendor tree is up to date.")
        return false
    end

    status("Preparing runtime vendor tree...")
    if exists("src/vendor") then
        copyDir("src/vendor", "build/vendor")
    else
        mkdir("build/vendor")
    end

    compileVendorTecsSources()

    local tecs = pathJoin("build/vendor/share/lua/5.1/tecs")
    local tecs2d = pathJoin("build/vendor/share/lua/5.1/tecs2d")
    if exists(tecs) then
        remove("build/tecs")
        copyDir(tecs, "build/tecs")
    end
    if exists(tecs2d) then
        remove("build/tecs2d")
        copyDir(tecs2d, "build/tecs2d")
    end
    local internal = pathJoin(tecs2d, "assets/internal")
    if exists(internal) then
        remove("build/internal")
        copyDir(internal, "build/internal")
    end
    pruneRuntimeVendor()
    writeFile(stamp, tostring(os.time()) .. "\n")
    return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Shared download and archive helpers used by dist.
--------------------------------------------------------------------------------

local function fetchUrl(url)
    local ok, https = pcall(require, "https")
    if not ok then
        error("network access unavailable; run tecs through its installed launcher", 0)
    end
    local code, body = https.request(url)
    if code ~= 200 or not body then
        error("download failed (HTTP " .. tostring(code) .. "): " .. url, 0)
    end
    return body
end

-- Mount a zip archive and call fn(mountpoint).
local function withMountedArchive(archive, fn)
    if not (isLoveCli and loveApi) then
        error("archive handling requires LÖVE; run tecs through its installed launcher", 0)
    end
    local fs = loveApi.filesystem
    if not fs.mountFullPath then
        error("this LÖVE runtime cannot mount archives; update the cached runtime", 0)
    end
    local mount = "tecs-archive-mount"
    if not fs.mountFullPath(archive, mount) then
        error("could not open archive " .. archive, 0)
    end
    local ok, err = pcall(fn, mount)
    pcall(fs.unmountFullPath, archive)
    if not ok then error(err, 0) end
end

local function ensureProject()
    if not exists("tlconfig.lua") then
        fail("not a Tecs project: tlconfig.lua not found in the current directory")
    end
end

--------------------------------------------------------------------------------
-- Distribution: package the built game as a .love file, a fused Windows
-- executable, and a macOS app bundle. Runtimes come from the launcher cache
-- when present, otherwise from the same pinned LÖVE nightly the launchers use.
--------------------------------------------------------------------------------

local DIST_RUNTIME_BASE = "https://nightly.link/love2d/love/workflows/main/main"

-- The distributable name, from the project directory.
local function distName()
    local name = basename(cwd()):gsub("[^%w%-_%. ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "game" end
    return name
end

-- Remove an array-valued plist key while respecting arrays nested in its value.
local function removePlistArray(plist, key)
    local declarationStart, keyEnd = plist:find("%s*<key>" .. key .. "</key>%s*")
    if not declarationStart then return plist end

    local arrayStart, arrayEnd = plist:find("<array%s*>", keyEnd + 1)
    if not arrayStart or arrayStart ~= keyEnd + 1 then
        error("Info.plist key " .. key .. " does not contain an array", 0)
    end

    local depth = 1
    local position = arrayEnd + 1
    while depth > 0 do
        local tagStart, tagEnd, closing = plist:find("<(/?)array%s*>", position)
        if not tagStart then
            error("Info.plist key " .. key .. " contains an unterminated array", 0)
        end
        if closing == "/" then
            depth = depth - 1
        else
            depth = depth + 1
        end
        position = tagEnd + 1
    end

    return plist:sub(1, declarationStart - 1) .. plist:sub(position)
end

-- Rebrand LÖVE's Info.plist for the game and drop its claim on .love files.
local function patchPlist(plist, name)
    plist = plist:gsub("(<key>CFBundleIdentifier</key>%s*<string>)[^<]*", "%1org.tecs2d." .. name, 1)
    plist = plist:gsub("(<key>CFBundleName</key>%s*<string>)[^<]*", "%1" .. name, 1)
    return removePlistArray(plist, "UTExportedTypeDeclarations")
end

local function readBinary(path)
    local file = assert(io.open(normalize(path), "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

-- Zip entries (paths relative to baseDir) into zipTarget, preserving
-- symlinks on POSIX. Uses Info-ZIP when available, else Windows' bsdtar.
local function createZip(baseDir, zipTarget, entries)
    remove(zipTarget)
    local zipAbs = pathJoin(cwd(), zipTarget)
    local quoted = {}
    for _, entry in ipairs(entries) do quoted[#quoted + 1] = q(entry) end
    local list = table.concat(quoted, " ")
    if isWindows then
        local bsdtar = pathJoin(os.getenv("WINDIR") or "C:\\Windows", "System32/tar.exe")
        run('cmd /C "cd /D ' .. q(pathJoin(cwd(), baseDir)) .. " && " .. q(bsdtar)
            .. " --format zip -cf " .. q(zipAbs) .. " " .. list .. '"')
    else
        run("cd " .. q(pathJoin(cwd(), baseDir)) .. " && zip -q -r -y " .. q(zipAbs) .. " " .. list)
    end
end

-- Copy every file under a mounted archive directory to dest.
local function copyMountTree(mount, dest)
    local fs = loveApi.filesystem
    local function walk(dir, prefix)
        for _, entry in ipairs(fs.getDirectoryItems(dir)) do
            local source = dir .. "/" .. entry
            local info = fs.getInfo(source)
            if info and info.type == "directory" then
                walk(source, prefix .. entry .. "/")
            elseif info and info.type == "file" then
                writeFile(pathJoin(dest, prefix .. entry), (fs.read(source)))
            end
        end
    end
    walk(mount, "")
end

-- Directory containing love.exe and its DLLs, reusing the host launcher's
-- cache on Windows and downloading the runtime zip elsewhere.
local function distWindowsRuntime()
    local launcherCache = pathJoin(cacheRoot(), "love12-main")
    if exists(launcherCache) then
        for _, file in ipairs(walkFiles(launcherCache, {})) do
            if basename(file) == "love.exe" then
                return dirname(file)
            end
        end
    end
    local dir = pathJoin(cacheRoot(), "dist/love-windows")
    for _, file in ipairs(walkFiles(dir, {})) do
        if basename(file) == "love.exe" then
            return dirname(file)
        end
    end

    status("Downloading the Windows LÖVE runtime...")
    mkdir(dir)
    local outer = pathJoin(cacheRoot(), "dist/love-windows-outer.zip")
    writeFile(outer, fetchUrl(DIST_RUNTIME_BASE .. "/love-windows-x64.zip"))
    local inner = pathJoin(cacheRoot(), "dist/love-windows-inner.zip")
    withMountedArchive(outer, function(mount)
        local fs = loveApi.filesystem
        local innerName
        for _, entry in ipairs(fs.getDirectoryItems(mount)) do
            if entry:match("%.zip$") then
                innerName = entry
                break
            end
        end
        if not innerName then
            error("unexpected Windows LÖVE runtime archive layout", 0)
        end
        writeFile(inner, (fs.read(mount .. "/" .. innerName)))
    end)
    withMountedArchive(inner, function(mount)
        copyMountTree(mount, dir)
    end)
    remove(outer)
    remove(inner)

    for _, file in ipairs(walkFiles(dir, {})) do
        if basename(file) == "love.exe" then
            return dirname(file)
        end
    end
    error("Windows LÖVE runtime did not contain love.exe", 0)
end

-- Path to love.app, reusing the host launcher's cache on macOS and
-- downloading the runtime zip elsewhere. POSIX hosts only (unzip preserves
-- the bundle's symlinks and permissions; archive mounting does not).
local function distMacosRuntime()
    local cached = pathJoin(cacheRoot(), "love12-main/love.app")
    if exists(pathJoin(cached, "Contents/MacOS/love")) then
        return cached
    end
    local baseDir = pathJoin(cacheRoot(), "dist/love-macos")
    local app = pathJoin(baseDir, "love.app")
    if exists(pathJoin(app, "Contents/MacOS/love")) then
        return app
    end

    status("Downloading the macOS LÖVE runtime...")
    remove(baseDir)
    mkdir(baseDir)
    writeFile(pathJoin(baseDir, "outer.zip"), fetchUrl(DIST_RUNTIME_BASE .. "/love-macos.zip"))
    run("cd " .. q(baseDir) .. " && unzip -q outer.zip && unzip -q love-macos.zip"
        .. " && rm -f outer.zip love-macos.zip")
    if not exists(pathJoin(app, "Contents/MacOS/love")) then
        error("macOS LÖVE runtime did not contain love.app", 0)
    end
    return app
end

-- Build metadata module consumed by tecs2d.buildinfo. Games (and the MCP
-- and debugger plugins) use it to tell dev builds from distributed ones.
local BUILDINFO_PATH = "build/tecs_buildinfo.lua"

local function buildinfoLua(dev)
    local loveVersion = ""
    if loveApi and loveApi.getVersion then
        local major, minor, revision = loveApi.getVersion()
        loveVersion = table.concat({major, minor, revision}, ".")
    end
    local jitApi = rawget(_G, "jit")
    return table.concat({
        "-- Generated by `tecs build`; do not edit.",
        "return {",
        ("    dev = %s,"):format(tostring(dev == true)),
        ("    name = %q,"):format(distName()),
        ("    built = %q,"):format(os.date("!%Y-%m-%dT%H:%M:%SZ")),
        ("    cli = %q,"):format(VERSION),
        ("    love = %q,"):format(loveVersion),
        ("    luajit = %q,"):format((jitApi and jitApi.version) or _VERSION),
        "}",
    }, "\n") .. "\n"
end

-- Write the manifest when the build changed, it is missing, or a `tecs dist`
-- run left it marked as distributed.
local function refreshBuildinfo(changed)
    local stale = changed or not exists(BUILDINFO_PATH)
    if not stale then
        stale = readBinary(BUILDINFO_PATH):match("dev = false") ~= nil
    end
    if stale then
        writeFile(BUILDINFO_PATH, buildinfoLua(true))
    end
end

-- Zip build/ into dist/<name>.love.
local function distLove(name)
    local loveFile = pathJoin("dist", name .. ".love")
    -- Compiled specs and their scratch output are development artifacts.
    local excluded = {spec = true, test_deps = true}
    local entries = {}
    for _, entry in ipairs(fileSystem.listDir("build")) do
        if entry ~= "." and entry ~= ".." and not entry:match("^%.") and not excluded[entry] then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries)
    createZip("build", loveFile, entries)
    status("Wrote " .. loveFile)
    return loveFile
end

-- Assemble dist/macos/<name>.app and dist/<name>-macos.zip.
local function distMacos(name, loveFile)
    local runtime = distMacosRuntime()
    local outDir = pathJoin("dist", "macos")
    local app = pathJoin(outDir, name .. ".app")
    remove(app)
    mkdir(outDir)
    run("cp -R " .. q(runtime) .. " " .. q(app))

    copyFile(loveFile, pathJoin(app, "Contents/Resources", name .. ".love"))
    local plistPath = pathJoin(app, "Contents/Info.plist")
    writeFile(plistPath, patchPlist(readBinary(plistPath), name))

    local bundleZip = pathJoin("dist", name .. "-macos.zip")
    createZip(outDir, bundleZip, {name .. ".app"})
    status("Wrote " .. app)
    status("Wrote " .. bundleZip .. " (unsigned; sign and notarize before wide distribution)")
end

-- Assemble dist/windows/<name>/ (fused exe plus DLLs) and dist/<name>-windows.zip.
local function distWindows(name, loveFile)
    local runtime = distWindowsRuntime()
    local outRoot = pathJoin("dist", "windows")
    local out = pathJoin(outRoot, name)
    remove(out)
    mkdir(out)

    writeFile(pathJoin(out, name .. ".exe"),
        readBinary(pathJoin(runtime, "love.exe")) .. readBinary(loveFile))
    for _, file in ipairs(walkFiles(runtime, {})) do
        local base = basename(file)
        if dirname(file) == normalize(runtime) then
            if base:lower():match("%.dll$") then
                copyFile(file, pathJoin(out, base))
            elseif base:lower():match("^license") then
                copyFile(file, pathJoin(out, "love-" .. base:lower()))
            end
        end
    end

    local bundleZip = pathJoin("dist", name .. "-windows.zip")
    createZip(outRoot, bundleZip, {name})
    status("Wrote " .. pathJoin(out, name .. ".exe"))
    status("Wrote " .. bundleZip)
end
local cliApi = require("tecs_cli.cliApi").new({
    version = VERSION,
    isLoveCli = isLoveCli,
    loveApi = loveApi,
    tecsDir = tecsDir,
    userDataDir = userDataDir,
    loadTealApi = loadTealApi,
    ensureVendor = ensureVendor,
    jsonModule = jsonModule,
    pathJoin = pathJoin,
    dirname = dirname,
    sourcePath = sourcePath,
    isDir = isDir,
    exists = exists,
    fileMtime = fileMtime,
    luaModulePath = luaModulePath,
    listTealSources = listTealSources,
    listFiles = listFiles,
    normalize = normalize,
    remove = remove,
    mkdir = mkdir,
    copyDir = copyDir,
    copyLoveDir = copyLoveDir,
    vendorLua = vendorLua,
})
local apiInvoke = cliApi.invoke
-- Task table: each entry implements one `tecs <target>` command.
local tasks = {}

-- Forward declaration; assigned after the command table below.
local parser

function tasks.check(args)
    ensureVendor()
    local sources = listTealSources()
    if args and args.json then
        local json = jsonModule()
        local checkOk, diagnostics = collectCheckDiagnostics(sources)
        print(json.serialize({ok = checkOk, diagnostics = diagnostics}, true))
        if not checkOk then
            fail("typecheck reported errors")
        end
        return
    end
    status("Typechecking...")
    local tlArgs = {"check"}
    for _, source in ipairs(sources) do tlArgs[#tlArgs + 1] = source end
    runTl(tlArgs)
    -- runTl errors out on any diagnostic, so reaching here means a clean pass.
    -- Say so explicitly: the exit code alone reads as ambiguous silence.
    status("OK: 0 type errors in " .. tostring(#sources) .. " files")
end

function tasks.build()
    status("Building...")
    ensureVendor()
    local changed = compileSources() > 0
    if copyAssets() then changed = true end
    if copyVendor() then changed = true end
    refreshBuildinfo(changed)
    -- Only refresh the stamp when output changed, so a no-op rebuild does not
    -- trigger the running game's hot reload.
    if changed or not exists(HOT_RELOAD_STAMP) then
        writeFile(HOT_RELOAD_STAMP, tostring(os.time()) .. "\n")
    end
end

function tasks.run()
    tasks.build()
    status("Launching game...")
    local executable = pathFromBuild(loveBin())
    if isWindows then
        run('cmd /C "set SDL_VIDEODRIVER=&& set SDL_AUDIODRIVER=&& cd /D build && '
            .. q(executable) .. ' ."')
    else
        run("cd build && env -u SDL_VIDEODRIVER -u SDL_AUDIODRIVER "
            .. q(executable) .. " .")
    end
end

function tasks.clean()
    status("Removing build artifacts...")
    remove("build")
end

function tasks.new(args)
    local target = args and args.project
    if not target or target == "" then
        fail("missing project path")
    end
    target = normalize(target)
    if exists(target) and not isEmptyDir(target) then
        fail("target already exists and is not empty: " .. target)
    end
    -- Refuse to nest a project inside an existing one: the nested project is
    -- detached from the outer project's MCP bridge and toolchain, so agents
    -- that "create a game" this way end up driving the outer template. An
    -- agent inside a generated project should implement in src/ instead.
    if not (args and args.force) and exists("tlconfig.lua") and isDir("src") then
        fail("this directory is already a Tecs project - implement your game "
            .. "in src/ (start from src/main.tl) instead of nesting a new "
            .. "project. Pass --force to nest one deliberately")
    end

    status("Creating project " .. target .. "...")
    mkdir(target)
    if isLoveCli then
        copyLoveDir("tecs_cli/templates/default", target)
    else
        copyDir(templateDir(), target)
    end
    mkdir(pathJoin(target, "assets"))

    -- Agent guidance ships from the bundled doc so `tecs agent` and generated
    -- projects stay in sync; CLAUDE.md defers to AGENTS.md.
    for _, doc in ipairs(listAgentDocs()) do
        if doc.name == "tecs-project" then
            writeFile(pathJoin(target, "AGENTS.md"), doc.content)
            writeFile(pathJoin(target, "CLAUDE.md"), "@AGENTS.md\n")
        end
    end

    -- Stamp the LÖVE identity and window title with the project name. A
    -- static identity would make every generated game share one save
    -- directory, so debugger artifacts (cmd_screenshot files, snapshots)
    -- from one project bleed into the next -- an agent reading a stale
    -- screenshot from a different game chases ghosts.
    local projectName = basename(target):gsub("[^%w%-_%. ]", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if projectName == "" then projectName = "game" end
    local confPath = pathJoin(target, "src/conf.tl")
    local conf = io.open(normalize(confPath), "rb")
    if conf then
        local text = conf:read("*a"); conf:close()
        text = text:gsub('t%.window%.title = "Tecs Game"',
            't.window.title = ' .. string.format("%q", projectName))
        text = text:gsub('t%.identity = "tecs%-game"',
            't.identity = ' .. string.format("%q", "tecs-" .. projectName))
        writeFile(confPath, text)
    end

    -- Stage the framework vendor now, so the project is complete at scaffold
    -- time: the first `tecs check`/`api` inside it must answer immediately,
    -- not pause on "Preparing embedded Tecs dependencies...".
    if isLoveCli then
        local savedVendor = vendorLua
        vendorLua = pathJoin(target, "src/vendor/share/lua/5.1")
        local ok, err = pcall(ensureVendor)
        vendorLua = savedVendor
        if not ok then fail(err) end
    end

    status("Project created. Next: cd " .. target .. " && tecs check")
end

function tasks.dev()
    if not tecsDir then
        error("set TECS_DIR to a local Tecs checkout before running `tecs dev`", 0)
    end
    status("Preparing local Tecs development source...")
    ensureVendor()
    status("Dev source copied. Re-run `tecs dev` after local framework changes.")
end

-- Run project specs with the vendored busted runner. Files matching
-- *_lovespec.tl launch the built game under real LÖVE and drive it over the
-- tecs2d MCP server, so this is intentionally not headless.
function tasks.integ()
    ensureProject()
    if isWindows then
        fail("tecs integ requires macOS or Linux; the test harness drives POSIX processes")
    end
    if not exists("spec") then
        fail("no spec/ directory; create spec/<name>_spec.tl or spec/<name>_lovespec.tl first")
    end

    -- The specs exercise the built game, so build first.
    tasks.build()

    status("Compiling specs...")
    local specSources = listFiles("spec", ".tl")
    local tlArgs = {"-q", "--global-env-def", "busted", "gen",
        "--root", ".", "--output-dir", "build"}
    local found = false
    for _, source in ipairs(specSources) do
        if not source:match("%.d%.tl$") then
            tlArgs[#tlArgs + 1] = source
            found = true
        end
    end
    if not found then
        fail("no Teal specs found under spec/")
    end
    runTl(tlArgs)

    -- The CLI itself runs under dummy SDL drivers; launched games need real
    -- ones, and the fixture harness finds the runtime through LOVE.
    local ffi = require("ffi")
    ffi.cdef([[
        int setenv(const char *name, const char *value, int overwrite);
        int unsetenv(const char *name);
    ]])
    ffi.C.unsetenv("SDL_VIDEODRIVER")
    ffi.C.unsetenv("SDL_AUDIODRIVER")
    ffi.C.setenv("LOVE", loveBin(), 1)

    status("Running specs...")
    local previousPath = package.path
    local previousArg = rawget(_G, "arg")
    local previousExit = os.exit
    local exitSignal = {}
    package.path = table.concat({
        "build/?.lua",
        "build/?/init.lua",
        "build/vendor/share/lua/5.1/?.lua",
        "build/vendor/share/lua/5.1/?/init.lua",
    }, ";") .. ";" .. package.path
    rawset(_G, "arg", {"--output", "plainTerminal", "--pattern", "_%a*spec", "build/spec"})
    rawset(os, "exit", function(code)
        exitSignal.code = tonumber(code) or 0
        error(exitSignal, 0)
    end)

    local ok, err = pcall(function()
        require("busted.runner")({standalone = false})
    end)
    rawset(os, "exit", previousExit)
    rawset(_G, "arg", previousArg)
    package.path = previousPath
    if not ok and err ~= exitSignal then error(err, 0) end
    if (exitSignal.code or 0) ~= 0 then
        fail("specs failed")
    end
end

-- Package the built game for distribution.
function tasks.dist(args)
    ensureProject()
    if not isLoveCli then
        error("packaging requires LÖVE; run tecs through its installed launcher", 0)
    end
    if args.target == "macos" and isWindows then
        fail("the macOS bundle cannot be assembled on Windows; its symlinks need a POSIX host")
    end
    tasks.build()

    mkdir("dist")
    local name = distName()
    -- Package with distributed-build metadata, then restore the dev manifest
    -- so later runs and specs keep the MCP server and debugger enabled.
    writeFile(BUILDINFO_PATH, buildinfoLua(false))
    local ok, err = pcall(function()
        local loveFile = distLove(name)
        if args.target == "love" then return end

        if not args.target or args.target == "macos" then
            if isWindows then
                status("Skipping the macOS bundle: assemble it on macOS or Linux.")
            else
                distMacos(name, loveFile)
            end
        end
        if not args.target or args.target == "windows" then
            distWindows(name, loveFile)
        end
    end)
    writeFile(BUILDINFO_PATH, buildinfoLua(true))
    if not ok then error(err, 0) end
end

-- Everything host-specific the MCP bridge needs, kept injectable so the
-- dispatcher stays unit-testable outside LÖVE.
local function buildMcpContext()
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        int setenv(const char *name, const char *value, int overwrite);
        int unsetenv(const char *name);
    ]])
    installFrameworkLoader()

    local kernelTools = {}
    do
        local ok, mcpTools = pcall(require, "tecs2d.mcp.tools")
        if ok and type(mcpTools) == "table" and type(mcpTools.list) == "table" then
            kernelTools = mcpTools.list
        end
    end

    -- The full default tool set (kernel + cmd_*) generated in the Tecs repo and
    -- vendored into the payload at build time. Front-loading it lets the bridge
    -- advertise everything at initialize on the very first run, before any
    -- start_game has populated the user-level cache.
    local function readBundledTools()
        local data
        if isLoveCli and loveApi then
            data = loveApi.filesystem.read("tecs_cli/mcp-default-tools.json")
        else
            local modulePath = sourcePath()
            local path = modulePath and pathJoin(dirname(modulePath), "mcp-default-tools.json")
            local handle = path and io.open(path, "rb")
            if handle then
                data = handle:read("*a")
                handle:close()
            end
        end
        if not data then return nil end
        local ok, parsed = pcall(jsonModule().parse, data)
        if ok and type(parsed) == "table" and parsed[1] then return parsed end
        return nil
    end

    -- The game's full tool set (kernel + registry-derived cmd_*) only exists
    -- once a game runs, but it is identical across projects, so cache it at a
    -- user-level path the first time start_game succeeds and front-load it
    -- thereafter. That lets the bridge advertise the full list at initialize
    -- instead of firing a large tools/list_changed after start_game, which some
    -- MCP clients mis-reconcile. (The CLI cannot enumerate cmd_* itself: it
    -- loads the framework from .tl on the fly, and observe()'s slotOf macroexp
    -- is not inlined on that path.)
    -- Last-seen full game tool list, keyed by CLI version: this cache takes
    -- precedence over the bundled manifest, so a file written by an older
    -- serializer (which froze empty {} schemas as [], making strict MCP
    -- clients reject the whole tools list) must never survive an upgrade.
    local defaultToolsPath = pathJoin(userDataDir(),
        "mcp-default-tools-" .. VERSION .. ".json")
    -- Drop the legacy unversioned cache; it may carry that corruption.
    pcall(os.remove, pathJoin(userDataDir(), "mcp-default-tools.json"))

    return {
        version = VERSION,
        projectName = distName(),
        json = jsonModule(),
        kernelTools = kernelTools,
        readBundledTools = readBundledTools,
        readDefaultTools = function()
            local fh = io.open(defaultToolsPath, "rb")
            if not fh then return nil end
            local data = fh:read("*a")
            fh:close()
            local ok, parsed = pcall(jsonModule().parse, data)
            if ok and type(parsed) == "table" then return parsed end
            return nil
        end,
        writeDefaultTools = function(tools)
            pcall(function()
                os.execute("mkdir -p " .. q(dirname(defaultToolsPath)))
                local fh = io.open(defaultToolsPath, "wb")
                if fh then
                    fh:write(jsonModule().serialize(tools))
                    fh:close()
                end
            end)
        end,
        loveProcess = require("tecs2d.testing.love_process"),
        mcpClient = require("tecs2d.testing.mcp_client"),
        loveBin = loveBin,
        -- start_game builds before launching; the toolchain itself (check,
        -- api, docs, integ, dist) is CLI-only by design -- the shell is the
        -- canonical interface for it, the bridge owns the live game.
        build = function()
            tasks.build()
        end,
        setEnv = function(name, value) ffi.C.setenv(name, value, 1) end,
        unsetEnv = function(name) ffi.C.unsetenv(name) end,
        readBuildinfo = function()
            if not exists("build/tecs_buildinfo.lua") then return nil end
            local chunk = loadstring(readBinary("build/tecs_buildinfo.lua"))
            if not chunk then return nil end
            local ok, info = pcall(chunk)
            if ok then return info end
            return nil
        end,
        log = status,
    }
end

-- Serve the project over MCP on stdio: toolchain tools, game lifecycle, and
-- a proxy to the running game's own MCP tools.
function tasks.mcp()
    ensureProject()
    if not isLoveCli then
        error("the MCP bridge requires LÖVE; run tecs through its installed launcher", 0)
    end
    if isWindows then
        fail("tecs mcp requires macOS or Linux; the game process harness is POSIX-only")
    end
    require("tecs_cli.mcp_bridge").serve(buildMcpContext())
end

function tasks.agent(args)
    local docs = listAgentDocs()

    if args.agentAction == "list" then
        if args.json then
            local json = jsonModule()
            local listed = {}
            for _, doc in ipairs(docs) do
                listed[#listed + 1] = {
                    name = doc.name,
                    description = agentDocDescription(doc.content),
                }
            end
            print(json.serialize(listed, true))
            return
        end
        local width = 0
        for _, doc in ipairs(docs) do
            width = math.max(width, #doc.name)
        end
        for _, doc in ipairs(docs) do
            print(string.format("%-" .. width .. "s  %s", doc.name, agentDocDescription(doc.content)))
        end
        return
    end

    local name = args.name
    if not name or name == "" then
        fail("missing agent name; run `tecs agent list` to see what is available")
    end
    local names = {}
    for _, doc in ipairs(docs) do
        names[#names + 1] = doc.name
        if doc.name == name then
            local target = pathJoin(userDataDir(), "agents", doc.name .. ".md")
            writeFile(target, doc.content)
            print(target)
            return
        end
    end
    fail("unknown agent '" .. tostring(name) .. "'. Expected one of: " .. table.concat(names, ", "))
end

function tasks.docs(args)
    -- --json and --full are listing/whole-corpus modifiers; a page prints one page.
    if args.page and args.full then
        fail("pass either a page or --full, not both")
    end
    if args.json and (args.page or args.full) then
        fail("--json is only valid for the page index (drop the page and --full)")
    end

    -- Content search: match a Lua pattern (case-insensitive; falls back to a
    -- plain-text match when the pattern is invalid) against every page's id
    -- and body, printing page ids plus their first matching lines. Retrieval
    -- beats browsing: agents were dumping the whole index to find one page.
    if args.search and args.search ~= "" then
        if args.page or args.full then
            fail("pass either --search or a page/--full, not both")
        end
        local pat = args.search:lower()
        local okPat = pcall(string.find, "", pat)
        local function matches(text)
            local hay = text:lower()
            if okPat then return hay:find(pat) ~= nil end
            return hay:find(pat, 1, true) ~= nil
        end
        local pages = docPagesByUrl(readDocBundle("llms-full.txt"))
        local ids = {}
        for u in pairs(pages) do ids[#ids + 1] = u end
        table.sort(ids)
        local shown = 0
        for _, u in ipairs(ids) do
            if shown >= 10 then
                io.write("... (more pages matched; narrow the pattern)\n")
                break
            end
            local id = u:gsub("^/", ""):gsub("%.md$", "")
            local body = pages[u]
            local hitLines = {}
            for lineText in body:gmatch("[^\n]+") do
                if #hitLines < 3 and matches(lineText) then
                    hitLines[#hitLines + 1] = "  " .. lineText:gsub("^%s+", ""):sub(1, 120)
                end
            end
            if #hitLines > 0 or matches(id) then
                shown = shown + 1
                io.write(id .. "\n")
                for _, h in ipairs(hitLines) do io.write(h .. "\n") end
            end
        end
        if shown == 0 then
            fail("no docs match '" .. args.search .. "'. Try a shorter pattern, "
                .. "or `tecs docs` for the page index")
        end
        return
    end

    -- Whole corpus.
    if args.full then
        io.write(readDocBundle("llms-full.txt"))
        return
    end

    -- One page, addressed by its index path (e.g. tecs2d/rendering/shapes or
    -- /tecs2d/rendering/shapes.md).
    if args.page and args.page ~= "" then
        local url = "/" .. (args.page:gsub("^/", ""):gsub("%.md$", "")) .. ".md"
        local pages = docPagesByUrl(readDocBundle("llms-full.txt"))
        local page = pages[url]
        if not page then
            -- Fuzzy-match the request against known page ids so a plausible
            -- guess redirects in one call instead of inviting another guess.
            local want = args.page:gsub("^/", ""):gsub("%.md$", ""):lower()
            local near = {}
            for u in pairs(pages) do
                local id = u:gsub("^/", ""):gsub("%.md$", "")
                local leaf = id:match("([^/]+)$") or id
                if id:lower():find(want, 1, true) or want:find(leaf:lower(), 1, true)
                    or leaf:lower():find(want:match("([^/]+)$") or want, 1, true) then
                    near[#near + 1] = id
                end
            end
            table.sort(near)
            local hint = "Run `tecs docs` to list pages"
            if #near > 0 then
                hint = "did you mean: " .. table.concat(near, ", ", 1, math.min(#near, 4)) .. "?"
            end
            fail("unknown page '" .. tostring(args.page) .. "'. " .. hint)
        end
        io.write(page)
        if not page:match("\n$") then
            io.write("\n")
        end
        return
    end

    -- The page index (llms.txt): titled, described, sectioned tree.
    local index = readDocBundle("llms.txt")
    if args.json then
        local json = jsonModule()
        local pages = {}
        for title, path, desc in index:gmatch("%-%s*%[(.-)%]%((/[%w%-%._/]+%.md)%):%s*([^\n]*)") do
            pages[#pages + 1] = {
                id = (path:gsub("^/", ""):gsub("%.md$", "")),
                title = title,
                description = (desc:gsub("%s+$", "")),
            }
        end
        print(json.serialize(pages, true))
        return
    end
    io.write(index)
    if not index:match("\n$") then
        io.write("\n")
    end
    io.write("\nSearch page contents instead of browsing: tecs docs --search <pattern>\n")
end

function tasks.api(args)
    local fields
    if args.fields and args.fields ~= "" then
        fields = {}
        for f in args.fields:gmatch("[^,%s]+") do fields[#fields + 1] = f end
    end

    local queries = {}
    if type(args.query) == "table" then
        for _, qy in ipairs(args.query) do queries[#queries + 1] = qy end
    elseif type(args.query) == "string" and args.query ~= "" then
        queries[#queries + 1] = args.query
    end

    local params = { fields = fields }
    if #queries == 1 then
        params.query = queries[1]
    elseif #queries > 1 then
        params.queries = queries
    end

    local res = apiInvoke(params)
    if args.json then
        print(jsonModule().serialize(res.json, true))
    else
        io.write(res.text)
        if res.text == "" or not res.text:match("\n$") then io.write("\n") end
    end
    if not res.ok then
        fail(res.message or (#queries > 1 and "one or more lookups did not resolve"
            or ("no match for '" .. (queries[1] or "") .. "'")))
    end
end

function tasks.completions(args)
    local p = parser()
    local script = p["get_" .. args.shell .. "_complete"](p)
    if args.shell == "fish" then
        -- argparse's fish generator omits positional-argument choices (the
        -- zsh one includes them), so emit them from the parser definition.
        local extra = {}
        for _, command in ipairs(p._commands) do
            for _, argument in ipairs(command._arguments or {}) do
                if argument._choices then
                    extra[#extra + 1] = ("complete -c tecs -n '__fish_tecs_seen_command %s' -f -a '%s'")
                        :format(command._name, table.concat(argument._choices, " "))
                end
            end
        end
        if #extra > 0 then
            script = script .. table.concat(extra, "\n") .. "\n"
        end
    end
    io.write(script)
end

local M = {}

-- Runtime and project facts backing both info renderings.
local function gatherInfo()
    local loveVersion
    if loveApi and loveApi.getVersion then
        local major, minor, revision, codename = loveApi.getVersion()
        loveVersion = table.concat({major, minor, revision}, ".")
        if codename and codename ~= "" then loveVersion = loveVersion .. " (" .. codename .. ")" end
    end

    local jitApi = rawget(_G, "jit")
    local project
    if exists("tlconfig.lua") and isDir("src") then
        local root = cwd()
        project = {
            name = basename(root),
            path = root,
            built = exists("build/main.lua"),
        }
    end

    return {
        version = VERSION,
        love = loveVersion,
        lua = jitApi and jitApi.version or _VERSION,
        loveBin = os.getenv("TECS_LOVE_BIN"),
        tecsDir = tecsDir,
        tealDir = tealDir,
        project = project,
    }
end

local function printInfo(args)
    local info = gatherInfo()

    if args and args.json then
        local json = jsonModule()
        print(json.serialize({
            version = info.version,
            love = info.love or json.NULL,
            lua = info.lua,
            loveBin = info.loveBin and luaModulePath(info.loveBin) or json.NULL,
            tecsDir = info.tecsDir and luaModulePath(info.tecsDir) or json.NULL,
            tealDir = info.tealDir and luaModulePath(info.tealDir) or json.NULL,
            project = info.project and {
                name = info.project.name,
                path = luaModulePath(info.project.path),
                built = info.project.built,
            } or json.NULL,
        }, true))
        return
    end

    print("Tecs CLI " .. info.version)
    if info.love then
        print("LÖVE " .. info.love)
    end
    print(info.lua)

    if info.project then
        print("")
        print("Project " .. info.project.name)
        print("  Path: " .. info.project.path)
        print("  Build: " .. (info.project.built and "ready" or "not built"))
        print("")
        print("Next: tecs run")
    else
        print("")
        print("Next: tecs new hello")
    end
end

--------------------------------------------------------------------------------
-- `tecs call`: a first-class MCP client for the running game's HTTP endpoint.
--
-- MCP clients read project MCP config (.mcp.json) only at session startup, so
-- the very session that scaffolds a project never has the stdio bridge tools.
-- This command gives that session the same capabilities -- tools/list plus any
-- tool call, handshake handled -- with no hand-rolled JSON-RPC client.
--------------------------------------------------------------------------------

local GAME_MCP_PORT = 19999

local function gameClient(port, timeout)
    if not isLoveCli then
        error("this command requires LÖVE; run tecs through its installed launcher", 0)
    end
    installFrameworkLoader()
    local mcpClient = require("tecs2d.testing.mcp_client")
    return mcpClient.new({port = port or GAME_MCP_PORT, timeout = timeout or 30})
end

local function noGameHint(port, err)
    return tostring(err) .. "\nNo game answering on port " .. tostring(port or GAME_MCP_PORT)
        .. ". Start it with `tecs run` (or the bridge's start_game tool) and retry."
end

function tasks.call(args)
    local json = jsonModule()
    local client = gameClient(args.port, args.timeout)

    if args.list then
        local response, err = client:rpc("tools/list", nil, args.timeout or 10)
        if not response then fail(noGameHint(args.port, err)) end
        local result = response.result or {}
        local tools = result.tools or {}
        if args.json then
            print(json.serialize(tools, true))
            return
        end
        local names = {}
        for _, t in ipairs(tools) do names[#names + 1] = t.name end
        table.sort(names)
        for _, n in ipairs(names) do print(n) end
        return
    end

    if not args.tool or args.tool == "" then
        fail("usage: tecs call <tool> ['<json-args>'] | tecs call --list")
    end
    local callArgs
    if args.args and args.args ~= "" then
        local ok, parsed = pcall(json.parse, args.args)
        if not ok or type(parsed) ~= "table" then
            fail("tool arguments must be a JSON object, e.g. "
                .. "tecs call run_lua '{\"code\":\"return 1\"}'")
        end
        callArgs = parsed
    end

    local envelope, err = client:tryCall(args.tool, callArgs, args.timeout or 30)
    if not envelope then fail(noGameHint(args.port, err)) end
    print(json.serialize(envelope, true))
    if envelope.ok == false then
        fail("tool '" .. args.tool .. "' returned an error")
    end
end

-- `tecs info --keys`: the running game's named context keys (resources by
-- name), served by cmd_resources over the same client.
local function printInfoKeys(args)
    local json = jsonModule()
    local client = gameClient(args.port, nil)
    local envelope, err = client:tryCall("cmd_resources", nil, 10)
    if not envelope then fail(noGameHint(args.port, err)) end
    if envelope.ok == false then
        fail("cmd_resources returned an error: " .. json.serialize(envelope))
    end
    local data = envelope.result or envelope
    if args.json then
        print(json.serialize({resources = data.resources, unset = data.unset}, true))
        return
    end
    print("Named resources (read one with `tecs call cmd_resources '{\"name\":\"<key>\"}'`):")
    for _, row in ipairs(data.resources or {}) do
        print("  " .. tostring(row.key) .. "  (" .. tostring(row.type) .. ")")
    end
    for _, name in ipairs(data.unset or {}) do
        print("  " .. name .. "  (registered, no value)")
    end
end

tasks.info = function(args)
    if args and args.keys then
        printInfoKeys(args)
        return
    end
    printInfo(args)
end

local commands = {
    {
        name = "info",
        summary = "Show runtime and project information",
        description = "Show CLI, Love2D, and LuaJIT versions plus current project status and a next step. "
            .. "With --keys: the running game's named context keys (resources by name).",
        action = function(args) tasks.info(args) end,
        setup = function(subcommand)
            subcommand:flag("--json", "Print runtime and project information as JSON on stdout.")
            subcommand:flag("--keys", "List the running game's named context keys (needs a running game).")
            subcommand:option("--port", "Game MCP port for --keys (default 19999)."):convert(tonumber)
        end,
    },
    {
        name = "new",
        summary = "Create a new Tecs project",
        description = "Create a new fixed-layout Tecs project from the bundled starter source.",
        action = tasks.new,
        setup = function(subcommand)
            subcommand:argument("project", "Directory to create for the new project.")
            subcommand:flag("--force",
                "Create even inside an existing Tecs project (nested projects "
                .. "detach from this project's MCP bridge).")
        end,
    },
    {
        name = "run",
        summary = "Build and run the game",
        description = "Build the project, then launch the game from build/ with the cached LÖVE runtime.",
        action = tasks.run,
    },
    {
        name = "build",
        summary = "Compile without running",
        description = "Prepare embedded dependencies, compile Teal sources, copy assets, "
            .. "and refresh build output.",
        action = tasks.build,
    },
    {
        name = "check",
        summary = "Type-check all Teal source files",
        description = "Prepare embedded dependencies and run the Teal type checker over src/.",
        action = tasks.check,
        setup = function(subcommand)
            subcommand:flag("--json", "Print diagnostics as JSON on stdout.")
        end,
    },
    {
        name = "dist",
        summary = "Package the game for distribution",
        description = "Zip the built game into a .love file, assemble a macOS app bundle, and "
            .. "fuse a Windows executable, using the cached LÖVE runtimes.",
        action = tasks.dist,
        setup = function(subcommand)
            subcommand:argument("target", "Optional target: love, macos, or windows; omit for all.")
                :choices({"love", "macos", "windows"})
                :args("?")
        end,
    },
    {
        name = "integ",
        summary = "Run project specs against the built game",
        description = "Compile spec/ and run it with the bundled busted runner; *_lovespec.tl "
            .. "specs launch the built game under real LÖVE and drive it over MCP.",
        action = tasks.integ,
    },
    {
        name = "clean",
        summary = "Remove build artifacts",
        description = "Remove build/ while leaving prepared source dependencies in place.",
        action = tasks.clean,
    },
    {
        name = "dev",
        summary = "Prepare local Tecs source for development",
        description = "Copy local Tecs/Tecs2D sources from TECS_DIR into src/vendor/ for development iteration.",
        action = tasks.dev,
    },
    {
        name = "mcp",
        summary = "Serve the project over MCP on stdio",
        description = "Run an MCP server for agent clients: check/build/integ/dist as tools, "
            .. "game lifecycle (start_game, stop_game, restart_game, game_status, game_logs), "
            .. "and a proxy to the running game's own MCP tools. Not the only way in: every "
            .. "running game embeds an HTTP MCP server; use that to attach to a game that is "
            .. "already running. The stdio bridge adds lifecycle control, toolchain tools, and "
            .. "sessions that survive restarts and crashes.",
        action = tasks.mcp,
    },
    {
        name = "agent",
        summary = "List bundled agent docs or print one's path",
        description = "List the agent guides bundled with the CLI, or write one to the user data "
            .. "directory and print its absolute path for use in agent configuration.",
        action = tasks.agent,
        setup = function(subcommand)
            subcommand:argument("action", "Either `list` or `path`.")
                :target("agentAction")
                :choices({"list", "path"})
            subcommand:argument("name", "Agent doc name, required for `path`."):args("?")
            subcommand:flag("--json", "Print the listing as JSON on stdout.")
        end,
    },
    {
        name = "docs",
        summary = "Print the framework documentation offline",
        description = "Offline mirror of the framework docs, versioned with the installed CLI. "
            .. "`tecs docs` prints the page index (a titled, described tree); `tecs docs <page>` "
            .. "prints one page by its index path (e.g. tecs2d/rendering/shapes); `tecs docs --full` "
            .. "prints every page. Prefer this over reading vendored sources under src/vendor/.",
        action = tasks.docs,
        setup = function(subcommand)
            subcommand:argument("page", "Page path to print, e.g. tecs/world; omit for the index."):args("?")
            subcommand:option("--search",
                "Search every page's content with a Lua pattern (case-insensitive); "
                .. "prints matching page ids and lines.")
            subcommand:flag("--full", "Print every page concatenated.")
            subcommand:flag("--json", "Print the page index as JSON on stdout.")
        end,
    },
    {
        name = "api",
        summary = "Look up framework and project API symbols",
        description = "Look up API symbols from the framework (always available) and your "
            .. "project's own src/ (type-checked on demand, no build or running game needed). "
            .. "`tecs api` lists modules; `tecs api <module>` lists its symbols; "
            .. "`tecs api <module>.<Type>` renders a type as a Teal record block; "
            .. "`tecs api <Type>:<method>` prints one method. Pass several symbols to look them "
            .. "all up at once. --json emits structured records; --fields <a,b,c> returns only "
            .. "those keys to save tokens.",
        action = tasks.api,
        setup = function(subcommand)
            subcommand:argument("query",
                "Symbol address(es): module, module.Type, Type:method, or a bare symbol.")
                :args("*")
            subcommand:flag("--json", "Emit structured records as JSON on stdout.")
            subcommand:option("--fields",
                "Comma-separated record keys to return, e.g. signature,doc,methods. "
                .. "`--fields constructor` prints just a component's constructor signature.")
        end,
    },
    {
        name = "call",
        summary = "Call an MCP tool on the running game",
        description = "Call one of the running game's MCP tools over its local HTTP endpoint "
            .. "(no bridge or client config needed; the handshake is handled for you). "
            .. "`tecs call --list` names every available tool; then e.g. "
            .. "`tecs call cmd_fetch '{\"expr\":\"Transform\"}'` or "
            .. "`tecs call run_lua '{\"code\":\"return world:count()\"}'`. Prints the JSON "
            .. "result envelope. The game must be running (`tecs run`).",
        action = tasks.call,
        setup = function(subcommand)
            subcommand:argument("tool", "Tool name (see --list).")
                :args("?")
            subcommand:argument("args", "Tool arguments as one JSON object.")
                :args("?")
            subcommand:flag("--list", "List the running game's tools.")
            subcommand:flag("--json", "With --list, print full tool records as JSON.")
            subcommand:option("--port", "Game MCP port (default 19999)."):convert(tonumber)
            subcommand:option("--timeout", "Seconds to wait for the response (default 30).")
                :convert(tonumber)
        end,
    },
    {
        name = "completions",
        summary = "Print a shell completion script",
        description = "Print a completion script for the given shell. bash: eval it from ~/.bashrc; "
            .. "zsh: write it to a file named _tecs on your fpath; "
            .. "fish: write it to ~/.config/fish/completions/tecs.fish.",
        action = tasks.completions,
        setup = function(subcommand)
            subcommand:argument("shell", "Target shell."):choices({"bash", "zsh", "fish"})
        end,
    },
}

local cliParser = require("tecs_cli.cliParser").new({
    argparse = argparse,
    color = color,
    commands = commands,
    version = VERSION,
})
local commandNames = cliParser.commandNames
local printHelp = cliParser.printHelp
parser = cliParser.create

function M.run(argv)
    argv = argv or {}
    local ok, err = pcall(function()
        if #argv == 1 and (argv[1] == "-h" or argv[1] == "--help") then
            printHelp()
            return
        end

        local ok, args = parser():pparse(argv)
        if not ok then
            fail(args)
        end
        quiet = args.quiet or false
        if args.version then
            print(VERSION)
            return
        end

        local target = args.command or "help"
        if target == "help" then
            printHelp()
            return
        end

        local task = tasks[target]
        if not task then
            fail("unknown command '" .. tostring(target) .. "'. Expected one of: " .. commandNames())
        end

        task(args)
    end)
    if not ok then
        if type(err) == "table" and err.tecsExit then
            return false, err.message
        end
        return false, tostring(err)
    end
    return true
end

function M.main(argv)
    local ok, err = M.run(argv)
    if not ok then
        io.stderr:write(color("red bright", "error: ") .. tostring(err) .. "\n")
        os.exit(1)
    end
end

-- Test-only access to internal helpers; see spec/cli_spec.lua. setPlatform
-- lets specs exercise other platforms' path handling on any host.
M._internal = {
    detectPlatform = detectPlatform,
    setPlatform = setPlatform,
    normalize = normalize,
    pathJoin = pathJoin,
    pathFromBuild = pathFromBuild,
    dirname = dirname,
    relativeTo = relativeTo,
    shouldExclude = shouldExclude,
    needsUpdate = needsUpdate,
    copyDir = copyDir,
    pruneRuntimeVendor = pruneRuntimeVendor,
    q = q,
    setDataDir = function(path) dataDirOverride = path end,
    listAgentDocs = listAgentDocs,
    agentDocDescription = agentDocDescription,
    attachRemediation = attachRemediation,
    jsonModule = jsonModule,
    apiInvoke = apiInvoke,
    distName = distName,
    patchPlist = patchPlist,
    buildinfoLua = buildinfoLua,
}

return M

-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local haveLfs, lfs = pcall(require, "lfs")

local VERSION = "0.10.8-dev"
local isLoveCli = rawget(_G, "TECS_LOVE_CLI") == true
local loveApi = rawget(_G, "love")

-- Platform traits detected from the OS path separator. Held in mutable locals
-- so specs can substitute another platform via M._internal.setPlatform.
local sep, isMsys, isWindows

local function detectPlatform()
    local hostSep = package.config:sub(1, 1)
    local msys = os.getenv("MSYSTEM") ~= nil
    local separator = msys and "/" or hostSep
    return {
        sep = separator,
        isMsys = msys,
        isWindows = separator == "\\" and not msys,
    }
end

local function setPlatform(platform)
    sep = platform.sep
    isMsys = platform.isMsys or false
    isWindows = platform.isWindows or false
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

local function requireLfs()
    if not haveLfs then
        error("filesystem adapter unavailable; run tecs through its installed launcher", 0)
    end
    return lfs
end

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
local function q(path)
    path = tostring(path)
    if isWindows then
        return '"' .. path:gsub('"', '""') .. '"'
    end
    return '"' .. path:gsub('"', '\\"') .. '"'
end

local function sourcePath()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        return source:sub(2)
    end
    return nil
end

-- Convert path separators to the current platform's convention.
local function normalize(path)
    if isWindows then
        return (path:gsub("/", "\\"))
    end
    path = path:gsub("\\", "/")
    if isMsys then
        path = path:gsub("^(%a):", function(drive)
            return "/" .. drive:lower()
        end)
    end
    return path
end

-- Path spelling for Lua module search: forward slashes work for every tool we
-- invoke, including Windows Lua, so just flip backslashes.
local function luaModulePath(path)
    path = tostring(path):gsub("\\", "/")
    return path
end

-- Join path segments, collapsing extra separators while preserving an
-- absolute prefix (leading "/" on unix or a drive letter on Windows).
local function pathJoin(...)
    local parts = {...}
    local out = {}
    for i = 1, #parts do
        local part = tostring(parts[i])
        local unixAbs = i == 1 and part:match("^/")
        part = part:gsub("[/\\]+$", "")
        if not unixAbs then
            part = part:gsub("^[/\\]+", "")
        end
        if i == 1 and (part:match("^%a:[/\\]") or unixAbs) then
            part = parts[i]:gsub("[/\\]+$", "")
        end
        if part ~= "" then out[#out + 1] = part end
    end
    return normalize(table.concat(out, sep))
end

-- Resolve an executable path after the run command changes into build/.
local function pathFromBuild(path)
    path = normalize(path)
    if path:match("^%a:[/\\]") or path:match("^[/\\]") then return path end
    return pathJoin("..", path)
end

local HOT_RELOAD_STAMP = pathJoin("build", ".tecs-reload-stamp")

-- Directory portion of a path, or "." when there is no parent.
local function dirname(path)
    local dir = normalize(path):gsub("[/\\][^/\\]+$", "")
    if dir == path then return "." end
    if dir == "" then return "." end
    return dir
end

local function basename(path)
    return normalize(path):match("[^/\\]+$") or normalize(path)
end

-- True if a file or directory exists.
local function exists(path)
    return requireLfs().attributes(normalize(path)) ~= nil
end

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

local function mkdir(path)
    path = normalize(path)
    if exists(path) then return end
    local current = ""
    if path:match("^%a:[/\\]") then
        current = path:sub(1, 2)
        path = path:sub(4)
    elseif path:match("^[/\\]") then
        current = sep
        path = path:gsub("^[/\\]+", "")
    end
    for part in path:gmatch("[^/\\]+") do
        if current == "" then
            current = part
        elseif current == sep then
            current = sep .. part
        else
            current = pathJoin(current, part)
        end
        if not exists(current) then
            local ok, err = requireLfs().mkdir(current)
            if not ok and not exists(current) then
                error("could not create directory " .. current .. ": " .. tostring(err), 0)
            end
        end
    end
end

local function writeFile(path, content)
    mkdir(dirname(path))
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function isDir(path)
    return requireLfs().attributes(normalize(path), "mode") == "directory"
end

local function isEmptyDir(path)
    if not isDir(path) then return false end
    for entry in requireLfs().dir(normalize(path)) do
        if entry ~= "." and entry ~= ".." then
            return false
        end
    end
    return true
end

local function remove(path)
    path = normalize(path)
    if not exists(path) then return end
    local mode = requireLfs().attributes(path, "mode")
    if mode == "directory" then
        for entry in requireLfs().dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove(pathJoin(path, entry))
            end
        end
        local ok, err = requireLfs().rmdir(path)
        if not ok then
            error("could not remove directory " .. path .. ": " .. tostring(err), 0)
        end
    else
        local ok, err = os.remove(path)
        if not ok then
            error("could not remove file " .. path .. ": " .. tostring(err), 0)
        end
    end
end

-- Escape a string for safe use as a literal inside a Lua pattern.
local function patternEscape(s)
    return (s:gsub("([^%w])", "%%%1"))
end

local function shouldExclude(rel, exclude)
    if not exclude then return false end
    for _, pattern in ipairs(exclude) do
        if rel == pattern or rel:match("^" .. patternEscape(pattern) .. "[/\\]") then
            return true
        end
        local suffix = pattern:match("^%*%.(.+)$")
        if suffix and rel:match("%." .. patternEscape(suffix) .. "$") then
            return true
        end
    end
    return false
end

local function copyFile(src, dst)
    mkdir(dirname(dst))
    local input = assert(io.open(src, "rb"))
    local content = input:read("*a")
    input:close()
    local output = assert(io.open(dst, "wb"))
    output:write(content)
    output:close()
end

local function walkFiles(dir, out)
    dir = normalize(dir)
    out = out or {}
    local attr = requireLfs().attributes(dir)
    if not attr then return out end
    if attr.mode ~= "directory" then
        out[#out + 1] = dir
        return out
    end
    for entry in requireLfs().dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = pathJoin(dir, entry)
            local mode = requireLfs().attributes(path, "mode")
            if mode == "directory" then
                walkFiles(path, out)
            elseif mode == "file" then
                out[#out + 1] = path
            end
        end
    end
    return out
end

local function relativeTo(path, base)
    path = normalize(path)
    base = normalize(base):gsub("[/\\]+$", "")
    local prefix = patternEscape(base) .. "[/\\]?"
    return path:gsub("^" .. prefix, "")
end

-- Mirror src into dst, deleting stale files in dst.
local function copyDir(src, dst, exclude)
    src = normalize(src)
    dst = normalize(dst)
    mkdir(dst)
    local seen = {}
    for _, file in ipairs(walkFiles(src, {})) do
        local rel = relativeTo(file, src)
        if not shouldExclude(rel, exclude) then
            local target = pathJoin(dst, rel)
            copyFile(file, target)
            seen[normalize(target)] = true
        end
    end
    for _, file in ipairs(walkFiles(dst, {})) do
        local rel = relativeTo(file, dst)
        if shouldExclude(rel, exclude) or not seen[normalize(file)] then
            remove(file)
        end
    end
end

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

-- First non-heading paragraph line of a doc, used as its list description.
local function agentDocDescription(content)
    for line in content:gmatch("[^\r\n]+") do
        if not line:match("^#") and line:match("%S") then
            return (line:gsub("^%s+", ""):gsub("%s+$", ""))
        end
    end
    return ""
end

-- Bundled Markdown docs as {name, content}, sorted by name, read from a
-- subdirectory under tecs_cli/ (e.g. "agents" or "docs") in both the LÖVE
-- payload and the source tree. `label` is used only in the read-error message.
local function listBundledDocs(subdir, label)
    local docs = {}
    if isLoveCli and loveApi then
        for _, entry in ipairs(loveApi.filesystem.getDirectoryItems("tecs_cli/" .. subdir)) do
            local name = entry:match("^(.+)%.md$")
            if name then
                local content, err = loveApi.filesystem.read("tecs_cli/" .. subdir .. "/" .. entry)
                if not content then
                    error("could not read embedded " .. label .. " " .. entry .. ": " .. tostring(err), 0)
                end
                docs[#docs + 1] = {name = name, content = content}
            end
        end
    else
        local modulePath = sourcePath()
        local dir = modulePath and pathJoin(dirname(modulePath), subdir)
        if dir and isDir(dir) then
            for _, file in ipairs(walkFiles(dir, {})) do
                local name = basename(file):match("^(.+)%.md$")
                if name then
                    local handle = assert(io.open(file, "rb"))
                    local content = handle:read("*a")
                    handle:close()
                    docs[#docs + 1] = {name = name, content = content}
                end
            end
        end
    end
    table.sort(docs, function(a, b) return a.name < b.name end)
    return docs
end

local function listAgentDocs()
    return listBundledDocs("agents", "agent doc")
end

-- The `docs` command serves an offline mirror of the framework documentation:
-- llms.txt (the titled, described page index) and llms-full.txt (every page).
-- Both are generated from the Tecs docs by `scripts/gen-docs-bundle.sh` into
-- tecs_cli/docs/ (gitignored) and vendored into the payload by build_love.sh, so
-- reads resolve to the same tecs_cli/docs/ path in a source tree and in the .love.
local function readDocBundle(name)
    if isLoveCli and loveApi then
        local content, err = loveApi.filesystem.read("tecs_cli/docs/" .. name)
        if not content then
            error("could not read bundled doc " .. name .. ": " .. tostring(err), 0)
        end
        return content
    end
    local modulePath = sourcePath()
    local path = modulePath and pathJoin(dirname(modulePath), "docs", name)
    local handle = path and io.open(path, "rb")
    if not handle then
        error("docs bundle missing; run `scripts/gen-docs-bundle.sh` (needs a Tecs checkout and Node)", 0)
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

-- Split llms-full.txt into { url = pageMarkdown } by the per-page
-- `---\nurl: /path.md\n...` frontmatter markers the docs build emits.
local function docPagesByUrl(full)
    local marks = {}
    local init = 1
    while true do
        local s, e, url = full:find("\n?%-%-%-\nurl:%s*([^\n]+)\n", init)
        if not s then break end
        marks[#marks + 1] = {start = s, url = (url:gsub("%s+$", ""))}
        init = e + 1
    end
    local pages = {}
    for i = 1, #marks do
        local stop = (marks[i + 1] and marks[i + 1].start - 1) or #full
        pages[marks[i].url] = (full:sub(marks[i].start, stop):gsub("^\n", ""))
    end
    return pages
end

-- Modification time of a path (platform-specific units), or 0 if it is missing.
local function fileMtime(path)
    path = normalize(path)
    local mtime = requireLfs().attributes(path, "modification")
    return tonumber(mtime) or 0
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
    return normalize(requireLfs().currentdir() or ".")
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

-- Type-check sources through the Teal compiler API and return ok plus a flat
-- diagnostic list, instead of tlcli's human-readable report. Mirrors tlcli's
-- Love2D events are re-exported from tecs2d as TYPES; passing one as a value
-- (e.g. world:observe(0, tecs2d.MousePressed, ...)) fails to type-check. Used to
-- attach a remediation hint to exactly that diagnostic.
local EVENT_EXPORTS = {
    Quit = true, KeyPressed = true, KeyReleased = true, MousePressed = true,
    MouseReleased = true, MouseMoved = true, WheelMoved = true,
    JoystickAdded = true, JoystickRemoved = true, DirectoryDropped = true,
    FileDropped = true, Focus = true, MouseFocus = true, Resize = true,
    Visible = true, Exposed = true, Occluded = true, LocaleChanged = true,
    ThemeChanged = true, DropBegan = true, DropMoved = true, DropCompleted = true,
    AudioDisconnected = true, SensorUpdated = true, JoystickSensorUpdated = true,
    TouchPressed = true, TouchMoved = true, TouchReleased = true,
}

local function nthLine(path, n)
    local file = io.open(path, "rb")
    if not file then return nil end
    local i = 0
    for text in file:lines() do
        i = i + 1
        if i == n then file:close(); return text end
    end
    file:close()
    return nil
end

-- Framework aliases that are directly usable as `tecs api` module addresses.
local API_HINT_MODULES = {
    tecs = true, tecs2d = true, gfx = true, input = true, events = true,
}

-- Primitive type names that never resolve to an API symbol, so an invalid-key
-- diagnostic against one gets no `tecs api` hint.
local API_HINT_PRIMITIVES = {
    number = true, integer = true, string = true, boolean = true, table = true,
    thread = true, userdata = true, ["function"] = true, ["nil"] = true,
    any = true, nominal = true,
}

-- Derive a `tecs api` address from the target of a failing call, or nil when
-- the target does not look like a framework or project symbol (locals, Lua
-- stdlib). `receiver:method` is already an api address; `world.getMut` becomes
-- the method form; a known module alias keeps its dotted address; otherwise a
-- capitalized name (a constructor like Health or gfx.Rectangle's last segment)
-- resolves as a bare symbol, project tier first.
local function apiAddressForCall(target)
    if target:find(":", 1, true) then return target end
    local first, rest = target:match("^([%a_][%w_]*)%.([%w_%.]+)$")
    if first then
        if first == "world" and not rest:find(".", 1, true) then
            return "world:" .. rest
        end
        if API_HINT_MODULES[first] then return target end
        local last = rest:match("([%w_]+)$")
        if last and last:match("^%u") then return last end
        return nil
    end
    if target:match("^%u") then return target end
    return nil
end

-- Derive a `tecs api` address from a type name in a Teal error message.
local function apiAddressForType(typeName)
    local last = typeName:match("([%w_]+)$")
    if not last or API_HINT_PRIMITIVES[last:lower()] then return nil end
    return last
end

-- The call expression a diagnostic points into: the identifier chain of the
-- call starting closest to (at or before) the diagnostic column, falling back
-- to the line's first call.
local function callTargetAt(lineText, column)
    local best
    local init = 1
    while true do
        local s, e, name = lineText:find("([%a_][%w_%.:]*)%s*%(", init)
        if not s then break end
        if not best or s <= column then best = name end
        init = e + 1
    end
    return best
end

-- Attach {hint, docs} remediation to diagnostics whose fix is well known, so an
-- agent gets a fix at the moment of the error instead of only if it pre-read the
-- right page. The same diagnostics flow through the MCP `check` tool, so this
-- covers CLI and MCP agents. Matchers must be zero-false-positive: match the
-- exact message and verify the offending source token.
local function attachRemediation(diagnostics)
    for _, d in ipairs(diagnostics) do
        if d.kind == "type"
            and d.message:find("type definition as a concrete value", 1, true) then
            local line = nthLine(d.file, d.line)
            local event = line and line:match("tecs2d%.(%u[%w]*)")
            if event and EVENT_EXPORTS[event] then
                d.hint = "Love2D events are exported as types; pass the value: "
                    .. 'local events = require("tecs2d.events") -- then events.'
                    .. event .. " as the observe argument."
                d.docs = "tecs2d/events"
            end
        end

        -- Unknown field or method: the message names the record type, which is
        -- exactly what `tecs api` renders. Anchored patterns keep this off
        -- structural types (maps, generics), whose names would not resolve.
        if not d.hint and d.kind == "type" then
            local key, typeName =
                d.message:match("^invalid key '([%w_]+)' in .- type ([%w_%.]+)$")
            if not key then
                key, typeName =
                    d.message:match("^cannot index key '([%w_]+)' in .- type ([%w_%.]+)$")
            end
            local addr = typeName and apiAddressForType(typeName)
            if key and addr then
                d.hint = "'" .. key .. "' does not exist on " .. typeName
                    .. ". Run `tecs api " .. addr
                    .. "` (CLI or the MCP api tool) for its real fields and signatures."
            end
        end

        -- Indexing with a non-integer number: the fix is always the same on
        -- the LuaJIT/5.1 target (no // operator), so say it outright.
        if not d.hint and d.kind == "type"
            and (d.message:match("^cannot index object of type .* with number$")
                or d.message:match("^wrong index type: got number, expected integer$")) then
            d.hint = "Lua array indexes must be integers and this target has no `//`: "
                .. "wrap the index expression in math.floor(...)."
        end

        -- Wrong arity or argument type: the message does not name the callee,
        -- so read it off the offending source line and point `tecs api` at it.
        if not d.hint and d.kind == "type"
            and (d.message:match("^wrong number of arguments %(given ")
                or d.message:match("^argument %d+: ")) then
            local line = nthLine(d.file, d.line)
            local target = line and callTargetAt(line, d.column)
            local addr = target and apiAddressForCall(target)
            if addr then
                d.hint = "Verify the exact signature: `tecs api " .. addr
                    .. "` (CLI or the MCP api tool)."
            end
        end
    end
end

-- rules: syntax errors suppress a file's other diagnostics, disabled warnings
-- are dropped, and warnings promoted by warning_error fail the check.
local function collectCheckDiagnostics(sources)
    local diagnostics = {}
    local checkOk = true

    local function add(err, severity, diagKind)
        diagnostics[#diagnostics + 1] = {
            file = luaModulePath(err.filename or ""),
            line = tonumber(err.y) or 0,
            column = tonumber(err.x) or 0,
            severity = severity,
            kind = diagKind,
            message = err.msg or "",
        }
        if err.tag then
            diagnostics[#diagnostics].tag = err.tag
        end
    end

    local code = withTealEnv(function()
        local configuration = require("tlcli.configuration")
        local driver = require("tlcli.driver")
        local tlconfig = configuration.get()
        configuration.merge_config_and_args(tlconfig, {include_dir = {}})
        local compiler = driver.setup_compiler(tlconfig)

        for _, source in ipairs(sources) do
            local _, _, err = driver.process_module(compiler, source)
            if err then
                checkOk = false
                add({filename = source, msg = err}, "error", "load")
            end
        end

        for name in compiler:loaded_files() do
            local _, errs = compiler:recall(name)
            if errs then
                if errs.syntax_errors and #errs.syntax_errors > 0 then
                    checkOk = false
                    for _, err in ipairs(errs.syntax_errors) do
                        add(err, "error", "syntax")
                    end
                else
                    for _, err in ipairs(errs.type_errors or {}) do
                        checkOk = false
                        add(err, "error", "type")
                    end
                    for _, warning in ipairs(errs.warnings or {}) do
                        if not tlconfig._disabled_warnings_set[warning.tag] then
                            if tlconfig._warning_errors_set[warning.tag] then
                                checkOk = false
                                add(warning, "error", "type")
                            else
                                add(warning, "warning", "warning")
                            end
                        end
                    end
                end
            end
        end
    end)
    if code ~= 0 then
        error("Teal failed with exit code " .. tostring(code), 0)
    end

    attachRemediation(diagnostics)
    table.sort(diagnostics, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        if a.line ~= b.line then return a.line < b.line end
        if a.column ~= b.column then return a.column < b.column end
        return a.message < b.message
    end)
    return checkOk, diagnostics
end

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
    for entry in requireLfs().dir("build") do
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
--------------------------------------------------------------------------------
-- `tecs api`: symbol lookup over a type index.
--
-- Two tiers, merged at query time:
--   * the framework tier -- generated at runtime by running the bundled apidocs
--     extractor over the framework's public modules (staged by ensureVendor,
--     exactly like `check`), then cached at the user level keyed by the CLI
--     version (api-framework-index-<VERSION>.json). A cache hit is instant with
--     no type-check; nothing is committed or bundled as a prebuilt index.
--   * a dynamic project overlay -- the same extractor run over the project's own
--     src/, cached under build/api-index.json keyed by the Teal source mtimes
--     and rebuilt when stale. Degrades gracefully: an unrelated type error never
--     fails a lookup.
--
-- Both tiers need no build and no running game. The same core backs the CLI
-- command and the MCP `api` tool (buildMcpContext exposes apiInvoke as ctx.api);
-- there is one resolver, one renderer.
--------------------------------------------------------------------------------

-- The framework's public modules, as apidocs specs. `file` is src-relative; the
-- runtime generator remaps it onto the vendored framework tree (or the Tecs
-- checkout in source mode). The extractor documents each module's full public
-- surface and derives per-type method receivers.
local FRAMEWORK_API_MODULES = {
    { module = "tecs",          file = "src/tecs/init.tl",      prefix = "tecs." },
    { module = "tecs.types",    file = "src/tecs/types.tl" },
    -- The public require path is tecs.builtins (re-exported from init.tl);
    -- the extractor needs the defining file. Transform is the first component
    -- every agent looks up, so this module must resolve.
    { module = "tecs.builtins", file = "src/tecs/internal/builtins.tl" },
    { module = "tecs2d",        file = "src/tecs2d/init.tl",    prefix = "tecs2d." },
    { module = "tecs2d.gfx",    file = "src/tecs2d/gfx/init.tl", prefix = "gfx." },
    { module = "tecs2d.input",  file = "src/tecs2d/input.tl",   prefix = "input." },
    { module = "tecs2d.events", file = "src/tecs2d/events.tl",  prefix = "events." },
}

-- Load the bundled apidocs extractor (tecs_cli/apidocs.lua). Requires the Teal
-- compiler modules, so loadTealApi() runs first to put them on the search path.
local apidocsModule
local function loadApidocs()
    if apidocsModule then return apidocsModule end
    loadTealApi()
    local chunk
    if isLoveCli and loveApi then
        local src = loveApi.filesystem.read("tecs_cli/apidocs.lua")
        if not src then error("bundled apidocs.lua missing from payload", 0) end
        chunk = assert(loadstring(src, "@tecs_cli/apidocs.lua"))
    else
        local modulePath = sourcePath()
        local p = modulePath and pathJoin(dirname(modulePath), "apidocs.lua")
        local fh = p and io.open(normalize(p), "rb")
        if not fh then
            error("tecs_cli/apidocs.lua not found next to cli.lua", 0)
        end
        local src = fh:read("*a"); fh:close()
        chunk = assert(loadstring(src, "@" .. luaModulePath(p)))
    end
    apidocsModule = chunk()
    return apidocsModule
end

-- Stage the framework sources and type declarations into a scratch tree under
-- the user data dir. Used when `tecs api` runs outside a project, so a
-- framework-tier build never writes src/vendor into an arbitrary cwd.
local function stageFrameworkScratch()
    local root = pathJoin(userDataDir(), "api-framework-src")
    -- Start clean so files deleted from a newer framework never linger.
    remove(root)
    mkdir(root)
    if tecsDir then
        copyDir(pathJoin(tecsDir, "src/tecs"), pathJoin(root, "tecs"))
        copyDir(pathJoin(tecsDir, "src/tecs2d"), pathJoin(root, "tecs2d"))
    else
        copyLoveDir("payload/framework/tecs", pathJoin(root, "tecs"))
        copyLoveDir("payload/framework/tecs2d", pathJoin(root, "tecs2d"))
    end
    copyLoveDir("payload/types", root)
    return root
end

-- The root under which the framework's Teal sources live. Inside a project the
-- vendored tree staged by ensureVendor is reused (exactly as `check` does);
-- outside one the payload is staged under the user data dir instead. nil when
-- neither the payload nor a Tecs checkout is available.
local function apiFrameworkRoot()
    if isLoveCli then
        if exists("tlconfig.lua") then
            ensureVendor()
            return vendorLua
        end
        return stageFrameworkScratch()
    elseif tecsDir then
        return pathJoin(tecsDir, "src")
    end
    return nil
end

-- Package.path roots that make the framework and its type declarations
-- resolvable while the extractor type-checks a module set. `frameworkRoot` is
-- wherever apiFrameworkRoot found (or staged) the framework; a source checkout
-- additionally needs the CLI's own runtime type declarations.
local function apiSearchRoots(frameworkRoot)
    local roots = {}
    if frameworkRoot then roots[#roots + 1] = frameworkRoot end
    if not isLoveCli then
        local modulePath = sourcePath()
        if modulePath then
            local rt = pathJoin(dirname(modulePath), "runtime/types")
            if isDir(rt) then roots[#roots + 1] = rt end
        end
    end
    return roots
end

-- Run the vendored extractor over `specs` with the framework rooted at
-- `frameworkRoot` on the search path. Shared by the framework tier and the
-- project overlay.
local function buildApiIndex(specs, frameworkRoot)
    local apidocs = loadApidocs()
    local roots = apiSearchRoots(frameworkRoot)

    local templates = { "src/?.lua", "src/?/init.lua" }
    for _, root in ipairs(roots) do
        local base = luaModulePath(root)
        templates[#templates + 1] = base .. "/?.lua"
        templates[#templates + 1] = base .. "/?/init.lua"
        templates[#templates + 1] = base .. "/?.tl"
        templates[#templates + 1] = base .. "/?/init.tl"
    end

    local previousPath = package.path
    package.path = table.concat(templates, ";") .. ";" .. previousPath
    local ok, result = pcall(function()
        return apidocs.build_index({ modules = specs, tolerant = true })
    end)
    package.path = previousPath
    if not ok then error(result, 0) end
    return result
end

-- Framework module specs with `file` remapped onto `root`.
local function frameworkModuleSpecs(root)
    local specs = {}
    for _, m in ipairs(FRAMEWORK_API_MODULES) do
        local rel = m.file:gsub("^src/", "")
        specs[#specs + 1] = { module = m.module, prefix = m.prefix,
            file = pathJoin(root, rel) }
    end
    return specs
end

-- Every buildable project module as an apidocs spec: module name derived from
-- the path under src/ (foo/init.tl -> "foo", bar/baz.tl -> "bar.baz").
local function projectModuleSpecs()
    local specs = {}
    for _, src in ipairs(listTealSources()) do
        local n = normalize(src)
        local rel = n:gsub("^src[/\\]", ""):gsub("%.tl$", "")
        rel = rel:gsub("[/\\]init$", "")
        local module = rel:gsub("[/\\]", ".")
        if module ~= "" then
            specs[#specs + 1] = { module = module, file = n }
        end
    end
    return specs
end

-- Run the extractor over the project. Returns the structured overlay index.
-- Only called inside a project, where the project's own vendored tree (staged
-- by ensureVendor, and also carrying any extra rocks the project vendored) is
-- the right resolver root for its sources.
local function buildProjectOverlay()
    local root
    if isLoveCli then
        ensureVendor()
        root = vendorLua
    elseif tecsDir then
        root = pathJoin(tecsDir, "src")
    end
    return buildApiIndex(projectModuleSpecs(), root)
end

-- With a local framework checkout (TECS_DIR) the framework sources can change
-- without the CLI version changing, so the framework cache is additionally
-- keyed by their paths + mtimes. nil for the payload framework, which is
-- invariant per CLI version.
local function frameworkSourceSignature()
    if not tecsDir then return nil end
    local parts = {}
    for _, f in ipairs(listFiles(pathJoin(tecsDir, "src"), ".tl")) do
        local n = normalize(f)
        parts[#parts + 1] = n .. ":" .. tostring(fileMtime(n))
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- The runtime framework tier: served from a user-level cache keyed by the CLI
-- version (plus the checkout signature under TECS_DIR), or generated
-- (type-checked once) and cached on a miss. Returns the index and an optional
-- note (set when generation failed or was incomplete).
local function frameworkApiIndex()
    local cachePath = pathJoin(userDataDir(), "api-framework-index-" .. VERSION .. ".json")
    local sig = frameworkSourceSignature()

    local fh = io.open(normalize(cachePath), "rb")
    if fh then
        local data = fh:read("*a"); fh:close()
        local ok, parsed = pcall(jsonModule().parse, data)
        if ok and type(parsed) == "table" and type(parsed.symbols) == "table"
            and type(parsed.modules) == "table" and parsed.signature == sig then
            return parsed, nil
        end
    end

    local ok, index = pcall(function()
        local root = apiFrameworkRoot()
        if not root then
            error("framework sources unavailable (set TECS_DIR or run through the launcher)", 0)
        end
        return buildApiIndex(frameworkModuleSpecs(root), root)
    end)
    if not ok then
        return { symbols = {}, modules = {} },
            "framework API index unavailable (" .. tostring(index) .. ")"
    end

    -- A framework module failing to extract is a packaging (or checkout) bug:
    -- serve what resolved, say so, and skip the cache so a fixed framework is
    -- picked up on the next run.
    if index.errors and #index.errors > 0 then
        return index, "framework API index incomplete ("
            .. index.errors[1].module .. ": " .. tostring(index.errors[1].error) .. ")"
    end

    pcall(function()
        mkdir(dirname(cachePath))
        local out = io.open(normalize(cachePath), "wb")
        if out then
            out:write(jsonModule().serialize({
                symbols = index.symbols, modules = index.modules, signature = sig,
            }))
            out:close()
        end
    end)
    return index, nil
end

-- A signature of the project's Teal source set (paths + mtimes) so the overlay
-- cache invalidates when any source changes.
local function projectSourceSignature()
    local parts = {}
    for _, src in ipairs(listTealSources()) do
        local n = normalize(src)
        parts[#parts + 1] = n .. ":" .. tostring(fileMtime(n))
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- The user-facing caveat when some project modules were skipped. Extraction
-- only fails on syntax errors or a crashed check -- plain type errors do not
-- block a module's symbols -- so this fires for genuinely unreadable modules.
local function overlayDegradedNote(overlay)
    if overlay.errors and #overlay.errors > 0 then
        return "some project modules could not be analyzed; their symbols may be missing"
    end
    return nil
end

-- Read the cached overlay if fresh, else rebuild and cache. Returns the overlay
-- index and an optional note (set when the build failed or was degraded, on
-- cache hits too, so a lookup still serves the framework tier).
local function cachedProjectOverlay()
    local cachePath = pathJoin("build", "api-index.json")
    local sig = projectSourceSignature()

    local fh = io.open(normalize(cachePath), "rb")
    if fh then
        local data = fh:read("*a"); fh:close()
        local ok, parsed = pcall(jsonModule().parse, data)
        if ok and type(parsed) == "table" and parsed.signature == sig
            and type(parsed.index) == "table" then
            return parsed.index, overlayDegradedNote(parsed.index)
        end
    end

    local ok, overlay = pcall(buildProjectOverlay)
    if not ok then
        return { symbols = {}, modules = {} },
            "project overlay unavailable (" .. tostring(overlay)
                .. "); serving the framework tier only"
    end

    pcall(function()
        mkdir(dirname(cachePath))
        local out = io.open(normalize(cachePath), "wb")
        if out then
            out:write(jsonModule().serialize({ signature = sig, index = overlay }))
            out:close()
        end
    end)

    return overlay, overlayDegradedNote(overlay)
end

-- Merge the framework tier (base) with the project overlay. The overlay adds
-- and overrides by (module, symbol). Returns the merged index, an optional
-- note, and the framework/project module-name sets (for grouped listing).
local function mergedApiIndex()
    local base, baseNote = frameworkApiIndex()
    local frameworkMods = {}
    for m in pairs(base.modules or {}) do frameworkMods[m] = true end

    local overlay, overlayNote
    if exists("tlconfig.lua") and isDir("src") then
        overlay, overlayNote = cachedProjectOverlay()
    end
    local notes = {}
    if baseNote then notes[#notes + 1] = baseNote end
    if overlayNote then notes[#notes + 1] = overlayNote end
    local note = #notes > 0 and table.concat(notes, "; ") or nil

    -- Project symbols come first so a bare-name lookup that matches both tiers
    -- resolves to the project's own symbol; the first entry per (module,
    -- symbol) key wins, which also lets the overlay override the base.
    local symbols = {}
    local byKey = {}
    local function add(sym)
        local key = sym.module .. "\0" .. sym.symbol
        if not byKey[key] then
            byKey[key] = true
            symbols[#symbols + 1] = sym
        end
    end

    local modules = {}
    for m, names in pairs(base.modules or {}) do modules[m] = names end

    local projectMods = {}
    if overlay then
        for _, s in ipairs(overlay.symbols or {}) do add(s) end
        for m, names in pairs(overlay.modules or {}) do
            modules[m] = names
            if not frameworkMods[m] then projectMods[m] = true end
        end
    end
    for _, s in ipairs(base.symbols or {}) do add(s) end

    return { symbols = symbols, modules = modules }, note, frameworkMods, projectMods
end

----------------------------------------------------------------------
-- Resolution
----------------------------------------------------------------------

local function apiFindSymbol(index, moduleName, symbolName)
    for _, s in ipairs(index.symbols) do
        if s.module == moduleName and s.symbol == symbolName then return s end
    end
    return nil
end

-- Resolve a module name or short alias (last dotted segment) to its canonical
-- name. Returns the name, or nil (with a list of ambiguous matches when a short
-- alias is shared by more than one module).
local function apiResolveModule(index, name)
    if index.modules[name] then return name end
    local matches = {}
    for m in pairs(index.modules) do
        if m:match("[^.]+$") == name then matches[#matches + 1] = m end
    end
    if #matches == 1 then return matches[1] end
    return nil, matches
end

-- Symbols matching a bare name, by symbol name or record receiver (so `world`
-- finds the World record whose receiver is "world"). Case-insensitive fallback.
local function apiFindByName(index, name)
    local exact, ci = {}, {}
    local lname = name:lower()
    for _, s in ipairs(index.symbols) do
        if s.symbol == name or s.receiver == name then
            exact[#exact + 1] = s
        elseif s.symbol:lower() == lname or (s.receiver and s.receiver:lower() == lname) then
            ci[#ci + 1] = s
        end
    end
    if #exact > 0 then return exact end
    return ci
end

local function apiFindMethod(sym, method)
    for _, m in ipairs(sym.methods or {}) do
        if m.name == method then return m end
    end
    return nil
end

-- Levenshtein distance, for did-you-mean ranking.
local function apiEditDistance(a, b)
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local ai = a:byte(i)
        for j = 1, lb do
            local cost = (ai == b:byte(j)) and 0 or 1
            local del, ins, sub = prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost
            local m = del < ins and del or ins
            cur[j] = m < sub and m or sub
        end
        for j = 0, lb do prev[j] = cur[j] end
    end
    return prev[lb]
end

-- Up to three closest candidates to `target`, ranked by edit distance. A
-- candidate is a plain string, or {name, display} to match on `name` but
-- report `display` -- a fully addressable form like `tecs2d.gfx.Rectangle` or
-- `world:getMut`, so a suggestion can be reused verbatim as the next query.
local function apiSuggest(target, candidates)
    local scored = {}
    local lt = target:lower()
    for _, c in ipairs(candidates) do
        local name = type(c) == "table" and c.name or c
        local display = type(c) == "table" and c.display or c
        scored[#scored + 1] = { display = display, d = apiEditDistance(lt, name:lower()) }
    end
    table.sort(scored, function(x, y)
        if x.d ~= y.d then return x.d < y.d end
        return x.display < y.display
    end)
    local out, seen = {}, {}
    local limit = #target + 2
    for _, s in ipairs(scored) do
        if #out >= 3 or s.d > limit then break end
        if not seen[s.display] then
            seen[s.display] = true
            out[#out + 1] = s.display
        end
    end
    return out
end

local function apiModuleSymbolNames(index, moduleName)
    return index.modules[moduleName] or {}
end

-- Every symbol as a did-you-mean candidate, module-qualified for display.
local function apiSymbolCandidates(index)
    local out = {}
    for _, s in ipairs(index.symbols) do
        out[#out + 1] = { name = s.symbol, display = s.module .. "." .. s.symbol }
    end
    return out
end

-- A known module's symbols as candidates, module-qualified for display.
local function apiModuleSymbolCandidates(index, moduleName)
    local out = {}
    for _, n in ipairs(apiModuleSymbolNames(index, moduleName)) do
        out[#out + 1] = { name = n, display = moduleName .. "." .. n }
    end
    return out
end

-- True when two symbols with the same bare name are the same underlying API --
-- a re-export (tecs2d.TouchPressed vs tecs2d.events.TouchPressed) rather than a
-- genuine name collision. Compares structure, never module, so only real
-- alternatives are reported as `also matches`.
local function apiSameSymbol(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "function" then
        local ap, bp = a.params or {}, b.params or {}
        if #ap ~= #bp then return false end
        for i = 1, #ap do
            if ap[i].type ~= bp[i].type
                or (ap[i].optional and true or false) ~= (bp[i].optional and true or false)
                or (ap[i].vararg and true or false) ~= (bp[i].vararg and true or false) then
                return false
            end
        end
        local ar, br = a.returns or {}, b.returns or {}
        if #ar ~= #br then return false end
        for i = 1, #ar do
            if ar[i] ~= br[i] then return false end
        end
        return true
    end
    if a.kind == "type" then
        -- signature is "<prefix><name>: <type>"; compare the type part so the
        -- module prefix does not make re-exports look different.
        local at = (a.signature or ""):match("^[^:]*:%s*(.*)$")
        local bt = (b.signature or ""):match("^[^:]*:%s*(.*)$")
        return at ~= nil and at == bt
    end
    -- record/component: fields, methods, and constructor must all agree.
    local af, bf = a.fields or {}, b.fields or {}
    if #af ~= #bf then return false end
    for i = 1, #af do
        if af[i].name ~= bf[i].name or af[i].type ~= bf[i].type then return false end
    end
    local am, bm = a.methods or {}, b.methods or {}
    if #am ~= #bm then return false end
    for i = 1, #am do
        if am[i].signature ~= bm[i].signature then return false end
    end
    local ac, bc = a.constructor, b.constructor
    if (ac == nil) ~= (bc == nil) then return false end
    if ac and ac.signature ~= bc.signature then return false end
    return true
end

-- Kind bucket for a resolved top-level symbol.
local function apiSymbolKind(sym)
    if sym.kind == "function" then return "function" end
    if sym.kind == "type" then return "value" end
    return "type"
end

-- Resolve one query string to a descriptor:
--   {kind="module", module=}
--   {kind="type"|"value"|"function", symrec=}
--   {kind="method", symrec=, methodrec=}
-- or a miss {miss=true, message=, suggestions={}}.
local function apiResolveQuery(index, query)
    local left, method = query:match("^([^:]+):(.+)$")
    if not left then left = query end

    if method then
        -- Left names a type (module.Type, or a bare type/receiver).
        local sym
        local modPart, symPart = left:match("^(.+)%.([^.]+)$")
        if modPart then
            local mod = apiResolveModule(index, modPart)
            if mod then sym = apiFindSymbol(index, mod, symPart) end
        end
        if not sym then
            local matches = apiFindByName(index, left)
            for _, s in ipairs(matches) do
                if s.methods and #s.methods > 0 then sym = s; break end
            end
            sym = sym or matches[1]
            -- Prefer the defining (deepest) module among re-exports of the
            -- same type, e.g. tecs.types.World over the tecs re-export.
            for _, s in ipairs(matches) do
                if sym and s ~= sym and apiSameSymbol(sym, s)
                    and #s.module > #sym.module then
                    sym = s
                end
            end
        end
        if not sym then
            return { miss = true, message = "no type '" .. left .. "'",
                suggestions = apiSuggest(left, apiSymbolCandidates(index)) }
        end
        local m = apiFindMethod(sym, method)
        if not m then
            local names = {}
            local rcv = sym.receiver or sym.symbol
            for _, mm in ipairs(sym.methods or {}) do
                names[#names + 1] = { name = mm.name, display = rcv .. ":" .. mm.name }
            end
            return { miss = true,
                message = "no method '" .. method .. "' on " .. sym.symbol,
                suggestions = apiSuggest(method, names) }
        end
        return { kind = "method", symrec = sym, methodrec = m }
    end

    -- No method. A full module name (e.g. `tecs.types`, `tecs2d.gfx`) wins over
    -- a module.Type split, so it lists the module rather than looking for a
    -- symbol named after its last segment.
    local wholeMod = apiResolveModule(index, left)
    if wholeMod then return { kind = "module", module = wholeMod } end

    -- Otherwise treat a dotted address as module.Type.
    local modPart, symPart = left:match("^(.+)%.([^.]+)$")
    if modPart then
        local mod = apiResolveModule(index, modPart)
        if mod then
            local sym = apiFindSymbol(index, mod, symPart)
            if sym then return { kind = apiSymbolKind(sym), symrec = sym } end
            return { miss = true,
                message = "no symbol '" .. symPart .. "' in " .. mod,
                suggestions = apiSuggest(symPart, apiModuleSymbolCandidates(index, mod)) }
        end
    end

    -- Bare symbol. Project symbols order first in the merged index, so a name
    -- the framework also uses resolves to the project's own symbol; genuinely
    -- different alternatives (not same-type re-exports) are reported alongside
    -- the hit as `also`.
    local matches = apiFindByName(index, left)
    if #matches >= 1 then
        local primary = matches[1]
        local also = {}
        for i = 2, #matches do
            if apiSameSymbol(primary, matches[i]) then
                -- Same API through a re-export: report the defining (deepest)
                -- module as the canonical address, e.g. tecs2d.events over the
                -- tecs2d aggregate.
                if #matches[i].module > #primary.module then primary = matches[i] end
            else
                also[#also + 1] = matches[i].module .. "." .. matches[i].symbol
            end
        end
        local res = { kind = apiSymbolKind(primary), symrec = primary }
        if #also > 0 then res.also = also end
        return res
    end

    local pool = apiSymbolCandidates(index)
    for m in pairs(index.modules) do pool[#pool + 1] = m end
    return { miss = true, message = "no symbol or module '" .. left .. "'",
        suggestions = apiSuggest(left, pool) }
end

----------------------------------------------------------------------
-- Rendering (Teal-style text)
----------------------------------------------------------------------

local function apiHasField(fields, name)
    if not fields then return true end
    for _, f in ipairs(fields) do if f == name then return true end end
    return false
end

-- Render function(params): returns from structured params/returns arrays.
local function apiRenderFnType(params, returns)
    local ps = {}
    for _, p in ipairs(params or {}) do
        if p.vararg then
            ps[#ps + 1] = "...: " .. p.type
        else
            ps[#ps + 1] = p.type .. (p.optional and "?" or "")
        end
    end
    local body = "function(" .. table.concat(ps, ", ") .. ")"
    local rs = returns or {}
    if #rs == 1 then
        body = body .. ": " .. rs[1]
    elseif #rs > 1 then
        body = body .. ": (" .. table.concat(rs, ", ") .. ")"
    end
    return body
end

local function apiSeeLine(sym)
    if not sym.see or #sym.see == 0 then return nil end
    return "see: " .. table.concat(sym.see, ", ")
end

-- Projected (non-full) render of a type: emit only the requested parts, as
-- plain lines (no `record ... end` wrapper), so `--fields signature` prints just
-- the signature and `--fields methods` prints just the method list.
local function apiRenderTypeProjected(sym, fields)
    local out = {}
    if apiHasField(fields, "signature") then
        out[#out + 1] = sym.signature
    end
    if apiHasField(fields, "fields") then
        for _, f in ipairs(sym.fields or {}) do
            local line = f.name .. ": " .. f.type
            if f.doc then line = line .. "  -- " .. f.doc end
            out[#out + 1] = line
        end
    end
    if apiHasField(fields, "constructor") and sym.constructor then
        out[#out + 1] = "metamethod __call: "
            .. apiRenderFnType(sym.constructor.params, sym.constructor.returns)
    end
    if apiHasField(fields, "methods") then
        for _, m in ipairs(sym.methods or {}) do
            out[#out + 1] = m.name .. ": " .. apiRenderFnType(m.params, m.returns)
        end
    end
    if apiHasField(fields, "doc") and sym.doc then
        out[#out + 1] = sym.doc
    end
    if apiHasField(fields, "see") then
        local see = apiSeeLine(sym)
        if see then out[#out + 1] = see end
    end
    return table.concat(out, "\n")
end

local function apiRenderTypeBlock(sym, fields)
    if fields then
        return apiRenderTypeProjected(sym, fields)
    end

    local out = {}
    out[#out + 1] = "record " .. sym.symbol
    for _, f in ipairs(sym.fields or {}) do
        local line = "  " .. f.name .. ": " .. f.type
        if f.doc then line = line .. "  -- " .. f.doc end
        out[#out + 1] = line
    end
    if sym.constructor then
        out[#out + 1] = "  metamethod __call: "
            .. apiRenderFnType(sym.constructor.params, sym.constructor.returns)
    end
    for _, m in ipairs(sym.methods or {}) do
        out[#out + 1] = "  " .. m.name .. ": " .. apiRenderFnType(m.params, m.returns)
    end
    out[#out + 1] = "end"

    if sym.doc then
        out[#out + 1] = ""
        out[#out + 1] = sym.doc
    end
    local see = apiSeeLine(sym)
    if see then out[#out + 1] = ""; out[#out + 1] = see end
    return table.concat(out, "\n")
end

local function apiRenderCallable(sym, fields)
    local out = {}
    if fields == nil or apiHasField(fields, "signature") then
        out[#out + 1] = sym.signature
    end
    if fields and apiHasField(fields, "params") then
        for _, p in ipairs(sym.params or {}) do
            out[#out + 1] = "param: " .. p.type .. (p.optional and " (optional)" or "")
        end
    end
    if fields and apiHasField(fields, "returns") and sym.returns and #sym.returns > 0 then
        out[#out + 1] = "returns: " .. table.concat(sym.returns, ", ")
    end
    if (fields == nil or apiHasField(fields, "doc")) and sym.doc then
        out[#out + 1] = ""
        out[#out + 1] = sym.doc
    end
    if fields == nil or apiHasField(fields, "see") then
        local see = apiSeeLine(sym)
        if see then out[#out + 1] = ""; out[#out + 1] = see end
    end
    return table.concat(out, "\n")
end

local function apiRenderMethod(m, fields)
    local out = {}
    if fields == nil or apiHasField(fields, "signature") then
        out[#out + 1] = m.signature
    end
    if fields and apiHasField(fields, "params") then
        for _, p in ipairs(m.params or {}) do
            out[#out + 1] = "param: " .. p.type .. (p.optional and " (optional)" or "")
        end
    end
    if fields and apiHasField(fields, "returns") and m.returns and #m.returns > 0 then
        out[#out + 1] = "returns: " .. table.concat(m.returns, ", ")
    end
    if (fields == nil or apiHasField(fields, "doc")) and m.doc then
        out[#out + 1] = ""
        out[#out + 1] = m.doc
    end
    return table.concat(out, "\n")
end

local function apiRenderModuleSymbols(index, moduleName)
    local rows = {}
    local width = 0
    for _, s in ipairs(index.symbols) do
        if s.module == moduleName then
            width = math.max(width, #s.symbol)
        end
    end
    for _, s in ipairs(index.symbols) do
        if s.module == moduleName then
            rows[#rows + 1] = string.format("  %-" .. width .. "s  %-9s %s",
                s.symbol, s.kind, s.signature)
        end
    end
    table.sort(rows)
    local out = { moduleName, "" }
    for _, r in ipairs(rows) do out[#out + 1] = r end
    return table.concat(out, "\n")
end

local function apiSortedKeys(set)
    local names = {}
    for m in pairs(set) do names[#names + 1] = m end
    table.sort(names)
    return names
end

local function apiRenderModuleList(index, frameworkMods, projectMods, note)
    local out = {}
    if note then out[#out + 1] = "note: " .. note; out[#out + 1] = "" end

    out[#out + 1] = "Framework modules:"
    for _, m in ipairs(apiSortedKeys(frameworkMods)) do
        out[#out + 1] = "  " .. m
    end

    local projList = {}
    for _, m in ipairs(apiSortedKeys(projectMods)) do
        if #apiModuleSymbolNames(index, m) > 0 then projList[#projList + 1] = m end
    end
    if #projList > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Project modules:"
        for _, m in ipairs(projList) do out[#out + 1] = "  " .. m end
    end

    out[#out + 1] = ""
    out[#out + 1] = "Use `tecs api <module>` to list a module's symbols, "
        .. "`tecs api <module>.<Type>` for a type."
    return table.concat(out, "\n")
end

local function apiRenderMiss(query, res)
    local out = { "no match for '" .. query .. "'" }
    if res.message then out[1] = res.message end
    if res.suggestions and #res.suggestions > 0 then
        out[#out + 1] = "did you mean: " .. table.concat(res.suggestions, ", ") .. "?"
    end
    return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- Structured projection (for --json)
----------------------------------------------------------------------

-- Copy `record` (all keys, or just `fields`) into a fresh table the callers
-- can annotate (note, also) without mutating the in-memory index. Identity
-- keys are always kept so a projected result stays addressable.
local function apiProjectKeys(record, fields)
    local out = {}
    if fields then
        for _, f in ipairs(fields) do
            if record[f] ~= nil then out[f] = record[f] end
        end
        out.symbol = record.symbol
        out.module = record.module
        out.type = record.type
        out.name = record.name
    else
        for k, v in pairs(record) do out[k] = v end
    end
    return out
end

local function apiResultJson(index, res, fields)
    if res.kind == "module" then
        return { module = res.module, symbols = apiModuleSymbolNames(index, res.module) }
    elseif res.kind == "method" then
        local m = res.methodrec
        local rec = {
            module = res.symrec.module,
            type = res.symrec.symbol,
            name = m.name,
            signature = m.signature,
            params = m.params,
            returns = m.returns,
            doc = m.doc,
            see = m.see,
        }
        return apiProjectKeys(rec, fields)
    end
    return apiProjectKeys(res.symrec, fields)
end

-- The canonical module-qualified address of a resolved symbol or method,
-- usable verbatim as a `tecs api` query.
local function apiCanonicalAddress(res)
    local addr = res.symrec.module .. "." .. res.symrec.symbol
    if res.kind == "method" then
        return addr .. ":" .. res.methodrec.name
    end
    return addr
end

local function apiResultText(index, res, fields)
    if res.kind == "module" then
        return apiRenderModuleSymbols(index, res.module)
    end
    -- Every hit opens with its canonical address, so a bare-name lookup always
    -- shows which module answered.
    local body
    if res.kind == "method" then
        body = apiRenderMethod(res.methodrec, fields)
    elseif res.kind == "type" then
        body = apiRenderTypeBlock(res.symrec, fields)
    else
        body = apiRenderCallable(res.symrec, fields)
    end
    return "-- " .. apiCanonicalAddress(res) .. "\n" .. body
end

-- The shared core. params: {query?, queries?, json?, fields?}. Returns
--   {ok=bool, text=string, json=<lua value>}
-- text is rendered Teal; json is the structured payload (both honor `fields`).
-- Never raises for a miss; a miss sets ok=false and reports suggestions.
local function apiInvoke(params)
    params = params or {}
    local index, note, frameworkMods, projectMods = mergedApiIndex()
    local fields = params.fields
    if fields and #fields == 0 then fields = nil end

    local queries = params.queries
    local single = false
    if not queries then
        if params.query and params.query ~= "" then
            queries = { params.query }
            single = true
        else
            queries = {}
        end
    end

    -- Module listing (no query).
    if #queries == 0 then
        return {
            ok = true,
            text = apiRenderModuleList(index, frameworkMods, projectMods, note),
            json = { modules = index.modules, note = note },
        }
    end

    -- Surface an overlay note (build failed, or some project modules did not
    -- type-check) on symbol lookups too, not just the bare module list, so an
    -- agent learns the project overlay is degraded even on a hit or a miss.
    local function noteText(text)
        if note and note ~= "" then return "note: " .. note .. "\n\n" .. text end
        return text
    end

    -- Rendered hit plus any shadowed alternatives from a bare-name lookup.
    local function hitText(item)
        local text = apiResultText(index, item.res, fields)
        if item.res.also and #item.res.also > 0 then
            text = text .. "\n\nalso matches: " .. table.concat(item.res.also, ", ")
        end
        return text
    end

    local resolved = {}
    local allOk = true
    for _, qy in ipairs(queries) do
        local r = apiResolveQuery(index, qy)
        resolved[#resolved + 1] = { query = qy, res = r }
        if r.miss then allOk = false end
    end

    if single then
        local item = resolved[1]
        if item.res.miss then
            return {
                ok = false,
                text = noteText(apiRenderMiss(item.query, item.res)),
                json = { query = item.query, ok = false,
                    error = item.res.message, suggestions = item.res.suggestions,
                    note = note },
            }
        end
        local json = apiResultJson(index, item.res, fields)
        json.also = item.res.also
        if note then json.note = note end
        return {
            ok = true,
            text = noteText(hitText(item)),
            json = json,
        }
    end

    -- Batch: one entry per query, never short-circuiting on a miss.
    local textParts, jsonArr = {}, {}
    for _, item in ipairs(resolved) do
        if item.res.miss then
            textParts[#textParts + 1] = "# " .. item.query .. "\n"
                .. apiRenderMiss(item.query, item.res)
            jsonArr[#jsonArr + 1] = { query = item.query, ok = false,
                error = item.res.message, suggestions = item.res.suggestions }
        else
            textParts[#textParts + 1] = "# " .. item.query .. "\n" .. hitText(item)
            jsonArr[#jsonArr + 1] = { query = item.query, ok = true,
                also = item.res.also,
                result = apiResultJson(index, item.res, fields) }
        end
    end
    return {
        ok = allOk,
        text = noteText(table.concat(textParts, "\n\n")),
        json = { results = jsonArr, note = note },
    }
end

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
        check = function()
            ensureVendor()
            return collectCheckDiagnostics(listTealSources())
        end,
        build = function()
            tasks.build()
        end,
        -- Symbol lookup: framework tier plus the on-demand project overlay.
        -- Toolchain-class like check/build -- no running game required.
        api = function(params)
            return apiInvoke(params)
        end,
        -- Run another CLI task in a child process: integ and dist mutate too
        -- much global state (busted's runner, os.exit traps) to share the
        -- bridge's process.
        reexec = function(task, extra)
            local command = q(loveBin()) .. " " .. q(loveApi.filesystem.getSource())
                .. " --tecs-project " .. q(cwd()) .. " " .. task
            if extra then command = command .. " " .. q(extra) end
            local pipe = io.popen(command .. " 2>&1")
            local output = pipe:read("*a") or ""
            local ok = pipe:close()
            return ok == true or ok == 0, output:sub(-8192)
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

    -- Whole corpus.
    if args.full then
        io.write(readDocBundle("llms-full.txt"))
        return
    end

    -- One page, addressed by its index path (e.g. tecs2d/rendering/shapes or
    -- /tecs2d/rendering/shapes.md).
    if args.page and args.page ~= "" then
        local url = "/" .. (args.page:gsub("^/", ""):gsub("%.md$", "")) .. ".md"
        local page = docPagesByUrl(readDocBundle("llms-full.txt"))[url]
        if not page then
            fail("unknown page '" .. tostring(args.page) .. "'. Run `tecs docs` to list pages")
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
        fail(#queries > 1 and "one or more lookups did not resolve"
            or ("no match for '" .. (queries[1] or "") .. "'"))
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
                "Comma-separated record keys to return, e.g. signature,doc,methods.")
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

local function commandNames()
    local names = {}
    for _, command in ipairs(commands) do
        names[#names + 1] = command.name
    end
    return table.concat(names, ", ")
end

local function printHelp()
    io.write(color("bright cyan", "Tecs CLI ") .. color("black", VERSION) .. "\n\n")
    io.write(color("bright", "Usage: ") .. color("green", "tecs")
        .. " [--version] [--quiet] " .. color("cyan", "<command>") .. "\n\n")
    io.write(color("bright", "Commands:") .. "\n")
    for _, command in ipairs(commands) do
        io.write("  " .. color("cyan", string.format("%-13s", command.name)) .. command.summary .. "\n")
    end
    io.write("\n")
    io.write(color("magenta", "MCP:") .. [[ there are two ways to connect agents. ]]
        .. color("cyan", "tecs mcp") .. [[ serves the project over
stdio: it can start and restart the game itself, exposes check/build/integ/
dist as tools, and the session survives game restarts and crashes. Every
running game also embeds its own MCP server over HTTP (port 19999 by
default); connect to that directly to attach to a game that is already
running, such as a distributed build with enableInDist.

]])
    io.write(color("magenta", "Dependencies:") .. [[ vendor pure-Lua rocks with LuaRocks into the
project tree, which already uses the LuaRocks layout:
    luarocks install --tree src/vendor --lua-version=5.1 <rock>
Teal declarations for popular rocks are published as <rock>-tl-type rocks.
src/vendor is regenerated and usually gitignored, so record your rocks
somewhere repeatable and reinstall after a fresh clone. Only pure-Lua rocks
work: the game runtime has no C toolchain.

]])
    io.write(color("magenta", "Hot reload:") .. [[ while the game is running, rerun ]]
        .. color("cyan", "tecs build") .. [[ from another terminal.
A successful build updates build/.tecs-reload-stamp; the running game will
snapshot, restart, and restore state automatically.
]])
end

function parser()
    local p = argparse("tecs", "Build, check, run, and manage fixed-layout Tecs starter projects.")
    p:help_max_width(88)
    p:flag("--version", "Show version and exit")
    p:flag("-q --quiet", "Suppress progress output")
    p:command_target("command")
    p:require_command(false)

    for _, command in ipairs(commands) do
        local subcommand = p:command(command.name, command.description or command.summary)
            :summary(command.summary)
            :action(function(args)
                args.command = command.name
            end)
        if command.setup then
            command.setup(subcommand)
        end
    end

    p:command("help", "Show the Tecs CLI command overview.")
        :summary("Show command overview")
        :action(function(args)
            args.command = "help"
        end)
    return p
end

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

-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local haveLfs, lfs = pcall(require, "lfs")

local VERSION = "0.10.2"
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

    -- The game's full tool set (kernel + registry-derived cmd_*) only exists
    -- once a game runs, but it is identical across projects, so cache it at a
    -- user-level path the first time start_game succeeds and front-load it
    -- thereafter. That lets the bridge advertise the full list at initialize
    -- instead of firing a large tools/list_changed after start_game, which some
    -- MCP clients mis-reconcile. (The CLI cannot enumerate cmd_* itself: it
    -- loads the framework from .tl on the fly, and observe()'s slotOf macroexp
    -- is not inlined on that path.)
    local defaultToolsPath = pathJoin(userDataDir(), "mcp-default-tools.json")

    return {
        version = VERSION,
        projectName = distName(),
        json = jsonModule(),
        kernelTools = kernelTools,
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

tasks.info = printInfo

local commands = {
    {
        name = "info",
        summary = "Show runtime and project information",
        description = "Show CLI, Love2D, and LuaJIT versions plus current project status and a next step.",
        action = printInfo,
        setup = function(subcommand)
            subcommand:flag("--json", "Print runtime and project information as JSON on stdout.")
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
    distName = distName,
    patchPlist = patchPlist,
    buildinfoLua = buildinfoLua,
}

return M

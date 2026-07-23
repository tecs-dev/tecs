--- Reusable debugger artifact-history subcommands and lookup helpers.

local logging <const> = require("tecs.utils.logging")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local osopen <const> = require("tecs2d.debug.internal.osopen")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local LOGGER <const> = logging.getLogger("tecs2d.debug.commands")
local format <const> = string.format

local record artifacts
    list: function(noun: string, items: function(): {any},
        line: function(any): string): cmdtypes.Subcommand
    clear: function(noun: string, items: function(): {any},
        removeFile: function(string), reset: function()): cmdtypes.Subcommand
    find: function(list: {any}, ref: string, byNumber?: boolean): {string: any}
    infoLines: function(title: string, entry: {string: any}, absPath: string): {string}
    open: function(cmdName: string, argName: string, argHelp: string,
        resolve: function(string): string): cmdtypes.Subcommand
    path: function(cmdName: string, argName: string, argHelp: string,
        resolve: function(string): string,
        toAbs: function(string): string): cmdtypes.Subcommand
    info: function(cmdName: string, noun: string, shortHelp: string,
        schema: cmdargs.Schema, items: function(): {any}, byNumber: boolean,
        detail: function({string: any}): cmdtypes.Result): cmdtypes.Subcommand
end

local function openSaveFile(rel: string, what: string): cmdtypes.Result
    local ok, detail = osopen.open(debugcontext.savePath(rel))
    if not ok then
        LOGGER:error("%s open failed path=%s detail=%s", what, rel, detail)
        return {ok = false, code = "open_failed",
            message = "failed to open " .. rel .. ": " .. detail}
    end
    return {ok = true, message = "opening " .. rel, data = {path = rel}}
end

-- Shared list/clear/open verbs for the artifact-history commands (snapshot,
-- screenshot, profile, record). Each history is a list of {path, size,
-- time, ...} entries on the context; `line` renders one popup row.
function artifacts.list(noun: string, items: function(): {any},
        line: function(any): string): cmdtypes.Subcommand
    return {
        name = "list",
        shortHelp = "list " .. noun .. " with size and timestamp",
        run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
            local list = items()
            if #list == 0 then
                return {ok = true, message = "no " .. noun .. " yet", data = {[noun] = list}}
            end
            local popup: {string} = {noun .. "  (type to dismiss):"}
            for i = 1, #list do popup[#popup + 1] = line(list[i]) end
            return {ok = true, popup = popup, data = {[noun] = list}}
        end,
    }
end

function artifacts.clear(noun: string, items: function(): {any},
        removeFile: function(string), reset: function()): cmdtypes.Subcommand
    return {
        name = "clear",
        shortHelp = "delete all " .. noun .. " this session",
        run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
            local list = items()
            local n = #list
            for i = 1, n do
                removeFile((list[i] as {string: any}).path as string)
            end
            reset()
            return {ok = true, message = "cleared " .. tostring(n) .. " " .. noun,
                data = {cleared = n}}
        end,
    }
end

-- Resolve an artifact-history ref: nil means the newest entry, a number
-- matches a snapshot number or 1-based list index, anything else matches
-- the entry path (exact, or by basename).
function artifacts.find(list: {any}, ref: string, byNumber?: boolean): {string: any}
    if not ref or ref == "" or ref == "latest" then
        return list[#list] as {string: any}
    end
    local n = tonumber(ref)
    if n then
        local wanted = math.floor(n)
        if byNumber then
            for i = 1, #list do
                local e = list[i] as {string: any}
                if e.number == wanted then return e end
            end
        end
        local e = list[wanted]
        if e then return e as {string: any} end
    end
    for i = 1, #list do
        local e = list[i] as {string: any}
        local path = e.path as string
        if path == ref or path:match("([^/]+)$") == ref then return e end
    end
    return nil
end

-- Common info popup rows for a {path, size, time, ...} artifact entry.
function artifacts.infoLines(title: string, e: {string: any}, absPath: string): {string}
    local lines: {string} = {title}
    if e.number then
        lines[#lines + 1] = "  number\t#" .. tostring(e.number)
    end
    lines[#lines + 1] = "  path\t" .. tostring(e.path)
    lines[#lines + 1] = "  full\t" .. absPath
    lines[#lines + 1] = format("  size\t%.1f KB", (e.size as number) / 1024)
    lines[#lines + 1] = "  when\t" ..
        (os.date("%Y-%m-%d %H:%M:%S", e.time as number) as string)
    return lines
end


-- `resolve` maps the (possibly nil) argument to a save-dir filename, e.g.
-- a save number or "latest entry when omitted".
function artifacts.open(cmdName: string, argName: string, argHelp: string,
        resolve: function(string): string): cmdtypes.Subcommand
    local schema: cmdargs.Schema = {
        args = { [argName] = {help = argHelp} },
        positional = {argName},
    }
    return {
        name = "open",
        shortHelp = "open with the OS default handler (latest if omitted)",
        schema = schema,
        run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
            local rel = resolve(v[argName] as string)
            if not rel or rel == "" then
                return {ok = false, code = "no_match",
                    message = cmdName .. " open: nothing to open. Use `" .. cmdName .. " list`."}
            end
            return openSaveFile(rel, cmdName)
        end,
    }
end

-- Shared `path` verb: copy an artifact's absolute path to the clipboard.
-- toAbs converts the stored relative path (save dir for most artifacts,
-- process CWD for profiles).
function artifacts.path(cmdName: string, argName: string, argHelp: string,
        resolve: function(string): string, toAbs: function(string): string): cmdtypes.Subcommand
    local schema: cmdargs.Schema = {
        args = { [argName] = {help = argHelp} },
        positional = {argName},
    }
    return {
        name = "path",
        shortHelp = "copy the file's absolute path to the clipboard (latest if omitted)",
        schema = schema,
        run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
            local rel = resolve(v[argName] as string)
            if not rel or rel == "" then
                return {ok = false, code = "no_match",
                    message = cmdName .. " path: nothing to copy. Use `" .. cmdName .. " list`."}
            end
            local abs = toAbs(rel)
            love.system.setClipboardText(abs)
            return {ok = true, message = "path copied to clipboard: " .. abs,
                data = {path = abs}}
        end,
    }
end

-- Shared `info` verb: resolve the ref against the artifact history (with
-- the standard "no X for '...'" miss), then hand the entry to `detail`
-- for the type-specific popup lines and payload.
function artifacts.info(cmdName: string, noun: string, shortHelp: string,
        schema: cmdargs.Schema, items: function(): {any}, byNumber: boolean,
        detail: function({string: any}): cmdtypes.Result): cmdtypes.Subcommand
    return {
        name = "info",
        shortHelp = shortHelp,
        schema = schema,
        run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
            local e = artifacts.find(items(), v.ref as string, byNumber)
            if not e then
                return {ok = false, code = "no_match",
                    message = cmdName .. " info: no " .. noun .. " for '" ..
                        tostring(v.ref) .. "'. Use `" .. cmdName .. " list`."}
            end
            return detail(e)
        end,
    }
end

return artifacts

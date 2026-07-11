--- Capture-section debugger commands: profile, snapshot, rewind, diff,
--- screenshot, and record, plus the artifact-history machinery they share
--- (the list/clear/open/path/info verbs over files in the save directory,
--- the shared world-load cooldown, and the diff decode cache).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local json <const> = require("tecs.utils.json")
local profile <const> = require("tecs.utils.profile")
local logging <const> = require("tecs.utils.logging")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local rewind <const> = require("tecs2d.debug.internal.rewind")
local snapdiff <const> = require("tecs2d.debug.internal.diff")
local osopen <const> = require("tecs2d.debug.internal.osopen")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

-- Same logger as the core registry so log filters see one command surface.
local LOGGER <const> = logging.getLogger("tecs2d.debug.commands")
local format <const> = string.format
local getTime <const> = love.timer.getTime

local record capture
    --- The Capture-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local recordSchema <const>: cmdargs.Schema = {
    args = {
        seconds = {default = 0, help = "auto-stop after N seconds; 0 records until stopped"},
        name = {help = "output filename"},
        fps = {default = 30, help = "capture frame rate"},
        scale = {default = 1, help = "output size multiplier, e.g. 0.5"},
        debug = {default = false, help = "keep the debugger visible and the game running"},
        countdown = {kind = "number", help = "seconds before recording starts (plugin default if omitted)"},
        stopOnDebugOpen = {kind = "boolean",
            help = "stop when the debugger opens (default: true only for untimed, non-debug recordings)"},
    },
    positional = {"seconds", "name"},
}

-- seconds 0 samples until you reopen the debugger.
local profileSchema <const>: cmdargs.Schema = {
    args = { seconds = {default = 0, help = "sample duration; 0 samples until reopen"} },
    positional = {"seconds"},
}

-- Shared ref schemas for the artifact verbs (profile/screenshot vs record).
local captureRefSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "capture name or list index"} },
    positional = {"ref"},
}

local recordingRefSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "recording name or list index"} },
    positional = {"ref"},
}

function capture.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local reg <const> = d.reg
    local env <const> = d.env
    local pipeline <const> = d.pipeline
    local componentFor <const> = d.componentFor
    local summarizeProfile <const> = d.summarizeProfile
    local systemZoneIds <const> = d.systemZoneIds
    local nameSchema <const> = d.nameSchema
    local refSchema <const> = d.refSchema
    local EDIT_SELECTION_TARGET <const> = d.selectionTarget

    -- Full-world loads are heavy; refuse a second one inside the cooldown so
    -- buffered or repeated Enter presses cannot stack them frame after frame.
    local LOAD_COOLDOWN <const> = 0.3
    local function loadCooldown(what: string): boolean, string
        local since = getTime() - reg.lastWorldLoadAt
        if since < LOAD_COOLDOWN then
            return true, what .. ": a world load just ran; retry in a moment"
        end
        return false, nil
    end


    -- Resolve a snapshot argument to a save-dir filename: a number is that save,
    -- a name is used as-is, and no argument is the last save.
    local function snapshotNameFor(a: string): string
        if not a or a == "" or a == "latest" then
            local last = ctx.snapshots[#ctx.snapshots]
            return last and last.path
        end
        local n = tonumber(a)
        if n then
            local wanted = math.floor(n)
            return reg.saves[wanted] or ("debug-save-" .. tostring(wanted) .. ".snapshot")
        end
        return a
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
    local function artifactList(noun: string, items: function(): {any},
            line: function(any): string): cmdtypes.Subcommand
        return {
            name = "list",
            aliases = {"ls"},
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

    local function artifactClear(noun: string, items: function(): {any},
            removeFile: function(string), reset: function()): cmdtypes.Subcommand
        return {
            name = "clear",
            aliases = {"rm"},
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
    local function findArtifact(list: {any}, ref: string, byNumber?: boolean): {string: any}
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
    local function artifactInfoLines(title: string, e: {string: any}, absPath: string): {string}
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
    local function artifactOpen(cmdName: string, argName: string, argHelp: string,
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
                        message = cmdName .. " open: nothing to open. Use `" .. cmdName .. " ls`."}
                end
                return openSaveFile(rel, cmdName)
            end,
        }
    end

    -- Shared `path` verb: copy an artifact's absolute path to the clipboard.
    -- toAbs converts the stored relative path (save dir for most artifacts,
    -- process CWD for profiles).
    local function artifactPath(cmdName: string, argName: string, argHelp: string,
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
                        message = cmdName .. " path: nothing to copy. Use `" .. cmdName .. " ls`."}
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
    local function artifactInfo(cmdName: string, noun: string, shortHelp: string,
            schema: cmdargs.Schema, items: function(): {any}, byNumber: boolean,
            detail: function({string: any}): cmdtypes.Result): cmdtypes.Subcommand
        return {
            name = "info",
            shortHelp = shortHelp,
            schema = schema,
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local e = findArtifact(items(), v.ref as string, byNumber)
                if not e then
                    return {ok = false, code = "no_match",
                        message = cmdName .. " info: no " .. noun .. " for '" ..
                            tostring(v.ref) .. "'. Use `" .. cmdName .. " ls`."}
                end
                return detail(e)
            end,
        }
    end

    -- Decode one diff reference into a snapshot table plus display metadata.
    -- "current" serializes the live world (read-only); binary refs load into
    -- a throwaway scratch world (components are process-global; a plugin-free
    -- world has no observers, so nothing fires into the game) and re-export
    -- as a table. Decoded tables are cached for the session by path + size,
    -- so refiltering the same pair only re-runs the comparison.
    local decodedDiffRefs: {string: {string: any}} = {}
    local decodedDiffOrder: {string} = {}
    -- Drop every cached decode. Called whenever ring or snapshot files can
    -- be replaced under a reused name (rewind start/clear, snapshot save,
    -- snapshot clear, rewind keep): path + size + modtime alone cannot see
    -- same-second same-size rewrites.
    local function invalidateDiffCache()
        decodedDiffRefs = {}
        decodedDiffOrder = {}
    end
    local function decodeDiffRef(ref: string): {string: any}, {string: any}, string, string
        if ref == nil or ref == "" or ref == "current" then
            local out = w:saveSnapshot({format = "table"}) as {string: any}
            return out.snapshot as {string: any},
                {ref = "current", time = os.time(), entities = w:getStats().entities},
                nil, nil
        end
        local path: string
        local meta: {string: any} = {ref = ref}
        local rest = ref:match("^rewind:(.*)$")
        if rest then
            local ago = rest:match("^ago=(%d+%.?%d*)$")
            local e, _, ferr = rewind.findEntry(ctx,
                ago and nil or rest, ago and tonumber(ago) or nil)
            if not e then
                return nil, nil, "invalid_ref", "diff: " .. ref .. ": " .. ferr
            end
            path = e.path
            meta.time = e.time
            meta.entities = e.entities
        else
            local plain = ref:match("^snapshot:(.*)$") or ref
            local name = snapshotNameFor(plain)
            if not name or name == "" then
                return nil, nil, "invalid_ref",
                    "diff: no snapshot for '" .. plain .. "'. Use `snapshot ls`."
            end
            path = name
            local entry = findArtifact(ctx.snapshots as {any}, plain, true)
            if entry then
                meta.time = entry.time
                meta.entities = entry.entities
            end
        end
        meta.path = path
        local info = love.filesystem.getInfo(path) as {string: any}
        local cacheKey = path .. "|" .. tostring(info and info.size or 0) ..
            "|" .. tostring(info and info.modtime or 0)
        local cached = decodedDiffRefs[cacheKey]
        if cached then
            return cached, meta, nil, nil
        end
        local bytes = love.filesystem.read(path)
        if not bytes then
            return nil, nil, "read_failed", "diff: cannot read " .. path
        end
        local snap: {string: any} = nil
        local ok, derr = pcall(function(): boolean
            local scratch = tecs.newWorld()
            -- Mirror the live world's created states so a snapshot taken with
            -- a pushed state stack can restore it (default policies: no game
            -- callbacks run on the scratch world).
            local liveStates = (w as {string: any})._stateComponents as {string: any}
            for stateName in pairs(liveStates or {}) do
                scratch:createState(stateName)
            end
            scratch:loadSnapshot(bytes)
            local out = scratch:saveSnapshot({format = "table"}) as {string: any}
            snap = out.snapshot as {string: any}
            return true
        end)
        if not ok or not snap then
            return nil, nil, "decode_failed",
                "diff: cannot decode " .. path .. ": " .. tostring(derr)
        end
        decodedDiffRefs[cacheKey] = snap
        decodedDiffOrder[#decodedDiffOrder + 1] = cacheKey
        if #decodedDiffOrder > 4 then
            decodedDiffRefs[table.remove(decodedDiffOrder, 1)] = nil
        end
        return snap, meta, nil, nil
    end

    -- Render a diff value (possibly a component object) as one short cell.
    local function diffCell(v: any): string
        if v == nil then return "-" end
        local text: string
        if type(v) == "table" then
            local okEnc, enc = pcall(json.serialize, v)
            text = okEnc and enc or tostring(v)
        else
            text = tostring(v)
        end
        if #text > 48 then text = text:sub(1, 45) .. "..." end
        return text
    end


    -- Parse diff filters from arguments: an entity restriction (id, mark, or
    -- @selection), an ignore set, and a validated single-component filter.
    -- Returns nil + an error Result when a filter names something unknown.
    local function parseDiffFilters(v: {string: any}): {integer: boolean}, {string: boolean}, cmdtypes.Result
        local entityFilter: {integer: boolean} = nil
        if v.entity ~= nil then
            local spec = v.entity as string
            entityFilter = {}
            if spec == EDIT_SELECTION_TARGET then
                for i = 1, #ctx.selected do entityFilter[ctx.selected[i]] = true end
            elseif tonumber(spec) then
                entityFilter[math.floor(tonumber(spec)) as integer] = true
            else
                local found = false
                for eid, nm in pairs(ctx.marks) do
                    if nm == spec then
                        entityFilter[eid] = true
                        found = true
                    end
                end
                if not found then
                    return nil, nil, {ok = false, code = "invalid_filter",
                        message = "diff: no mark named '" .. spec .. "'"}
                end
            end
        end
        local ignoreSet: {string: boolean} = {}
        if v.ignore ~= nil then
            for _, raw in ipairs(v.ignore as {string}) do
                local nm = raw:match("^%s*(.-)%s*$")
                if not componentFor(nm) then
                    return nil, nil, {ok = false, code = "invalid_filter",
                        message = "diff: unknown component '" .. nm .. "' in ignore="}
                end
                ignoreSet[nm] = true
            end
        end
        if v.component ~= nil and not componentFor(v.component as string) then
            return nil, nil, {ok = false, code = "invalid_filter",
                message = "diff: unknown component '" .. tostring(v.component) .. "'"}
        end
        return entityFilter, ignoreSet, nil
    end

    -- Render a diff result as popup lines: header, per-component summary
    -- sorted by change volume, skip/artifact notes, then the detailed changes
    -- up to the limit.
    local function diffPopup(result: {string: any}, fromMeta: {string: any},
            toMeta: {string: any}): {string}
        local summary = result.summary as {string: any}
        local popup: {string} = {
            format("diff %s -> %s  (%.0fms, %s)",
                tostring(fromMeta.ref), tostring(toMeta.ref),
                result.elapsedMs as number,
                (result.totalChanges as integer == 0) and "no differences"
                    or (tostring(result.totalChanges) .. " changes")),
        }
        if (summary.entitiesAdded as integer) > 0 or (summary.entitiesRemoved as integer) > 0 then
            popup[#popup + 1] = format("  entities\t+%d  -%d",
                summary.entitiesAdded as integer, summary.entitiesRemoved as integer)
        end
        -- Components ordered by how much changed, so the hot spot leads.
        local byComp = summary.byComponent as {string: {string: integer}}
        local compNames: {string} = {}
        for nm in pairs(byComp) do compNames[#compNames + 1] = nm end
        table.sort(compNames, function(a: string, b: string): boolean
            local ta = (byComp[a].changed or 0) + (byComp[a].added or 0) + (byComp[a].removed or 0)
            local tb = (byComp[b].changed or 0) + (byComp[b].added or 0) + (byComp[b].removed or 0)
            if ta ~= tb then return ta > tb end
            return a < b
        end)
        for i = 1, #compNames do
            local nm = compNames[i]
            local c = byComp[nm]
            local bits: {string} = {}
            if c.changed then bits[#bits + 1] = tostring(c.changed) .. " changed" end
            if c.added then bits[#bits + 1] = tostring(c.added) .. " added" end
            if c.removed then bits[#bits + 1] = tostring(c.removed) .. " removed" end
            popup[#popup + 1] = "  " .. nm .. "\t" .. table.concat(bits, ", ")
        end
        if result.skipped then
            popup[#popup + 1] = "  (skipped: " ..
                table.concat(result.skipped as {string}, ", ") .. ")"
        end
        if result.artifactError then
            popup[#popup + 1] = "  (artifact write failed: " ..
                tostring(result.artifactError) .. ")"
        end
        local shown = result.changes as {{string: any}}
        if #shown > 0 then popup[#popup + 1] = "Changes:" end
        for i = 1, #shown do
            local ch = shown[i]
            popup[#popup + 1] = format("  %s\t%s\t%s\t%s -> %s",
                (ch.entity ~= nil) and tostring(ch.entity) or "world",
                (ch.component as string) or "",
                (ch.path as string ~= "") and ch.path as string or ch.operation as string,
                diffCell(ch.before), diffCell(ch.after))
        end
        if result.truncated then
            popup[#popup + 1] = format("  (showing %d of %d; filter or raise limit=)",
                #shown, result.totalChanges as integer)
        end
        return popup
    end

    return {
        {
            name = "profile",
            section = "Capture",
            mcp = false,   -- agents use the profiler_start / profiler_stop MCP tools
            shortHelp = "sample the running game with the LuaJIT profiler",
            schema = profileSchema,
            examples = {"profile", "profile 5", "profile ls"},
            subcommands = {
                artifactList("profiles",
                    function(): {any} return ctx.profiles as {any} end,
                    function(e: any): string
                        local p = e as debugcontext.ProfileEntry
                        return format("  %.1f KB\t%s\t%s",
                            p.size / 1024, os.date("%Y-%m-%d %H:%M:%S", p.time) as string, p.path)
                    end),
                -- Profiles land in the process working directory, not the save
                -- dir, so clearing goes through os.remove.
                artifactClear("profiles",
                    function(): {any} return ctx.profiles as {any} end,
                    function(path: string) os.remove(path) end,
                    function() ctx.profiles = {} end),
                artifactInfo("profile", "capture", "re-show a capture's summary (latest if omitted)",
                    captureRefSchema,
                    function(): {any} return ctx.profiles as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local f = io.open(e.path as string, "r")
                        if not f then
                            return {ok = false, code = "read_failed",
                                message = "profile info: cannot read " .. tostring(e.path)}
                        end
                        local text = f:read("*a")
                        f:close()
                        local popup, top = summarizeProfile(text, e.path as string, systemZoneIds(w))
                        return {ok = true, popup = popup,
                            data = {path = e.path, size = e.size, summary = top}}
                    end),
                artifactPath("profile", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.profiles as {any}, ref)
                        return e and e.path as string
                    end,
                    -- Captures live in the process working directory.
                    function(rel: string): string
                        return love.filesystem.getWorkingDirectory() .. "/" .. rel
                    end),
                {
                    name = "open",
                    shortHelp = "open speedscope and copy the capture's path to the clipboard",
                    schema = captureRefSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local e = findArtifact(ctx.profiles as {any}, v.ref as string)
                        if not e then
                            return {ok = false, code = "no_match",
                                message = "profile open: no capture for '" .. tostring(v.ref) .. "'. Use `profile ls`."}
                        end
                        -- Captures live in the process working directory.
                        local absPath = love.filesystem.getWorkingDirectory() .. "/" .. (e.path as string)
                        love.system.setClipboardText(absPath)
                        local url = "https://www.speedscope.app/"
                        pcall(function() love.system.openURL(url) end)
                        return {ok = true,
                            message = "opened speedscope; capture path in clipboard: " .. absPath,
                            data = {path = absPath, url = url}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                if reg.profiler.session then
                    return {ok = false, code = "already_running", message = "profile: already running"}
                end
                local secs = v.seconds as number
                local ok, sess = pcall(profile.sample, {})
                if not ok or not sess then
                    return {ok = false, code = "start_failed",
                        message = "profile: could not start (already sampling?)"}
                end
                reg.profiler.session = sess as profile.SampleSession
                reg.signals.action = "exit"
                if secs > 0 then
                    if secs < 0.1 then secs = 0.1 end
                    if secs > 60 then secs = 60 end
                    reg.profiler.deadline = getTime() + secs
                    return {ok = true, message = "profiling " .. tostring(secs) .. "s"}
                end
                reg.profiler.deadline = 0.0
                return {ok = true, message = "profiling until reopen (" ..
                    env.keys.leader .. "+" .. env.keys.debugToggle .. ")"}
            end,
        },
        {
            name = "snapshot",
            section = "Capture",
            shortHelp = "save and restore the whole world",
            examples = {"snapshot save boss-fight", "snapshot load 3", "snapshot ls"},
            subcommands = {
                {
                    name = "save",
                    shortHelp = "save the world; reports a number for load/open",
                    mcpHelp = "Save the whole world to a snapshot file in the save directory. Returns a snapshot number usable as a debug_snapshot_load and debug_diff ref. Does not disturb the running game.",
                    schema = nameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        reg.saveCounter = reg.saveCounter + 1
                        local name = (v.name as string) or ("debug-save-" .. tostring(reg.saveCounter) .. ".snapshot")
                        local ok, err = pcall(function(): boolean
                            local out = w:saveSnapshot()
                            local wok, werr = love.filesystem.write(name, tostring(out.buffer))
                            if not wok then
                                error(werr or "write failed", 0)
                            end
                            return true
                        end)
                        invalidateDiffCache()
                        if not ok then
                            -- A failed save must not burn a snapshot number.
                            reg.saveCounter = reg.saveCounter - 1
                            return {ok = false, code = "save_failed",
                                message = "snapshot save failed: " .. tostring(err)}
                        end
                        local info = love.filesystem.getInfo(name)
                        local sz = (info and info.size) or 0
                        local entityCount = w:getStats().entities
                        reg.saves[reg.saveCounter] = name
                        ctx.snapshots[#ctx.snapshots + 1] = {
                            number = reg.saveCounter, path = name,
                            size = sz as integer, time = os.time(),
                            entities = entityCount,
                        }
                        w:emit(0, debugcontext.OnDebugContext("snapshot", name, reg.saveCounter))
                        debugcontext.pushEvent(ctx, "snapshot",
                            {number = reg.saveCounter, path = name, entities = entityCount})
                        return {ok = true,
                            message = "snapshot #" .. tostring(reg.saveCounter) ..
                                " saved at " .. debugcontext.savePath(name),
                            data = {number = reg.saveCounter, path = name, size = sz,
                                entities = entityCount}}
                    end,
                },
                {
                    name = "load",
                    shortHelp = "restore a save (the last if omitted)",
                    mcpHelp = "Replace the live world with a saved snapshot (ref is a number, name, or latest). Destructive to current state; selection, marks, and notes clear. Loads are rate limited, so retry on a busy error after a moment.",
                    schema = refSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local held, heldErr = loadCooldown("snapshot load")
                        if held then
                            return {ok = false, code = "busy", message = heldErr}
                        end
                        local name = snapshotNameFor(v.ref as string)
                        if not name or name == "" then
                            return {ok = false, code = "no_match",
                                message = "snapshot load: nothing to load. Use `snapshot ls`."}
                        end
                        local bytes = love.filesystem.read(name)
                        if not bytes then
                            return {ok = false, code = "read_failed",
                                message = "snapshot load: cannot read " .. name .. ". Use `snapshot ls`."}
                        end
                        local ok, err = pcall(w.loadSnapshot, w, bytes)
                        if not ok then
                            return {ok = false, code = "load_failed",
                                message = "snapshot load failed: " .. tostring(err)}
                        end
                        reg.lastWorldLoadAt = getTime()
                        ctx.selected = {}
                        ctx.marks = {}
                        ctx.notes = {}
                        debugcontext.pushEvent(ctx, "snapshot", {path = name, loaded = true})
                        return {ok = true, message = "loaded: " .. name, data = {path = name}}
                    end,
                },
                artifactOpen("snapshot", "ref", "save name or number", snapshotNameFor),
                artifactPath("snapshot", "ref", "save name or number", snapshotNameFor,
                    debugcontext.savePath),
                artifactList("snapshots",
                    function(): {any} return ctx.snapshots as {any} end,
                    function(e: any): string
                        local s = e as debugcontext.SnapshotEntry
                        return format("  #%d\t%.1f KB\t%s\t%s",
                            s.number, s.size / 1024, os.date("%Y-%m-%d %H:%M:%S", s.time) as string, s.path)
                    end),
                artifactClear("snapshots",
                    function(): {any} return ctx.snapshots as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function()
                        reg.saves = {}
                        reg.saveCounter = 0
                        ctx.snapshots = {}
                        invalidateDiffCache()
                    end),
                artifactInfo("snapshot", "save", "show one save's details (latest if omitted)",
                    refSchema,
                    function(): {any} return ctx.snapshots as {any} end, true,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifactInfoLines("snapshot #" .. tostring(e.number), e, abs)
                        if e.entities then
                            lines[#lines + 1] = "  entities\t" .. tostring(e.entities)
                        end
                        local onDisk = love.filesystem.getInfo(e.path as string)
                        lines[#lines + 1] = "  on disk\t" .. (onDisk and "yes" or "missing")
                        return {ok = true, popup = lines,
                            data = {number = e.number, path = e.path, full = abs,
                                size = e.size, time = e.time, entities = e.entities,
                                exists = onDisk ~= nil}}
                    end),
            },
        },
        {
            name = "rewind",
            section = "Capture",
            shortHelp = "time travel: keep a rolling snapshot ring and load back into it",
            examples = {"rewind start 2 30", "rewind list", "rewind load ago=10",
                "rewind keep latest before-bug", "rewind info"},
            subcommands = {
                {
                    name = "start",
                    shortHelp = "begin capturing; refuses over a stopped ring",
                    mcpHelp = "Start the time-travel ring: a rolling window of world snapshots captured every interval seconds (cap entries) while the game runs unfrozen. Capture holds automatically while the game is paused. Refuses if a stopped ring still holds entries. Start this early; debug_rewind_load and debug_diff feed on it.",
                    schema = { args = {
                        interval = {default = 5, help = "seconds between captures"},
                        cap = {default = 10, kind = "number", help = "entries kept before the oldest is dropped"},
                    }, positional = {"interval", "cap"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local interval = v.interval as number
                        local cap = math.floor(v.cap as number) as integer
                        local ok, err = rewind.start(ctx, getTime(), interval, cap)
                        if not ok then
                            return {ok = false, code = "start_failed", message = "rewind start: " .. err}
                        end
                        invalidateDiffCache()
                        debugcontext.pushEvent(ctx, "rewind", {started = true, interval = interval, cap = cap})
                        return {ok = true,
                            message = format("rewind capturing every %gs (cap %d, ~%gs window);" ..
                                " holds while frozen", interval, cap, interval * cap),
                            data = {interval = interval, cap = cap}}
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop capturing; the ring stays for list/load/keep",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ok, err = rewind.stop(ctx)
                        if not ok then
                            return {ok = false, code = "not_running", message = "rewind stop: " .. err}
                        end
                        debugcontext.pushEvent(ctx, "rewind", {stopped = true})
                        return {ok = true, message = "rewind stopped; " ..
                            tostring(#ctx.rewind.entries) .. " entries kept", data = {entries = #ctx.rewind.entries}}
                    end,
                },
                {
                    name = "pause",
                    shortHelp = "hold capture without ending the session",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ok, err = rewind.pause(ctx)
                        if not ok then
                            return {ok = false, code = "not_running", message = "rewind pause: " .. err}
                        end
                        return {ok = true, message = "rewind paused", data = {}}
                    end,
                },
                {
                    name = "resume",
                    shortHelp = "resume after a pause (including after a load)",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ok, err = rewind.resume(ctx, getTime())
                        if not ok then
                            return {ok = false, code = "not_paused", message = "rewind resume: " .. err}
                        end
                        return {ok = true, message = "rewind resumed", data = {}}
                    end,
                },
                {
                    name = "list",
                    aliases = {"ls"},
                    shortHelp = "list ring entries, newest first",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = ctx.rewind
                        local n = #st.entries
                        if n == 0 then
                            return {ok = true, message = "the ring is empty (status: " .. st.status .. ")",
                                data = {entries = {}, status = st.status}}
                        end
                        local nowWall = os.time()
                        local popup: {string} = {"rewind ring  (" .. tostring(n) .. ", newest first):"}
                        local rows: {{string: any}} = {}
                        for i = n, 1, -1 do
                            local e = st.entries[i]
                            local idx = n - i + 1
                            popup[#popup + 1] = format("  %d\t%ds ago\t%s\t%.1f KB\t%d entities",
                                idx, nowWall - e.time,
                                os.date("%H:%M:%S", e.time) as string, e.size / 1024, e.entities)
                            rows[#rows + 1] = {index = idx, age = nowWall - e.time,
                                time = e.time, size = e.size, entities = e.entities, path = e.path}
                        end
                        return {ok = true, popup = popup,
                            data = {entries = rows, status = st.status}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show the session state: interval, cap, window, cost",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = ctx.rewind
                        local popup: {string} = {
                            "rewind  (" .. st.status ..
                                ((st.pauseReason ~= "") and (", " .. st.pauseReason) or "") .. ")",
                            format("  interval\t%gs", st.interval),
                            "  cap\t" .. tostring(st.cap),
                            "  entries\t" .. tostring(#st.entries),
                            format("  bytes\t%.1f KB", st.bytes / 1024),
                        }
                        local nowWall = os.time()
                        if #st.entries > 0 then
                            popup[#popup + 1] = format("  window\t%ds to %ds ago",
                                nowWall - st.entries[#st.entries].time,
                                nowWall - st.entries[1].time)
                        end
                        if st.lastCaptureMs > 0 then
                            popup[#popup + 1] = format("  last capture\t%.1f ms", st.lastCaptureMs)
                        end
                        if st.status == "running" then
                            popup[#popup + 1] = format("  next capture\tin %.1fs",
                                math.max(0, st.nextDueAt - getTime()))
                        end
                        if st.lastError ~= "" then
                            popup[#popup + 1] = "  last error\t" .. st.lastError
                        end
                        return {ok = true, popup = popup,
                            data = {status = st.status, pauseReason = st.pauseReason,
                                interval = st.interval, cap = st.cap, count = #st.entries,
                                bytes = st.bytes, lastCaptureMs = st.lastCaptureMs}}
                    end,
                },
                {
                    name = "load",
                    shortHelp = "restore a ring entry; capture pauses until resumed",
                    mcpHelp = "Rewind the live world to a ring entry: ref is a newest-first index or latest, or use ago=N seconds. Overwrites current world state (selection, marks, and notes clear) and pauses capture until debug_rewind_resume. Pair with the step tool to replay toward a bug.",
                    schema = { args = {
                        ref = {help = "entry index (newest first), latest, or Ns for seconds back"},
                        ago = {kind = "number", help = "seconds back; picks the closest at or before"},
                    }, positional = {"ref"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local held, heldErr = loadCooldown("rewind load")
                        if held then
                            return {ok = false, code = "busy", message = heldErr}
                        end
                        local e, idx, err = rewind.findEntry(ctx, v.ref as string, v.ago as number)
                        if not e then
                            return {ok = false, code = "no_match", message = "rewind load: " .. err}
                        end
                        local bytes = love.filesystem.read(e.path)
                        if not bytes then
                            return {ok = false, code = "read_failed",
                                message = "rewind load: cannot read " .. e.path}
                        end
                        local ok, lerr = pcall(w.loadSnapshot, w, bytes)
                        if not ok then
                            return {ok = false, code = "load_failed",
                                message = "rewind load failed: " .. tostring(lerr)}
                        end
                        reg.lastWorldLoadAt = getTime()
                        ctx.selected = {}
                        ctx.marks = {}
                        ctx.notes = {}
                        if ctx.rewind.status == "running" then
                            ctx.rewind.status = "paused"
                            ctx.rewind.pauseReason = "loaded"
                        end
                        local age = os.time() - e.time
                        debugcontext.pushEvent(ctx, "rewind", {loaded = idx, age = age})
                        return {ok = true,
                            message = format("rewound %ds (entry %d); capture paused, `rewind resume` to continue",
                                age, idx),
                            data = {index = idx, age = age, path = e.path, entities = e.entities}}
                    end,
                },
                {
                    name = "keep",
                    shortHelp = "promote a ring entry into the snapshot history",
                    mcpHelp = "Copy a ring entry into the permanent snapshot history with a snapshot number, preserving its capture time. Use it to keep pre-bug evidence before the ring evicts it. Returns the new snapshot number.",
                    schema = { args = {
                        ref = {help = "entry index (newest first), latest, or Ns for seconds back"},
                        name = {help = "snapshot filename for the copy"},
                        ago = {kind = "number", help = "seconds back; picks the closest at or before"},
                    }, positional = {"ref", "name"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local e, idx, err = rewind.findEntry(ctx, v.ref as string, v.ago as number)
                        if not e then
                            return {ok = false, code = "no_match", message = "rewind keep: " .. err}
                        end
                        local bytes = love.filesystem.read(e.path)
                        if not bytes then
                            return {ok = false, code = "read_failed",
                                message = "rewind keep: cannot read " .. e.path}
                        end
                        reg.saveCounter = reg.saveCounter + 1
                        local name = (v.name as string)
                            or ("kept-rewind-" .. tostring(reg.saveCounter) .. ".snapshot")
                        local wok, werr = love.filesystem.write(name, bytes)
                        if not wok then
                            reg.saveCounter = reg.saveCounter - 1
                            return {ok = false, code = "save_failed",
                                message = "rewind keep: " .. tostring(werr)}
                        end
                        invalidateDiffCache()
                        reg.saves[reg.saveCounter] = name
                        -- The entry keeps its capture time: "before the bug"
                        -- means when it was taken, not when it was promoted.
                        ctx.snapshots[#ctx.snapshots + 1] = {
                            number = reg.saveCounter, path = name,
                            size = e.size, time = e.time, entities = e.entities,
                        }
                        w:emit(0, debugcontext.OnDebugContext("snapshot", name, reg.saveCounter))
                        debugcontext.pushEvent(ctx, "snapshot",
                            {number = reg.saveCounter, path = name, keptFromRewind = idx})
                        return {ok = true,
                            message = "kept entry " .. tostring(idx) .. " as snapshot #" ..
                                tostring(reg.saveCounter) .. " (" .. name .. ")",
                            data = {number = reg.saveCounter, path = name, index = idx,
                                capturedAt = e.time, entities = e.entities}}
                    end,
                },
                {
                    name = "clear",
                    shortHelp = "delete the ring files and reset to idle",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local removed = rewind.clear(ctx)
                        invalidateDiffCache()
                        debugcontext.pushEvent(ctx, "rewind", {cleared = removed})
                        return {ok = true, message = "rewind cleared (" .. tostring(removed) .. " files)",
                            data = {removed = removed}}
                    end,
                },
            },
        },
        {
            name = "diff",
            section = "Capture",
            shortHelp = "structural diff between snapshots, rewind entries, and the live world",
            mcpHelp = "Compare two moments structurally: from/to are a snapshot number, name, or latest; rewind:<idx|latest|Ns|ago=N>; or current (default to). Call with limit=0 first: the per-component summary always covers the whole diff and tells you what to filter (component=, ignore=, entity=). Read-only. Returns summary, changes with JSON Pointer paths, and the path of a JSON artifact holding the full result. Drill in with debug_diff_get.",
            schema = {
                args = {
                    from = {required = true,
                        help = "snapshot number/name/latest, rewind:<idx|latest|Ns|ago=N>, or current"},
                    to = {help = "second reference; defaults to current"},
                    entity = {help = "restrict to an entity id, mark, or @selection"},
                    component = {help = "restrict to one component"},
                    ignore = {kind = "list",
                        help = "components to exclude (comma separated, or a JSON array)"},
                    epsilon = {kind = "number", min = 0, help = "numeric tolerance (default exact)"},
                    limit = {default = 100, min = 0, help = "max detailed changes; 0 = summary only"},
                },
                positional = {"from", "to"},
            },
            examples = {"diff 1", "diff rewind:10s ignore=Transform", "diff 1 2 component=Health",
                "diff rewind:3 current limit=0", "diff get /changes/0/after"},
            subcommands = {
                artifactList("diffs",
                    function(): {any} return ctx.diffs as {any} end,
                    function(e: any): string
                        local entry = e as debugcontext.DiffEntry
                        return format("  %d changes\t%.1f KB\t%s\t%s",
                            entry.changes, entry.size / 1024,
                            os.date("%Y-%m-%d %H:%M:%S", entry.time) as string, entry.path)
                    end),
                artifactClear("diffs",
                    function(): {any} return ctx.diffs as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function()
                        ctx.diffs = {}
                        reg.diffCounter = 0
                        reg.lastDiff = nil
                    end),
                artifactOpen("diff", "ref", "diff name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.diffs as {any}, ref)
                        return e and e.path as string
                    end),
                artifactPath("diff", "ref", "diff name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.diffs as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
                {
                    name = "get",
                    shortHelp = "dereference a JSON Pointer into a diff result",
                    mcpHelp = "Dereference an RFC 6901 pointer (e.g. /summary/byComponent or /changes/0/after) into the last diff result, or into a saved diff artifact when ref is given. Use after debug_diff to fetch payloads its truncated change list omitted.",
                    schema = { args = {
                        pointer = {required = true, help = "RFC 6901 pointer, e.g. /summary/byComponent"},
                        ref = {help = "diff artifact index or latest; omit for the last diff"},
                    }, positional = {"pointer", "ref"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local doc: any = reg.lastDiff
                        if v.ref ~= nil then
                            local e = findArtifact(ctx.diffs as {any}, v.ref as string)
                            if not e then
                                return {ok = false, code = "no_match",
                                    message = "diff get: no diff artifact for '" .. tostring(v.ref) .. "'. Use `diff ls`."}
                            end
                            local bytes = love.filesystem.read(e.path as string)
                            if not bytes then
                                return {ok = false, code = "read_failed",
                                    message = "diff get: cannot read " .. tostring(e.path)}
                            end
                            local okParse, parsed = pcall(json.parse, bytes)
                            if not okParse then
                                return {ok = false, code = "decode_failed",
                                    message = "diff get: cannot parse " .. tostring(e.path)}
                            end
                            doc = parsed
                        end
                        if doc == nil then
                            return {ok = false, code = "no_match",
                                message = "diff get: no diff this session; run `diff <from>` first"}
                        end
                        local node, deepest = snapdiff.resolvePointer(doc, v.pointer as string)
                        if node == nil then
                            return {ok = false, code = "no_match",
                                message = "diff get: nothing at " .. tostring(v.pointer) ..
                                    ((deepest and deepest ~= "") and (" (deepest match: " .. deepest .. ")")
                                        or " (" .. tostring(deepest) .. ")")}
                        end
                        local popup: {string} = {"diff get " .. tostring(v.pointer)}
                        local pretty = json.serializePretty(node, true)
                        for line in (pretty .. "\n"):gmatch("(.-)\n") do
                            popup[#popup + 1] = "  " .. line
                        end
                        return {ok = true, popup = popup,
                            data = {pointer = v.pointer, value = node}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local t0 = getTime()
                local entityFilter, ignoreSet, filterErr = parseDiffFilters(v)
                if filterErr then return filterErr end
                local fromSnap, fromMeta, fromCode, fromErr = decodeDiffRef(v.from as string)
                if not fromSnap then
                    return {ok = false, code = fromCode, message = fromErr}
                end
                local toSnap, toMeta, toCode, toErr = decodeDiffRef(v.to as string)
                if not toSnap then
                    return {ok = false, code = toCode, message = toErr}
                end

                local fromEntities, fromM = snapdiff.normalize(fromSnap)
                local toEntities, toM = snapdiff.normalize(toSnap)
                -- Custom snapshot-handler data never survives the scratch
                -- decode, so any binary ref makes it incomparable.
                if fromMeta.ref ~= "current" then fromM.hasCustomData = true end
                if toMeta.ref ~= "current" then toM.hasCustomData = true end
                local result = snapdiff.compare(fromEntities, fromM, toEntities, toM, {
                    entityFilter = entityFilter,
                    component = v.component as string,
                    ignore = ignoreSet,
                    epsilon = v.epsilon as number,
                    limit = math.max(0, math.floor(v.limit as number)) as integer,
                })
                result.from = fromMeta
                result.to = toMeta
                result.elapsedMs = (getTime() - t0) * 1000
                reg.lastDiff = result

                -- Every run is also written as a JSON artifact for external
                -- tools and agents with file access.
                reg.diffCounter = reg.diffCounter + 1
                local fileName = "debug-diff-" .. tostring(reg.diffCounter) .. ".json"
                local wok, werr = love.filesystem.write(fileName, json.serialize(result, true))
                if wok then
                    local finfo = love.filesystem.getInfo(fileName) as {string: any}
                    ctx.diffs[#ctx.diffs + 1] = {
                        path = fileName,
                        size = ((finfo and finfo.size) or 0) as integer,
                        time = os.time() as integer,
                        changes = result.totalChanges as integer,
                    }
                    result.path = fileName
                else
                    -- The comparison itself succeeded; report the artifact
                    -- failure without minting a history entry for a missing file.
                    result.artifactError = tostring(werr or "write failed")
                end
                debugcontext.pushEvent(ctx, "diff",
                    {from = fromMeta.ref, to = toMeta.ref, changes = result.totalChanges})

                return {ok = true, popup = diffPopup(result, fromMeta, toMeta), data = result}
            end,
        },
        {
            name = "screenshot",
            section = "Capture",
            shortHelp = "capture the screen (or drag area) to a PNG",
            schema = {
                args = {
                    name = {help = "output filename"},
                    panel = {kind = "boolean", help = "keep the debug panel visible in the shot"},
                    delay = {kind = "number", help = "seconds to wait before capturing"},
                },
                positional = {"name"},
            },
            examples = {"screenshot", "screenshot boss.png", "screenshot panel=true delay=2",
                "screenshot ls"},
            subcommands = {
                artifactList("screenshots",
                    function(): {any} return ctx.screenshots as {any} end,
                    function(e: any): string
                        local s = e as debugcontext.ScreenshotEntry
                        return format("  %.1f KB\t%s\t%s",
                            s.size / 1024, os.date("%Y-%m-%d %H:%M:%S", s.time) as string, s.path)
                    end),
                artifactClear("screenshots",
                    function(): {any} return ctx.screenshots as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function() ctx.screenshots = {} end),
                artifactOpen("screenshot", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.screenshots as {any}, ref)
                        return e and e.path as string
                    end),
                artifactPath("screenshot", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.screenshots as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
                artifactInfo("screenshot", "capture",
                    "show one capture's details with a thumbnail (latest if omitted)",
                    captureRefSchema,
                    function(): {any} return ctx.screenshots as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifactInfoLines("screenshot", e, abs)
                        return {ok = true, popup = lines,
                            -- The overlay renders the file as a thumbnail for
                            -- the popup's lifetime.
                            popupImagePath = e.path as string,
                            data = {path = e.path, full = abs, size = e.size, time = e.time}}
                    end),
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                reg.shotCounter = reg.shotCounter + 1
                local name = (v.name as string) or ("debug-shot-" .. tostring(reg.shotCounter) .. ".png")
                local p = pipeline()
                local hasArea = ctx.hasArea and p ~= nil
                local ax1, ay1, ax2, ay2 = 0.0, 0.0, 0.0, 0.0
                if hasArea then
                    local cam = p:getCamera()
                    ax1, ay1 = cam:toScreen(ctx.areaX1, ctx.areaY1)
                    ax2, ay2 = cam:toScreen(ctx.areaX2, ctx.areaY2)
                end
                local keepPanel = v.panel == true
                local delay = (v.delay as number) or 0
                local function fire()
                    -- Hide the overlay chrome for this one frame so the shot is
                    -- the game only (unless panel=true); the capture runs at
                    -- end of frame.
                    if not keepPanel then
                        reg.signals.hideOverlay = true
                    end
                    love.graphics.captureScreenshot(function(imageData: love.image.ImageData)
                        local captureErr: string = nil
                        local ok = xpcall(function()
                            local finalData = imageData
                            if hasArea then
                                local pw = imageData:getWidth()
                                local ph = imageData:getHeight()
                                local scaleX = pw / love.graphics.getWidth()
                                local scaleY = ph / love.graphics.getHeight()
                                local cx = math.max(0, math.min(math.floor(math.min(ax1, ax2) * scaleX) as integer, pw - 1))
                                local cy = math.max(0, math.min(math.floor(math.min(ay1, ay2) * scaleY) as integer, ph - 1))
                                local cw = math.max(1, math.min(math.floor(math.abs(ax2 - ax1) * scaleX) as integer, pw - cx))
                                local ch = math.max(1, math.min(math.floor(math.abs(ay2 - ay1) * scaleY) as integer, ph - cy))
                                local cropped = love.image.newImageData(cw, ch)
                                cropped:paste(imageData, 0, 0, cx, cy, cw, ch)
                                finalData = cropped
                            end
                            finalData:encode("png", name)
                            local info = love.filesystem.getInfo(name)
                            local size = (info and info.size) or 0
                            ctx.screenshots[#ctx.screenshots + 1] =
                                {path = name, size = size as integer, time = os.time()}
                            w:emit(0, debugcontext.OnDebugContext("screenshot", name, 0))
                            debugcontext.pushEvent(ctx, "screenshot", {path = name})
                            debugcontext.setStatus(ctx, "screenshot saved at " .. debugcontext.savePath(name))
                        end, function(e: any): string
                            captureErr = tostring(e)
                            return captureErr
                        end)
                        if not ok then
                            LOGGER:error("screenshot capture failed name=%s error=%s", name, captureErr)
                            debugcontext.setStatus(ctx, "screenshot failed: " .. captureErr)
                        end
                    end)
                end
                if delay > 0 then
                    reg.pendingShots[#reg.pendingShots + 1] = {dueIn = delay, fire = fire}
                    return {ok = true,
                        message = format("capturing %s in %.1fs%s%s", name, delay,
                            hasArea and " (area)" or "", keepPanel and " (panel)" or ""),
                        data = {path = name, area = hasArea, panel = keepPanel, delay = delay}}
                end
                fire()
                return {ok = true, message = "capturing " .. name .. (hasArea and " (area)" or "") ..
                        (keepPanel and " (panel)" or ""),
                    data = {path = name, area = hasArea, panel = keepPanel}}
            end,
        },
        {
            name = "record",
            section = "Capture",
            shortHelp = "record the window to a video",
            examples = {"record start 30 clip fps=60", "record start debug", "record stop", "record ls"},
            subcommands = {
                {
                    name = "start",
                    shortHelp = "start recording the window",
                    schema = recordSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        -- `debug` keeps the debugger open and the game running so
                        -- it is captured in the recording without freezing.
                        local secs = v.seconds as number
                        local showDebug = v.debug as boolean
                        local stopOnOpen = v.stopOnDebugOpen as boolean
                        if stopOnOpen == nil then
                            stopOnOpen = secs <= 0 and not showDebug
                        end
                        local out = env.recorder:start({
                            seconds = secs,
                            name = v.name as string,
                            fps = math.floor(v.fps as number) as integer,
                            scale = v.scale as number,
                            countdown = v.countdown as number,
                            stopOnDebugOpen = stopOnOpen,
                            hideDebugger = not showDebug,
                        })
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop the active recording",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local out = env.recorder:stop("manual")
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "cancel",
                    shortHelp = "cancel an armed countdown",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local out = env.recorder:cancel()
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "status",
                    shortHelp = "show the current recording state",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local r = ctx.recording
                        local msg: string
                        if r.status == "countdown" then
                            msg = format("recording in %ds -> %s", math.ceil(r.countdown), r.path)
                        elseif r.status == "recording" then
                            msg = format("recording %.1fs -> %s (log %s)",
                                getTime() - r.startedAt, r.path, r.logPath)
                        elseif r.status == "failed" then
                            msg = "recording failed: " .. r.error .. " (log " .. r.logPath .. ")"
                        else
                            msg = "recording: " .. r.status
                        end
                        return {ok = true, message = msg, data = {recording = r}}
                    end,
                },
                artifactList("recordings",
                    function(): {any} return ctx.recordings as {any} end,
                    function(e: any): string
                        local rec = e as debugcontext.RecordingEntry
                        return format("  %.1f KB  %.1fs  %s  %s",
                            rec.size / 1024, rec.duration,
                            os.date("%Y-%m-%d %H:%M:%S", rec.time) as string, rec.path)
                    end),
                {
                    name = "open",
                    shortHelp = "open a completed recording (latest if omitted)",
                    schema = recordingRefSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ref = v.ref as string
                        local e = findArtifact(ctx.recordings as {any}, ref)
                        local out = env.recorder:open(e and e.path as string or ref)
                        return {ok = out.ok, message = out.message}
                    end,
                },
                artifactPath("record", "ref", "recording name or list index",
                    function(ref: string): string
                        local e = findArtifact(ctx.recordings as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
                artifactInfo("record", "recording",
                    "show one completed recording's details (latest if omitted)",
                    recordingRefSchema,
                    function(): {any} return ctx.recordings as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifactInfoLines("recording", e, abs)
                        lines[#lines + 1] = format("  duration\t%.1fs", e.duration as number)
                        lines[#lines + 1] = "  stopped\t" .. tostring(e.stopReason)
                        lines[#lines + 1] = "  log\t" .. tostring(e.path) .. ".ffmpeg.log"
                        return {ok = true, popup = lines,
                            data = {path = e.path, full = abs, size = e.size, time = e.time,
                                duration = e.duration, stopReason = e.stopReason}}
                    end),
            },
        },
    }
end

return capture

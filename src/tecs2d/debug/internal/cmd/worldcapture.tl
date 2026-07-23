--- World-state capture commands: snapshots, rewind, replay, and diffs.

local tecs <const> = require("tecs")
local bit <const> = require("bit")
local json <const> = require("tecs.utils.json")
local StringBuffer <const> = require("string.buffer")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local rewind <const> = require("tecs2d.debug.internal.rewind")
local snapdiff <const> = require("tecs2d.debug.internal.diff")
local replaytape <const> = require("tecs2d.debug.internal.replaytape")
local inputtape <const> = require("tecs2d.debug.internal.inputtape")
local suspension <const> = require("tecs2d.internal.suspension")
local artifacts <const> = require("tecs2d.debug.internal.artifacts")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format
local getTime <const> = love.timer.getTime
local Transform <const> = tecs.builtins.Transform

local record worldcapture
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local snapshotSaveSchema <const>: cmdargs.Schema = {
    args = {
        name = {help = "output filename"},
        format = {default = "luajit", enum = {"json", "luajit"},
            help = "snapshot encoding: compact luajit binary or json"},
        layers = {kind = "list",
            help = "only save entities whose Transform.layer is in this set (values 0-31)"},
        pretty = {default = false, help = "pretty-print json output (json format only)"},
        inline = {default = false,
            help = "return the payload in the result instead of writing a numbered artifact"},
    },
    positional = {"name"},
}
cmdargs.validate(snapshotSaveSchema)

local snapshotLoadSchema <const>: cmdargs.Schema = {
    args = {
        ref = {help = "save name or number"},
        payload = {help = "inline snapshot payload: json text, or base64 luajit binary"},
        format = {default = "luajit", enum = {"json", "luajit"},
            help = "encoding of the payload or file"},
    },
    positional = {"ref"},
}
cmdargs.validate(snapshotLoadSchema)

-- Parse and validate the snapshot layer filter (numeric strings, 0..31).
-- Returns nil + nil for an absent filter, nil + error for a bad one.
local function parseLayers(raw: any): {integer}, string
    if raw == nil then return nil, nil end
    local out: {integer} = {}
    for _, item in ipairs(raw as {string}) do
        local n = tonumber(item)
        if not n then
            return nil, "layers must be numbers, got '" .. item .. "'"
        end
        local layer = math.floor(n)
        if layer < 0 or layer > 31 then
            return nil, "layer values must be in 0..31, got " .. item
        end
        out[#out + 1] = layer as integer
    end
    return out, nil
end

function worldcapture.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world
    local ctx <const> = d.ctx
    local reg <const> = d.reg
    local componentFor <const> = d.componentFor
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


    -- Count live entities and non-empty archetypes for snapshot reports.
    local function countEntities(): integer, integer
        local ec, ac = 0, 0
        w:forEachArchetype(function(arch: tecs.Archetype)
            local c = arch.entities[0] as integer
            if c > 0 then
                ec = ec + c
                ac = ac + 1
            end
        end)
        return ec, ac
    end

    -- The same counts under a layer filter: what saveSnapshot will actually
    -- emit, so the reported numbers stay truthful.
    local function countLayerFiltered(layers: {integer}): integer, integer
        local mask = 0
        for i = 1, #layers do mask = bit.bor(mask, bit.lshift(1, layers[i])) end
        local ec, ac = 0, 0
        w:forEachArchetype(function(arch: tecs.Archetype)
            local c = arch.entities[0] as integer
            local transforms = arch:get(Transform) as {{string: integer}}
            if c == 0 or not transforms then return end
            local matched = 0
            for row = 1, c do
                local layer = transforms[row].layer
                if bit.band(bit.rshift(mask, layer), 1) == 1 then
                    matched = matched + 1
                end
            end
            if matched > 0 then
                ec = ec + matched
                ac = ac + 1
            end
        end)
        return ec, ac
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
                    "diff: no snapshot for '" .. plain .. "'. Use `snapshot list`."
            end
            path = name
            local entry = artifacts.find(ctx.snapshots as {any}, plain, true)
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
            name = "snapshot",
            section = "Capture",
            shortHelp = "save and restore the whole world",
            examples = {"snapshot save boss-fight", "snapshot load 3", "snapshot list"},
            subcommands = {
                {
                    name = "save",
                    shortHelp = "save the world; reports a number for load/open",
                    mcpHelp = "Save the whole world to a snapshot file in the save directory (format luajit by default, or json; layers restricts to Transform layers). Returns a snapshot number usable as a cmd_snapshot_load and cmd_diff ref. inline=true instead returns the payload in the result (a json snapshot object, or a base64 luajit payload) and writes no artifact. Does not disturb the running game.",
                    schema = snapshotSaveSchema,
                    examples = {"snapshot save", "snapshot save boss-fight",
                        "snapshot save format=json pretty=true",
                        "snapshot save inline=true format=json", "snapshot save layers=0,1"},
                    outputSchema = {
                        type = "object",
                        properties = {
                            number = {type = "integer",
                                description = "snapshot number (artifact form only)"},
                            path = {type = "string",
                                description = "save-dir filename (artifact form only)"},
                            size = {type = "integer", description = "file size in bytes (artifact form only)"},
                            format = {type = "string"},
                            snapshot = {type = "object",
                                description = "the snapshot object (inline json form only)"},
                            payload = {type = "string",
                                description = "base64 snapshot binary (inline luajit form only)"},
                            encoding = {type = "string",
                                description = "always base64 in the inline luajit form"},
                            bytes = {type = "integer",
                                description = "payload size in bytes (inline forms only)"},
                            entities = {type = "integer", description = "entities saved"},
                            archetypes = {type = "integer",
                                description = "archetypes saved (inline forms only)"},
                            elapsedMs = {type = "number", description = "inline forms only"},
                        },
                        required = {"entities"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local fmt = v.format as string
                        local layers, lerr = parseLayers(v.layers)
                        if lerr then
                            return {ok = false, code = "invalid_arguments",
                                message = "snapshot save: " .. lerr}
                        end
                        local pretty = v.pretty == true

                        if v.inline == true then
                            -- Inline form: the payload rides in the result, no
                            -- artifact is written, and no snapshot number is
                            -- minted.
                            local tStart = getTime()
                            if fmt == "json" then
                                local okS, snapOrErr = pcall(function(): {string: any}
                                    local out = w:saveSnapshot({format = "table", layers = layers})
                                        as {string: any}
                                    return out.snapshot as {string: any}
                                end)
                                if not okS then
                                    return {ok = false, code = "save_failed",
                                        message = "snapshot save failed: " .. tostring(snapOrErr)}
                                end
                                local snap = snapOrErr as {string: any}
                                local archs = snap.archetypes as {{string: any}}
                                local archCount = #archs
                                local entityCount = 0
                                for i = 1, archCount do
                                    entityCount = entityCount + #(archs[i].entities as {any})
                                end
                                local payload: string
                                if pretty then
                                    payload = json.serializePretty(snap, true)
                                else
                                    payload = json.serialize(snap)
                                end
                                return {ok = true,
                                    message = format("inline json snapshot: %d entities, %.1f KB",
                                        entityCount, #payload / 1024),
                                    data = {format = "json", snapshot = snap,
                                        entities = entityCount, archetypes = archCount,
                                        bytes = #payload,
                                        elapsedMs = (getTime() - tStart) * 1000}}
                            end
                            local entityCount: integer
                            local archCount: integer
                            if layers then
                                entityCount, archCount = countLayerFiltered(layers)
                            else
                                entityCount, archCount = countEntities()
                            end
                            local okS, binOrErr = pcall(function(): string
                                local buf = StringBuffer.new()
                                local out = w:saveSnapshot({buffer = buf, layers = layers})
                                return tostring(out.buffer)
                            end)
                            if not okS then
                                return {ok = false, code = "save_failed",
                                    message = "snapshot save failed: " .. tostring(binOrErr)}
                            end
                            local binary = binOrErr as string
                            local encoded = love.data.encode("string", "base64", binary) as string
                            return {ok = true,
                                message = format("inline luajit snapshot: %d entities, %.1f KB",
                                    entityCount, #binary / 1024),
                                data = {format = "luajit", encoding = "base64", payload = encoded,
                                    entities = entityCount, archetypes = archCount,
                                    bytes = #binary,
                                    elapsedMs = (getTime() - tStart) * 1000}}
                        end

                        reg.saveCounter = reg.saveCounter + 1
                        local name = (v.name as string) or ("debug-save-" .. tostring(reg.saveCounter) .. ".snapshot")
                        local ok, err = pcall(function(): boolean
                            local payload: string
                            if fmt == "json" then
                                local out = w:saveSnapshot({format = "table", layers = layers})
                                    as {string: any}
                                local snap = out.snapshot as {string: any}
                                if pretty then
                                    payload = json.serializePretty(snap, true)
                                else
                                    payload = json.serialize(snap)
                                end
                            elseif layers then
                                local buf = StringBuffer.new()
                                local out = w:saveSnapshot({buffer = buf, layers = layers})
                                payload = tostring(out.buffer)
                            else
                                local out = w:saveSnapshot()
                                payload = tostring(out.buffer)
                            end
                            local wok, werr = love.filesystem.write(name, payload)
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
                        local entityCount: integer
                        if layers then
                            entityCount = (countLayerFiltered(layers))
                        else
                            entityCount = w:getStats().entities
                        end
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
                                format = fmt, entities = entityCount}}
                    end,
                },
                {
                    name = "load",
                    shortHelp = "restore a save (the last if omitted) or an inline payload",
                    mcpHelp = "Replace the live world with a saved snapshot (ref is a number, name, or latest) or an inline payload (json text, or base64 luajit binary; set format to match how it was produced). Destructive to current state; selection, marks, and notes clear. Loads are rate limited, so retry on a busy error after a moment.",
                    schema = snapshotLoadSchema,
                    examples = {"snapshot load", "snapshot load 3",
                        "snapshot load boss-fight format=json"},
                    outputSchema = {
                        type = "object",
                        properties = {
                            path = {type = "string",
                                description = "loaded filename (file form only)"},
                            format = {type = "string"},
                            source = {type = "string",
                                description = "the filename, or inline-payload"},
                            bytes = {type = "integer", description = "payload size in bytes"},
                            entities = {type = "integer", description = "entities after the load"},
                            archetypes = {type = "integer",
                                description = "non-empty archetypes after the load"},
                            elapsedMs = {type = "number"},
                        },
                        required = {"archetypes", "bytes", "entities", "format", "source"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local held, heldErr = loadCooldown("snapshot load")
                        if held then
                            return {ok = false, code = "busy", message = heldErr}
                        end
                        local fmt = v.format as string
                        local payload = v.payload as string
                        local source: string
                        local name: string = nil
                        if payload then
                            source = "inline-payload"
                        else
                            name = snapshotNameFor(v.ref as string)
                            if not name or name == "" then
                                return {ok = false, code = "no_match",
                                    message = "snapshot load: nothing to load. Use `snapshot list`."}
                            end
                            payload = love.filesystem.read(name)
                            if not payload then
                                return {ok = false, code = "read_failed",
                                    message = "snapshot load: cannot read " .. name .. ". Use `snapshot list`."}
                            end
                            source = name
                        end
                        local tStart = getTime()
                        local bytes = #payload
                        if fmt == "json" then
                            local okParse, parsed = pcall(json.parse, payload)
                            if not okParse then
                                return {ok = false, code = "json_parse_failed",
                                    message = "snapshot load: JSON parse failed: " .. tostring(parsed)}
                            end
                            local ok, err = pcall(function(): boolean
                                w:loadSnapshot(parsed as tecs.Snapshot)
                                return true
                            end)
                            if not ok then
                                return {ok = false, code = "load_failed",
                                    message = "snapshot load failed: " .. tostring(err)}
                            end
                        else
                            -- Inline luajit payloads arrive base64-encoded; file
                            -- reads are raw bytes.
                            local binary = payload
                            if name == nil then
                                local decodedOk, decoded = pcall(function(): string
                                    return love.data.decode("string", "base64", payload) as string
                                end)
                                if not decodedOk then
                                    return {ok = false, code = "base64_decode_failed",
                                        message = "snapshot load: base64 decode failed: " ..
                                            tostring(decoded)}
                                end
                                binary = decoded as string
                                bytes = #binary
                            end
                            local ok, err = pcall(w.loadSnapshot, w, binary)
                            if not ok then
                                return {ok = false, code = "load_failed",
                                    message = "snapshot load failed: " .. tostring(err)}
                            end
                        end
                        reg.lastWorldLoadAt = getTime()
                        ctx.selected = {}
                        ctx.marks = {}
                        ctx.notes = {}
                        local entityCount, archCount = countEntities()
                        debugcontext.pushEvent(ctx, "snapshot", {path = source, loaded = true})
                        return {ok = true, message = "loaded: " .. source,
                            data = {path = name, format = fmt, source = source, bytes = bytes,
                                entities = entityCount, archetypes = archCount,
                                elapsedMs = (getTime() - tStart) * 1000}}
                    end,
                },
                artifacts.open("snapshot", "ref", "save name or number", snapshotNameFor),
                artifacts.path("snapshot", "ref", "save name or number", snapshotNameFor,
                    debugcontext.savePath),
                artifacts.list("snapshots",
                    function(): {any} return ctx.snapshots as {any} end,
                    function(e: any): string
                        local s = e as debugcontext.SnapshotEntry
                        return format("  #%d\t%.1f KB\t%s\t%s",
                            s.number, s.size / 1024, os.date("%Y-%m-%d %H:%M:%S", s.time) as string, s.path)
                    end),
                artifacts.clear("snapshots",
                    function(): {any} return ctx.snapshots as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function()
                        reg.saves = {}
                        reg.saveCounter = 0
                        ctx.snapshots = {}
                        invalidateDiffCache()
                    end),
                artifacts.info("snapshot", "save", "show one save's details (latest if omitted)",
                    refSchema,
                    function(): {any} return ctx.snapshots as {any} end, true,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifacts.infoLines("snapshot #" .. tostring(e.number), e, abs)
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
                    mcpHelp = "Start the time-travel ring: a rolling window of world snapshots captured every interval seconds (cap entries) while the game runs unfrozen. Capture holds automatically while the game is paused. Refuses if a stopped ring still holds entries. Start this early; cmd_rewind_load and cmd_diff feed on it.",
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
                        -- The replay recorder rides the rewind session: input
                        -- events and per-frame dt are recorded while a ring
                        -- exists, so every entry doubles as a replay anchor.
                        replaytape.ensure(w)
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
                    mcpHelp = "Rewind the live world to a ring entry: ref is a newest-first index or latest, or use ago=N seconds. Overwrites current world state (selection, marks, and notes clear) and pauses capture until cmd_rewind_resume. Pair with cmd_step to replay toward a bug.",
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
                    name = "replay",
                    shortHelp = "re-run recorded input and dt forward from a ring entry",
                    mcpHelp = "Deterministically re-run the game from a ring entry: restores that snapshot (RNG state included), re-presses inputs that were held at the anchor, queues every recorded input event onto the input tape at its original gameplay frame, feeds the recorded per-frame dt, and steps. Requires gameplay to be suspended, such as while the debugger is open, and a rewind session (the recorder rides the ring). frames defaults to the full recording since that entry. Live input is not muted: touching the controls during a replay simply makes a new timeline.",
                    schema = { args = {
                        ref = {help = "entry index (newest first), latest, or Ns for seconds back"},
                        ago = {kind = "number", help = "seconds back; picks the closest at or before"},
                        frames = {kind = "number", help = "gameplay frames to replay (default: to the end of the recording)"},
                    }, positional = {"ref", "frames"} },
                    outputSchema = {
                        type = "object",
                        properties = {
                            index = {type = "integer", description = "the ring entry replayed from"},
                            frames = {type = "integer", description = "gameplay frames being replayed"},
                            events = {type = "integer", description = "recorded event rows queued"},
                            held = {type = "integer", description = "held inputs re-pressed at the anchor"},
                        },
                        required = {"index", "frames", "events", "held"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ctl = suspension.ensure(w)
                        if not ctl:isSuspended() then
                            return {ok = false, code = "not_frozen",
                                message = "rewind replay: open the debugger first; replay drives frames through step"}
                        end
                        local recorder = w.resources[replaytape.KEY]
                        if not recorder then
                            return {ok = false, code = "no_recording",
                                message = "rewind replay: no recording; start a rewind session first"}
                        end
                        local e, idx, err = rewind.findEntry(ctx, v.ref as string, v.ago as number)
                        if not e then
                            return {ok = false, code = "no_match", message = "rewind replay: " .. err}
                        end
                        if e.frame == nil then
                            return {ok = false, code = "no_anchor",
                                message = "rewind replay: that entry predates the recorder"}
                        end
                        local frames = math.floor((v.frames as number) or (recorder.frame - e.frame)) as integer
                        if frames < 1 then
                            return {ok = false, code = "empty_window",
                                message = "rewind replay: nothing recorded after that entry yet"}
                        end
                        local rows, dts, serr = recorder:slice(e.frame, frames)
                        if not rows then
                            return {ok = false, code = "window_gone", message = "rewind replay: " .. serr}
                        end

                        -- Restore the anchor world (mirrors rewind load).
                        local heldCd, heldErr = loadCooldown("rewind replay")
                        if heldCd then
                            return {ok = false, code = "busy", message = heldErr}
                        end
                        local bytes = love.filesystem.read(e.path)
                        if not bytes then
                            return {ok = false, code = "read_failed",
                                message = "rewind replay: cannot read " .. e.path}
                        end
                        local lok, lerr = pcall(w.loadSnapshot, w, bytes)
                        if not lok then
                            return {ok = false, code = "load_failed",
                                message = "rewind replay failed: " .. tostring(lerr)}
                        end
                        reg.lastWorldLoadAt = getTime()
                        ctx.selected = {}
                        ctx.marks = {}
                        ctx.notes = {}
                        if ctx.rewind.status == "running" then
                            ctx.rewind.status = "paused"
                            ctx.rewind.pauseReason = "loaded"
                        end

                        -- Feed the tape: anchor-held presses first (frame 1,
                        -- lower seq), then the recorded rows.
                        local tape = inputtape.ensure(w)
                        tape:clear()
                        local queuedHeld = 0
                        if e.held and #e.held > 0 then
                            local heldRows: {{string: any}} = {}
                            for i = 1, #e.held do
                                heldRows[i] = {at = 1, event = e.held[i].event, args = e.held[i].args}
                            end
                            local q, qerr = tape:queue(heldRows, true)
                            if not q then
                                return {ok = false, code = "tape_failed", message = "rewind replay: " .. qerr}
                            end
                            queuedHeld = q
                        end
                        if #rows > 0 then
                            local q2, qerr2 = tape:queue(rows, true)
                            if not q2 then
                                return {ok = false, code = "tape_failed", message = "rewind replay: " .. qerr2}
                            end
                        end

                        recorder:feedDts(dts, function(): boolean return ctl.stepping end)
                        ctl:step(frames)
                        debugcontext.pushEvent(ctx, "rewind", {replayed = idx, frames = frames})
                        return {ok = true,
                            message = format("replaying %d frame(s) from entry %d (%d event(s), %d held)",
                                frames, idx, #rows, queuedHeld),
                            data = {index = idx, frames = frames, events = #rows, held = queuedHeld}}
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
            mcpHelp = "Compare two moments structurally: from/to are a snapshot number, name, or latest; rewind:<idx|latest|Ns|ago=N>; or current (default to). Call with limit=0 first: the per-component summary always covers the whole diff and tells you what to filter (component=, ignore=, entity=). Read-only. Returns summary, changes with JSON Pointer paths, and the path of a JSON artifact holding the full result.",
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
            examples = {"diff 1", "diff rewind:10s ignore=Transform",
                "diff 1 2 component=Health", "diff rewind:3 current limit=0"},
            subcommands = {
                artifacts.list("diffs",
                    function(): {any} return ctx.diffs as {any} end,
                    function(e: any): string
                        local entry = e as debugcontext.DiffEntry
                        return format("  %d changes\t%.1f KB\t%s\t%s",
                            entry.changes, entry.size / 1024,
                            os.date("%Y-%m-%d %H:%M:%S", entry.time) as string, entry.path)
                    end),
                artifacts.clear("diffs",
                    function(): {any} return ctx.diffs as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function()
                        ctx.diffs = {}
                        reg.diffCounter = 0
                    end),
                artifacts.open("diff", "ref", "diff name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.diffs as {any}, ref)
                        return e and e.path as string
                    end),
                artifacts.path("diff", "ref", "diff name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.diffs as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
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
    }
end

return worldcapture


--- Engine integration commands: physics, controllers, assets, audio, logs,
--- and resources.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local gfxtypes <const> = require("tecs2d.gfx.types")
local sanitize <const> = require("tecs2d.debug.internal.sanitize")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local logtap <const> = require("tecs2d.internal.logtap")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local markup <const> = require("tecs2d.debug.internal.markup")
local assets_module <const> = require("tecs2d.assets")

local format <const> = string.format

local record engine
    --- The Engine-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local resourcesSchema <const>: cmdargs.Schema = {
    args = {
        name = {help = "named key (from tecs.newKey(\"name\")): return that resource's value"},
    },
    positional = {"name"},
}
cmdargs.validate(resourcesSchema)

local logsSchema <const>: cmdargs.Schema = {
    args = {
        query = {rest = true,
            help = "case-insensitive text in the message, logger, or level"},
        level = {enum = {"debug", "info", "warn", "error"},
            help = "minimum severity"},
        source = {completion = "loggers",
            help = "case-insensitive logger-name substring"},
        since = {kind = "number", min = 0,
            help = "only lines captured within this many seconds"},
        limit = {default = 100, min = 1, max = 500,
            help = "maximum matching lines, newest retained"},
        clear = {kind = "boolean", help = "empty the captured log ring"},
    },
    positional = {"query"},
}
cmdargs.validate(logsSchema)

local verbositySchema <const>: cmdargs.Schema = {
    args = {
        level = {enum = {"debug", "info", "warn", "error", "off"},
            help = "global logger verbosity; omit to show the current value"},
    },
    positional = {"level"},
}
cmdargs.validate(verbositySchema)

local LOG_LEVELS <const>: {string: logging.LogLevel} = {
    debug = "DEBUG",
    info = "INFO",
    warn = "WARN",
    error = "ERROR",
    off = "OFF",
}

local function shortLogTime(value: string): string
    return value:match("(%d%d:%d%d:%d%d)$") or value
end

local function logLine(entry: {string: any}): markup.Line
    local time = shortLogTime(entry.time as string)
    local level = entry.level as string
    local logger = entry.logger as string
    local message = entry.message as string
    local levelStyle = (level == "WARN" or level == "ERROR") and "warning"
        or ((level == "INFO") and "accent" or "muted")
    local prefix = time .. "  " .. level .. "  " .. logger .. "  "
    return {
        text = prefix .. message,
        style = "body",
        spans = {
            {text = time .. "  ", style = "muted"},
            {text = level, style = levelStyle},
            {text = "  ", style = "body"},
            {text = logger, style = "code"},
            {text = "  ", style = "body"},
            {text = message, style = "body"},
        },
    }
end

function engine.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local pipeline <const> = d.pipeline
    local resolveTargets <const> = d.resolveTargets
    local onOffSchema <const> = d.onOffSchema
    local optionalTargetSchema <const> = d.optionalTargetSchema

    -- Pre-mute master volume for `audio mute off`.
    local preMuteVolume: number = nil

    -- Resolve the pipeline, or produce the standard failure Result. Call
    -- sites early-return the second value.
    local function needPipeline(message: string): gfxtypes.Pipeline, cmdtypes.Result
        local p = pipeline()
        if p then return p, nil end
        return nil, {ok = false, code = "no_pipeline", message = message}
    end

    -- Plugin modules (physics, controller, assets, audio) double as their
    -- resource keys. They are read from package.loaded, never required here:
    -- a require would register their components in every game the debugger
    -- runs in, plugin installed or not. A module that was never required
    -- cannot have been installed as a plugin, so a package.loaded miss means
    -- the plugin is absent.
    local function pluginResource(modname: string): any
        local key = package.loaded[modname]
        if key == nil then return nil end
        return w.resources[key as tecs.Key<any>]
    end

    local function physicsState(): {string: any}
        return pluginResource("tecs2d.physics") as {string: any}
    end

    -- Find an entity's Box2D body by scanning shape user data.
    local function bodyForEntity(st: {string: any}, eid: integer): love.physics.Body
        local world = st.world as love.physics.World
        local bodies = world:getBodies()
        for i = 1, #bodies do
            local body = bodies[i]
            local shapes = (body as {string: any}).getShapes as function(any): {any}
            local okShapes, list = pcall(shapes, body)
            if okShapes and list then
                for j = 1, #list do
                    local shapeAny = list[j] as {string: any}
                    local getUD = shapeAny.getUserData as function(any): any
                    local okUD, data = pcall(getUD, list[j])
                    if okUD and data and ((data as {string: any}).entity as integer) == eid then
                        return body
                    end
                end
            end
        end
        return nil
    end

    local function controllerManager(): {string: any}
        return pluginResource("tecs2d.controller") as {string: any}
    end

    local function audioManager(): any
        return pluginResource("tecs2d.audio")
    end

    local function assetManager(): {string: any}
        return assets_module.manager as {string: any}
    end

    -- Sorted asset keys, optionally filtered by a plain substring. Reads the
    -- manager's strong _assetLog (the cache is weak-valued, so cache entries
    -- vanish once the game drops its handles) unioned with the live cache.
    -- Returns nil + reason when the manager is missing.
    local function assetKeys(filter: string): {string}, string
        local mgr = assetManager()
        if not mgr then
            return nil, "manager not installed"
        end
        local seen: {string: boolean} = {}
        local keys: {string} = {}
        local function collect(t: {string: any})
            for k in pairs(t or {}) do
                if not seen[k] and (not filter or k:find(filter, 1, true)) then
                    seen[k] = true
                    keys[#keys + 1] = k
                end
            end
        end
        collect(mgr._assetLog as {string: any})
        collect(mgr._cache as {string: any})
        table.sort(keys)
        return keys, nil
    end

    -- One asset's action/path/status plus whether a live handle is still
    -- cached, from the log entry or the handle (whichever exists).
    local function assetEntry(key: string): {string: any}
        local mgr = assetManager()
        local logTable = mgr._assetLog as {string: any}
        local logged = logTable and logTable[key] as {string: any}
        local cache = mgr._cache as {string: any}
        local handle = cache and cache[key] as {string: any}
        local action = logged and logged.action or "(custom)"
        local path = logged and logged.path or key
        local status = logged and (logged.status as string) or nil
        if handle and (status == nil or status == "custom") then
            status = "loaded"
            if not handle.isComplete then
                status = "loading"
            elseif handle.err ~= nil then
                status = "failed: " .. tostring(handle.err)
            end
        end
        return {key = key, action = action, path = path,
            status = status or "unknown", cached = handle ~= nil}
    end

    return {
        {
            name = "physics",
            section = "Engine",
            shortHelp = "physics info; debug draw, body info, raycast, and area query",
            examples = {"physics info", "physics debug", "physics info 42",
                "physics raycast 0 0 100 100", "physics query 0 0 64 64"},
            subcommands = {
                {
                    name = "debug",
                    shortHelp = "toggle collision-shape debug drawing (installs the drawer if needed)",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        if not physicsState() then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        -- Requiring the module here is safe: physicsState()
                        -- proves the game already loaded tecs2d.physics, so no
                        -- components get registered behind the game's back.
                        local physicsdebug = require("tecs2d.gfx.internal.physicsdebug")
                            as {string: any}
                        -- Install the debug drawer on demand.
                        if not systemcontrol.info(w, "tecs2d.gfx.physicsdebug") then
                            local p, perr = needPipeline("physics debug: the drawer needs a render pipeline")
                            if not p then return perr end
                            local newPlugin = physicsdebug.new as function(): tecs.Plugin
                            w:addPlugin(newPlugin())
                        end
                        local toggle = physicsdebug.PhysicsDebugToggle as function(): tecs.Event
                        w:emit(0, toggle())
                        return {ok = true, message = "physics debug toggled", data = {}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "physics state, or one entity's Box2D body properties",
                    schema = optionalTargetSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        if v.target == nil then
                            local pworld = st.world as love.physics.World
                            local gx, gy = pworld:getGravity()
                            return {ok = true, popup = {
                                "physics",
                                "  bodies\t" .. tostring(pworld:getBodyCount()),
                                format("  gravity\t%.2f, %.2f", gx, gy),
                                "  smoothing\t" .. tostring(st.smoothing),
                                "  debug draw\t" .. (st.debug and "on" or "off"),
                            }, data = {bodies = pworld:getBodyCount(), gravityX = gx, gravityY = gy,
                                smoothing = st.smoothing}}
                        end
                        local ids = resolveTargets(v)
                        local target = ids[1]
                        if not target then
                            return {ok = false, code = "no_match",
                                message = "physics info: no match for '" .. tostring(v.target) .. "'"}
                        end
                        local body = bodyForEntity(st, target)
                        if not body then
                            return {ok = false, code = "no_body",
                                message = "physics info: entity #" .. tostring(target) .. " has no body"}
                        end
                        local bx, by = body:getPosition()
                        local vx, vy = body:getLinearVelocity()
                        return {ok = true, popup = {
                            "body #" .. tostring(target),
                            "  type\t" .. tostring(body:getType()),
                            format("  position\t%.2f, %.2f", bx, by),
                            format("  velocity\t%.2f, %.2f", vx, vy),
                            format("  angle\t%.3f", body:getAngle()),
                            format("  mass\t%.3f", body:getMass()),
                            "  awake\t" .. (body:isAwake() and "yes" or "no"),
                            "  bullet\t" .. (body:isBullet() and "yes" or "no"),
                        }, data = {entity = target, type = body:getType(), x = bx, y = by,
                            vx = vx, vy = vy, angle = body:getAngle(), mass = body:getMass(),
                            awake = body:isAwake()}}
                    end,
                },
                {
                    name = "raycast",
                    shortHelp = "cast a ray and select the hits",
                    schema = { args = {
                        x1 = {required = true, kind = "number", help = "start world x"},
                        y1 = {required = true, kind = "number", help = "start world y"},
                        x2 = {required = true, kind = "number", help = "end world x"},
                        y2 = {required = true, kind = "number", help = "end world y"},
                    }, positional = {"x1", "y1", "x2", "y2"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        local x1 = v.x1 as number
                        local y1 = v.y1 as number
                        local x2 = v.x2 as number
                        local y2 = v.y2 as number
                        local hits: {{string: number}} = {}
                        local raycaster = st.world as {string: any}
                        local rayFn = raycaster.rayCast as function(any, number, number, number, number,
                            function(any, number, number, number, number, number): number)
                        local castOk, castErr = pcall(rayFn, st.world, x1, y1, x2, y2,
                            function(shape: any, hx: number, hy: number,
                                    _nx: number, _ny: number, fraction: number): number
                                local shapeAny = shape as {string: any}
                                local getUD = shapeAny.getUserData as function(any): any
                                local data = getUD(shape) as {string: any}
                                local eid = data and (data.entity as integer) or 0
                                hits[#hits + 1] = {entity = eid, x = hx, y = hy, fraction = fraction}
                                return 1   -- keep going: collect every hit
                            end) as (boolean, any)
                        if not castOk then
                            return {ok = false, code = "raycast_failed",
                                message = "physics raycast: " .. tostring(castErr)}
                        end
                        table.sort(hits, function(a: {string: number}, b: {string: number}): boolean
                            return a.fraction < b.fraction
                        end)
                        for i = 1, #hits do
                            if hits[i].entity ~= 0 then
                                debugcontext.addSelected(ctx, hits[i].entity as integer)
                            end
                        end
                        if #hits > 0 then
                            debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                        end
                        return {ok = true,
                            message = "raycast hit " .. tostring(#hits) .. " shape(s)",
                            data = {hits = hits}}
                    end,
                },
                {
                    name = "query",
                    shortHelp = "select bodies inside a world-space box",
                    schema = { args = {
                        x = {required = true, kind = "number", help = "left world x"},
                        y = {required = true, kind = "number", help = "top world y"},
                        w = {required = true, kind = "number", help = "width"},
                        h = {required = true, kind = "number", help = "height"},
                    }, positional = {"x", "y", "w", "h"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        local qx = v.x as number
                        local qy = v.y as number
                        local qw = v.w as number
                        local qh = v.h as number
                        local found: {integer} = {}
                        local seen: {integer: boolean} = {}
                        local pworld = st.world as love.physics.World
                        pworld:queryBoundingBox(qx, qy, qx + qw, qy + qh,
                            function(shape: any): boolean
                                local shapeAny = shape as {string: any}
                                local getUD = shapeAny.getUserData as function(any): any
                                local okUD, data = pcall(getUD, shape)
                                local eid = okUD and data and ((data as {string: any}).entity as integer) or 0
                                if eid ~= 0 and not seen[eid] then
                                    seen[eid] = true
                                    found[#found + 1] = eid
                                    debugcontext.addSelected(ctx, eid)
                                end
                                return true
                            end)
                        if #found > 0 then
                            debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                        end
                        return {ok = true,
                            message = "query matched " .. tostring(#found) .. " bodies",
                            data = {entities = found}}
                    end,
                },
            },
        },
        {
            name = "controllers",
            section = "Engine",
            shortHelp = "list controllers; `info <n>` shows bindings, `rumble` tests one",
            examples = {"controllers list", "controllers info 1", "controllers rumble 1"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list controllers and their joysticks",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local list = mgr.controllers as {any}
                        local popup: {string} = {"controllers  (" .. tostring(#list) .. "):"}
                        local rows: {{string: any}} = {}
                        for i = 1, #list do
                            local ctrl = list[i] as {string: any}
                            local js = ctrl.joystick as {string: any}
                            local jsName = "(no joystick)"
                            if js then
                                local getName = js.getName as function(any): string
                                local okName, nm = pcall(getName, js)
                                jsName = okName and nm or "(unknown)"
                            end
                            popup[#popup + 1] = "  " .. tostring(i) .. "\t" .. jsName
                            rows[#rows + 1] = {index = i, joystick = jsName}
                        end
                        return {ok = true, popup = popup,
                            data = {count = #list, controllers = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show a controller's joystick, deadzone, and bindings",
                    schema = { args = { id = {required = true, kind = "number", help = "controller index"} },
                        positional = {"id"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local list = mgr.controllers as {any}
                        local idx = math.floor(v.id as number)
                        local ctrl = list[idx] as {string: any}
                        if not ctrl then
                            return {ok = false, code = "no_match",
                                message = "controllers info: no controller " .. tostring(idx)}
                        end
                        local js = ctrl.joystick as {string: any}
                        local jsName = "(none)"
                        if js then
                            local getName = js.getName as function(any): string
                            local okName, nm = pcall(getName, js)
                            jsName = okName and nm or "(unknown)"
                        end
                        local popup: {string} = {
                            "controller " .. tostring(idx),
                            "  joystick\t" .. jsName,
                            format("  deadzone\t%.2f", (ctrl.deadzone as number) or 0),
                            "  auto-assign\t" .. (ctrl.auto and "yes" or "no"),
                            "Bindings:",
                        }
                        local bindings = ctrl.bindings as {string: {string}}
                        local actions: {string} = {}
                        for action in pairs(bindings or {}) do actions[#actions + 1] = action end
                        table.sort(actions)
                        for i = 1, #actions do
                            popup[#popup + 1] = "  " .. actions[i] .. "\t" ..
                                table.concat(bindings[actions[i]], ", ")
                        end
                        return {ok = true, popup = popup,
                            data = {id = idx, joystick = jsName,
                                deadzone = ctrl.deadzone, auto = ctrl.auto, bindings = bindings}}
                    end,
                },
                {
                    name = "rumble",
                    shortHelp = "vibrate a controller's joystick to verify it",
                    schema = { args = {
                        id = {required = true, kind = "number", help = "controller index"},
                        seconds = {default = 0.5, help = "vibration duration"},
                    }, positional = {"id", "seconds"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local ctrl = (mgr.controllers as {any})[math.floor(v.id as number)] as {string: any}
                        if not ctrl then
                            return {ok = false, code = "no_match",
                                message = "controllers rumble: no controller " .. tostring(v.id)}
                        end
                        local js = ctrl.joystick as {string: any}
                        if not js then
                            return {ok = false, code = "no_joystick",
                                message = "controllers rumble: controller " .. tostring(v.id) ..
                                    " has no joystick assigned"}
                        end
                        local vib = js.setVibration as function(any, number, number, number): boolean
                        local okVib = pcall(vib, js, 1, 1, v.seconds as number)
                        return {ok = true,
                            message = okVib and "rumbling controller " .. tostring(v.id)
                                or "controller " .. tostring(v.id) .. " does not support vibration",
                            data = {id = v.id, supported = okVib}}
                    end,
                },
            },
        },
        {
            name = "assets",
            section = "Engine",
            shortHelp = "list cached assets, show one, or reload one from disk",
            examples = {"assets list", "assets info player.png", "assets reload player.png"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list cached asset keys, optionally filtered",
                    schema = { args = { filter = {help = "substring to filter keys"} },
                        positional = {"filter"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local keys, err = assetKeys(v.filter as string)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        local popup: {string} = {"assets  (" .. tostring(#keys) .. "):"}
                        local rows: {{string: any}} = {}
                        for i = 1, #keys do
                            local e = assetEntry(keys[i])
                            rows[#rows + 1] = e
                            popup[#popup + 1] = format("  %s\t%s%s", e.status as string,
                                e.path as string, (e.cached as boolean) and "" or "\t(handle dropped)")
                        end
                        if #keys == 0 then popup[#popup + 1] = "  (none)" end
                        return {ok = true, popup = popup, data = {count = #keys, assets = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show a cached asset's action, path, and load state",
                    schema = { args = { path = {required = true, help = "asset path or key substring"} },
                        positional = {"path"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = v.path as string
                        local keys, err = assetKeys(wanted)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        if #keys == 0 then
                            return {ok = false, code = "no_match",
                                message = "assets info: nothing loaded matching '" .. wanted .. "'"}
                        end
                        local e = assetEntry(keys[1])
                        return {ok = true, popup = {
                            "asset " .. keys[1],
                            "  action\t" .. tostring(e.action),
                            "  path\t" .. tostring(e.path),
                            "  status\t" .. tostring(e.status),
                            "  live handle\t" .. ((e.cached as boolean) and "yes" or "no (dropped)"),
                        }, data = e}
                    end,
                },
                {
                    name = "reload",
                    shortHelp = "re-read matching cached assets from disk in place",
                    schema = { args = { path = {required = true, help = "asset path or key substring"} },
                        positional = {"path"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = v.path as string
                        local keys, err = assetKeys(wanted)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        if #keys == 0 then
                            return {ok = false, code = "no_match",
                                message = "assets reload: nothing cached matching '" .. wanted .. "'"}
                        end
                        local mgr = assetManager()
                        local assetLog = mgr._assetLog as {string: {string: any}}
                        local reloaded: {string} = {}
                        local skipped = 0
                        for i = 1, #keys do
                            local key = keys[i]
                            local reload = mgr._reload as function(any, string): any
                            if reload and reload(mgr, key) then
                                reloaded[#reloaded + 1] = key
                                local logged = assetLog and assetLog[key]
                                if logged then logged.status = "loading" end
                            else
                                skipped = skipped + 1
                            end
                        end
                        if #reloaded == 0 then
                            return {ok = false, code = "not_reloadable",
                                message = "assets reload: no built-in request metadata matched"}
                        end
                        debugcontext.pushEvent(ctx, "edit", {assetsReloaded = #reloaded})
                        return {ok = true,
                            message = "reloading " .. tostring(#reloaded) .. " asset(s)" ..
                                ((skipped > 0) and (", skipped " .. tostring(skipped)) or "") ..
                                "; future asset lookups use the refreshed handles",
                            data = {reloaded = reloaded, skipped = skipped}}
                    end,
                },
            },
        },
        {
            name = "audio",
            section = "Engine",
            shortHelp = "audio info; stop everything or mute the master group",
            examples = {"audio info", "audio stop", "audio mute", "audio mute off"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show active sources per group and the master volume",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local mgrAny = mgr as {string: any}
                        local active = mgrAny._activeSources as {any: any}
                        local byGroup: {string: integer} = {}
                        local total = 0
                        for _, info in pairs(active or {}) do
                            total = total + 1
                            local g = tostring((info as {string: any}).group or "?")
                            byGroup[g] = (byGroup[g] or 0) + 1
                        end
                        local getVol = mgrAny.getGroupVolume as function(any, string): number
                        local popup: {string} = {
                            "audio",
                            "  active sources\t" .. tostring(total),
                            format("  master volume\t%.2f", getVol(mgr, "master")),
                        }
                        local groups: {string} = {}
                        for g in pairs(byGroup) do groups[#groups + 1] = g end
                        table.sort(groups)
                        for i = 1, #groups do
                            popup[#popup + 1] = "  " .. groups[i] .. "\t" .. tostring(byGroup[groups[i]]) .. " playing"
                        end
                        return {ok = true, popup = popup,
                            data = {active = total, groups = byGroup, masterVolume = getVol(mgr, "master")}}
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop every active source",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local stopAll = (mgr as {string: any}).stopAll as function(any)
                        stopAll(mgr)
                        return {ok = true, message = "stopped all sources", data = {}}
                    end,
                },
                {
                    name = "mute",
                    shortHelp = "silence the master group; `audio mute off` restores",
                    schema = onOffSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local mgrAny = mgr as {string: any}
                        local getVol = mgrAny.getGroupVolume as function(any, string): number
                        local setVol = mgrAny.setGroupVolume as function(any, string, number)
                        local want = v.on as boolean
                        if want == nil then want = getVol(mgr, "master") > 0 end
                        if want then
                            preMuteVolume = getVol(mgr, "master")
                            if preMuteVolume <= 0 then preMuteVolume = 1 end
                            setVol(mgr, "master", 0)
                        else
                            setVol(mgr, "master", preMuteVolume or 1)
                        end
                        return {ok = true, message = want and "audio muted" or "audio unmuted",
                            data = {muted = want}}
                    end,
                },
            },
        },
        {
            name = "logs",
            section = "Engine",
            mcp = false,
            shortHelp = "search recent engine logs or change logger verbosity",
            schema = logsSchema,
            examples = {
                "logs",
                "logs collision",
                "logs level=warn",
                "logs source=tecs2d.debug since=10",
                "logs verbosity",
                "logs verbosity debug",
            },
            subcommands = {
                {
                    name = "verbosity",
                    mcp = false,
                    shortHelp = "show or change the global logger verbosity",
                    schema = verbositySchema,
                    examples = {
                        "logs verbosity",
                        "logs verbosity debug",
                        "logs verbosity info",
                        "logs verbosity off",
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local previous = logging.level
                        local requested = v.level as string
                        if requested then
                            logging.setLevel(LOG_LEVELS[requested])
                        end
                        local current = logging.level
                        local message = requested
                            and ("log verbosity: " .. previous:lower()
                                .. " -> " .. current:lower())
                            or ("log verbosity: " .. current:lower())
                        return {
                            ok = true,
                            message = message,
                            data = {
                                verbosity = current,
                                previous = requested and previous or nil,
                            },
                        }
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                if v.clear == true then
                    local cleared = logtap.clear()
                    return {
                        ok = true,
                        message = "logs: cleared " .. tostring(cleared) .. " line(s)",
                        data = {cleared = cleared},
                    }
                end

                local level = (v.level as string) or "debug"
                local minRank = logtap.levelRank(level)
                local entries, matched, captured, dropped, latest = logtap.query(
                    minRank,
                    v.query as string,
                    v.source as string,
                    0,
                    (v.since as number) or 0,
                    v.limit as integer)

                local document = markup.new("logs")
                local summary = tostring(#entries) .. " shown"
                    .. "  ·  " .. tostring(matched) .. " matched"
                    .. "  ·  " .. tostring(captured) .. " captured"
                    .. "  ·  verbosity " .. logging.level:lower()
                if dropped > 0 then
                    summary = summary .. "  ·  " .. tostring(dropped) .. " dropped"
                end
                markup.text(document, summary, "muted")
                if #entries == 0 then
                    markup.text(document, "No matching log lines.", "muted")
                else
                    markup.rule(document)
                    for i = 1, #entries do
                        markup.add(document, logLine(entries[i]))
                    end
                end

                return {
                    ok = true,
                    popupDocument = document,
                    popupModal = true,
                    popupClosable = true,
                    popupScrollToEnd = true,
                    data = {
                        logs = entries,
                        returned = #entries,
                        matched = matched,
                        captured = captured,
                        dropped = dropped,
                        latest = latest,
                    },
                }
            end,
        },
        {
            name = "resources",
            section = "Engine",
            shortHelp = "list world resources; pass a name to read one value",
            mcpHelp = "Without arguments: every world resource as {key, type} -- keys created with "
                .. "tecs.newKey(\"name\") resolve to that name -- plus `unset`, the registered key "
                .. "names holding no value yet. With name=<key name>: that resource's current value, "
                .. "deep-copied to JSON-safe data (live objects render as their tostring). This is "
                .. "the way to read named game state (e.g. a GameState resource) without writing Lua.",
            examples = {"resources", "resources game.state"},
            annotations = {readOnlyHint = true, idempotentHint = true},
            schema = resourcesSchema,
            outputSchema = {
                type = "object",
                properties = {
                    count = {type = "integer"},
                    resources = {type = "array", items = {type = "object", properties = {
                        key = {type = "string", description = "resource key name"},
                        type = {type = "string", description = "value type name"},
                    }}},
                    unset = {type = "array", items = {type = "string"},
                        description = "registered key names with no value (list form)"},
                    key = {type = "string", description = "the requested key (value form)"},
                    set = {type = "boolean", description = "whether the resource holds a value (value form)"},
                    value = {description = "the resource value, JSON-safe (value form)"},
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local named = tecs.listKeys()

                -- Value form: read one named resource.
                if v.name ~= nil then
                    local nm = v.name as string
                    local id = named[nm]
                    if not id then
                        local known: {string} = {}
                        for n in pairs(named) do known[#known + 1] = n end
                        table.sort(known)
                        return {ok = false, code = "unknown_key",
                            message = "resources: no key named '" .. nm .. "'; named keys: "
                                .. table.concat(known, ", ")}
                    end
                    local value = (w.resources as {any: any})[id]
                    return {ok = true,
                        popup = {"resource " .. nm .. " (" .. type(value) .. ")"},
                        data = {key = nm, set = value ~= nil,
                            value = sanitize.value(value)}}
                end

                local reverse: {integer: string} = {}
                for n, id in pairs(named) do reverse[id] = n end

                local resources = w.resources as {any: any}
                local rows: {{string: any}} = {}
                for key, value in pairs(resources) do
                    local keyStr: string
                    if type(key) == "table" and (key as {string: any}).name then
                        keyStr = (key as {string: any}).name as string
                    elseif type(key) == "number" and reverse[key as integer] then
                        keyStr = reverse[key as integer]
                    else
                        keyStr = tostring(key)
                    end
                    local valueType: string
                    if type(value) == "table" and getmetatable(value) then
                        local mt = getmetatable(value) as {string: any}
                        if mt.__name then
                            valueType = mt.__name as string
                        elseif mt.__index and type(mt.__index) == "table"
                            and (mt.__index as {string: any}).__name then
                            valueType = (mt.__index as {string: any}).__name as string
                        else
                            valueType = "table"
                        end
                    else
                        valueType = type(value)
                    end
                    rows[#rows + 1] = {key = keyStr, type = valueType}
                end
                table.sort(rows, function(a: {string: any}, b: {string: any}): boolean
                    return (a.key as string) < (b.key as string)
                end)

                -- Named keys with no value: still worth surfacing, so an agent
                -- learns the name exists before the game first sets it.
                local unset: {string} = {}
                for n, id in pairs(named) do
                    if resources[id] == nil then unset[#unset + 1] = n end
                end
                table.sort(unset)

                local popup: {string} = {"resources  (" .. tostring(#rows) .. "):"}
                for i = 1, #rows do
                    popup[#popup + 1] = "  " .. tostring(rows[i].key) .. "\t" ..
                        tostring(rows[i].type)
                end
                return {ok = true, popup = popup,
                    data = {count = #rows, resources = rows, unset = unset}}
            end,
        },
    }
end

return engine

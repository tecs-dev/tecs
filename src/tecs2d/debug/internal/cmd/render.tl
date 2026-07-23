--- Render-section debugger commands: light, camera, layers, grid, bounds,
--- map, materials, and sprites, plus their shared helpers (camera summary,
--- layer references, solo-restore state, and tilemap lookup).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local gfxtypes <const> = require("tecs2d.gfx.types")
local materialregistry <const> = require("tecs2d.gfx.internal.materialregistry")
local bucketmanager <const> = require("tecs2d.gfx.internal.sprite.bucketmanager")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format

local Transform <const> = tecs.builtins.Transform

local record render
    --- The Render-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

-- One live Tilemap entity: its id, the tilemap component instance (opaque;
-- the debugger never loads the tiled module), and its Transform position.
local record TilemapEntry
    entity: integer
    map: any
    x: number
    y: number
end

local lightSchema <const>: cmdargs.Schema = {
    args = {
        r = {kind = "number", help = "red 0-1 (unchanged if omitted)"},
        g = {kind = "number", help = "green 0-1 (unchanged if omitted)"},
        b = {kind = "number", help = "blue 0-1 (unchanged if omitted)"},
    },
    positional = {"r", "g", "b"},
}

-- First slot is `<intensity|on>`: a number sets the glow strength, on/off toggles.
-- Numbers are tried first so `bloom 1` means intensity 1, not on=true.
local bloomSchema <const>: cmdargs.Schema = {
    args = {
        intensity = {kind = "number", forward = "level", help = "glow strength 0-10"},
        on = {kind = "boolean", forward = "level", help = "turn bloom on or off"},
        level = {synthetic = {"intensity", "on"}, help = "an intensity, or on/off"},
        radius = {kind = "number", help = "blur radius 0.1-5"},
        threshold = {kind = "number", help = "brightness cutoff 0+"},
    },
    positional = {"level", "radius", "threshold"},
}

local cameraMoveSchema <const>: cmdargs.Schema = {
    args = {
        x = {kind = "number", help = "world x (unchanged if omitted)"},
        y = {kind = "number", help = "world y (unchanged if omitted)"},
        r = {kind = "number", help = "rotation in radians (unchanged if omitted)"},
        z = {kind = "number", help = "zoom (unchanged if omitted)"},
        name = {help = "camera name (primary if omitted)"},
    },
    positional = {"x", "y", "r", "z"},
}

local cameraTimescaleSchema <const>: cmdargs.Schema = {
    args = { scale = {required = true, kind = "number", help = "0 = frozen, 1 = normal, 2 = double speed"} },
    positional = {"scale"},
}

local cameraToggleSchema <const>: cmdargs.Schema = {
    args = { name = {required = true, completion = "cameras",
        help = "camera name (see `camera`)"} },
    positional = {"name"},
}

function render.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local env <const> = d.env
    local pipeline <const> = d.pipeline
    local componentFor <const> = d.componentFor
    local tileAt <const> = d.tileAt
    local onOffSchema <const> = d.onOffSchema

    -- Solo state for `layers solo`: previous visibility per layer, restored
    -- by a bare `layers solo`.
    local soloRestore: {integer: boolean} = nil

    -- Resolve the pipeline, or produce the standard failure Result for the
    -- given message prefix. Call sites early-return the second value.
    local function needPipeline(prefix: string): gfxtypes.Pipeline, cmdtypes.Result
        local p = pipeline()
        if p then return p, nil end
        return nil, {ok = false, code = "no_pipeline",
            message = prefix .. ": no render pipeline"}
    end

    -- A layer argument is a name or a number typed as text.
    local function layerRef(raw: string): integer | string
        local n = tonumber(raw)
        if n then return math.floor(n) end
        return raw
    end

    -- Resolve a layer reference to its number via the same validation path
    -- the setters use, or nil when the layer is unknown.
    local function resolveLayerNum(p: gfxtypes.Pipeline, ref: integer | string): integer
        local okRef, target = pcall(function(): integer
            p:isLayerVisible(ref)
            if ref is string then
                return ((p as {string: any}).layerNames as {string: integer})[ref]
            end
            return ref as integer
        end)
        if not okRef then return nil end
        return target
    end

    -- Live Tilemap entities resolved by component name, so the debugger
    -- never loads the tiled module. Oldest entity first.
    local function tilemaps(): {TilemapEntry}
        local list: {TilemapEntry} = {}
        local comp = componentFor("Tilemap")
        if not comp then return list end
        w:forEachArchetype(function(arch: tecs.Archetype)
            local col = arch:get(comp) as {any}
            if not col then return end
            local tcol = arch:get(Transform)
            local n = arch.entities[0] as integer
            for row = 1, n do
                local t = tcol and tcol[row]
                list[#list + 1] = {
                    entity = arch.entities[row] as integer,
                    map = col[row],
                    x = t and t.x or 0,
                    y = t and t.y or 0,
                }
            end
        end)
        table.sort(list, function(a: TilemapEntry, b: TilemapEntry): boolean
            return a.entity < b.entity
        end)
        return list
    end

    -- One tilemap by entity id, or the first when id is nil.
    local function mapByRef(id: number): TilemapEntry, string
        local maps = tilemaps()
        if #maps == 0 then
            return nil, "no tilemaps loaded"
        end
        if id == nil then return maps[1], nil end
        local wanted = math.floor(id)
        for i = 1, #maps do
            if maps[i].entity == wanted then return maps[i], nil end
        end
        return nil, "no tilemap entity #" .. tostring(wanted)
    end

    -- Camera summary shared by `camera` and `camera info`.
    local function cameraInfo(): cmdtypes.Result
        local p, perr = needPipeline("camera")
        if not p then return perr end
        local cam = p:getCamera()
        local cx, cy = cam:getPosition()
        local vw, vh = cam:getVisibleDimensions()
        local cams: {{string: any}} = {}
        local registered = (p as {string: any})._cameras as {gfxtypes.Camera}
        if registered then
            for i = 1, #registered do
                local c = registered[i]
                cams[#cams + 1] = {name = c:getName(), active = c:isActive()}
            end
        end
        -- While frozen the live pipeline scale is 0; report the scale that
        -- resumes, in the popup and the structured payload alike.
        local frozen = env.suspension:isSuspended()
        local timescale = frozen and env.suspension.savedTimeScale or p:getTimeScale()
        local popup: {string} = {
            "camera",
            format("  position\t%.1f, %.1f", cx, cy),
            format("  zoom\t%.2f", cam:getZoom()),
            format("  rotation\t%.2f", cam:getRotation()),
            format("  visible\t%.0f x %.0f", vw, vh),
            format("  timescale\t%.2f%s", timescale, frozen and " (frozen)" or ""),
        }
        if #cams > 1 then
            popup[#popup + 1] = "Cameras:"
            for i = 1, #cams do
                popup[#popup + 1] = "  " .. tostring(cams[i].name) .. "\t" ..
                    ((cams[i].active as boolean) and "active" or "inactive")
            end
        end
        return {ok = true, popup = popup,
            data = {x = cx, y = cy, zoom = cam:getZoom(), rotation = cam:getRotation(),
                w = vw, h = vh, timescale = timescale, frozen = frozen, cameras = cams}}
    end


    -- The tile at (tx, ty) on every tile layer of a loaded map: popup lines
    -- ("layer<TAB>gid N (tileset)" or "empty") plus the structured hits.
    -- GID arrays are 0-indexed FFI casts; out-of-layer tiles are skipped.
    local function readTileLayers(data: {string: any}, tx: integer, ty: integer): {string}, {{string: any}}
        local lines: {string} = {}
        local hits: {{string: any}} = {}
        local layers = data.layers as {any}
        local tilesets = data.tilesets as {any}
        for i = 1, (layers and #layers or 0) do
            local layer = layers[i] as {string: any}
            if layer.type == "tilelayer" and layer.data ~= nil
                and tx >= 0 and ty >= 0
                and tx < (layer.width as integer) and ty < (layer.height as integer) then
                local gid = 0
                local okG, g = pcall(function(): integer
                    return (layer.data as {integer})[ty * (layer.width as integer) + tx]
                end)
                if okG then gid = g end
                -- The owning tileset is the last one whose firstgid <= gid.
                local tilesetName = ""
                if gid > 0 then
                    for tsi = 1, (tilesets and #tilesets or 0) do
                        local ts = tilesets[tsi] as {string: any}
                        if (ts.firstgid as integer) <= gid then
                            tilesetName = tostring(ts.name)
                        end
                    end
                end
                lines[#lines + 1] = "  " .. tostring(layer.name) .. "\t" ..
                    ((gid > 0) and ("gid " .. tostring(gid) ..
                        ((tilesetName ~= "") and (" (" .. tilesetName .. ")") or ""))
                        or "empty")
                hits[#hits + 1] = {name = layer.name, gid = gid,
                    tileset = (tilesetName ~= "") and tilesetName or nil}
            end
        end
        return lines, hits
    end

    return {
        {
            name = "light",
            section = "Render",
            shortHelp = "lighting state; verbs set color, bloom, lighting, and shadows",
            examples = {"light info", "light color 0.3 0.3 0.4", "light toggle",
                "light shadows off", "light bloom 3 1 0.8"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show ambient color, lighting, shadows, and bloom state",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("light")
                        if not p then return perr end
                        local cr, cg, cb = p:getAmbientLight()
                        local pAny = p as {string: any}
                        local bloom = p:getBloom()
                        local lightingOn = p:isLightingEnabled()
                        local shadowsOn = pAny.shadowsEnabled as boolean
                        return {ok = true, popup = {
                            "lighting",
                            format("  ambient\t%.2f %.2f %.2f", cr, cg, cb),
                            "  lighting\t" .. (lightingOn and "on" or "off"),
                            "  shadows\t" .. (shadowsOn and "on" or "off"),
                            format("  bloom\t%s  i%.2f  r%.2f  t%.2f",
                                bloom.enabled and "on" or "off", bloom.intensity or 0,
                                bloom.radius or 0, bloom.threshold or 0),
                        }, data = {r = cr, g = cg, b = cb, lighting = lightingOn,
                            shadows = shadowsOn, bloom = {enabled = bloom.enabled,
                                intensity = bloom.intensity, radius = bloom.radius,
                                threshold = bloom.threshold}}}
                    end,
                },
                {
                    name = "color",
                    shortHelp = "set or show the ambient light color",
                    schema = lightSchema,
                    examples = {"light color", "light color 0.3 0.3 0.4", "light color b=0.8"},
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("light")
                        if not p then return perr end
                        local cr, cg, cb = p:getAmbientLight()
                        if v.r == nil and v.g == nil and v.b == nil then
                            return {ok = true,
                                message = format("ambient light now %.2f %.2f %.2f", cr, cg, cb),
                                data = {r = cr, g = cg, b = cb}}
                        end
                        local r, g, b = cr, cg, cb
                        if v.r ~= nil then r = v.r as number end
                        if v.g ~= nil then g = v.g as number end
                        if v.b ~= nil then b = v.b as number end
                        p:setAmbientLight(r, g, b)
                        return {ok = true, message = format("ambient light %.2f %.2f %.2f", r, g, b),
                            data = {r = r, g = g, b = b}}
                    end,
                },
                {
                    name = "toggle",
                    shortHelp = "enable or disable lighting entirely",
                    schema = onOffSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("light")
                        if not p then return perr end
                        local want = v.on as boolean
                        if want == nil then want = not p:isLightingEnabled() end
                        if want then p:enableLighting() else p:disableLighting() end
                        return {ok = true, message = "lighting " .. (want and "on" or "off"),
                            data = {enabled = want}}
                    end,
                },
                {
                    name = "shadows",
                    shortHelp = "enable or disable shadow rendering",
                    schema = onOffSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("light")
                        if not p then return perr end
                        -- shadowsEnabled is a live-read pipeline field (checked
                        -- every frame before the shadow passes).
                        local pAny = p as {string: any}
                        local want = v.on as boolean
                        if want == nil then want = not (pAny.shadowsEnabled as boolean) end
                        pAny.shadowsEnabled = want
                        return {ok = true, message = "shadows " .. (want and "on" or "off"),
                            data = {enabled = want}}
                    end,
                },
                {
                    name = "bloom",
                    shortHelp = "configure or show the bloom effect",
                    schema = bloomSchema,
                    examples = {"light bloom on", "light bloom off",
                        "light bloom 3 1 0.8", "light bloom radius=2"},
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("bloom")
                        if not p then return perr end
                        local function state(prefix: string): cmdtypes.Result
                            local now = p:getBloom()
                            return {ok = true,
                                message = format("%s%s  i%.2f  r%.2f  t%.2f", prefix,
                                    now.enabled and "on" or "off", now.intensity or 0,
                                    now.radius or 0, now.threshold or 0),
                                data = {enabled = now.enabled, intensity = now.intensity,
                                    radius = now.radius, threshold = now.threshold}}
                        end
                        if v.on == nil and v.intensity == nil and v.radius == nil and v.threshold == nil then
                            return state("bloom now ")
                        end
                        local cfg: gfxtypes.BloomConfig = {}
                        -- Setting any value enables bloom unless on=false was given.
                        cfg.enabled = v.on == nil or (v.on as boolean)
                        if v.intensity ~= nil then cfg.intensity = v.intensity as number end
                        if v.radius ~= nil then cfg.radius = v.radius as number end
                        if v.threshold ~= nil then cfg.threshold = v.threshold as number end
                        p:setBloom(cfg)
                        return state("bloom ")
                    end,
                },
            },
        },
        {
            name = "camera",
            section = "Render",
            shortHelp = "inspect and control the camera and time scale",
            examples = {"camera info", "camera move 100 50", "camera move z=0.3",
                "camera timescale 0.5", "camera toggle minimap"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show camera position, zoom, time scale, and registered cameras",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        return cameraInfo()
                    end,
                },
                {
                    name = "move",
                    shortHelp = "set camera position (and optionally rotation and zoom)",
                    schema = cameraMoveSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("camera")
                        if not p then return perr end
                        local cam = p:getCamera(v.name as string)
                        if not cam then
                            return {ok = false, code = "no_match",
                                message = "camera: no camera named '" .. tostring(v.name) .. "'"}
                        end
                        -- Every parameter is optional: omitted ones keep the
                        -- camera's current value, so `camera move z=0.3` works.
                        if v.x ~= nil or v.y ~= nil then
                            local curX, curY = cam:getPosition()
                            cam:setPosition(
                                (v.x ~= nil) and v.x as number or curX,
                                (v.y ~= nil) and v.y as number or curY)
                        end
                        if v.r ~= nil then cam:setRotation(v.r as number) end
                        if v.z ~= nil then cam:setZoom(v.z as number) end
                        local cx, cy = cam:getPosition()
                        return {ok = true,
                            message = format("camera at %.0f,%.0f  z%.2f  r%.2f",
                                cx, cy, cam:getZoom(), cam:getRotation()),
                            data = {x = cx, y = cy, zoom = cam:getZoom(), rotation = cam:getRotation()}}
                    end,
                },
                {
                    name = "timescale",
                    shortHelp = "set the game time scale (0 = frozen, 1 = normal)",
                    schema = cameraTimescaleSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("camera")
                        if not p then return perr end
                        local scale = v.scale as number
                        -- While frozen, the controller owns the live time scale
                        -- (it is 0); update what it restores instead.
                        if env.suspension:isSuspended() then
                            env.suspension.savedTimeScale = scale
                            return {ok = true,
                                message = format("timescale %.2f (applies when unfrozen)", scale),
                                data = {scale = scale, deferred = true}}
                        end
                        p:setTimeScale(scale)
                        return {ok = true, message = format("timescale %.2f", scale),
                            data = {scale = scale}}
                    end,
                },
                {
                    name = "toggle",
                    shortHelp = "toggle a named camera's active flag",
                    schema = cameraToggleSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("camera")
                        if not p then return perr end
                        local nm = v.name as string
                        local cam = p:getCamera(nm)
                        if not cam then
                            return {ok = false, code = "no_match",
                                message = "camera: no camera named '" .. nm .. "'"}
                        end
                        if cam == p:getCamera() and cam:isActive() then
                            return {ok = false, code = "invalid_arguments",
                                message = "camera: refusing to deactivate the primary camera"}
                        end
                        cam:setActive(not cam:isActive())
                        return {ok = true,
                            message = "camera " .. nm .. (cam:isActive() and " on" or " off"),
                            data = {name = nm, active = cam:isActive()}}
                    end,
                },
            },
        },
        {
            name = "layers",
            section = "Render",
            shortHelp = "list render layers; show, toggle, solo, or unlight one",
            examples = {"layers list", "layers info 3", "layers toggle background",
                "layers solo 3", "layers all", "layers unlit hud"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list named or modified layers with their flags",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        local names = (p as {string: any}).layerNames as {string: integer}
                        local byNum: {integer: string} = {}
                        for nm, num in pairs(names) do byNum[num] = nm end
                        local popup: {string} = {"layers  (1-16):"}
                        local rows: {{string: any}} = {}
                        for layerNum = 1, 16 do
                            local nm = byNum[layerNum]
                            local visible = p:isLayerVisible(layerNum)
                            local unlit = p:isLayerUnlit(layerNum)
                            if nm or not visible or unlit then
                                local flags: {string} = {}
                                if not visible then flags[#flags + 1] = "hidden" end
                                if unlit then flags[#flags + 1] = "unlit" end
                                popup[#popup + 1] = format("  %d\t%s\t%s", layerNum, nm or "",
                                    table.concat(flags, ", "))
                                rows[#rows + 1] = {layer = layerNum, name = nm,
                                    visible = visible, unlit = unlit}
                            end
                        end
                        if #rows == 0 then
                            popup[#popup + 1] = "  (no named or modified layers; all 16 visible and lit)"
                        end
                        return {ok = true, popup = popup,
                            data = {layers = rows, soloed = soloRestore ~= nil}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show one layer's name, flags, and entity count",
                    schema = { args = { layer = {required = true, help = "layer name or number"} },
                        positional = {"layer"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        local ref = layerRef(v.layer as string)
                        local target = resolveLayerNum(p, ref)
                        if not target then
                            return {ok = false, code = "no_match",
                                message = "layers info: unknown layer '" .. tostring(v.layer) .. "'"}
                        end
                        local names = (p as {string: any}).layerNames as {string: integer}
                        local layerName: string = nil
                        for nm, num in pairs(names) do
                            if num == target then layerName = nm end
                        end
                        -- One-shot walk; fine for a typed command, never per frame.
                        local count = 0
                        w:forEachArchetype(function(arch: tecs.Archetype)
                            local col = arch:get(Transform)
                            if not col then return end
                            local n = arch.entities[0] as integer
                            for row = 1, n do
                                if col[row].layer == target then count = count + 1 end
                            end
                        end)
                        local visible = p:isLayerVisible(target)
                        local unlit = p:isLayerUnlit(target)
                        return {ok = true, popup = {
                            "layer " .. tostring(target),
                            "  name\t" .. (layerName or "(unnamed)"),
                            "  visible\t" .. (visible and "yes" or "no"),
                            "  unlit\t" .. (unlit and "yes" or "no"),
                            "  entities\t" .. tostring(count),
                        }, data = {layer = target, name = layerName, visible = visible,
                            unlit = unlit, entities = count}}
                    end,
                },
                {
                    name = "all",
                    shortHelp = "show every layer (undo toggles and solo)",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        for layerNum = 1, 16 do
                            p:setLayerVisibility(layerNum, true)
                        end
                        -- A later bare `layers solo` must not re-hide layers
                        -- from before this reset.
                        soloRestore = nil
                        return {ok = true, message = "all 16 layers visible", data = {}}
                    end,
                },
                {
                    name = "toggle",
                    shortHelp = "show or hide a layer by name or number",
                    schema = { args = { layer = {required = true, help = "layer name or number"} },
                        positional = {"layer"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        local ref = layerRef(v.layer as string)
                        local ok, err = pcall(function(): boolean
                            p:setLayerVisibility(ref, not p:isLayerVisible(ref))
                            return true
                        end)
                        if not ok then
                            return {ok = false, code = "no_match", message = "layers: " .. tostring(err)}
                        end
                        local visible = p:isLayerVisible(ref)
                        return {ok = true,
                            message = "layer " .. tostring(v.layer) .. (visible and " shown" or " hidden"),
                            data = {layer = v.layer, visible = visible}}
                    end,
                },
                {
                    name = "solo",
                    shortHelp = "hide every layer but one; bare `layers solo` restores",
                    schema = { args = { layer = {help = "layer name or number; omit to restore"} },
                        positional = {"layer"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        if v.layer == nil then
                            if not soloRestore then
                                return {ok = false, code = "no_match", message = "layers solo: nothing soloed"}
                            end
                            for layerNum, visible in pairs(soloRestore) do
                                p:setLayerVisibility(layerNum, visible)
                            end
                            soloRestore = nil
                            return {ok = true, message = "solo off; layer visibility restored", data = {}}
                        end
                        local ref = layerRef(v.layer as string)
                        local target = resolveLayerNum(p, ref)
                        if not target then
                            return {ok = false, code = "no_match",
                                message = "layers solo: unknown layer '" .. tostring(v.layer) .. "'"}
                        end
                        if not soloRestore then
                            soloRestore = {}
                            for layerNum = 1, 16 do
                                soloRestore[layerNum] = p:isLayerVisible(layerNum)
                            end
                        end
                        for layerNum = 1, 16 do
                            p:setLayerVisibility(layerNum, layerNum == target)
                        end
                        return {ok = true, message = "solo layer " .. tostring(v.layer),
                            data = {layer = target}}
                    end,
                },
                {
                    name = "unlit",
                    shortHelp = "toggle a layer between lit and unlit",
                    schema = { args = { layer = {required = true, help = "layer name or number"} },
                        positional = {"layer"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local p, perr = needPipeline("layers")
                        if not p then return perr end
                        local ref = layerRef(v.layer as string)
                        local ok, err = pcall(function(): boolean
                            p:setLayerUnlit(ref, not p:isLayerUnlit(ref))
                            return true
                        end)
                        if not ok then
                            return {ok = false, code = "no_match", message = "layers: " .. tostring(err)}
                        end
                        local unlit = p:isLayerUnlit(ref)
                        return {ok = true,
                            message = "layer " .. tostring(v.layer) .. (unlit and " unlit" or " lit"),
                            data = {layer = v.layer, unlit = unlit}}
                    end,
                },
            },
        },
        {
            name = "grid",
            section = "Render",
            shortHelp = "toggle a world-space grid matched to the tile grid",
            schema = {
                args = {
                    on = {kind = "boolean", help = "enable or disable; omit to toggle"},
                    size = {kind = "number", help = "grid cell size in world units; omit to match tile chunks"},
                    offsetX = {kind = "number", help = "grid origin X in world units"},
                    offsetY = {kind = "number", help = "grid origin Y in world units"},
                },
                positional = {"on"},
            },
            examples = {"grid", "grid size=16 offsetX=8 offsetY=8", "grid off"},
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local want = v.on as boolean
                if want == nil then
                    local configured = v.size ~= nil or v.offsetX ~= nil or v.offsetY ~= nil
                    want = configured and true or not ctx.gridEnabled
                end
                local source = "unchanged"
                if want then
                    if v.size ~= nil then
                        local size = v.size as number
                        if size <= 0 then
                            return {ok = false, code = "invalid_arguments",
                                message = "grid: size must be positive"}
                        end
                        ctx.gridW, ctx.gridH = size, size
                        ctx.gridOX, ctx.gridOY = 0, 0
                        source = "explicit"
                    elseif ctx.gridW <= 0 then
                        -- Match the first tile chunk's grid: cell size from the
                        -- component, origin from its Transform so lines land on
                        -- tile edges even for offset maps.
                        local gw, gh, gox, goy = 0.0, 0.0, 0.0, 0.0
                        local chunkComp = componentFor("TileChunk")
                        if chunkComp then
                            w:forEachArchetype(function(arch: tecs.Archetype)
                                if gw > 0 then return end
                                local col = arch:get(chunkComp) as {any}
                                local n = arch.entities[0] as integer
                                if col and n > 0 then
                                    local c = col[1] as {string: number}
                                    gw, gh = c.tileWidth, c.tileHeight
                                    local tcol = arch:get(Transform)
                                    local t = tcol and tcol[1]
                                    if t and gw > 0 and gh > 0 then
                                        gox, goy = t.x % gw, t.y % gh
                                    end
                                end
                            end)
                        end
                        if gw > 0 and gh > 0 then
                            source = "tile chunks"
                        else
                            gw, gh = 32, 32
                            source = "default"
                        end
                        ctx.gridW, ctx.gridH = gw, gh
                        ctx.gridOX, ctx.gridOY = gox, goy
                    end
                    if v.offsetX ~= nil then ctx.gridOX = v.offsetX as number end
                    if v.offsetY ~= nil then ctx.gridOY = v.offsetY as number end
                end
                ctx.gridEnabled = want
                return {ok = true,
                    message = want
                        and format("grid on (%gx%g at %g,%g, %s)",
                            ctx.gridW, ctx.gridH, ctx.gridOX, ctx.gridOY, source)
                        or "grid off",
                    data = {enabled = want, w = ctx.gridW, h = ctx.gridH,
                        offsetX = ctx.gridOX, offsetY = ctx.gridOY, source = source}}
            end,
        },
        {
            name = "bounds",
            section = "Render",
            shortHelp = "toggle size outlines around entities with known bounds",
            schema = onOffSchema,
            examples = {"bounds", "bounds off"},
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local want = v.on as boolean
                if want == nil then want = not ctx.showBounds end
                ctx.showBounds = want
                return {ok = true, message = want and "bounds on" or "bounds off",
                    data = {enabled = want}}
            end,
        },
        {
            name = "map",
            section = "Render",
            shortHelp = "tilemap info; `info x y` shows the tile at a world point",
            schema = { args = { id = {kind = "number", help = "tilemap entity id; omit for the first"} },
                positional = {"id"} },
            examples = {"map", "map 42", "map info 320 96", "map info 320 96 42"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "tile coordinates and per-layer tiles at a world point",
                    mcpHelp = "The tile at a world point: coordinates against the tilemap origin plus each tile layer's gid and tileset there (map picks a tilemap by entity id, first map by default). Falls back to debug-grid coordinates when no tilemaps are loaded. Read-only.",
                    schema = { args = {
                        x = {required = true, kind = "number", help = "world x"},
                        y = {required = true, kind = "number", help = "world y"},
                        map = {kind = "number", help = "tilemap entity id; omit for the first"},
                    }, positional = {"x", "y", "map"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wx = v.x as number
                        local wy = v.y as number
                        local entry, merr = mapByRef(v.map as number)
                        if not entry then
                            if v.map ~= nil then
                                return {ok = false, code = "no_map", message = "map info: " .. merr}
                            end
                            -- No tilemaps: fall back to grid coordinates so
                            -- grid-only games still get tile math.
                            local tx, ty, tw, th, ox, oy = tileAt(w, ctx, wx, wy)
                            if not tx then
                                return {ok = false, code = "no_grid",
                                    message = "map info: no tilemaps and no grid enabled (`grid size=16`)"}
                            end
                            return {ok = true,
                                message = format("tile %d, %d  (grid %gx%g; no tilemaps loaded)",
                                    tx, ty, tw, th),
                                data = {x = tx, y = ty, w = tw, h = th,
                                    worldX = ox + tx * tw, worldY = oy + ty * th}}
                        end
                        local data = (entry.map as {string: any}).data as {string: any}
                        if not data then
                            return {ok = false, code = "not_loaded",
                                message = "map info: tilemap #" .. tostring(entry.entity) .. " is still loading"}
                        end
                        local tw = data.tilewidth as number
                        local th = data.tileheight as number
                        local tx = math.floor((wx - entry.x) / tw)
                        local ty = math.floor((wy - entry.y) / th)
                        local inside = tx >= 0 and ty >= 0
                            and tx < (data.width as integer) and ty < (data.height as integer)
                        local popup: {string} = {
                            format("tile %d, %d  (map #%s%s)", tx, ty,
                                tostring(entry.entity), inside and "" or ", outside the map"),
                            format("  world\t%g, %g  (%gx%g)",
                                entry.x + tx * tw, entry.y + ty * th, tw, th),
                        }
                        local layerLines, layerHits = readTileLayers(data, tx, ty)
                        for i = 1, #layerLines do
                            popup[#popup + 1] = layerLines[i]
                        end
                        return {ok = true, popup = popup,
                            data = {x = tx, y = ty, map = entry.entity, inside = inside,
                                w = tw, h = th, layers = layerHits,
                                worldX = entry.x + tx * tw,
                                worldY = entry.y + ty * th}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local entry, merr = mapByRef(v.id as number)
                if not entry then
                    return {ok = false, code = "no_map", message = "map: " .. merr}
                end
                local inst = entry.map as {string: any}
                local data = inst.data as {string: any}
                local popup: {string} = {"map #" .. tostring(entry.entity)}
                if inst.path then
                    popup[#popup + 1] = "  path\t" .. tostring(inst.path)
                end
                if not data then
                    popup[#popup + 1] = "  (still loading)"
                    return {ok = true, popup = popup,
                        data = {entity = entry.entity, path = inst.path, loaded = false}}
                end
                local layers = data.layers as {any}
                local kinds: {string: integer} = {}
                local layerNames: {string} = {}
                for i = 1, (layers and #layers or 0) do
                    local layer = layers[i] as {string: any}
                    local kind = tostring(layer.type)
                    kinds[kind] = (kinds[kind] or 0) + 1
                    layerNames[#layerNames + 1] = tostring(layer.name)
                end
                local tilesets = data.tilesets as {any}
                local tilesetNames: {string} = {}
                for i = 1, (tilesets and #tilesets or 0) do
                    tilesetNames[#tilesetNames + 1] = tostring((tilesets[i] as {string: any}).name)
                end
                popup[#popup + 1] = format("  size\t%dx%d tiles  (%dx%d px)",
                    data.width as integer, data.height as integer,
                    (data.width as integer) * (data.tilewidth as integer),
                    (data.height as integer) * (data.tileheight as integer))
                popup[#popup + 1] = format("  tile\t%dx%d px",
                    data.tilewidth as integer, data.tileheight as integer)
                popup[#popup + 1] = format("  origin\t%g, %g", entry.x, entry.y)
                local kindBits: {string} = {}
                for kind, count in pairs(kinds) do
                    kindBits[#kindBits + 1] = tostring(count) .. " " .. kind
                end
                table.sort(kindBits)
                popup[#popup + 1] = "  layers\t" .. tostring(#layerNames) ..
                    ((#kindBits > 0) and ("  (" .. table.concat(kindBits, ", ") .. ")") or "")
                popup[#popup + 1] = "  tilesets\t" .. table.concat(tilesetNames, ", ")
                local all = tilemaps()
                if #all > 1 then
                    local ids: {string} = {}
                    for i = 1, #all do ids[#ids + 1] = "#" .. tostring(all[i].entity) end
                    popup[#popup + 1] = "  maps\t" .. table.concat(ids, ", ")
                end
                return {ok = true, popup = popup,
                    data = {entity = entry.entity, path = inst.path, loaded = true,
                        width = data.width, height = data.height,
                        tilewidth = data.tilewidth, tileheight = data.tileheight,
                        layers = layerNames, tilesets = tilesetNames,
                        x = entry.x, y = entry.y, maps = #all}}
            end,
        },
        {
            name = "materials",
            section = "Render",
            shortHelp = "list registered materials or show one material's GLSL",
            examples = {"materials list", "materials info testglow"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list registered materials",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local popup: {string} = {"materials:"}
                        local rows: {{string: any}} = {}
                        for id = 1, 255 do
                            local candidate = materialregistry.getById(id)
                            if candidate then
                                popup[#popup + 1] = "  " .. tostring(id) .. "\t" .. tostring(candidate.name)
                                rows[#rows + 1] = {id = id, name = candidate.name}
                            end
                        end
                        if #rows == 0 then popup[#popup + 1] = "  (none registered)" end
                        return {ok = true, popup = popup, data = {count = #rows, materials = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show a material's GLSL sources by name or id",
                    schema = { args = { name = {required = true, help = "material name or id"} },
                        positional = {"name"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local nm = v.name as string
                        local def: materialregistry.MaterialDef = nil
                        local wanted = tonumber(nm)
                        if wanted then
                            def = materialregistry.getById(math.floor(wanted) as integer)
                        else
                            for id = 1, 255 do
                                local candidate = materialregistry.getById(id)
                                if candidate and candidate.name == nm then def = candidate end
                            end
                        end
                        if not def then
                            return {ok = false, code = "no_match",
                                message = "materials info: no material named '" .. nm .. "'"}
                        end
                        local popup: {string} = {
                            "material " .. tostring(def.name) .. "  (id " .. tostring(def.id) .. ")",
                        }
                        if def.fragmentPath then
                            popup[#popup + 1] = "  fragment\t" .. def.fragmentPath
                        end
                        if def.fragmentSource then
                            popup[#popup + 1] = "Fragment GLSL:"
                            for line in (def.fragmentSource .. "\n"):gmatch("(.-)\n") do
                                popup[#popup + 1] = "  " .. line
                            end
                        end
                        if def.vertexSource then
                            popup[#popup + 1] = "Vertex GLSL:"
                            for line in (def.vertexSource .. "\n"):gmatch("(.-)\n") do
                                popup[#popup + 1] = "  " .. line
                            end
                        end
                        return {ok = true, popup = popup,
                            data = {name = def.name, id = def.id, fragment = def.fragmentSource,
                                vertex = def.vertexSource}}
                    end,
                },
            },
        },
        {
            name = "sprites",
            section = "Render",
            shortHelp = "sprite renderer stats: buckets, texture arrays, instances",
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show bucket instance counts and texture memory",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = bucketmanager.get() as {string: any}
                        if not mgr then
                            return {ok = false, code = "no_sprites",
                                message = "sprites: the sprite renderer is not initialized"}
                        end
                        local buckets = mgr.buckets as {any}
                        local popup: {string} = {"sprite buckets:"}
                        local rows: {{string: any}} = {}
                        local total = 0
                        for i = 1, buckets and #buckets or 0 do
                            local b = buckets[i] as {string: any}
                            local count = (b.count as integer) or (b.instanceCount as integer) or 0
                            total = total + count
                            popup[#popup + 1] = format("  #%d\t%d instances", i, count)
                            rows[#rows + 1] = {bucket = i, instances = count}
                        end
                        if #rows == 0 then popup[#popup + 1] = "  (none)" end
                        local gstats = love.graphics.getStats()
                        popup[#popup + 1] = format("  textures\t%.1f MB", gstats.texturememory / 1048576)
                        return {ok = true, popup = popup,
                            data = {buckets = rows, instances = total,
                                textureMemory = gstats.texturememory}}
                    end,
                },
            },
        },
    }
end

return render

--- Shared builder for the debugger-context report. One function produces the
--- exact payload served by the cmd_context MCP tool and the public report
--- helper, so the two surfaces cannot drift.

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local worldregistry <const> = require("tecs2d.gfx.internal.worldregistry")
local toolworldkey <const> = require("tecs2d.debug.internal.toolworldkey")

local record contextreport
    --- Build the debugger-context payload. Prunes marks and notes on
    --- despawned entities in place, then reports the session state with the
    --- artifact histories capped to their newest entries.
    build: function(w: tecs.World, ctx: debugcontext.Context): {string: any}
end

-- Cap the artifact lists so a long-running session does not ship an
-- unbounded history to the agent on every call.
local CONTEXT_LIST_LIMIT <const> = 5

local function lastN<T>(list: {T}, n: integer): {T}
    local total = #list
    if total <= n then return list end
    local out: {T} = {}
    for i = total - n + 1, total do
        out[#out + 1] = list[i]
    end
    return out
end

function contextreport.build(w: tecs.World, ctx: debugcontext.Context): {string: any}
    -- Drop marks and notes on entities the game has since despawned.
    for eid in pairs(ctx.marks) do
        if not w:isAlive(eid) then ctx.marks[eid] = nil end
    end
    for eid in pairs(ctx.notes) do
        if not w:isAlive(eid) then ctx.notes[eid] = nil end
    end
    -- selection is an entity id; call cmd_info with it for the components.
    -- marks/notes are keyed by name/message with compact id-range values.
    local tools = w.resources[toolworldkey.KEY]
    return {
        worldId = w.resources[worldregistry.WORLD_ID],
        debugWorldId = tools and tools.pipeline:getWorldId() or nil,
        open = ctx.open,
        frozen = ctx.frozen,
        mode = ctx.mode,
        command = ctx.command,
        message = ctx.message,
        selected = ctx.selected,
        statsShown = ctx.statsShown,
        showIds = ctx.showIds,
        showBounds = ctx.showBounds,
        grid = ctx.gridEnabled and {w = ctx.gridW, h = ctx.gridH,
            offsetX = ctx.gridOX, offsetY = ctx.gridOY} or nil,
        rewind = {status = ctx.rewind.status, count = #ctx.rewind.entries,
            interval = ctx.rewind.interval, cap = ctx.rewind.cap, bytes = ctx.rewind.bytes},
        diffs = lastN(ctx.diffs, CONTEXT_LIST_LIMIT),
        menu = {open = ctx.menuOpen, target = ctx.menuTarget},
        marks = debugcontext.encodeGroups(ctx.marks),
        notes = debugcontext.encodeGroups(ctx.notes),
        snapshots = lastN(ctx.snapshots, CONTEXT_LIST_LIMIT),
        profiles = lastN(ctx.profiles, CONTEXT_LIST_LIMIT),
        screenshots = lastN(ctx.screenshots, CONTEXT_LIST_LIMIT),
        recording = ctx.recording,
        recordings = lastN(ctx.recordings, CONTEXT_LIST_LIMIT),
        profileTop = (#ctx.profileTop > 0) and ctx.profileTop or nil,
        entityCount = ctx.entityCount,
        area = ctx.hasArea and {
            x1 = ctx.areaX1, y1 = ctx.areaY1, x2 = ctx.areaX2, y2 = ctx.areaY2
        } or nil,
        mouse = {
            screenX = ctx.mouseScreenX, screenY = ctx.mouseScreenY,
            worldX = ctx.mouseWorldX, worldY = ctx.mouseWorldY
        },
        camera = {
            x = ctx.cameraX, y = ctx.cameraY, zoom = ctx.cameraZoom,
            rotation = ctx.cameraRotation, w = ctx.cameraW, h = ctx.cameraH
        }
    }
end

return contextreport

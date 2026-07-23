--- Sampling-profile reporting and artifact publication for the debugger.

local tecs <const> = require("tecs")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format

local record profilecapture
    summarize: function(
        text: string,
        name: string,
        systemsById: {string: string}
    ): {string}, {string}
    systemZoneIds: function(world: tecs.World): {string: string}
    finish: function(
        state: cmdtypes.ProfilerState,
        world: tecs.World,
        ctx: debugcontext.Context
    ): {string}
end

local function sortedCounts(counts: {string: integer}): {{string, integer}}
    local out: {{string, integer}} = {}
    for key, value in pairs(counts) do out[#out + 1] = {key, value} end
    table.sort(out, function(a: {string, integer},
            b: {string, integer}): boolean
        return a[2] > b[2]
    end)
    return out
end

function profilecapture.summarize(text: string, name: string,
        systemsById: {string: string}): {string}, {string}
    local byHot: {string: integer} = {}
    local bySystem: {string: integer} = {}
    local total = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local stack, count = line:match("^(.-)%s+(%d+)$")
        if stack and count then
            local n = tonumber(count) as integer
            total = total + n
            local leaf = stack:match("([^;]+)$") or stack
            local zone = stack:match("^([^;]+)") or ""
            if zone:lower() == "root" then zone = "" end
            local hotKey = leaf .. "\1" .. zone
            byHot[hotKey] = (byHot[hotKey] or 0) + n
            local secondSegment = stack:match("^[^;]+;([^;]+)")
            local systemName = secondSegment and systemsById[secondSegment]
            if systemName then
                bySystem[systemName] = (bySystem[systemName] or 0) + n
            end
        end
    end
    local hot = sortedCounts(byHot)
    local systems = sortedCounts(bySystem)

    local top: {string} = {}
    local popup: {string} = {
        "profile  (type to dismiss)",
        "saved: " .. name,
        "samples: " .. tostring(total),
        "Hot spots (self, zone):",
    }
    for i = 1, math.min(10, #hot) do
        local leaf, zone = hot[i][1]:match("^(.-)\1(.*)$")
        local zoneText = zone ~= "" and ("<" .. zone .. ">") or ""
        local percent = total > 0 and hot[i][2] * 100.0 / total or 0.0
        popup[#popup + 1] = format("  %d\t%.1f%%\t%s\t%s",
            hot[i][2], percent, leaf, zoneText)
        top[#top + 1] = format("%d %.1f%% %s %s",
            hot[i][2], percent, leaf, zoneText)
    end
    if #systems > 0 then
        popup[#popup + 1] = cmdtypes.HRULE
        popup[#popup + 1] = "Systems (inclusive samples):"
        for i = 1, math.min(10, #systems) do
            local percent = total > 0
                and systems[i][2] * 100.0 / total or 0.0
            popup[#popup + 1] = format("  %d\t%.1f%%\t%s",
                systems[i][2], percent, systems[i][1])
            top[#top + 1] = format("system %d %.1f%% %s",
                systems[i][2], percent, systems[i][1])
        end
    end
    return popup, top
end

function profilecapture.systemZoneIds(world: tecs.World): {string: string}
    local out: {string: string} = {}
    local infos = systemcontrol.list(world)
    for i = 1, #infos do
        out[infos[i].phase .. ":" .. infos[i].name] = infos[i].name
    end
    return out
end

function profilecapture.finish(state: cmdtypes.ProfilerState,
        world: tecs.World, ctx: debugcontext.Context): {string}
    if not state.session then return nil end
    local text = state.session:stop()
    state.session = nil
    state.deadline = 0.0
    state.counter = state.counter + 1
    local name = "debug-profile-" .. tostring(state.counter) .. ".collapsed"
    local file = io.open(name, "w")
    if file then
        file:write(text)
        file:close()
    end
    ctx.profiles[#ctx.profiles + 1] = {
        path = name,
        size = #text,
        time = os.time(),
    }

    local popup, top = profilecapture.summarize(text, name,
        profilecapture.systemZoneIds(world))
    ctx.profileTop = top
    debugcontext.setStatus(ctx, "profile saved at "
        .. love.filesystem.getWorkingDirectory() .. "/" .. name)
    debugcontext.pushEvent(ctx, "profile", {path = name})
    world:emit(0, debugcontext.OnDebugContext("profile", name, 0))
    return popup
end

return profilecapture

-- The Engine-section commands that answer for what the world is running: the
-- systems in its pipeline, and the states on its stack.
--
-- Both commands read and both commands write, which is what separates them from
-- the rest of the Engine section. An agent looking at a world that misbehaves
-- narrows the cause by stopping one system and stepping the world again, and it
-- moves the world into the state it wants to look at rather than playing the
-- game until the world arrives there.

local type types = require("tecs.types")
local answer <const> = require("tecs.debug.internal.answer")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")

local type Command = debugtypes.Command
local type Result = debugtypes.Result

local record session
    --- The `systems` and `states` commands, in the order they are presented.
    ---
    --- @param env The caller supplies the world both commands read and write.
    --- @return A fresh list the caller owns, each command closing over
    ---     `env.world` and none of them registered yet.
    commands: function(env: debugtypes.Env): {debugtypes.Command}
end

local SYSTEMS_LIST_SCHEMA <const>: cmdargs.Schema = {
    args = {
        phase = {help = "Narrows the listing to the systems in this phase, spelled as a row reports it."},
        disabled = {default = false, help = "Narrows the listing to the systems that are currently stopped."},
    },
    positional = {"phase"},
}

local SYSTEM_NAME_SCHEMA <const>: cmdargs.Schema = {
    args = {name = {required = true, help = "Names the system, as `systems list` reports it."}},
    positional = {"name"},
}

local STATE_NAME_SCHEMA <const>: cmdargs.Schema = {
    args = {name = {required = true, help = "Names the state, which the game created with `world:createState`."}},
    positional = {"name"},
}

--- Describes one system, which is what all four `systems` verbs carry.
local SYSTEM_PROPERTIES <const>: {string: any} = {
    name = {["type"] = "string", description = "Names the system, and is what `stop` and `start` take."},
    phase = {["type"] = "string", description = "Names the phase the system runs in."},
    position = {
        ["type"] = "integer",
        description = "Reports where the system runs within its phase, counting from one.",
    },
    enabled = {["type"] = "boolean", description = "Reports whether the system runs at all."},
    hasRunIf = {
        ["type"] = "boolean",
        description = "Reports whether the system declares a gate of its own, which can skip a frame "
            .. "even while the system is enabled.",
    },
}

local SYSTEM_KEYS <const>: {string} = {"name", "phase", "position", "enabled", "hasRunIf"}

--- Describes the state stack, which every `states` verb answers with.
local STACK_PROPERTIES <const>: {string: any} = {
    states = {
        ["type"] = "array",
        description = "Names the states on the stack, bottom-first.",
        items = {["type"] = "string"},
    },
    depth = {["type"] = "integer", description = "Counts the states on the stack."},
    top = {
        ["type"] = "string",
        description = "Names the state on top, which is the one a game reads, and is absent on an empty stack.",
    },
}

--- Reports one system the way every `systems` verb carries it.
local function systemData(info: types.SystemInfo): {string: any}
    return {
        name = info.name,
        phase = info.phase,
        position = info.position,
        enabled = info.enabled,
        hasRunIf = info.hasRunIf,
    }
end

--- Finds one system by name in the world's current listing.
local function findSystem(world: types.World, name: string): types.SystemInfo
    local listed <const> = world:listSystems()
    for index = 1, #listed do
        if listed[index].name == name then
            return listed[index]
        end
    end
    return nil
end

--- Reports the stack the way every `states` verb carries it.
local function stackData(stack: {string}): {string: any}
    return {states = answer.list(stack), depth = #stack, top = stack[#stack]}
end

--- Builds the `systems` and `states` commands for one world.
---
--- @param env The caller supplies the world both commands read and write.
--- @return The commands in presentation order.
function session.commands(env: debugtypes.Env): {Command}
    local w <const> = env.world

    return {
        {
            name = "systems",
            section = "Engine",
            shortHelp = "report the systems the world runs, and stop or start one",
            agentHelp = "Reports every system in the world's pipeline with the phase it runs in, and stops "
                .. "or starts one by name. Call systems list first to learn the names, then stop one system "
                .. "to find out what depends on it. A stopped system is a part of the game that no longer "
                .. "runs, so stop one deliberately and start it again when you are done.",
            examples = {"systems list", "systems list Update", "systems info tecs.SyncRenderState"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list the systems with their phase and state",
                    agentHelp = "Lists the systems the world runs, in the order it runs them, each with its "
                        .. "phase, its position within that phase, whether it is enabled, and whether it "
                        .. "declares a gate of its own. Narrow it with `phase` to one phase, or with "
                        .. "`disabled` to the systems something has stopped.",
                    schema = SYSTEMS_LIST_SCHEMA,
                    examples = {"systems list", "systems list Update", "systems list disabled=true"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            systems = {
                                ["type"] = "array",
                                description = "The systems the filters admitted, in the order they run.",
                                items = {
                                    ["type"] = "object",
                                    properties = SYSTEM_PROPERTIES,
                                    required = SYSTEM_KEYS,
                                },
                            },
                            total = {["type"] = "integer", description = "Systems the answer carries."},
                            registered = {
                                ["type"] = "integer",
                                description = "Systems the world holds, which the filters do not reduce.",
                            },
                        },
                        required = {"systems", "total", "registered"},
                    },
                    run = function(values: {string: any}): Result
                        local wantedPhase <const> = values.phase as string
                        local onlyDisabled <const> = values.disabled as boolean
                        local listed <const> = w:listSystems()
                        local rows: {types.SystemInfo} = {}
                        for index = 1, #listed do
                            local info <const> = listed[index]
                            local matches <const> = (wantedPhase == nil or info.phase == wantedPhase)
                                and (not onlyDisabled or not info.enabled)
                            if matches then
                                rows[#rows + 1] = info
                            end
                        end
                        return {
                            message = tostring(#rows) .. " of " .. tostring(#listed) .. " systems",
                            data = {systems = answer.list(rows), total = #rows, registered = #listed},
                        }
                    end,
                },
                {
                    name = "info",
                    shortHelp = "report one system by name",
                    agentHelp = "Reports one system's phase, its position within that phase, whether it is "
                        .. "enabled, and whether it declares a gate of its own. It fails with "
                        .. "`unknown_system` when no system carries that name, so call systems list when you "
                        .. "are unsure of the spelling.",
                    schema = SYSTEM_NAME_SCHEMA,
                    examples = {"systems info tecs.SyncRenderState", "systems info name=game.Spin"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = SYSTEM_PROPERTIES,
                        required = SYSTEM_KEYS,
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.name as string
                        local info <const> = findSystem(w, wanted)
                        if info == nil then
                            return {
                                ok = false,
                                code = "unknown_system",
                                message = "no system named '" .. wanted .. "'; see `systems list`",
                            }
                        end
                        return {
                            message = wanted .. " runs in " .. info.phase,
                            data = systemData(info),
                        }
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop one system from running",
                    agentHelp = "Stops one system, which stops the part of the game that system performs: "
                        .. "movement stops moving, a renderer's extraction stops updating the picture. The "
                        .. "system stays registered and keeps its place in the schedule, and it stays "
                        .. "stopped until `systems start` starts it again or the process restarts, so start "
                        .. "it again once you have what you needed.",
                    schema = SYSTEM_NAME_SCHEMA,
                    examples = {"systems stop game.Spin", "systems stop name=game.Spin"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = SYSTEM_PROPERTIES,
                        required = SYSTEM_KEYS,
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.name as string
                        local changed <const>, reason <const> = w:setSystemEnabled(wanted, false)
                        if not changed then
                            return {ok = false, code = "unknown_system", message = reason .. "; see `systems list`"}
                        end
                        return {
                            message = wanted .. " is stopped and will not run until it is started",
                            data = systemData(findSystem(w, wanted)),
                        }
                    end,
                },
                {
                    name = "start",
                    shortHelp = "start one stopped system again",
                    agentHelp = "Starts one system that `systems stop` stopped, from the next world update "
                        .. "onward. The system keeps the gate it declared for itself, so a gated system "
                        .. "comes back gated rather than running unconditionally. Starting a system that is "
                        .. "already running changes nothing and reports its state.",
                    schema = SYSTEM_NAME_SCHEMA,
                    examples = {"systems start game.Spin", "systems start name=game.Spin"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = SYSTEM_PROPERTIES,
                        required = SYSTEM_KEYS,
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.name as string
                        local changed <const>, reason <const> = w:setSystemEnabled(wanted, true)
                        if not changed then
                            return {ok = false, code = "unknown_system", message = reason .. "; see `systems list`"}
                        end
                        return {
                            message = wanted .. " runs again from the next update",
                            data = systemData(findSystem(w, wanted)),
                        }
                    end,
                },
            },
        },
        {
            name = "states",
            section = "Engine",
            shortHelp = "report the world's state stack, and push or pop one state",
            agentHelp = "Reports the whole state stack bottom-first and moves the world between states. The "
                .. "stack is what a game gates menus, pauses and cutscenes on, so read it before deciding "
                .. "why a system does nothing. Pushing and popping fire the game's own transition policies, "
                .. "which pause, disable or despawn the entities that state tagged.",
            examples = {"states info", "states push pause", "states pop"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "report the whole state stack",
                    agentHelp = "Reports the states on the stack bottom-first, how deep the stack is, and "
                        .. "which state is on top. An empty stack answers with no top, which is the world a "
                        .. "game that never pushed a state runs in. Call it before push or pop to know what "
                        .. "the world will return to.",
                    examples = {"states info"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = STACK_PROPERTIES,
                        required = {"states", "depth"},
                    },
                    run = function(_values: {string: any}): Result
                        local stack <const> = w:listStates()
                        return {
                            message = #stack == 0 and "the state stack is empty"
                                or (tostring(#stack) .. " states, " .. stack[#stack] .. " on top"),
                            data = stackData(stack),
                        }
                    end,
                },
                {
                    name = "push",
                    shortHelp = "push one state onto the stack",
                    agentHelp = "Pushes one state the game created, which blurs the state under it and fires "
                        .. "the new state's enter policy. Entities spawned afterwards carry that state's "
                        .. "tag, so a push changes what later spawns belong to. A name the game never "
                        .. "created fails with `unknown_state` rather than pushing anything.",
                    schema = STATE_NAME_SCHEMA,
                    examples = {"states push pause", "states push name=game"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = STACK_PROPERTIES,
                        required = {"states", "depth"},
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.name as string
                        local before <const> = #w:listStates()
                        -- `pushState` raises on a name nothing created, and the
                        -- name here comes from a person or an agent, so the
                        -- raise is caught and reported as a code to match on.
                        -- The depth separates the two failures: an unknown name
                        -- raises before the push, and an enter policy raises
                        -- after it, with the state already on the stack.
                        local pushed <const>, failure <const> = pcall(function()
                            w:pushState(wanted)
                        end) as (boolean, string)
                        local stack <const> = w:listStates()
                        if not pushed then
                            if #stack == before then
                                return {
                                    ok = false,
                                    code = "unknown_state",
                                    message = "no state named '"
                                        .. wanted
                                        .. "'; the game creates its states "
                                        .. "with world:createState",
                                }
                            end
                            return {
                                ok = false,
                                code = "enter_failed",
                                message = wanted .. " is on the stack and its enter policy raised: " .. failure,
                            }
                        end
                        return {
                            message = wanted .. " is on top of " .. tostring(#stack) .. " states",
                            data = stackData(stack),
                        }
                    end,
                },
                {
                    name = "pop",
                    shortHelp = "pop the top state off the stack",
                    agentHelp = "Pops the top state, which fires its exit policy and then the revealed "
                        .. "state's focus policy. The default exit policy despawns every entity that state "
                        .. "tagged, so a pop destroys entities the game cannot get back without a snapshot. "
                        .. "Popping an empty stack fails with `empty_stack` rather than raising.",
                    destructive = true,
                    examples = {"states pop"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = STACK_PROPERTIES,
                        required = {"states", "depth"},
                    },
                    run = function(_values: {string: any}): Result
                        local before <const> = w:listStates()
                        if #before == 0 then
                            return {
                                ok = false,
                                code = "empty_stack",
                                message = "the state stack is empty, so there is nothing to pop",
                            }
                        end
                        w:popState()
                        local stack <const> = w:listStates()
                        return {
                            message = before[#before] .. " is off the stack, leaving " .. tostring(#stack),
                            data = stackData(stack),
                        }
                    end,
                },
            },
        },
    }
end

return session

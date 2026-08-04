-- The Engine-section `physics` command: whether a world simulates at all, what
-- a ray meets when it does, and where its colliders are.
--
-- The first two verbs read. Together they answer the question an agent has
-- before it trusts anything positional: is there a simulation behind these
-- transforms, and is the collider it reports where the sprite appears to be.
-- The third answers the same question for a person watching the window, by
-- drawing every collider's outline over the scene.

local storekeys <const> = require("tecs.internal.storekeys")
local type types = require("tecs.types")
local type Store = require("tecs.data.store")
local type PhysicsWorld = require("tecs.physics.World")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")

local type Command = debugtypes.Command
local type Result = debugtypes.Result

local record physics
    --- The `physics` command, which is presented in the Engine section.
    ---
    --- @param env The caller supplies the world both verbs read.
    --- @return A fresh list the caller owns, each command closing over
    ---     `env.world` and none of them registered yet.
    commands: function(env: debugtypes.Env): {debugtypes.Command}
end

local RAYCAST_SCHEMA <const>: cmdargs.Schema = {
    args = {
        x1 = {required = true, kind = "number", help = "Starts the segment at this world x, in pixels."},
        y1 = {
            required = true,
            kind = "number",
            help = "Starts the segment at this world y, in pixels and positive downward.",
        },
        x2 = {required = true, kind = "number", help = "Ends the segment at this world x, in pixels."},
        y2 = {
            required = true,
            kind = "number",
            help = "Ends the segment at this world y, in pixels and positive downward.",
        },
        categoryBits = {
            kind = "number",
            help = "Gives the ray its own collision categories as a bit mask, defaulting to every "
                .. "category. The ray skips a shape whose mask excludes all of them.",
        },
        maskBits = {
            kind = "number",
            help = "Limits the ray to shapes in these categories, defaulting to every category.",
        },
    },
    positional = {"x1", "y1", "x2", "y2"},
}

local DEBUG_SCHEMA <const>: cmdargs.Schema = {
    args = {
        on = {
            kind = "boolean",
            help = "Draws the outlines when true and hides them when false. Omitting it switches the "
                .. "overlay to the state it is not in.",
        },
    },
    positional = {"on"},
}

-- The layer the overlay is installed on, which is one under the layer a HUD
-- conventionally takes, and which this command reports so an agent can tell
-- where the outlines land against the rest of the scene.
local OVERLAY_LAYER <const> = 15

-- Requiring `tecs.physics` registers its events and components as a side
-- effect of loading the module, and this group is built in every session,
-- including ones that never simulate anything. So the simulation is found by
-- the name its store key carries rather than by reaching for the module: a
-- name no key was created under means nothing has loaded `tecs.physics`, and
-- nothing that never loaded it can have installed the plugin. An action
-- requires the module only after this probe has answered, by which point the
-- require registers nothing that is not already registered.
--
-- `"tecs.physics"` is an externally typed compatibility surface. The same
-- string names the snapshot handler and the store key `tecs.physics` itself
-- creates, so it stays as it is written here.
local function simulationOf(world: types.World): PhysicsWorld
    local key <const> = storekeys.findKey("tecs.physics") as Store.Key<PhysicsWorld>
    if key == nil then
        return nil
    end
    return world.resources[key]
end

function physics.commands(env: debugtypes.Env): {Command}
    local w <const> = env.world

    return {
        {
            name = "physics",
            section = "Engine",
            shortHelp = "report the rapier simulation and cast rays into it",
            agentHelp = "Reports whether this world runs a Rapier simulation and how many rigid bodies it "
                .. "holds, casts a segment into it, and draws its colliders. Call physics info first: a "
                .. "world with no simulation answers `installed` false, and physics raycast and physics "
                .. "debug both fail with `no_physics` on the same world. Every coordinate on this command "
                .. "is world pixels, in and out.",
            examples = {"physics info", "physics raycast 0 0 100 0", "physics debug on"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "report whether this world simulates, and how much",
                    agentHelp = "Reports whether the world has a Rapier simulation installed and how many "
                        .. "rigid bodies it currently holds. A world without one answers `installed` false "
                        .. "rather than failing, because having no physics is an ordinary state. Call it "
                        .. "before physics raycast, which needs a simulation.",
                    examples = {"physics info"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            installed = {
                                ["type"] = "boolean",
                                description = "Reports whether the world has a simulation installed.",
                            },
                            bodies = {
                                ["type"] = "integer",
                                description = "The rigid bodies the simulation holds, and absent when there "
                                    .. "is no simulation.",
                            },
                        },
                        required = {"installed"},
                    },
                    run = function(_values: {string: any}): Result
                        local simulation <const> = simulationOf(w)
                        if simulation == nil then
                            return {
                                message = "this world has no physics simulation; install one by adding "
                                    .. "tecs.physics.plugin() to it",
                                data = {installed = false},
                            }
                        end

                        local bodies <const> = simulation:bodyCount()
                        return {
                            message = tostring(bodies) .. " rigid bodies",
                            data = {installed = true, bodies = bodies},
                        }
                    end,
                },
                {
                    name = "raycast",
                    shortHelp = "cast a segment and report the nearest collider",
                    agentHelp = "Casts the segment from one point to another and reports the first collider "
                        .. "it meets, as the entity that owns the shape, the contact point, the outward "
                        .. "normal and the fraction along the segment. Points are world pixels, and the cast "
                        .. "ignores everything past the end point, so a miss may only mean the segment was "
                        .. "too short. Sensors are hit too unless the category filters exclude them.",
                    schema = RAYCAST_SCHEMA,
                    examples = {
                        "physics raycast 0 0 100 0",
                        "physics raycast 0 0 0 500 maskBits=1",
                    },
                    readOnly = true,
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            hit = {
                                ["type"] = "boolean",
                                description = "Reports whether the segment met a collider. Every field "
                                    .. "below is absent when it did not.",
                            },
                            entity = {
                                ["type"] = "integer",
                                description = "The entity owning the shape that was hit. A secondary "
                                    .. "collider reports itself rather than its body.",
                            },
                            x = {["type"] = "number", description = "The contact point's world x, in pixels."},
                            y = {
                                ["type"] = "number",
                                description = "The contact point's world y, in pixels and positive downward.",
                            },
                            normalX = {
                                ["type"] = "number",
                                description = "The outward unit normal along x, which is not scaled to pixels.",
                            },
                            normalY = {
                                ["type"] = "number",
                                description = "The outward unit normal along y, which is not scaled to pixels.",
                            },
                            fraction = {
                                ["type"] = "number",
                                description = "How far along the segment the hit lies, from 0 at the start "
                                    .. "to 1 at the end.",
                            },
                        },
                        required = {"hit"},
                    },
                    run = function(values: {string: any}): Result
                        local simulation <const> = simulationOf(w)
                        if simulation == nil then
                            return {
                                ok = false,
                                code = "no_physics",
                                message = "this world has no physics simulation; see `physics info`",
                            }
                        end

                        -- Safe here, and only here: the probe above found the
                        -- store key, which exists only because this module has
                        -- already run.
                        local physicsapi <const> = require("tecs.physics")
                        local hit <const> = physicsapi.raycast(
                            w,
                            values.x1 as number,
                            values.y1 as number,
                            values.x2 as number,
                            values.y2 as number,
                            {
                                categoryBits = values.categoryBits as number,
                                maskBits = values.maskBits as number,
                            }
                        )
                        if hit == nil then
                            return {message = "the segment met no collider", data = {hit = false}}
                        end

                        return {
                            message = "hit entity "
                                .. tostring(hit.entity)
                                .. " at "
                                .. tostring(hit.x)
                                .. ", "
                                .. tostring(hit.y),
                            data = {
                                hit = true,
                                entity = hit.entity,
                                x = hit.x,
                                y = hit.y,
                                normalX = hit.normalX,
                                normalY = hit.normalY,
                                fraction = hit.fraction,
                            },
                        }
                    end,
                },
                {
                    name = "debug",
                    shortHelp = "draw every collider outline over the scene",
                    agentHelp = "Draws the outline of every collider in the world, solid shapes in one "
                        .. "color and sensors in another, and answers with what the overlay is drawing. "
                        .. "Call it to see whether a collider sits where its sprite does, which physics "
                        .. "raycast answers one segment at a time. Passing no argument switches the "
                        .. "overlay to the state it is not in, so an agent that wants a known state "
                        .. "passes one. The outlines are drawn on layer 15, under a HUD on 16, and they "
                        .. "spawn no entities, so nothing a query sees changes. The world needs a "
                        .. "simulation and a bound renderer: without either this fails rather than "
                        .. "drawing nothing.",
                    schema = DEBUG_SCHEMA,
                    examples = {"physics debug", "physics debug on", "physics debug false"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            enabled = {
                                ["type"] = "boolean",
                                description = "Reports whether the overlay is drawing after the call.",
                            },
                            shapes = {
                                ["type"] = "integer",
                                description = "The colliders the last build drew, which is zero until the "
                                    .. "first update after the overlay is enabled.",
                            },
                            instances = {
                                ["type"] = "integer",
                                description = "The quads those colliders occupy, one per outline segment.",
                            },
                            layer = {
                                ["type"] = "integer",
                                description = "The layer the outlines are drawn on.",
                            },
                        },
                        required = {"enabled", "shapes", "instances", "layer"},
                    },
                    run = function(values: {string: any}): Result
                        local simulation <const> = simulationOf(w)
                        if simulation == nil then
                            return {
                                ok = false,
                                code = "no_physics",
                                message = "this world has no physics simulation; see `physics info`",
                            }
                        end

                        local renderer <const> = env.renderer()
                        if renderer == nil then
                            return {
                                ok = false,
                                code = "no_renderer",
                                message = "nothing has bound a renderer to this world, so there is nothing "
                                    .. "to draw collider outlines through",
                            }
                        end

                        -- Required here rather than at the top, for the reason
                        -- `tecs.physics` is: the overlay reaches the FFI and the
                        -- GPU layer tables as it loads, and this group is built
                        -- in every session, including headless ones that never
                        -- draw.
                        local colliders <const> = require("tecs.debug.internal.colliders")
                        local overlay <const> = colliders.install(w, renderer, {layer = OVERLAY_LAYER})

                        local on = values.on as boolean
                        if on == nil then
                            on = not overlay:isEnabled()
                        end
                        overlay:setEnabled(on)

                        -- The counts describe the last build, and enabling the
                        -- overlay does not build one: the outlines are laid out
                        -- by a system in `PostUpdate`, so the first real counts
                        -- arrive one update later.
                        local counts <const> = overlay:stats()
                        local message: string
                        if not on then
                            message = "collider outlines hidden"
                        elseif counts.shapes == 0 then
                            message = "drawing collider outlines on layer "
                                .. tostring(counts.layer)
                                .. "; the counts arrive after the next update"
                        else
                            message = "drawing "
                                .. tostring(counts.shapes)
                                .. " collider outlines on layer "
                                .. tostring(counts.layer)
                        end

                        return {
                            message = message,
                            data = {
                                enabled = on,
                                shapes = counts.shapes,
                                instances = counts.instances,
                                -- Reported by the overlay rather than by the
                                -- request above, because installing twice keeps
                                -- the first overlay and a game that installed
                                -- its own chose the layer this answers with.
                                layer = counts.layer,
                            },
                        }
                    end,
                },
            },
        },
    }
end

return physics

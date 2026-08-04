-- The Engine-section commands: what a session asks about the world itself
-- rather than about one entity in it.
--
-- Every action here reads. Together they answer what an agent needs before it
-- selects anything: how the world is partitioned into archetypes, how big it
-- is, which resources a game hung off it, and which materials the renderer can
-- dispatch to.

local type types = require("tecs.types")
local answer <const> = require("tecs.debug.internal.answer")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")
local storekeys <const> = require("tecs.internal.storekeys")

local type Command = debugtypes.Command
local type Result = debugtypes.Result

local record engine
    --- The Engine-section commands, in the order they are presented.
    ---
    --- @param env The caller supplies the world every command reads.
    --- @return A fresh list the caller owns, each command closing over
    ---     `env.world` and none of them registered yet.
    commands: function(env: debugtypes.Env): {debugtypes.Command}
end

--- Reports one archetype the way `archetypes list` carries it.
local record ArchetypeRow
    id: integer
    entities: integer
    components: {string}
end

--- Reports one component column the way `archetypes info` carries it.
local record ColumnRow
    name: string
    dirty: boolean
end

--- Reports one store key the way `resources list` carries it.
local record ResourceRow
    name: string
    id: integer
    valueType: string
end

--- Reports one material the way `materials list` carries it.
local record MaterialRow
    id: integer
    name: string
end

-- The public `Store.Key<T>` interface declares no fields, because identity is
-- the whole of what a holder needs from a key. Naming the keys a world carries
-- needs the number behind that identity, so the two resource verbs read it
-- through this narrow view of the value `tecs.internal.storekeys` builds.
local record StoreKeyView
    id: integer
end

local ARCHETYPES_LIST_SCHEMA <const>: cmdargs.Schema = {
    args = {
        limit = {default = 50, min = 1, help = "Caps how many archetypes the answer carries."},
        empty = {default = false, help = "Includes archetypes holding no entities."},
    },
    positional = {"limit"},
}

local ARCHETYPES_INFO_SCHEMA <const>: cmdargs.Schema = {
    args = {
        id = {
            required = true,
            kind = "number",
            min = 0,
            help = "Identifies the archetype by the id `archetypes list` reports.",
        },
    },
    positional = {"id"},
}

local RESOURCES_INFO_SCHEMA <const>: cmdargs.Schema = {
    args = {name = {required = true, help = "Names the store key, as `resources list` reports it."}},
    positional = {"name"},
}

local MATERIALS_INFO_SCHEMA <const>: cmdargs.Schema = {
    args = {name = {required = true, help = "Names the material, which is its file name without the extension."}},
    positional = {"name"},
}

--- Describes the component name list both archetype answers carry.
local COMPONENT_NAMES <const>: {string: any} = {
    ["type"] = "array",
    description = "Component names in the archetype's signature order.",
    items = {["type"] = "string"},
}

--- Describes the entity count both archetype answers carry.
local ENTITY_COUNT <const>: {string: any} = {
    ["type"] = "integer",
    description = "Entities the archetype currently holds.",
}

--- Names an archetype's components in signature order.
local function componentNames(archetype: types.Archetype): {string}
    local names: {string} = {}
    local list <const> = archetype.componentList
    for index = 1, #list do
        names[index] = list[index].componentName
    end
    return names
end

--- Maps each registered store key's id back to the name it was created under.
local function keyNamesById(): {integer: string}
    local named <const>: {integer: string} = {}
    for name, id in pairs(storekeys.listKeys()) do
        named[id] = name
    end
    return named
end

--- Builds the Engine-section commands for one world.
---
--- @param env The caller supplies the world every command reads.
--- @return The commands in presentation order.
function engine.commands(env: debugtypes.Env): {Command}
    local w <const> = env.world

    return {
        {
            name = "archetypes",
            section = "Engine",
            shortHelp = "report how the world partitions its entities",
            agentHelp = "Reports the archetypes the world holds, which is how it groups entities by "
                .. "component signature. Call it to learn what a world contains before querying it, "
                .. "then call archetypes info on one id for its per-column dirty state.",
            examples = {"archetypes list", "archetypes list 10 empty", "archetypes info 3"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list the archetypes and what each carries",
                    agentHelp = "Lists archetypes with their entity counts and component names, most "
                        .. "recently created last. Empty archetypes are left out unless `empty` is set, "
                        .. "because a world keeps the ones it has emptied. Call archetypes info on an id "
                        .. "for that archetype's dirty columns.",
                    schema = ARCHETYPES_LIST_SCHEMA,
                    examples = {"archetypes list", "archetypes list 10", "archetypes list limit=200 empty=true"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            archetypes = {
                                ["type"] = "array",
                                description = "The archetypes the limit admitted.",
                                items = {
                                    ["type"] = "object",
                                    properties = {
                                        id = {["type"] = "integer", description = "Identifies the archetype."},
                                        entities = ENTITY_COUNT,
                                        components = COMPONENT_NAMES,
                                    },
                                    required = {"id", "entities", "components"},
                                },
                            },
                            total = {
                                ["type"] = "integer",
                                description = "Archetypes matching the filter, which the limit does not reduce.",
                            },
                            returned = {
                                ["type"] = "integer",
                                description = "Archetypes the answer carries, at most `limit`.",
                            },
                        },
                        required = {"archetypes", "total", "returned"},
                    },
                    run = function(values: {string: any}): Result
                        local limit <const> = values.limit as number
                        local includeEmpty <const> = values.empty as boolean
                        local rows: {ArchetypeRow} = {}
                        local total = 0

                        w:forEachArchetype(function(archetype: types.Archetype)
                            local count <const> = archetype.entities[0]
                            if count == 0 and not includeEmpty then
                                return
                            end
                            total = total + 1
                            if #rows < limit then
                                rows[#rows + 1] = {
                                    id = archetype.id,
                                    entities = count,
                                    components = answer.list(componentNames(archetype)),
                                }
                            end
                        end)

                        return {
                            message = tostring(#rows) .. " of " .. tostring(total) .. " archetypes",
                            data = {archetypes = answer.list(rows), total = total, returned = #rows},
                        }
                    end,
                },
                {
                    name = "info",
                    shortHelp = "report one archetype and its dirty columns",
                    agentHelp = "Reports one archetype's entity count and its components, each with "
                        .. "whether that column is dirty right now. A column is dirty from the write "
                        .. "that marked it until the end of the world update it happened in, so read "
                        .. "this while the world is frozen to learn what a step changed.",
                    schema = ARCHETYPES_INFO_SCHEMA,
                    examples = {"archetypes info 3", "archetypes info id=12"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            id = {["type"] = "integer", description = "Identifies the archetype."},
                            entities = ENTITY_COUNT,
                            components = {
                                ["type"] = "array",
                                description = "The archetype's columns in signature order.",
                                items = {
                                    ["type"] = "object",
                                    properties = {
                                        name = {["type"] = "string", description = "Names the component."},
                                        dirty = {
                                            ["type"] = "boolean",
                                            description = "Reports whether this column is currently marked dirty.",
                                        },
                                    },
                                    required = {"name", "dirty"},
                                },
                            },
                        },
                        required = {"id", "entities", "components"},
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.id as number
                        local found: types.Archetype = nil
                        w:forEachArchetype(function(archetype: types.Archetype)
                            if archetype.id == wanted then
                                found = archetype
                            end
                        end)
                        if found == nil then
                            return {
                                ok = false,
                                code = "unknown_archetype",
                                message = "no archetype has id " .. tostring(wanted),
                            }
                        end

                        local list <const> = found.componentList
                        local columns: {ColumnRow} = {}
                        for index = 1, #list do
                            columns[index] = {
                                name = list[index].componentName,
                                dirty = found:isComponentDirty(list[index]),
                            }
                        end
                        return {
                            message = "archetype "
                                .. tostring(found.id)
                                .. " holds "
                                .. tostring(found.entities[0])
                                .. " entities",
                            data = {id = found.id, entities = found.entities[0], components = answer.list(columns)},
                        }
                    end,
                },
            },
        },
        {
            name = "stats",
            section = "Engine",
            shortHelp = "report the world's counts and fixed-step loss",
            agentHelp = "Reports how many entities, archetypes, components and systems the world holds, "
                .. "plus the simulated time the fixed-step overload policy abandoned. The world counts "
                .. "entities by walking every archetype, so read this as a snapshot at a moment rather "
                .. "than polling it every frame.",
            readOnly = true,
            examples = {"stats"},
            outputSchema = {
                ["type"] = "object",
                properties = {
                    entities = {["type"] = "integer", description = "Active entities."},
                    archetypes = {["type"] = "integer", description = "Archetypes, including emptied ones."},
                    components = {["type"] = "integer", description = "Components registered in this process."},
                    systems = {["type"] = "integer", description = "Systems registered on the world."},
                    fixedTimeDropped = {
                        ["type"] = "number",
                        description = "Simulated seconds the fixed-step overload policy abandoned.",
                    },
                    fixedStepsDropped = {
                        ["type"] = "integer",
                        description = "Fixed steps the overload policy abandoned.",
                    },
                },
                required = {
                    "entities",
                    "archetypes",
                    "components",
                    "systems",
                    "fixedTimeDropped",
                    "fixedStepsDropped",
                },
            },
            run = function(_values: {string: any}): Result
                local stats <const> = w:getStats()
                return {
                    message = tostring(stats.entities)
                        .. " entities in "
                        .. tostring(stats.archetypes)
                        .. " archetypes",
                    data = {
                        entities = stats.entities,
                        archetypes = stats.archetypes,
                        components = stats.components,
                        systems = stats.systems,
                        fixedTimeDropped = stats.fixedTimeDropped,
                        fixedStepsDropped = stats.fixedStepsDropped,
                    },
                }
            end,
        },
        {
            name = "resources",
            section = "Engine",
            shortHelp = "report the typed values the world stores",
            agentHelp = "Reports the store keys the world carries in `world.resources`, which is where "
                .. "the engine and a game keep shared values. It answers with each key's name, id and "
                .. "Lua value type and never with the value, because a resource is arbitrary and often "
                .. "holds a native handle. Read a value with run_lua when you need one.",
            examples = {"resources list", "resources info tecs.debug"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list the store keys this world carries",
                    agentHelp = "Lists every store key the world has a value under, in key id order, with "
                        .. "the Lua type of each value. A key created without a name reports its id and no "
                        .. "name. Call resources info to ask about one name, and run_lua to read a value.",
                    examples = {"resources list"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            resources = {
                                ["type"] = "array",
                                description = "The keys the world holds a value under, in key id order.",
                                items = {
                                    ["type"] = "object",
                                    properties = {
                                        name = {
                                            ["type"] = "string",
                                            description = "Names the key, and is absent for an unnamed one.",
                                        },
                                        id = {
                                            ["type"] = "integer", description = "Identifies the key in this process."
                                        },
                                        valueType = {
                                            ["type"] = "string",
                                            description = "Reports the Lua type of the stored value.",
                                        },
                                    },
                                    required = {"id", "valueType"},
                                },
                            },
                            total = {["type"] = "integer", description = "Keys the world holds a value under."},
                        },
                        required = {"resources", "total"},
                    },
                    run = function(_values: {string: any}): Result
                        local named <const> = keyNamesById()
                        local rows: {ResourceRow} = {}
                        -- A store types its access through key metamethods and
                        -- declares no iteration, so listing what one holds reads
                        -- the plain table underneath it.
                        for key, value in pairs(w.resources as {any: any}) do
                            local id <const> = (key as StoreKeyView).id
                            rows[#rows + 1] = {name = named[id], id = id, valueType = type(value)}
                        end
                        table.sort(
                            rows, function(left: ResourceRow, right: ResourceRow): boolean return left.id < right.id end
                        )
                        return {
                            message = tostring(#rows) .. " resources",
                            data = {resources = answer.list(rows), total = #rows},
                        }
                    end,
                },
                {
                    name = "info",
                    shortHelp = "report whether one named key holds a value",
                    agentHelp = "Reports whether the world holds a value under one named store key, and "
                        .. "what Lua type that value has. A name no key was registered under answers "
                        .. "`present` false rather than failing, because a key exists only once something "
                        .. "has created it. The value itself is never returned; read it with run_lua.",
                    schema = RESOURCES_INFO_SCHEMA,
                    examples = {"resources info tecs.debug", "resources info name=tecs.physics"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            name = {["type"] = "string", description = "Echoes the name that was asked about."},
                            present = {
                                ["type"] = "boolean",
                                description = "Reports whether the world holds a value under that key.",
                            },
                            valueType = {
                                ["type"] = "string",
                                description = "Reports the Lua type of the value, and is absent when there is none.",
                            },
                        },
                        required = {"name", "present"},
                    },
                    run = function(values: {string: any}): Result
                        local wanted <const> = values.name as string
                        local id <const> = storekeys.listKeys()[wanted]
                        if id ~= nil then
                            for key, value in pairs(w.resources as {any: any}) do
                                if (key as StoreKeyView).id == id then
                                    return {
                                        message = wanted .. " holds a " .. type(value),
                                        data = {name = wanted, present = true, valueType = type(value)},
                                    }
                                end
                            end
                        end
                        return {
                            message = "this world holds no value under '" .. wanted .. "'",
                            data = {name = wanted, present = false},
                        }
                    end,
                },
            },
        },
        {
            name = "materials",
            section = "Engine",
            shortHelp = "report the materials the renderer dispatches to",
            agentHelp = "Reports the materials compiled into the fragment dispatch, which is what a "
                .. "Material component selects by id. Call materials info to resolve a name to the id "
                .. "to write, because ids come from sorted name order and a new material file renumbers "
                .. "every later one.",
            examples = {"materials list", "materials info rounded"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list every material with its id",
                    agentHelp = "Lists every material name with the id an instance carries to select it, "
                        .. "in id order, starting from the default at id zero. Call it to learn which "
                        .. "materials a build has before setting a Material component.",
                    examples = {"materials list"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            materials = {
                                ["type"] = "array",
                                description = "The materials in id order.",
                                items = {
                                    ["type"] = "object",
                                    properties = {
                                        id = {
                                            ["type"] = "integer",
                                            description = "The id a Material component carries to select it.",
                                        },
                                        name = {["type"] = "string", description = "Names the material."},
                                    },
                                    required = {"id", "name"},
                                },
                            },
                            total = {["type"] = "integer", description = "Materials in the dispatch."},
                        },
                        required = {"materials", "total"},
                    },
                    run = function(_values: {string: any}): Result
                        -- Required here rather than at the top of the module.
                        -- Every session builds this command group, including a
                        -- headless one, while `tecs.gpu.materials` resolves SDL
                        -- through the FFI at require time.
                        local materials <const> = require("tecs.gpu.materials")
                        local names <const> = materials.names()
                        local rows: {MaterialRow} = {}
                        for index = 1, #names do
                            local name <const> = names[index]
                            rows[index] = {id = materials.find(name), name = name}
                        end
                        return {
                            message = tostring(#rows) .. " materials",
                            data = {materials = answer.list(rows), total = #rows},
                        }
                    end,
                },
                {
                    name = "info",
                    shortHelp = "resolve one material name to its id",
                    agentHelp = "Resolves one material name to the id a Material component carries, and "
                        .. "fails with `unknown_material` when this build has no such material. Call "
                        .. "materials list first when you are unsure of the spelling.",
                    schema = MATERIALS_INFO_SCHEMA,
                    examples = {"materials info rounded", "materials info name=glyph"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            name = {["type"] = "string", description = "Echoes the material name."},
                            id = {
                                ["type"] = "integer",
                                description = "The id a Material component carries to select it.",
                            },
                        },
                        required = {"name", "id"},
                    },
                    run = function(values: {string: any}): Result
                        -- Lazy for the reason `materials list` gives.
                        local materials <const> = require("tecs.gpu.materials")
                        local wanted <const> = values.name as string
                        local id <const> = materials.find(wanted)
                        if id == nil then
                            return {
                                ok = false,
                                code = "unknown_material",
                                message = "no material named '" .. wanted .. "'; see `materials list`",
                            }
                        end
                        return {
                            message = wanted .. " is material " .. tostring(id),
                            data = {name = wanted, id = id},
                        }
                    end,
                },
            },
        },
    }
end

return engine

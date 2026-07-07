--- MCP tool definitions shared between server and client bridge.
local record tools
    record Schema
        type: string
        properties: {string: Schema}
        items: Schema
        required: {string}
        additionalProperties: boolean
        description: string
    end

    record Tool
        name: string
        description: string
        inputSchema: Schema
    end

    list: {Tool}

    --- Serialize tools list to JSON string (for bridge)
    toJSON: function(): string
end

local EMPTY_SCHEMA: tools.Schema = {
    type = "object",
    properties = {},
    additionalProperties = false
}

local JSON_TEXT_RESPONSE <const> = " Returns compact JSON text envelope."

tools.list = {
    {
        name = "ping",
        description = "Check if the game is running." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "screenshot",
        description = "Capture a screenshot of the game window. Returns MCP image content.",
        inputSchema = {
            type = "object",
            properties = {
                x = {type = "number", description = "Optional X coordinate for region capture"},
                y = {type = "number", description = "Optional Y coordinate for region capture"},
                width = {type = "number", description = "Optional width for region capture"},
                height = {type = "number", description = "Optional height for region capture"}
            },
            additionalProperties = false
        }
    },
    {
        name = "sample_pixels",
        description = "Sample framebuffer pixel colors at one or more points without transferring a " ..
            "full screenshot. Returns RGBA floats in 0..1 per point plus the framebuffer size." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                points = {
                    type = "array",
                    description = "Points to sample, each an object with x and y. " ..
                        "Pixel coordinates by default; out-of-range points are clamped.",
                    items = {
                        type = "object",
                        properties = {
                            x = {type = "number", description = "X coordinate"},
                            y = {type = "number", description = "Y coordinate"}
                        },
                        required = {"x", "y"},
                        additionalProperties = false
                    }
                },
                normalized = {
                    type = "boolean",
                    description = "When true, x and y are 0..1 fractions of the framebuffer size " ..
                        "instead of pixel coordinates (resolution-independent)."
                }
            },
            required = {"points"},
            additionalProperties = false
        }
    },
    {
        name = "send_love_event",
        description = "Send a Love2D event to the game." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                event = {
                    type = "string",
                    description = "Event name: keypressed, keyreleased, mousepressed, " ..
                        "mousereleased, mousemoved, wheelmoved, resize, focus"
                },
                args = {
                    type = "array",
                    description = "Event arguments. Mixed types allowed; each item is " ..
                        "passed through to love.event.push() with its original type so events " ..
                        "like resize/mousepressed/wheelmoved receive numbers, focus receives booleans, etc.",
                    -- No `type` on items means "any JSON type" per JSON Schema.
                    items = {}
                }
            },
            required = {"event"},
            additionalProperties = false
        }
    },
    {
        name = "get_window_size",
        description = "Get the game window dimensions." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_fps",
        description = "Get the current frames per second." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_stats",
        description = "Get ECS world stats (entities, archetypes, components, systems, memory)." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_components",
        description = "Get list of all component types used in the game." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_systems",
        description = "Get list of all systems and their phases." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_resources",
        description = "Get list of all world resources (keys and type names)." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "despawn",
        description = "Despawn entities by ID." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                id = {type = "number", description = "Single entity ID to despawn"},
                ids = {type = "array", description = "List of entity IDs to despawn", items = {type = "number"}}
            },
            additionalProperties = false
        }
    },
    {
        name = "quit",
        description = "Quit the game." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "restart",
        description = "Restart the game." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_entity",
        description = "Get a single entity by ID with all serializable components." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                id = {type = "number", description = "Entity ID to look up"}
            },
            required = {"id"},
            additionalProperties = false
        }
    },
    {
        name = "query",
        description = "Query entities by component composition and return serializable included components." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                include = {
                    type = "array", description = "Component names to include (required)",
                    items = {type = "string"}
                },
                exclude = {
                    type = "array", description = "Component names to exclude (optional)",
                    items = {type = "string"}
                },
                limit = {type = "number", description = "Max entities to return (default: 100)"}
            },
            required = {"include"},
            additionalProperties = false
        }
    },
    {
        name = "get_archetypes",
        description = "Get list of all archetypes with their component composition and entity counts." ..
            JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "spawn",
        description = "Spawn an entity with the specified components." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                components = {type = "object", description = "Map of component name to component data"}
            },
            required = {"components"},
            additionalProperties = false
        }
    },
    {
        name = "get_bundles",
        description = "Get registered bundles as a map of name to component requirements." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "spawn_bundle",
        description = "Spawn entity from a registered bundle." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                bundle = {type = "string", description = "Bundle name"},
                components = {type = "object", description = "Component overrides (required + optional)"}
            },
            required = {"bundle"},
            additionalProperties = false
        }
    },
    {
        name = "run_lua",
        description = "Run Lua code in the game. " ..
            "Code is wrapped in function(world) ... end automatically. " ..
            "Use 'world' directly to access the ECS world." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                code = {type = "string", description = "Lua code to execute with 'world' in scope"}
            },
            required = {"code"},
            additionalProperties = false
        }
    },
    {
        name = "patch_entities",
        description = "Update components on existing entities. Each patch can set (add/update) or remove components." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                id = {type = "number", description = "Single entity ID to patch"},
                ids = {
                    type = "array", description = "List of entity IDs to patch (all get same changes)",
                    items = {type = "number"}
                },
                set = {type = "object", description = "Components to add or update (map of component name to data)"},
                remove = {type = "array", description = "Component names to remove", items = {type = "string"}}
            },
            additionalProperties = false
        }
    },
    {
        name = "screen_to_world",
        description = "Convert screen coordinates to world coordinates using the active camera." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                x = {type = "number", description = "Screen X coordinate"},
                y = {type = "number", description = "Screen Y coordinate"}
            },
            required = {"x", "y"},
            additionalProperties = false
        }
    },
    {
        name = "query_in_bounds",
        description = "Query entities within a world-space bounding box. " ..
            "Uses the Position component if registered, otherwise falls back to Transform." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                x = {type = "number", description = "Left X coordinate of bounds"},
                y = {type = "number", description = "Top Y coordinate of bounds"},
                width = {type = "number", description = "Width of bounds"},
                height = {type = "number", description = "Height of bounds"},
                include = {
                    type = "array",
                    description = "Additional components to include (the spatial component is always included)",
                    items = {type = "string"}
                },
                limit = {type = "number", description = "Max entities to return (default: 100)"}
            },
            required = {"x", "y", "width", "height"},
            additionalProperties = false
        }
    },
    {
        name = "toggle_system",
        description = "Enable or disable a system by name. Disabled systems are skipped during update." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                name = {type = "string", description = "System name to toggle"},
                enabled = {type = "boolean", description = "True to enable, false to disable"}
            },
            required = {"name", "enabled"},
            additionalProperties = false
        }
    },
    {
        name = "set_time_scale",
        description = "Set the time scale for the game. 1.0 is normal speed, 0.5 is half speed, 2.0 is double speed." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                scale = {type = "number", description = "Time scale multiplier (0.1 to 10.0)"}
            },
            required = {"scale"},
            additionalProperties = false
        }
    },
    {
        name = "pause",
        description = "Hard pause: disable all gameplay/physics systems while rendering continues. " ..
            "Different from set_time_scale(0) which still ticks systems with zero dt." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "resume",
        description = "Resume gameplay after a pause, restoring the previous time scale." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "step",
        description = "Advance N frames while paused, then pause again. Must be paused first." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                frames = {type = "number", description = "Number of frames to advance (default: 1)"}
            },
            additionalProperties = false
        }
    },
    {
        name = "debug_draw",
        description = "Draw a debug overlay shape in world space. Renders on top of the game, works while paused. " ..
            "Returns the command ID for later clearing." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                type = {type = "string", description = "Shape type: rect, circle, text, line"},
                x = {type = "number", description = "X position in world coordinates"},
                y = {type = "number", description = "Y position in world coordinates"},
                w = {type = "number", description = "Width (rect only)"},
                h = {type = "number", description = "Height (rect only)"},
                radius = {type = "number", description = "Radius (circle only)"},
                text = {type = "string", description = "Text to display (text only)"},
                x2 = {type = "number", description = "End X position (line only)"},
                y2 = {type = "number", description = "End Y position (line only)"},
                color = {type = "array", description = "RGBA color array, e.g. [1,0,0,0.8] for red", items = {type = "number"}},
                tag = {type = "string", description = "Optional tag for grouped clearing"},
                duration = {type = "number", description = "Seconds before auto-removal (wall clock). 0 = single frame, omit = persistent"},
                lineWidth = {type = "number", description = "Line width in pixels (default: 4)"},
                fontSize = {type = "number", description = "Font size for text (default: 14)"}
            },
            required = {"type"},
            additionalProperties = false
        }
    },
    {
        name = "clear_debug_draw",
        description = "Clear debug draw commands. No args = clear all. Specify tag or id to clear selectively." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                tag = {type = "string", description = "Clear all commands with this tag"},
                id = {type = "number", description = "Clear a specific command by ID"}
            },
            additionalProperties = false
        }
    },
    {
        name = "profiler_start",
        description = "Start the LuaJIT sampling profiler. Auto-stops after `seconds` elapses; " ..
            "omit `seconds` to record until profiler_stop is called. Filtering and interval " ..
            "are fixed at start; you cannot change them at stop time." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                seconds = {type = "number", description = "Record for this many seconds (0.1-60), then auto-stop"},
                interval_ms = {type = "number", description = "Sampler interval in ms (default 1; raise to 5 or 10 for long sessions)"},
                zone = {type = "string", description = "Restrict output to samples whose zone path starts with this prefix. " ..
                    "E.g. 'afterFixed/Render' keeps only the render subtree."}
            },
            additionalProperties = false
        }
    },
    {
        name = "profiler_stop",
        description = "Stop the profiler. Inline results include collapsed-stack text in result.payload; " ..
            "save_to results include result.path. " ..
            "If profiler_start was called with `seconds` and the auto-stop has already fired, " ..
            "the captured recording is returned here." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                save_to = {type = "string", description = "File path to write output to instead of returning it"}
            },
            additionalProperties = false
        }
    },
    {
        name = "snapshot_save",
        description = "Capture a snapshot of the world. Inline results include result.snapshot for JSON or " ..
            "base64 result.payload for LuaJIT; save_to results include result.path. " ..
            "The format picks between JSON and compact LuaJIT string.buffer binary." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                format = {type = "string", description = "'json' (default) or 'luajit'. JSON is human-readable; luajit is a compact binary via string.buffer, returned base64-encoded when no `save_to` is given."},
                save_to = {type = "string", description = "Optional filename inside the LOVE save directory. When set, the snapshot is written to disk and the file path is returned instead of the payload."},
                pretty = {type = "boolean", description = "Pretty-print JSON output (json format only; default: false)."},
                layers = {
                    type = "array",
                    description = "Optional allow-list of Transform.layer values. Only entities whose layer is in this set are saved. Values must be in 0..31.",
                    items = {type = "number"}
                }
            },
            additionalProperties = false
        }
    },
    {
        name = "snapshot_load",
        description = "Restore a world snapshot. Accepts either an inline payload or a filename in LOVE's save " ..
            "directory. Set format to match how the snapshot was produced." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                format = {type = "string", description = "'json' (default) or 'luajit'. Must match the format the snapshot was saved with."},
                payload = {type = "string", description = "Inline snapshot payload. JSON is passed as-is; luajit binary payloads must be base64-encoded."},
                load_from = {type = "string", description = "Filename inside the LOVE save directory to read the snapshot from. Ignored when `payload` is supplied."}
            },
            additionalProperties = false
        }
    }
}

-- Simple JSON serializer for tool definitions (no external deps)
local function escapeString(s: string): string
    local result = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
    return result
end

local function serializeSchema(schema: tools.Schema): string
    local parts: {string} = {}
    if schema.type then
        table.insert(parts, '"type":"' .. schema.type .. '"')
    end

    if schema.properties then
        local propParts: {string} = {}
        for k, v in pairs(schema.properties) do
            local propJson = serializeSchema(v)
            table.insert(propParts, '"' .. k .. '":' .. propJson)
        end
        table.insert(parts, '"properties":{' .. table.concat(propParts, ",") .. '}')
    end

    if schema.items then
        table.insert(parts, '"items":' .. serializeSchema(schema.items))
    end

    if schema.required then
        local reqParts: {string} = {}
        local required <const> = schema.required
        for i = 1, #required do
            table.insert(reqParts, '"' .. required[i] .. '"')
        end
        table.insert(parts, '"required":[' .. table.concat(reqParts, ",") .. ']')
    end

    if schema.additionalProperties ~= nil then
        table.insert(parts, '"additionalProperties":' .. tostring(schema.additionalProperties))
    end

    if schema.description then
        table.insert(parts, '"description":"' .. escapeString(schema.description) .. '"')
    end

    return '{' .. table.concat(parts, ",") .. '}'
end

function tools.toJSON(): string
    local toolParts: {string} = {}
    local list <const> = tools.list
    for i = 1, #list do
        local tool = list[i]
        local json = '{"name":"' .. tool.name .. '",' ..
                     '"description":"' .. escapeString(tool.description) .. '",' ..
                     '"inputSchema":' .. serializeSchema(tool.inputSchema) .. '}'
        table.insert(toolParts, json)
    end
    return '[' .. table.concat(toolParts, ",") .. ']'
end

return tools

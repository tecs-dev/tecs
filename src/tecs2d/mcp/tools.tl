local json <const> = require("tecs.utils.json")

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

    --- MCP safety hints, declared explicitly because the protocol's
    --- defaults are pessimistic. A closed record so a typo'd hint key
    --- fails typecheck.
    record Annotations
        readOnlyHint: boolean
        destructiveHint: boolean
        idempotentHint: boolean
        openWorldHint: boolean
    end

    record Tool
        name: string
        description: string
        inputSchema: Schema
        annotations: Annotations
    end

    list: {Tool}

    --- Serialize tools list to JSON string (for bridge)
    toJSON: function(): string
end

-- json.EMPTY_OBJECT keeps empty schema tables serializing as {} rather than [].
local EMPTY_SCHEMA: tools.Schema = {
    type = "object",
    properties = json.EMPTY_OBJECT as {string: tools.Schema},
    additionalProperties = false
}

local JSON_TEXT_RESPONSE <const> = " Returns compact JSON text envelope."

tools.list = {
    {
        name = "ping",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Check if the game is running." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "screenshot",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
                    items = json.EMPTY_OBJECT as tools.Schema
                }
            },
            required = {"event"},
            additionalProperties = false
        }
    },
    {
        name = "get_window_size",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get the game window dimensions." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_fps",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get the current frames per second." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_stats",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get ECS world stats (entities, archetypes, components, systems, memory)." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_components",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get every registered component type with its id and live entity count " ..
            "(0 when registered but unused)." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_systems",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get list of all systems and their phases." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_resources",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get list of all world resources (keys and type names)." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "despawn",
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
        description = "Quit the game." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "restart",
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
        description = "Restart the game." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "get_entity",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get list of all archetypes with their component composition and entity counts." ..
            JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "spawn",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get registered bundles as a map of name to component requirements." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "spawn_bundle",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Set the time scale for the game. 1.0 is normal speed, 0.5 is half speed, 2.0 is double speed. " ..
            "While the debugger freeze is held, prefer debug_camera_timescale, which reads and writes " ..
            "the scale that resumes." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                scale = {type = "number", description = "Time scale multiplier, clamped to 0.0-10.0 (0 = fully paused)"}
            },
            required = {"scale"},
            additionalProperties = false
        }
    },
    {
        name = "pause",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Hard pause: disable all gameplay/physics systems while rendering continues. " ..
            "Different from set_time_scale(0) which still ticks systems with zero dt." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "resume",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Resume gameplay after a pause, restoring the previous time scale." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "step",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
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
        name = "get_logs",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Read recent engine log lines captured from tecs logging (ring of 500), including the " ..
            "tecs2d.debug.events operator-action feed. Each line carries a monotonic seq; poll incrementally " ..
            "with after=<last seen seq> (result.latest). Filter by minimum level or substring; newest last. " ..
            "Pass clear=true to empty the buffer." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                level = {type = "string", description = "Minimum severity: DEBUG, INFO, WARN, or ERROR"},
                contains = {type = "string", description = "Only lines whose message or logger contains this text"},
                after = {type = "number", description = "Only lines with seq greater than this (cursor; default 0)"},
                limit = {type = "number", description = "Max lines to return, newest last (default 50)"},
                clear = {type = "boolean", description = "Clear the captured buffer instead of reading"}
            },
            additionalProperties = false
        }
    },
    {
        name = "get_component_schema",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get a component's field names and types (exact C types for FFI components) " ..
            "plus default values, for constructing patch_entities / spawn / debug_set payloads." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                name = {type = "string", description = "Component name"}
            },
            required = {"name"},
            additionalProperties = false
        }
    },
    {
        name = "profiler_start",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
        description = "Start the LuaJIT sampling profiler. Auto-stops after `seconds` elapses; " ..
            "omit `seconds` to record until profiler_stop is called. Filtering and interval " ..
            "are fixed at start; you cannot change them at stop time." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                seconds = {type = "number", description = "Record for this many seconds (0.1-60), then auto-stop"},
                intervalMs = {type = "number", description = "Sampler interval in ms (default 1; raise to 5 or 10 for long sessions)"},
                zone = {type = "string", description = "Restrict output to samples whose zone path starts with this prefix. " ..
                    "E.g. 'afterFixed/Render' keeps only the render subtree."}
            },
            additionalProperties = false
        }
    },
    {
        name = "profiler_stop",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
        description = "Stop the profiler. Inline results include collapsed-stack text in result.payload; " ..
            "saveTo results include result.path. " ..
            "If profiler_start was called with `seconds` and the auto-stop has already fired, " ..
            "the captured recording is returned here." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                saveTo = {type = "string", description = "File path to write output to instead of returning it"}
            },
            additionalProperties = false
        }
    },
    {
        name = "snapshot_save",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
        description = "Capture a snapshot of the world. Inline results include result.snapshot for JSON or " ..
            "base64 result.payload for LuaJIT; saveTo results include result.path. " ..
            "The format picks between JSON and compact LuaJIT string.buffer binary." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                format = {type = "string", description = "'json' (default) or 'luajit'. JSON is human-readable; " ..
                    "luajit is a compact binary via string.buffer, returned base64-encoded when no `saveTo` is given."},
                saveTo = {type = "string", description = "Optional filename inside the LOVE save directory. When set, " ..
                    "the snapshot is written to disk and the file path is returned instead of the payload."},
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
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
        description = "Restore a world snapshot. Accepts either an inline payload or a filename in LOVE's save " ..
            "directory. Set format to match how the snapshot was produced." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                format = {type = "string", description = "'json' (default) or 'luajit'. Must match the format " ..
                    "the snapshot was saved with."},
                payload = {type = "string", description = "Inline snapshot payload. JSON is passed as-is; " ..
                    "luajit binary payloads must be base64-encoded."},
                loadFrom = {type = "string", description = "Filename inside the LOVE save directory to read " ..
                    "the snapshot from. Ignored when `payload` is supplied."}
            },
            additionalProperties = false
        }
    },
    {
        name = "get_debug_context",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Get the in-game debugger context: selection, mode, camera, and mouse " ..
            "(screen and world). Drive it with the debug_* command tools " ..
            "(debug_select, debug_mark, debug_record_start, ...). " ..
            "Requires the debug plugin (require(\"tecs2d.debug\").new())." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    }
}

function tools.toJSON(): string
    return json.serialize(tools.list)
end

return tools

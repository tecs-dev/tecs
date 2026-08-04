-- The Render-section commands: what a session asks about how a world is drawn
-- rather than about what it holds.
--
-- The camera and the frame counters live on a renderer, which `env.renderer`
-- answers with only once an application binds one, so those actions report
-- `no_renderer` rather than assuming a graphics stack exists behind them. The
-- layer table is not one of them: it is per-process configuration in plain Lua
-- and answers the same whether anything is drawing or not.

local answer <const> = require("tecs.debug.internal.answer")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")
-- Required for real, and safe to be. `tecs.gfx.layers` is per-process
-- configuration held in plain Lua tables, it requires nothing itself, and it
-- reaches neither the FFI nor a device, so naming it as this module loads costs
-- a headless session nothing.
local layers <const> = require("tecs.gfx.layers")
-- Type only, and both have to stay that way. `tecs.Renderer` pulls the GPU
-- modules in and `tecs.gfx.Camera2D` requires `tecs.ffi.loader`, so either one
-- required for real would resolve SDL through the FFI as this module loads,
-- while a headless session declares these commands without a device.
local type Renderer = require("tecs.Renderer")
local type Camera2D = require("tecs.gfx.Camera2D")

local type Command = debugtypes.Command
local type Result = debugtypes.Result

local record render
    --- The Render-section commands, in the order they are presented.
    ---
    --- @param env The caller supplies the world and the renderer accessor every
    ---     command reads.
    --- @return A fresh list the caller owns, each command closing over `env` and
    ---     none of them registered yet.
    commands: function(env: debugtypes.Env): {debugtypes.Command}
end

--- Reports one layer the way both layer answers carry it.
local record LayerRow
    layer: integer
    sort: string
    space: string
    parallax: number
    ignoreZoom: boolean
    unlit: boolean
    overlay: boolean
    viewCulled: boolean
    isDefault: boolean
end

--- Reports the sprite domain the way `render info` carries it.
local record SpriteStatsRow
    count: integer
    dropped: integer
    rewritten: integer
    extractSeconds: number
    capacity: integer
end

--- Reports the mesh domain the way `render info` carries it.
local record MeshStatsRow
    count: integer
    dropped: integer
    rewritten: integer
    extractSeconds: number
    capacity: integer
    meshCount: integer
    vertexCount: integer
    vertexCapacity: integer
    indexCount: integer
    indexCapacity: integer
    materialCount: integer
    textureCount: integer
    lightCount: integer
    lightCapacity: integer
end

--- Names each sort identifier, indexed by the identifier plus one.
---
--- `tecs.gfx.layers` answers with the number the vertex shader compares against
--- rather than with the `Sort` string a caller configured, so reporting a
--- layer's sort to a person needs the map back.
local SORT_NAMES <const>: {string} = {"topdown", "z", "isometric"}

--- Names each positioning mode `entryOf` reports, indexed by the mode plus one.
local SPACE_NAMES <const>: {string} = {"world", "screen", "virtual"}

-- The grammar bounds a number inclusively, so the smallest zoom it admits
-- stands in for the exclusive "greater than zero" the camera actually needs.
-- Every method on a camera divides by zoom, and zero or less makes each of them
-- answer with an infinity or an inverted view rather than failing.
local MIN_ZOOM <const> = 1e-6

local CAMERA_MOVE_SCHEMA <const>: cmdargs.Schema = {
    args = {
        x = {kind = "number", help = "Sets the horizontal center of the view in world pixels."},
        y = {kind = "number", help = "Sets the vertical center of the view in world pixels, increasing downward."},
        zoom = {
            kind = "number",
            min = MIN_ZOOM,
            help = "Sets the magnification, where two shows half as much world at twice the size. Must be "
                .. "greater than zero.",
        },
        rotation = {
            kind = "number",
            help = "Sets the rotation in radians, turning the scene counter-clockwise on screen.",
        },
    },
    positional = {"x", "y"},
}

local LAYERS_INFO_SCHEMA <const>: cmdargs.Schema = {
    args = {
        layer = {
            required = true,
            kind = "number",
            min = 1,
            max = layers.MAX,
            help = "Selects the layer, which is the fourth argument of a Transform2D.",
        },
    },
    positional = {"layer"},
}

--- Describes the camera placement both camera answers carry.
local CAMERA_STATE_PROPERTIES <const>: {string: any} = {
    x = {["type"] = "number", description = "The horizontal center of the view in world pixels."},
    y = {["type"] = "number", description = "The vertical center of the view in world pixels, increasing downward."},
    zoom = {["type"] = "number", description = "The magnification, where two shows half as much world."},
    rotation = {["type"] = "number", description = "The rotation in radians, counter-clockwise on screen."},
    viewport = {
        ["type"] = "object",
        description = "The pixel size of the last composited frame, which is what the bounds were resolved "
            .. "against. Absent before the renderer has drawn a frame.",
        properties = {
            width = {["type"] = "integer", description = "Viewport width in pixels."},
            height = {["type"] = "integer", description = "Viewport height in pixels."},
        },
        required = {"width", "height"},
    },
    viewBounds = {
        ["type"] = "object",
        description = "The world rectangle this camera sees at that viewport, widened to an axis-aligned "
            .. "box while the camera is rotated. Absent whenever `viewport` is.",
        properties = {
            minX = {["type"] = "number", description = "Left edge in world pixels."},
            minY = {["type"] = "number", description = "Top edge in world pixels."},
            maxX = {["type"] = "number", description = "Right edge in world pixels."},
            maxY = {["type"] = "number", description = "Bottom edge in world pixels."},
        },
        required = {"minX", "minY", "maxX", "maxY"},
    },
}

--- Describes the camera answer, which `info` and `move` both carry.
local CAMERA_OUTPUT_SCHEMA <const>: {string: any} = {
    ["type"] = "object",
    properties = CAMERA_STATE_PROPERTIES,
    required = {"x", "y", "zoom", "rotation"},
}

--- Describes the instance count a domain published for the last frame.
local COUNT_FIELD <const>: {string: any} = {
    ["type"] = "integer",
    description = "Instances resident after the last extraction.",
}

--- Describes the counter that reports a silent visual failure.
local DROPPED_FIELD <const>: {string: any} = {
    ["type"] = "integer",
    description = "Instances the last extraction could not fit in the domain's buffer. Check this field "
        .. "first when something is missing from a frame: a dropped instance is not drawn and nothing "
        .. "raises, so the only symptom is the gap on screen. Anything above zero means the domain's "
        .. "`capacity` is too small for the world.",
}

--- Describes the instances a domain rewrote for the last frame.
local REWRITTEN_FIELD <const>: {string: any} = {
    ["type"] = "integer",
    description = "Instances the last extraction rewrote, which is the work a dirty column cost.",
}

--- Describes one domain's share of the extraction time.
local EXTRACT_SECONDS_FIELD <const>: {string: any} = {
    ["type"] = "number",
    description = "Seconds the domain's last extraction took, or zero while measurement is inactive.",
}

--- Describes the instance capacity a domain fixed at creation.
local CAPACITY_FIELD <const>: {string: any} = {
    ["type"] = "integer",
    description = "The instance capacity fixed when the domain was created, which `count` cannot exceed.",
}

--- Names the counters every domain answer carries.
local DOMAIN_REQUIRED <const>: {string} = {"count", "dropped", "rewritten", "extractSeconds", "capacity"}

--- Describes one layer's configuration, which both layer answers carry.
local LAYER_PROPERTIES <const>: {string: any} = {
    layer = {["type"] = "integer", description = "The layer number, from one through `max`."},
    sort = {
        ["type"] = "string",
        description = "How contents order inside the layer's band, as `topdown`, `z` or `isometric`.",
        enum = {"topdown", "z", "isometric"},
    },
    space = {
        ["type"] = "string",
        description = "The coordinate space contents are positioned in. `world` follows the camera, "
            .. "`screen` uses target pixels and ignores it, and `virtual` uses the authored "
            .. "`virtualWidth` by `virtualHeight` system stretched to the target.",
        enum = {"world", "screen", "virtual"},
    },
    parallax = {
        ["type"] = "number",
        description = "How much the camera's position carries contents. One moves them with the world and "
            .. "a half drifts them at half speed.",
    },
    ignoreZoom = {
        ["type"] = "boolean",
        description = "Reports whether contents follow the camera's position but keep their drawn size.",
    },
    unlit = {
        ["type"] = "boolean",
        description = "Reports whether contents bypass the lighting pass and appear at their own color.",
    },
    overlay = {
        ["type"] = "boolean",
        description = "Reports whether opaque contents are routed through the sprite forward lane, which "
            .. "runs after meshes and bloom.",
    },
    viewCulled = {
        ["type"] = "boolean",
        description = "Reports whether the camera's view rectangle decides if contents draw. False on a "
            .. "layer the camera does not place where its world bound says, which is any layer using "
            .. "screen or virtual space, parallax, or `ignoreZoom`.",
    },
    isDefault = {
        ["type"] = "boolean",
        description = "Reports whether the layer still holds the configuration it starts with: sorted "
            .. "`topdown`, positioned in `world` space, parallax one, lit, and neither zoom-independent "
            .. "nor an overlay.",
    },
}

--- Names the fields of every layer row.
local LAYER_REQUIRED <const>: {string} = {
    "layer",
    "sort",
    "space",
    "parallax",
    "ignoreZoom",
    "unlit",
    "overlay",
    "viewCulled",
    "isDefault",
}

--- Describes the smallest depth difference a sort produces, which both layer
--- answers carry because it is what a depth format has to preserve.
local DEPTH_RESOLUTION_FIELD <const>: {string: any} = {
    ["type"] = "number",
    description = "The smallest depth difference two entities one world unit apart receive, over every "
        .. "sort mode. A depth format with a larger step keeps the bands and loses the sort inside them.",
}

--- Answers with the renderer drawing this world, or with the failure every
--- command in this section reports when nothing has bound one.
local function boundRenderer(env: debugtypes.Env): Renderer, Result
    local renderer <const> = env.renderer()
    if renderer == nil then
        return nil,
            {
                ok = false,
                code = "no_renderer",
                message = "this session is headless: no renderer is bound to this world",
            }
    end
    return renderer
end

--- Reports a camera's placement, and the world rectangle it sees once the
--- renderer has composited a frame.
local function cameraState(renderer: Renderer, camera: Camera2D): {string: any}
    local state <const>: {string: any} = {
        x = camera.x,
        y = camera.y,
        zoom = camera.zoom,
        rotation = camera.rotation,
    }

    -- The scene target is sized to the frame it was last composited for and is
    -- nil until one has been. `viewBounds` resolves against a viewport, and the
    -- renderer retains no other record of the one it last drew at.
    local scene <const> = renderer:captureTexture()
    if scene == nil then
        return state
    end
    state.viewport = {width = scene.width, height = scene.height}

    -- Copied out here rather than retained: `viewBounds` rewrites the camera's
    -- own four-element table, so the next call on this camera replaces what
    -- this one answered with.
    local view <const> = camera:viewBounds(scene.width, scene.height)
    state.viewBounds = {minX = view[1], minY = view[2], maxX = view[3], maxY = view[4]}
    return state
end

--- Reports one layer's whole configuration.
local function layerRow(layer: integer): LayerRow
    local mode <const>, parallaxOffset <const>, zoomFlag <const>, litFlag <const> = layers.entryOf(layer)
    local row <const>: LayerRow = {
        layer = layer,
        sort = SORT_NAMES[layers.sortOf(layer) + 1],
        space = SPACE_NAMES[math.floor(mode) + 1],
        -- The module stores what the camera's position is multiplied by, which
        -- is one minus the parallax a caller configured.
        parallax = 1.0 - parallaxOffset,
        ignoreZoom = zoomFlag == 1.0,
        unlit = litFlag == 0.0,
        overlay = layers.isOverlay(layer),
        viewCulled = layers.viewCulled(layer),
        isDefault = false,
    }
    row.isDefault = row.sort == "topdown"
        and row.space == "world"
        and row.parallax == 1.0
        and not row.ignoreZoom
        and not row.unlit
        and not row.overlay
    return row
end

--- Builds the Render-section commands for one session.
---
--- @param env The caller supplies the world and the renderer accessor.
--- @return The commands in presentation order.
function render.commands(env: debugtypes.Env): {Command}
    return {
        {
            name = "camera",
            section = "Render",
            shortHelp = "report and move the 2D view onto the world",
            agentHelp = "Reports and moves the sprite domain's camera, which is the 2D view every world "
                .. "layer is drawn through. Positions are world pixels and rotation is radians. Call "
                .. "camera info to learn what the frame currently covers, then camera move to look "
                .. "somewhere else, remembering that moving it changes what every later screenshot shows.",
            examples = {"camera info", "camera move 100 50", "camera move zoom=2"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "report where the camera is and what it sees",
                    agentHelp = "Reports the camera's center in world pixels, its zoom, its rotation in "
                        .. "radians, and the world rectangle it covers at the size of the last composited "
                        .. "frame. The viewport and the bounds are absent until the renderer has drawn "
                        .. "once. Call it before capturing a screenshot to check that the entity you care "
                        .. "about falls inside `viewBounds`.",
                    examples = {"camera info"},
                    outputSchema = CAMERA_OUTPUT_SCHEMA,
                    run = function(_values: {string: any}): Result
                        local renderer <const>, failure <const> = boundRenderer(env)
                        if renderer == nil then
                            return failure
                        end
                        if renderer.sprites == nil then
                            return {
                                ok = false,
                                code = "no_sprite_domain",
                                message = "this renderer was created with its sprite domain disabled, so it "
                                    .. "has no 2D camera",
                            }
                        end

                        local camera <const> = renderer.sprites.camera
                        return {
                            message = "camera at "
                                .. tostring(camera.x)
                                .. ", "
                                .. tostring(camera.y)
                                .. " at zoom "
                                .. tostring(camera.zoom),
                            data = cameraState(renderer, camera),
                        }
                    end,
                },
                {
                    name = "move",
                    shortHelp = "place the camera and answer with where it landed",
                    agentHelp = "Writes the camera's center in world pixels, its zoom and its rotation in "
                        .. "radians, leaving every omitted value where it was, and answers with the whole "
                        .. "placement afterwards. The renderer copies the camera during extraction, so a "
                        .. "move lands on the next frame rather than the one in flight, and it changes "
                        .. "what every later screenshot shows. Call camera info to read a placement back "
                        .. "without changing one.",
                    schema = CAMERA_MOVE_SCHEMA,
                    examples = {
                        "camera move 100 50",
                        "camera move zoom=2",
                        "camera move x=0 y=0 zoom=1 rotation=0",
                    },
                    outputSchema = CAMERA_OUTPUT_SCHEMA,
                    run = function(values: {string: any}): Result
                        local renderer <const>, failure <const> = boundRenderer(env)
                        if renderer == nil then
                            return failure
                        end
                        if renderer.sprites == nil then
                            return {
                                ok = false,
                                code = "no_sprite_domain",
                                message = "this renderer was created with its sprite domain disabled, so it "
                                    .. "has no 2D camera",
                            }
                        end

                        local camera <const> = renderer.sprites.camera
                        if values.x ~= nil then
                            camera.x = values.x as number
                        end
                        if values.y ~= nil then
                            camera.y = values.y as number
                        end
                        if values.zoom ~= nil then
                            camera.zoom = values.zoom as number
                        end
                        if values.rotation ~= nil then
                            camera.rotation = values.rotation as number
                        end

                        return {
                            message = "camera moved to "
                                .. tostring(camera.x)
                                .. ", "
                                .. tostring(camera.y)
                                .. " at zoom "
                                .. tostring(camera.zoom),
                            data = cameraState(renderer, camera),
                        }
                    end,
                },
            },
        },
        {
            name = "render",
            section = "Render",
            shortHelp = "report what the last frame cost each rendering domain",
            agentHelp = "Reports the counters each enabled rendering domain published for the frame that "
                .. "was just drawn. A renderer may enable either domain alone, so the answer names the "
                .. "domains it found rather than assuming both. Call render info when a frame is slower "
                .. "than expected, or when something you spawned is not on screen.",
            examples = {"render info"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "report the counters from the frame that was just drawn",
                    agentHelp = "Reports each enabled domain's resident instance count, its capacity, what "
                        .. "it dropped, what it rewrote, and what its extraction cost, plus the aggregate "
                        .. "extraction time. Read `dropped` first: instances that did not fit the buffer "
                        .. "are silently not drawn, so a non-zero value is the reason something is missing "
                        .. "from a frame. Call camera info next when nothing was dropped and the entity is "
                        .. "still not visible.",
                    examples = {"render info"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            domains = {
                                ["type"] = "array",
                                description = "Names the rendering domains this renderer enabled, as "
                                    .. "`sprites`, `meshes`, or both. A domain named here has an object of "
                                    .. "the same name in this answer.",
                                items = {["type"] = "string", enum = {"sprites", "meshes"}},
                            },
                            extractSeconds = {
                                ["type"] = "number",
                                description = "Seconds the last extraction took across every enabled "
                                    .. "domain, or zero while measurement is inactive.",
                            },
                            sprites = {
                                ["type"] = "object",
                                description = "The 2D domain, and absent when creation disabled it.",
                                properties = {
                                    count = COUNT_FIELD,
                                    dropped = DROPPED_FIELD,
                                    rewritten = REWRITTEN_FIELD,
                                    extractSeconds = EXTRACT_SECONDS_FIELD,
                                    capacity = CAPACITY_FIELD,
                                },
                                required = DOMAIN_REQUIRED,
                            },
                            meshes = {
                                ["type"] = "object",
                                description = "The 3D domain, and absent when creation omitted mesh options.",
                                properties = {
                                    count = COUNT_FIELD,
                                    dropped = DROPPED_FIELD,
                                    rewritten = REWRITTEN_FIELD,
                                    extractSeconds = EXTRACT_SECONDS_FIELD,
                                    capacity = CAPACITY_FIELD,
                                    meshCount = {
                                        ["type"] = "integer",
                                        description = "Meshes registered for immutable residency.",
                                    },
                                    vertexCount = {
                                        ["type"] = "integer",
                                        description = "Vertices registered for immutable residency.",
                                    },
                                    vertexCapacity = {
                                        ["type"] = "integer",
                                        description = "The vertex capacity fixed at creation, which "
                                            .. "registering a mesh past it cannot exceed.",
                                    },
                                    indexCount = {
                                        ["type"] = "integer",
                                        description = "Indices registered for immutable residency.",
                                    },
                                    indexCapacity = {
                                        ["type"] = "integer",
                                        description = "The index capacity fixed at creation.",
                                    },
                                    materialCount = {
                                        ["type"] = "integer",
                                        description = "Resident material slots, counting the neutral "
                                            .. "built-in slot zero.",
                                    },
                                    textureCount = {
                                        ["type"] = "integer",
                                        description = "Unique images uploaded to the mesh texture array.",
                                    },
                                    lightCount = {
                                        ["type"] = "integer",
                                        description = "Local point and spot lights extracted for the last "
                                            .. "frame, and zero while the lane is disabled.",
                                    },
                                    lightCapacity = {
                                        ["type"] = "integer",
                                        description = "The local-light capacity fixed at creation, and "
                                            .. "zero while the lane is disabled.",
                                    },
                                },
                                required = DOMAIN_REQUIRED,
                            },
                        },
                        required = {"domains", "extractSeconds"},
                    },
                    run = function(_values: {string: any}): Result
                        local renderer <const>, failure <const> = boundRenderer(env)
                        if renderer == nil then
                            return failure
                        end

                        local names: {string} = {}
                        local data <const>: {string: any} = {extractSeconds = renderer:extractSeconds()}
                        local dropped = 0

                        local sprites <const> = renderer.sprites
                        if sprites ~= nil then
                            names[#names + 1] = "sprites"
                            dropped = dropped + sprites.dropped
                            data.sprites = {
                                count = sprites.count,
                                dropped = sprites.dropped,
                                rewritten = sprites.rewritten,
                                extractSeconds = sprites:extractSeconds(),
                                capacity = sprites.capacity,
                            } as SpriteStatsRow
                        end

                        local meshes <const> = renderer.meshes
                        if meshes ~= nil then
                            names[#names + 1] = "meshes"
                            dropped = dropped + meshes.dropped
                            data.meshes = {
                                count = meshes.count,
                                dropped = meshes.dropped,
                                rewritten = meshes.rewritten,
                                extractSeconds = meshes:extractSeconds(),
                                capacity = meshes.capacity,
                                meshCount = meshes.meshCount,
                                vertexCount = meshes.vertexCount,
                                vertexCapacity = meshes.vertexCapacity,
                                indexCount = meshes.indexCount,
                                indexCapacity = meshes.indexCapacity,
                                materialCount = meshes.materialCount,
                                textureCount = meshes.textureCount,
                                lightCount = meshes.lightCount,
                                lightCapacity = meshes.lightCapacity,
                            } as MeshStatsRow
                        end

                        data.domains = answer.list(names)
                        return {
                            message = tostring(#names) .. " domains, " .. tostring(dropped) .. " instances dropped",
                            data = data,
                        }
                    end,
                },
            },
        },
        {
            name = "layers",
            section = "Render",
            shortHelp = "report how each depth band is configured",
            agentHelp = "Reports the sixteen depth bands a scene sorts into, which the fourth argument of a "
                .. "Transform2D selects. A layer decides how its contents sort, what coordinate space they "
                .. "are positioned in, whether the camera carries them, and whether they are lit. Call "
                .. "layers list to find the layers a game configured, then layers info on one for its depth "
                .. "band.",
            examples = {"layers list", "layers info 8"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list every layer and how it is configured",
                    agentHelp = "Lists all `max` layers from one upward with their whole configuration, and "
                        .. "names separately the ones a game changed from the default, because most scenes "
                        .. "leave most layers untouched. Higher layers draw nearer, so a HUD on a high "
                        .. "layer covers a world on a low one. Call layers info on a layer for its depth "
                        .. "band.",
                    examples = {"layers list"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            layers = {
                                ["type"] = "array",
                                description = "Every layer in ascending order, from one through `max`.",
                                items = {
                                    ["type"] = "object",
                                    properties = LAYER_PROPERTIES,
                                    required = LAYER_REQUIRED,
                                },
                            },
                            configured = {
                                ["type"] = "array",
                                description = "The layer numbers whose configuration differs from the "
                                    .. "default, which is where a game said something deliberate. Empty "
                                    .. "when nothing has called `tecs.gfx.layers.configure`.",
                                items = {["type"] = "integer"},
                            },
                            max = {
                                ["type"] = "integer",
                                description = "How many depth bands divide the range, which is sixteen and "
                                    .. "is load-bearing at that value.",
                            },
                            revision = {
                                ["type"] = "integer",
                                description = "A count that rises with every `configure`. Compare it across "
                                    .. "two calls to learn whether a layer changed; the number itself means "
                                    .. "nothing else.",
                            },
                            depthResolution = DEPTH_RESOLUTION_FIELD,
                        },
                        required = {"layers", "configured", "max", "revision", "depthResolution"},
                    },
                    run = function(_values: {string: any}): Result
                        local rows: {LayerRow} = {}
                        local configured: {integer} = {}
                        for layer = 1, layers.MAX do
                            local row <const> = layerRow(layer)
                            rows[layer] = row
                            if not row.isDefault then
                                configured[#configured + 1] = layer
                            end
                        end

                        return {
                            message = tostring(#configured)
                                .. " of "
                                .. tostring(layers.MAX)
                                .. " layers differ from the default",
                            data = {
                                layers = answer.list(rows),
                                configured = answer.list(configured),
                                max = layers.MAX,
                                revision = layers.revision(),
                                depthResolution = layers.depthResolution(),
                            },
                        }
                    end,
                },
                {
                    name = "info",
                    shortHelp = "report one layer's configuration and depth band",
                    agentHelp = "Reports one layer's whole configuration plus the depth band it occupies, "
                        .. "as the near and far edges of the range its contents sort inside. Depth runs "
                        .. "from zero nearest to one farthest, so a higher layer holds a band closer to "
                        .. "zero and draws over a lower one. Call layers list first when you do not know "
                        .. "which layer a game put something on.",
                    schema = LAYERS_INFO_SCHEMA,
                    examples = {"layers info 8", "layers info layer=1"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            layer = LAYER_PROPERTIES.layer,
                            sort = LAYER_PROPERTIES.sort,
                            space = LAYER_PROPERTIES.space,
                            parallax = LAYER_PROPERTIES.parallax,
                            ignoreZoom = LAYER_PROPERTIES.ignoreZoom,
                            unlit = LAYER_PROPERTIES.unlit,
                            overlay = LAYER_PROPERTIES.overlay,
                            viewCulled = LAYER_PROPERTIES.viewCulled,
                            isDefault = LAYER_PROPERTIES.isDefault,
                            bandNear = {
                                ["type"] = "number",
                                description = "The near edge of the layer's depth band, which is the "
                                    .. "smallest depth its contents can receive.",
                            },
                            bandFar = {
                                ["type"] = "number",
                                description = "The far edge of the layer's depth band. Contents never sort "
                                    .. "past it into another layer's band.",
                            },
                            depthResolution = DEPTH_RESOLUTION_FIELD,
                        },
                        required = {
                            "layer",
                            "sort",
                            "space",
                            "parallax",
                            "ignoreZoom",
                            "unlit",
                            "overlay",
                            "viewCulled",
                            "isDefault",
                            "bandNear",
                            "bandFar",
                            "depthResolution",
                        },
                    },
                    run = function(values: {string: any}): Result
                        local layer <const> = math.floor(values.layer as number) as integer
                        local row <const> = layerRow(layer)
                        local near <const> = layers.bandOf(layer)

                        return {
                            message = "layer "
                                .. tostring(layer)
                                .. " sorts "
                                .. row.sort
                                .. " in "
                                .. row.space
                                .. " space",
                            data = {
                                layer = row.layer,
                                sort = row.sort,
                                space = row.space,
                                parallax = row.parallax,
                                ignoreZoom = row.ignoreZoom,
                                unlit = row.unlit,
                                overlay = row.overlay,
                                viewCulled = row.viewCulled,
                                isDefault = row.isDefault,
                                bandNear = near,
                                bandFar = near + 1.0 / layers.MAX,
                                depthResolution = layers.depthResolution(),
                            },
                        }
                    end,
                },
            },
        },
    }
end

return render

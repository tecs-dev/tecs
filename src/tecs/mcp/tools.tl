--- The tools every build exposes.
---
--- Deliberately few. A game registers what its own world needs; these are the
--- ones that are true of any build and that an agent reaches for before it
--- knows anything else: is it alive, what is it, and what has it been saying.

local data <const> = require("tecs.data")
local sdl <const> = require("tecs.ffi.sdl3")
local system <const> = require("tecs.platform.system")
local filesystem <const> = require("tecs.platform.filesystem")
local log <const> = require("tecs.log")
local ecs <const> = require("tecs.ecs")
local mcp <const> = require("tecs.mcp")
local events <const> = require("tecs.platform.events")
local watch <const> = require("tecs.platform.watch")
local sandbox <const> = require("tecs.mcp.sandbox")
local shaders <const> = require("tecs.gpu.shaders")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local materials <const> = require("tecs.gpu.materials")
local Renderer <const> = require("tecs.Renderer")
local Audio <const> = require("tecs.Audio")
local assets <const> = require("tecs.assets")
local text <const> = require("tecs.gfx.text")

local C <const> = sdl.C

--- The built-in tools, and the bindings the application supplies them with.
---
--- Requiring this module registers its tools as a side effect; there is no
--- install step. What is on the surface besides that is the two binders and
--- the four reloads, which the tools are thin wrappers over, so that an agent
--- asking and the file watcher noticing a saved file are refused on identical
--- terms rather than through two descriptions that can drift apart.
---
--- Every handler runs on the game thread inside the frame. Nothing is bound
--- until the application starts, so a tool called before then fails with a
--- message naming what is missing rather than with an opaque error.
local record tools
    --- Set by the application so the frame-facing tools have something to
    --- look at. Absent means those tools report why rather than failing.
    ---
    --- @param renderer Passing nil unbinds, and the frame-facing tools then
    ---     report that the application has not started.
    --- @param world Bound in the same call as the renderer, so the two cannot
    ---     be replaced independently.
    bind: function(renderer: Renderer, world: ecs.World)
    --- Supplies what rebuilds the pipelines after a shader reload.
    ---
    --- Separate from `bind` because it is the device's half of the operation
    --- and the source half is all this module can do on its own. Swapping a
    --- pipeline object means destroying live GPU handles and creating new ones
    --- against the formats the device claimed, which is knowledge the
    --- renderer's backend has and nothing here does.
    ---
    --- @param rebuild Runs with the device idle and outside any pass, and
    ---     raising from it is reported as the tool failing. Passing nil
    ---     unregisters, after which `reloadShaders` refuses outright rather
    ---     than re-reading the sources to no visible effect.
    bindReload: function(rebuild: function())

    --- The four reloads, as the functions the tools below are wrappers over.
    ---
    --- Each raises with the reason when it refuses, which is what the tool
    --- reports and what the file watcher logs. They are named here because the
    --- rules a reload may not break are the interesting part and there must be
    --- one description of them: an agent asking and a saved file arriving have
    --- to be refused on identical terms or the two disagree about what the
    --- process is drawing.
    reloadShaders: function(): {string}
    reloadImage: function(path: string): integer, integer, integer
    reloadSound: function(path: string): boolean
    reloadFont: function(path: string): string, integer
end

local bound: Renderer = nil
local boundWorld: ecs.World = nil
local boundReload: function() = nil

function tools.bind(renderer: Renderer, world: ecs.World)
    bound = renderer
    boundWorld = world
end

function tools.bindReload(rebuild: function())
    boundReload = rebuild
end

--- The bound world, or an error naming why there is not one.
local function world(): ecs.World
    if boundWorld == nil then
        error("no world is bound; the application has not started", 0)
    end
    return boundWorld
end

--- The bound renderer, or an error naming why there is not one.
local function renderer(): Renderer
    if bound == nil then
        error("no renderer is bound; the application has not started", 0)
    end
    return bound
end

--- The audio installed into the bound world, or an error naming why there is
--- not one. Found through the world rather than bound separately, because the
--- audio is what `Audio:install` attached to it and there is no second one.
local function audio(): Audio
    local found = Audio.of(world())
    if found == nil then
        error("no audio is installed on the bound world", 0)
    end
    return found
end

mcp.register({
    name = "ping",
    description = "Confirms the game is running and answering. Reports a "
        .. "crash rather than refusing to answer after one.",
    readOnly = true,
    whenCrashed = true,
    inputSchema = {type = "object", properties = data.empty_array},
    handler = function(_: {string: any}): {string: any}
        local crash = mcp.crashed()
        return {
            ok = crash == nil,
            crashed = crash or data.null,
            ticks = tonumber(C.SDL_GetTicks()) as number,
        }
    end,
})

--- What the bound world holds, or nil before one is bound.
---
--- Through `world:getStats`, which is the ECS's own count of entities,
--- archetypes, components and systems, rather than a second tally kept here.
--- `declared` is beside it because the component registry is process-wide
--- while `stats.components` counts only what an archetype in this world
--- carries, and the difference between the two is what an agent looking for a
--- component it cannot find needs to see.
local function worldContext(): {string: any}
    if boundWorld == nil then
        return nil
    end
    local stats = boundWorld:getStats()
    local declared = 0
    for _ in pairs(ecs.declaredComponents()) do
        declared = declared + 1
    end
    return {
        entities = stats.entities,
        archetypes = stats.archetypes,
        components = stats.components,
        declaredComponents = declared,
        systems = stats.systems,
        -- Beside the counts because an agent looking at a world that is
        -- behaving oddly needs to know whether its fixed step has been
        -- silently losing time before it reads anything else here.
        fixedTimeDropped = stats.fixedTimeDropped,
        fixedStepsDropped = stats.fixedStepsDropped,
    }
end

mcp.register({
    name = "context",
    description = "What this build is, what it can do, and what the world it " .. "is running holds.",
    readOnly = true,
    whenCrashed = true,
    inputSchema = {type = "object", properties = data.empty_array},
    handler = function(_: {string: any}): {string: any}
        local caps = system.capabilities()
        return {
            world = worldContext() or data.null,
            target = caps.target,
            architecture = caps.architecture,
            jit = caps.jit,
            dynamicLibraries = caps.dynamicLibraries,
            runtimeShaders = caps.runtimeShaders,
            packagedShaders = caps.packagedShaders,
            shaderFormats = caps.shaderFormats,
            cores = caps.cores,
            assets = filesystem.assetRoot(),
            writable = filesystem.preferencePath(),
            logFile = log.filePath() or data.null,
            loggers = log.loggers(),
        }
    end,
})

--- Bytes read per call. A cursor rather than a whole file, so polling a long
--- run stays cheap.
local WINDOW <const> = 65536

mcp.register({
    name = "get_logs",
    description = "Reads the log file from a byte offset. Poll with the " .. "returned offset to follow it.",
    readOnly = true,
    whenCrashed = true,
    inputSchema = {
        type = "object",
        properties = {
            after = {
                type = "integer",
                description = "Byte offset to read from. Omit to start at 0.",
            },
            contains = {
                type = "string",
                description = "Only return lines containing this text.",
            },
        },
    },
    handler = function(args: {string: any}): {string: any}
        local path = log.filePath()
        if path == nil then
            return {lines = data.empty_array, offset = 0, path = data.null}
        end

        -- The path is returned so an agent sharing a filesystem with the game
        -- can grep it directly instead of pulling it through here, which is
        -- what cmd_screenshot already does with artifacts.
        local file = io.open(path, "rb")
        if file == nil then
            return {lines = data.empty_array, offset = 0, path = path}
        end

        local after = math.floor(tonumber(args.after) or 0) as integer
        local size = file:seek("end")
        if after > size then
            after = 0
        end -- the file was truncated
        file:seek("set", after)
        local window = file:read(WINDOW) or ""
        file:close()

        -- Only whole lines, so a cursor never lands mid-record and the next
        -- read does not start with a fragment.
        local lastBreak = window:find("\n[^\n]*$")
        if lastBreak ~= nil then
            window = window:sub(1, lastBreak)
        end

        local contains = args.contains as string
        local lines: {string} = {}
        for line in window:gmatch("[^\n]+") do
            if contains == nil or line:find(contains, 1, true) then
                lines[#lines + 1] = line
            end
        end

        return {
            path = path,
            offset = after + #window,
            lines = #lines > 0 and lines or data.empty_array,
        }
    end,
})

--- Writes the last composited frame to a PNG under the writable root.
---
--- A file rather than inline base64, because an agent that shares a filesystem
--- with the game reads it far more cheaply, it persists for a human to look at
--- afterwards, and a screenshot is large enough that carrying it through the
--- protocol is worth avoiding. The path is returned either way.
mcp.register({
    name = "screenshot",
    description = "Captures the last rendered frame to a PNG and returns its " .. "path.",
    readOnly = true,
    inputSchema = {
        type = "object",
        properties = {
            name = {
                type = "string",
                description = "File name under the writable root. Defaults to " .. "screenshot.png.",
            },
        },
    },
    handler = function(args: {string: any}): {string: any}
        local activeRenderer = renderer()
        local texture = activeRenderer:captureTexture()
        local width, height = texture.width, texture.height

        local name = (args.name as string) or "screenshot.png"
        local path = filesystem.writablePath(name)
        local saved, reason = activeRenderer:saveScreenshot(path)
        if not saved then
            error(reason, 0)
        end

        return {path = path, width = width, height = height}
    end,
})

--- Reads specific pixels without writing a file.
---
--- What a test asserts on. A screenshot answers "what does it look like" and
--- needs eyes; this answers "is that pixel the colour it should be" and does
--- not, which is the question an agent can actually check.
mcp.register({
    name = "sample_pixels",
    description = "Reads the colour of specific pixels from the last frame.",
    readOnly = true,
    inputSchema = {
        type = "object",
        properties = {
            points = {
                type = "array",
                description = "Points to sample, as {x, y} pairs.",
                items = {type = "array", items = {type = "integer"}},
            },
        },
        required = {"points"},
    },
    handler = function(args: {string: any}): {string: any}
        local points = args.points as {any}
        if points == nil or #points == 0 then
            error("points is required and must not be empty", 0)
        end

        local texture = renderer():captureTexture()
        local pixels = texture:readback()
        local width, height = texture.width, texture.height

        local sampled: {any} = {}
        for index = 1, #points do
            local point = points[index] as {any}
            local x = math.floor(tonumber(point[1]) or 0) as integer
            local y = math.floor(tonumber(point[2]) or 0) as integer
            if x < 0 or y < 0 or x >= width or y >= height then
                sampled[index] = {x = x, y = y, outside = true}
            else
                local pixel = texture:getPixel(pixels, x, y)
                sampled[index] = {
                    x = x,
                    y = y,
                    r = pixel.r,
                    g = pixel.g,
                    b = pixel.b,
                    a = pixel.a,
                }
            end
        end

        return {width = width, height = height, pixels = sampled}
    end,
})

--- Pushes a synthetic event into the same stream real input arrives on.
---
--- Still available after a crash, deliberately: quit and escape are exactly
--- what a game that has stopped simulating still needs to be told, and a
--- window nobody can close is worse than one that is not drawing.
mcp.register({
    name = "send_event",
    description = "Pushes an event into the input stream, as if it had come " .. "from the platform.",
    destructive = true,
    whenCrashed = true,
    inputSchema = {
        type = "object",
        properties = {
            kind = {
                type = "string",
                description = "Event kind. Call with no kind to list them.",
            },
            scancode = {type = "integer", description = "For keyDown, keyUp."},
            button = {type = "integer", description = "For mouseDown, mouseUp."},
            x = {type = "number"},
            y = {type = "number"},
            clicks = {
                type = "integer",
                description = "Clicks in the run, for mouseDown and mouseUp. " .. "One when omitted.",
            },
            wheelX = {type = "number", description = "For mouseWheel."},
            wheelY = {type = "number", description = "For mouseWheel."},
            wheelTicksX = {
                type = "integer",
                description = "Whole notches, for mouseWheel.",
            },
            wheelTicksY = {type = "integer", description = "Whole notches."},
            flipped = {
                type = "boolean",
                description = "Send the wheel event as a platform with "
                    .. "natural scrolling does, which arrives negated.",
            },
            penState = {
                type = "integer",
                description = "SDL_PEN_INPUT_* mask, for the pen kinds.",
            },
            repeated = {type = "boolean", description = "For keyDown."},
            which = {
                type = "integer",
                description = "Device, window or display the event is about.",
            },
            data1 = {
                type = "integer",
                description = "First payload, for the window and display kinds.",
            },
            data2 = {type = "integer", description = "Second payload."},
            scale = {
                type = "number",
                description = "Zoom factor, for the pinch kinds.",
            },
            recording = {
                type = "boolean",
                description = "Whether an audio device records.",
            },
        },
    },
    handler = function(args: {string: any}): {string: any}
        local kind = args.kind as string
        if kind == nil then
            return {kinds = events.kinds()}
        end
        -- events.push validates the kind against the same table the drain
        -- decodes with, so an unknown one cannot be pushed and then ignored.
        events.push(
            kind,
            {
                scancode = args.scancode as integer,
                button = args.button as integer,
                x = args.x as number,
                y = args.y as number,
                clicks = args.clicks as integer,
                wheelX = args.wheelX as number,
                wheelY = args.wheelY as number,
                wheelTicksX = args.wheelTicksX as integer,
                wheelTicksY = args.wheelTicksY as integer,
                flipped = args.flipped as boolean,
                penState = args.penState as integer,
                repeated = args.repeated as boolean,
                which = args.which as number,
                data1 = args.data1 as integer,
                data2 = args.data2 as integer,
                scale = args.scale as number,
                recording = args.recording as boolean,
            } as events.Event
        )
        return {pushed = kind}
    end,
})

--- What the mixer is doing, in one call.
---
--- Sound is the one subsystem with nothing to look at. A screenshot answers
--- what the frame drew, and there is no equivalent readback for what came out
--- of the speakers, so what an agent can check is what the layer was asked
--- for: which clips loaded, which voices are sounding and on what, and which
--- of the gains, mutes and pauses over them explains a silence.
mcp.register({
    name = "audio",
    description = "Sound output: the clips loaded, the voices sounding, and "
        .. "the gains, mutes and pauses over them.",
    readOnly = true,
    inputSchema = {type = "object", properties = data.empty_array},
    handler = function(_: {string: any}): {string: any}
        local sound = audio()
        -- What this build linked rather than what it asked for, which is the
        -- first thing a clip that will not load needs ruling out.
        local decoders = Audio.decoders()

        local clips: {any} = {}
        for _, clip in ipairs(sound:clips()) do
            clips[#clips + 1] = {
                path = clip.path,
                id = clip.id,
                status = clip.status,
                duration = clip.duration,
                resident = clip.resident,
                error = clip.error or data.null,
            }
        end

        local voices: {any} = {}
        local perGroup: {string: integer} = {}
        for _, voice in ipairs(sound:voices()) do
            if voice.group ~= nil then
                perGroup[voice.group] = (perGroup[voice.group] or 0) + 1
            end
            voices[#voices + 1] = {
                handle = voice.handle,
                clip = voice.clip or data.null,
                gain = voice.gain,
                applied = voice.applied,
                pitch = voice.pitch,
                group = voice.group or data.null,
                key = voice.key or data.null,
                paused = voice.paused,
                stopping = voice.stopping,
                owned = voice.owned,
                spatial = voice.spatial,
                x = voice.x,
                y = voice.y,
                z = voice.z,
            }
        end

        local groups: {any} = {}
        for _, name in ipairs(sound:groups()) do
            groups[#groups + 1] = {
                name = name,
                gain = sound:groupGain(name),
                muted = sound:groupMuted(name),
                -- The standing instruction, not a count of held voices: a
                -- paused group with nothing in it still holds what starts.
                paused = sound:groupPaused(name),
                voices = perGroup[name] or 0,
            }
        end

        local keys: {any} = {}
        for _, key in ipairs(sound:keys()) do
            local limit = sound:limit(key)
            keys[#keys + 1] = {
                key = key,
                count = sound:keyCount(key),
                voices = limit ~= nil and limit.voices or data.null,
                cooldown = limit ~= nil and limit.cooldown or data.null,
            }
        end

        return {
            available = sound.available,
            masterGain = sound:masterGain(),
            muted = sound:muted(),
            sounding = sound:sounding(),
            maxVoices = sound:maxVoices(),
            loading = sound:loading(),
            decoders = #decoders > 0 and decoders or data.empty_array,
            clips = #clips > 0 and clips or data.empty_array,
            groups = #groups > 0 and groups or data.empty_array,
            keys = #keys > 0 and keys or data.empty_array,
            voices = #voices > 0 and voices or data.empty_array,
        }
    end,
})

--- Re-reads the shader and material sources and rebuilds what draws from them.
---
--- The interesting question is what a reload may not do, and both answers to
--- that are checked here.
---
--- The pipeline objects a frame binds are read through the backend every
--- frame, so replacing them is picked up by the next frame with no graph
--- rebuild and nothing in the world touched.
---
--- @return Every material name the sources now define, which is what they say
---     after the reload rather than before it, so a material that was removed
---     is gone from this list. Raises instead of returning when the build
---     links no compiler, when no rebuild has been registered, or when the
---     sources themselves were refused.
function tools.reloadShaders(): {string}
    -- A pack decides the shader format the device claimed at creation, so a
    -- build without a compiler has nothing to put in its place and no way to
    -- change what it draws with while it is running.
    if not shadercompiler.available() then
        error("this build links no shader compiler, so its shaders are " .. "fixed at the pack it was built against", 0)
    end
    if boundReload == nil then
        error(
            "no shader rebuild is registered, so the sources would be "
                .. "re-read and nothing would draw differently",
            0
        )
    end

    local reloaded, refused = materials.reload()
    if not reloaded then
        error(refused, 0)
    end
    shaders.invalidate()
    boundReload()
    return materials.names()
end

--- Re-reads an image file and writes it over the one already registered.
---
--- Refuses on the same principle `reloadShaders` does: a reload may not change
--- what is already drawn to mean something else. An image keeps its layer and
--- its rect, so every sprite naming it goes on naming the right texels and the
--- next frame draws the new pixels with nothing in the world touched. A file
--- that changed size cannot do that, so it is refused rather than half applied.
---
--- @param path The path the image was already registered under, not a new file
---     to add. Nil or empty raises, as does a path nothing was registered for.
--- @return The layer of the atlas the image occupies, unchanged by the reload.
--- @return Its width in pixels, necessarily the width it had before.
--- @return Its height in pixels, likewise unchanged: a file whose size moved
---     is refused rather than reported back with new numbers.
function tools.reloadImage(path: string): integer, integer, integer
    if path == nil or path == "" then
        error("path is required", 0)
    end
    local target = renderer()
    if not assets.installed() then
        error("no asset loader is running, so there is nothing here that " .. "decodes an image file", 0)
    end

    -- Nothing in `assets` is a cache, so this decodes the file as it is now
    -- rather than answering with what the first load produced.
    local handle = assets.loadImage(path)
    assets.waitAll()
    if handle.status ~= "ready" then
        local reason = handle.error or ("still " .. handle.status)
        handle:release()
        error(("'%s' did not load: %s"):format(path, reason), 0)
    end

    local _, region = target:replaceImage(handle)
    return region.layer, region.width, region.height
end

--- Re-reads a sound file over the clip already loaded from it.
---
--- The mixer's half is `Audio:reload`, which is where the difference between a
--- resident clip and a streamed one lives. This is the part that finds the
--- mixer and turns a refusal into a raise.
---
--- @param path The path the clip was loaded from, which is also its identity,
---     so the edited file comes back under the index every `Sound` row already
---     carries. Nil or empty raises.
--- @return Whether the clip is held in memory, which is what was replaced. A
---     streamed clip holds nothing and had nothing to replace, so false here
---     is a successful call and not a refusal.
function tools.reloadSound(path: string): boolean
    if path == nil or path == "" then
        error("path is required", 0)
    end
    local sound = audio()
    local reloaded, refused = sound:reload(path)
    if not reloaded then
        error(refused, 0)
    end
    local clip = sound:clip(Audio.clipId(path))
    return clip ~= nil and clip.resident
end

--- Re-reads a font's metrics over the font already loaded from them.
---
--- `text.reloadFont` is the half that owns the rules, the way `Audio:reload`
--- owns the mixer's: identity, the refusal on an atlas whose size moved, and
--- laying out again exactly the texts that draw this font. What is here is
--- turning a path into a refusal an agent can read and reporting what came
--- back.
---
--- @param path Path to the metrics file, which must be one a font is already
---     loaded from. Nil, empty, or a path nothing was loaded from raises, as
---     does a file whose atlas size moved, since the glyphs already laid out
---     could not be put right against a different atlas.
--- @return The name the font is loaded under. Carried over from the original
---     load rather than re-read, so a reload never changes it, and it is what
---     the path is resolved from rather than being the path.
--- @return How many glyphs it carries, counted after the reload.
function tools.reloadFont(path: string): string, integer
    if path == nil or path == "" then
        error("path is required", 0)
    end
    local font = text.reloadFont(path)
    local glyphs = 0
    for _ in pairs(font.glyphs) do
        glyphs = glyphs + 1
    end
    return font.name, glyphs
end

mcp.register({
    name = "reload_shaders",
    whenCrashed = true,
    description = "Re-reads shaders and materials from their files and "
        .. "rebuilds the pipelines. Refuses where a reload would change what "
        .. "already-drawn entities mean.",
    destructive = true,
    inputSchema = {type = "object", properties = data.empty_array},
    handler = function(_: {string: any}): {string: any} return {materials = tools.reloadShaders()} end,
})

mcp.register({
    name = "reload_image",
    whenCrashed = true,
    description = "Re-reads an image file and uploads it over the one already "
        .. "registered under that path. Refuses a file whose size changed.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "The path the image was registered under.",
            },
        },
        required = {"path"},
    },
    handler = function(args: {string: any}): {string: any}
        local path = args.path as string
        local layer, width, height = tools.reloadImage(path)
        return {path = path, layer = layer, width = width, height = height}
    end,
})

--- Re-reads a sound file over the clip already loaded from it.
---
--- The same operation for the mixer, and identity is kept the same way: a clip
--- is its path, so an edited file comes back under the index every `Sound` row
--- already carries. What differs from an image is that there is a case with
--- nothing to do, because a streamed clip holds nothing and each voice opens
--- the file for itself.
mcp.register({
    name = "reload_sound",
    whenCrashed = true,
    description = "Re-reads a sound file over the clip already loaded from "
        .. "that path. A streamed clip holds nothing, so it reports that "
        .. "rather than replacing anything.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "The path the clip was loaded from.",
            },
        },
        required = {"path"},
    },
    handler = function(args: {string: any}): {string: any}
        local path = args.path as string
        local resident = tools.reloadSound(path)
        return {path = path, resident = resident, replaced = resident}
    end,
})

--- Re-reads a font's metrics over the font already loaded from them.
---
--- The one reload with something in the world to put right afterwards. An
--- image, a clip and a pipeline are each read through every frame, so replacing
--- one is picked up by the next frame and nothing has to be told. A glyph is
--- not: it is an instance laid out once from the metrics and left alone until
--- something about its text changes, and re-reading the metrics changes nothing
--- about its text. So this is also what lays those glyphs out again.
mcp.register({
    name = "reload_font",
    whenCrashed = true,
    description = "Re-reads a font's metrics over the font already loaded "
        .. "from that path, and lays out every text drawing it again. Refuses "
        .. "metrics that name an atlas of a different size.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "The path the font's metrics were loaded from.",
            },
        },
        required = {"path"},
    },
    handler = function(args: {string: any}): {string: any}
        local path = args.path as string
        local name, glyphs = tools.reloadFont(path)
        return {path = path, font = name, glyphs = glyphs}
    end,
})

--- Turns the file watcher on and off, and drives it a poll at a time.
---
--- The watcher is what makes the four reloads above happen without being
--- asked, so this is the switch over them rather than a fifth reload. Polling
--- from here as well as from the loop is what lets an agent that has just
--- written a file wait for the effect rather than for the interval.
mcp.register({
    name = "watch",
    whenCrashed = true,
    description = "Reports, starts, stops or steps the content file watcher, "
        .. "which reloads shaders, images, sounds and fonts when their files "
        .. "change.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            enabled = {
                type = "boolean",
                description = "Starts or stops the watcher. Omit to leave it " .. "as it is.",
            },
            poll = {
                type = "boolean",
                description = "Looks at every watched file now, without " .. "waiting for the interval.",
            },
        },
    },
    handler = function(args: {string: any}): {string: any}
        if not watch.available() then
            error(
                "this build links no shader compiler, so it is a release "
                    .. "and has no business polling the filesystem",
                0
            )
        end

        local enabled = args.enabled as boolean
        if enabled == true and not watch.installed() then
            watch.install()
        elseif enabled == false then
            watch.uninstall()
        end

        local fired = 0
        if args.poll == true then
            fired = watch.scan()
        end

        local watching = watch.watching()
        local unsettled = watch.unsettled()
        local kinds = watch.kinds()
        return {
            watching = watch.installed(),
            files = #watching,
            paths = #watching > 0 and watching or data.empty_array,
            -- Files seen changing and not acted on yet, which is what a save
            -- still being written looks like from here.
            unsettled = #unsettled > 0 and unsettled or data.empty_array,
            kinds = #kinds > 0 and kinds or data.empty_array,
            dispatched = watch.dispatched(),
            reloaded = fired,
        }
    end,
})

--- Runs Lua in the game, with the world in scope.
---
--- Synchronous, because tools are answered inside the frame before the world
--- updates. The engine this replaces had to queue the code and answer a frame
--- later, keeping the client socket open in between; there is nothing to defer
--- here, so there is no deferral machinery.
mcp.register({
    name = "run_lua",
    description = "Runs Lua with `world` in scope. Returns an envelope "
        .. "{returned, values}. State persists between calls, so a handle "
        .. "stashed in a global is there next time. Prefer a structured tool "
        .. "where one covers the operation.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            code = {
                type = "string",
                description = "Lua to run. A bare expression is returned.",
            },
        },
        required = {"code"},
    },
    handler = function(args: {string: any}): {string: any}
        local code = args.code as string
        if code == nil or code == "" then
            error("code is required", 0)
        end

        local chunk, reason = sandbox.compile(code)
        if chunk == nil then
            error("does not compile: " .. tostring(reason), 0)
        end

        -- Counted through select rather than table.pack, which LuaJIT does
        -- not have: it is 5.1, while the type checker describes 5.4. A
        -- returning nil has to be distinguishable from returning nothing.
        local function collect(ok: boolean, ...: any): integer, {any}
            if not ok then
                error(tostring((...)), 0)
            end
            local count = select("#", ...)
            local values: {any} = {}
            for index = 1, count do
                values[index] = sandbox.describe((select(index, ...)))
            end
            return count, values
        end

        local count, values = collect(pcall(chunk, world()))
        return {
            returned = count,
            values = count > 0 and values or data.empty_array,
        }
    end,
})

return tools

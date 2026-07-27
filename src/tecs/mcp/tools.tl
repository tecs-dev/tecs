--- The tools every build exposes.
---
--- Deliberately few. A game registers what its own world needs; these are the
--- ones that are true of any build and that an agent reaches for before it
--- knows anything else: is it alive, what is it, and what has it been saying.

local cjson <const> = require("cjson")
local sdl <const> = require("tecs.ffi.sdl3")
local image <const> = require("tecs.ffi.sdl3image")
local capabilities <const> = require("tecs.platform.capabilities")
local paths <const> = require("tecs.platform.paths")
local log <const> = require("tecs.log")
local ecs <const> = require("tecs.ecs")
local mcp <const> = require("tecs.mcp")
local events <const> = require("tecs.platform.events")
local sandbox <const> = require("tecs.mcp.sandbox")
local shaders <const> = require("tecs.gpu.shaders")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local materials <const> = require("tecs.gpu.materials")
local Renderer <const> = require("tecs.Renderer")
local Audio <const> = require("tecs.Audio")

local C <const> = sdl.C

local record tools
    --- Set by the application so the frame-facing tools have something to
    --- look at. Absent means those tools report why rather than failing.
    bind: function(renderer: Renderer, world: ecs.World)
    --- Supplies what rebuilds the pipelines after a shader reload.
    bindReload: function(rebuild: function())
end

local bound: Renderer = nil
local boundWorld: ecs.World = nil
local boundReload: function() = nil

function tools.bind(renderer: Renderer, world: ecs.World)
    bound = renderer
    boundWorld = world
end

--- Supplies what rebuilds the pipelines after a shader reload.
---
--- Separate from `bind` because it is the device's half of the operation and
--- the source half is all this module can do on its own. Swapping a pipeline
--- object means destroying live GPU handles and creating new ones against the
--- formats the device claimed, which is knowledge the renderer's backend has
--- and nothing here does. `rebuild` runs with the device idle and outside any
--- pass, and raising from it is reported as the tool failing.
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
    inputSchema = { type = "object", properties = cjson.empty_array },
    handler = function(_: {string: any}): {string: any}
        local crash = mcp.crashed()
        return {
            ok = crash == nil,
            crashed = crash or cjson.null,
            ticks = tonumber(C.SDL_GetTicks()) as number,
        }
    end,
})

mcp.register({
    name = "context",
    description = "What this build is and what it can do.",
    readOnly = true,
    whenCrashed = true,
    inputSchema = { type = "object", properties = cjson.empty_array },
    handler = function(_: {string: any}): {string: any}
        local caps = capabilities.get()
        return {
            target = caps.target,
            architecture = caps.architecture,
            jit = caps.jit,
            dynamicLibraries = caps.dynamicLibraries,
            runtimeShaders = caps.runtimeShaders,
            packagedShaders = caps.packagedShaders,
            shaderFormats = caps.shaderFormats,
            cores = caps.cores,
            assets = paths.assets(),
            writable = paths.pref(),
            logFile = log.filePath() or cjson.null,
            loggers = log.loggers(),
        }
    end,
})

--- Bytes read per call. A cursor rather than a whole file, so polling a long
--- run stays cheap.
local WINDOW <const> = 65536

mcp.register({
    name = "get_logs",
    description = "Reads the log file from a byte offset. Poll with the "
        .. "returned offset to follow it.",
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
            return { lines = cjson.empty_array, offset = 0, path = cjson.null }
        end

        -- The path is returned so an agent sharing a filesystem with the game
        -- can grep it directly instead of pulling it through here, which is
        -- what cmd_screenshot already does with artifacts.
        local file = io.open(path, "rb")
        if file == nil then
            return { lines = cjson.empty_array, offset = 0, path = path }
        end

        local after = math.floor(tonumber(args.after) or 0) as integer
        local size = file:seek("end")
        if after > size then after = 0 end   -- the file was truncated
        file:seek("set", after)
        local text = file:read(WINDOW) or ""
        file:close()

        -- Only whole lines, so a cursor never lands mid-record and the next
        -- read does not start with a fragment.
        local lastBreak = text:find("\n[^\n]*$")
        if lastBreak ~= nil then text = text:sub(1, lastBreak) end

        local contains = args.contains as string
        local lines: {string} = {}
        for line in text:gmatch("[^\n]+") do
            if contains == nil or line:find(contains, 1, true) then
                lines[#lines + 1] = line
            end
        end

        return {
            path = path,
            offset = after + #text,
            lines = #lines > 0 and lines or cjson.empty_array,
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
    description = "Captures the last rendered frame to a PNG and returns its "
        .. "path.",
    readOnly = true,
    inputSchema = {
        type = "object",
        properties = {
            name = {
                type = "string",
                description = "File name under the writable root. Defaults to "
                    .. "screenshot.png.",
            },
        },
    },
    handler = function(args: {string: any}): {string: any}
        local texture = renderer():captureTexture()
        local pixels = texture:readback()
        local width, height = texture.width, texture.height

        -- Wrapping rather than copying: the surface borrows the readback
        -- buffer, which outlives the save because it is still referenced here.
        --
        -- X rather than A in the format, so the alpha channel is ignored. The
        -- lit target carries the G-buffer's alpha, which is zero everywhere
        -- nothing was drawn, and a screenshot that came back transparent would
        -- show as white in every viewer rather than as the black it was.
        local surface = C.SDL_CreateSurfaceFrom(width, height,
            C.SDL_PIXELFORMAT_XBGR8888, pixels, width * 4)
        if surface == nil then
            error("SDL_CreateSurfaceFrom failed: " .. sdl.error(), 0)
        end

        local name = (args.name as string) or "screenshot.png"
        local path = paths.writable(name)
        local saved = image.C.IMG_SavePNG(surface, path)
        C.SDL_DestroySurface(surface)
        if not saved then
            error("IMG_SavePNG failed: " .. sdl.error(), 0)
        end

        return { path = path, width = width, height = height }
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
                items = { type = "array", items = { type = "integer" } },
            },
        },
        required = { "points" },
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
                sampled[index] = { x = x, y = y, outside = true }
            else
                local pixel = texture:getPixel(pixels, x, y)
                sampled[index] = {
                    x = x, y = y,
                    r = pixel.r, g = pixel.g, b = pixel.b, a = pixel.a,
                }
            end
        end

        return { width = width, height = height, pixels = sampled }
    end,
})

--- Pushes a synthetic event into the same stream real input arrives on.
---
--- Still available after a crash, deliberately: quit and escape are exactly
--- what a game that has stopped simulating still needs to be told, and a
--- window nobody can close is worse than one that is not drawing.
mcp.register({
    name = "send_event",
    description = "Pushes an event into the input stream, as if it had come "
        .. "from the platform.",
    destructive = true,
    whenCrashed = true,
    inputSchema = {
        type = "object",
        properties = {
            kind = {
                type = "string",
                description = "Event kind. Call with no kind to list them.",
            },
            scancode = { type = "integer", description = "For keyDown, keyUp." },
            button = { type = "integer", description = "For mouseDown, mouseUp." },
            x = { type = "number" },
            y = { type = "number" },
            clicks = {
                type = "integer",
                description = "Clicks in the run, for mouseDown and mouseUp. "
                    .. "One when omitted.",
            },
            wheelX = { type = "number", description = "For mouseWheel." },
            wheelY = { type = "number", description = "For mouseWheel." },
            wheelTicksX = {
                type = "integer",
                description = "Whole notches, for mouseWheel.",
            },
            wheelTicksY = { type = "integer", description = "Whole notches." },
            flipped = {
                type = "boolean",
                description = "Send the wheel event as a platform with "
                    .. "natural scrolling does, which arrives negated.",
            },
            penState = {
                type = "integer",
                description = "SDL_PEN_INPUT_* mask, for the pen kinds.",
            },
            repeated = { type = "boolean", description = "For keyDown." },
            which = {
                type = "integer",
                description = "Device, window or display the event is about.",
            },
            data1 = {
                type = "integer",
                description = "First payload, for the window and display kinds.",
            },
            data2 = { type = "integer", description = "Second payload." },
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
            return { kinds = events.kinds() }
        end
        -- events.push validates the kind against the same table the drain
        -- decodes with, so an unknown one cannot be pushed and then ignored.
        events.push(kind, {
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
        } as events.Event)
        return { pushed = kind }
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
    inputSchema = { type = "object", properties = cjson.empty_array },
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
                error = clip.error or cjson.null,
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
                clip = voice.clip or cjson.null,
                gain = voice.gain,
                applied = voice.applied,
                pitch = voice.pitch,
                group = voice.group or cjson.null,
                key = voice.key or cjson.null,
                paused = voice.paused,
                stopping = voice.stopping,
                owned = voice.owned,
                spatial = voice.spatial,
                x = voice.x, y = voice.y, z = voice.z,
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
                voices = limit ~= nil and limit.voices or cjson.null,
                cooldown = limit ~= nil and limit.cooldown or cjson.null,
            }
        end

        return {
            available = sound.available,
            masterGain = sound:masterGain(),
            muted = sound:muted(),
            sounding = sound:sounding(),
            maxVoices = sound:maxVoices(),
            loading = sound:loading(),
            decoders = #decoders > 0 and decoders or cjson.empty_array,
            clips = #clips > 0 and clips or cjson.empty_array,
            groups = #groups > 0 and groups or cjson.empty_array,
            keys = #keys > 0 and keys or cjson.empty_array,
            voices = #voices > 0 and voices or cjson.empty_array,
        }
    end,
})

--- Re-reads the shader and material sources and rebuilds what draws from them.
---
--- Driven from here rather than from a watcher on the filesystem. Whatever
--- edited a `.glsl` knows that it did, and a watcher is the part of a reload
--- with no decision in it: the interesting question is what a reload may not
--- do, and both answers to that are checked below.
---
--- The pipeline objects a frame binds are read through the backend every
--- frame, so replacing them is picked up by the next frame with no graph
--- rebuild and nothing in the world touched.
mcp.register({
    name = "reload_shaders",
    description = "Re-reads shaders and materials from their files and "
        .. "rebuilds the pipelines. Refuses where a reload would change what "
        .. "already-drawn entities mean.",
    destructive = true,
    inputSchema = { type = "object", properties = cjson.empty_array },
    handler = function(_: {string: any}): {string: any}
        -- A pack decides the shader format the device claimed at creation, so
        -- a build without a compiler has nothing to put in its place and no
        -- way to change what it draws with while it is running.
        if not shadercompiler.available() then
            error("this build links no shader compiler, so its shaders are "
                .. "fixed at the pack it was built against", 0)
        end
        if boundReload == nil then
            error("no shader rebuild is registered, so the sources would be "
                .. "re-read and nothing would draw differently", 0)
        end

        local reloaded, refused = materials.reload()
        if not reloaded then error(refused, 0) end
        shaders.invalidate()
        boundReload()

        return { materials = materials.names() }
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
        required = { "code" },
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
            if not ok then error(tostring((...)), 0) end
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
            values = count > 0 and values or cjson.empty_array,
        }
    end,
})

return tools

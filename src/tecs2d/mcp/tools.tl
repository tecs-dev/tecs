--- The tools every build exposes.
---
--- Deliberately few. A game registers what its own world needs; these are the
--- ones that are true of any build and that an agent reaches for before it
--- knows anything else: is it alive, what is it, and what has it been saying.

local cjson <const> = require("cjson")
local sdl <const> = require("tecs2d.ffi.sdl3")
local image <const> = require("tecs2d.ffi.sdl3image")
local capabilities <const> = require("tecs2d.platform.capabilities")
local paths <const> = require("tecs2d.platform.paths")
local log <const> = require("tecs2d.log")
local mcp <const> = require("tecs2d.mcp")
local Renderer <const> = require("tecs2d.Renderer")

local C <const> = sdl.C

local record tools
    --- Set by the application so the frame-facing tools have something to
    --- look at. Absent means those tools report why rather than failing.
    bind: function(renderer: Renderer)
end

local bound: Renderer = nil

function tools.bind(renderer: Renderer)
    bound = renderer
end

--- The bound renderer, or an error naming why there is not one.
local function renderer(): Renderer
    if bound == nil then
        error("no renderer is bound; the application has not started", 0)
    end
    return bound
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

return tools

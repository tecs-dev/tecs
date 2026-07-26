--- The tools every build exposes.
---
--- Deliberately few. A game registers what its own world needs; these are the
--- ones that are true of any build and that an agent reaches for before it
--- knows anything else: is it alive, what is it, and what has it been saying.

local cjson <const> = require("cjson")
local sdl <const> = require("tecs2d.ffi.sdl3")
local capabilities <const> = require("tecs2d.platform.capabilities")
local paths <const> = require("tecs2d.platform.paths")
local log <const> = require("tecs2d.log")
local mcp <const> = require("tecs2d.mcp")

local C <const> = sdl.C

local record tools
end

mcp.register({
    name = "ping",
    description = "Confirms the game is running and answering.",
    readOnly = true,
    inputSchema = { type = "object", properties = cjson.empty_array },
    handler = function(_: {string: any}): {string: any}
        return {
            ok = true,
            ticks = tonumber(C.SDL_GetTicks()) as number,
        }
    end,
})

mcp.register({
    name = "context",
    description = "What this build is and what it can do.",
    readOnly = true,
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

return tools

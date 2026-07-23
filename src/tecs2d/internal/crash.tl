--- Crash-time coordination between the run loop's error handler and the
--- plugins that must stay useful after a gameplay error (the MCP server
--- above all: an agent's next tool call should get a clear "game crashed"
--- answer with the traceback, never a hang against a dead socket).
---
--- Plugins register at install time; the error handler notifies once with
--- the formatted traceback and then drives the registered pumps every
--- iteration of the error screen loop.

local record crash
    --- Register a one-shot crash observer (receives the full traceback).
    onCrash: function(fn: function(string)): function()

    --- Register a per-frame pump run while the error screen is up
    --- (the MCP transport's accept/serve tick).
    addPump: function(fn: function()): function()

    --- Fired by the error handler. Runs every observer, isolated.
    notify: function(err: string)

    --- Drives every registered pump, isolated. Called each error-loop frame.
    pump: function()

    --- The traceback from notify, or nil when no crash has happened.
    error: function(): string
end

local handlers: {function(string)} = {}
local pumps: {function()} = {}
local crashError: string = nil

local function removeCallback(list: {any}, callback: any)
    for i = #list, 1, -1 do
        if list[i] == callback then
            table.remove(list, i)
            return
        end
    end
end

function crash.onCrash(fn: function(string)): function()
    handlers[#handlers + 1] = fn
    return function()
        removeCallback(handlers as {any}, fn)
    end
end

function crash.addPump(fn: function()): function()
    pumps[#pumps + 1] = fn
    return function()
        removeCallback(pumps as {any}, fn)
    end
end

function crash.notify(err: string)
    if crashError ~= nil then return end
    crashError = err or "unknown error"
    for i = 1, #handlers do
        pcall(handlers[i], crashError)
    end
end

function crash.pump()
    for i = 1, #pumps do
        pcall(pumps[i])
    end
end

function crash.error(): string
    return crashError
end

return crash

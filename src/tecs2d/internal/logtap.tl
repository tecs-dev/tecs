--- Shared log capture ring backing the debugger's `logs` command and MCP's
--- `get_logs` tool. A tee sink forwards every line to the original sink and
--- keeps a bounded ring. Installed once per process; log writes are
--- level-gated and not hot, so the extra table insert per line is negligible.

local logging <const> = require("tecs.utils.logging")

local record logtap
    CAP: integer
    install: function()
    --- Empty the ring and reset the dropped counter; returns the number of
    --- lines cleared.
    clear: function(): integer
    --- Rank for a level name (DEBUG=1 .. ERROR=4); nil when unknown.
    levelRank: function(level: string): integer
    --- Sorted logger names currently represented in the ring.
    loggers: function(): {string}
    --- Filter captured lines by minimum rank, text, logger, sequence cursor,
    --- and maximum age in seconds. Returns at most `limit` from the tail
    --- (newest last) plus matched, captured, dropped, and latest counts.
    query: function(minRank: integer, contains: string, logger: string,
        after: integer, since: number, limit: integer):
        {{string: any}}, integer, integer, integer, integer
end

logtap.CAP = 500

local capturedLogs: {{string: any}} = {}
local logsDropped = 0
local logSeq = 0
local installed = false

local rank <const>: {string: integer} = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}

local function now(): number
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.time()
end

function logtap.install()
    if installed then return end
    installed = true
    local original = logging.sink
    local tee: {string: any} = {
        write = function(self: any, ...: string): any
            original:write(...)
            -- Logger writes (dateStr, "name LEVEL: ", message, "\n").
            local dateStr, prefix, msg = ...
            local loggerName, level = (prefix or ""):match("^(.-) (%u+): $")
            logSeq = logSeq + 1
            capturedLogs[#capturedLogs + 1] = {
                seq = logSeq,
                time = (dateStr or ""):gsub("%s+$", ""),
                logger = loggerName or "",
                level = level or "",
                message = msg or "",
                capturedAt = now(),
            }
            if #capturedLogs > logtap.CAP then
                table.remove(capturedLogs, 1)
                logsDropped = logsDropped + 1
            end
            -- FILE:write chains; returning self keeps a chained write captured.
            return self
        end,
    }
    logging.setSink(tee as FILE)
end

function logtap.clear(): integer
    local n = #capturedLogs
    capturedLogs = {}
    logsDropped = 0
    return n
end

function logtap.levelRank(level: string): integer
    return rank[level:upper()]
end

function logtap.loggers(): {string}
    local seen: {string: boolean} = {}
    local out: {string} = {}
    for i = 1, #capturedLogs do
        local logger = capturedLogs[i].logger as string
        if logger ~= "" and not seen[logger] then
            seen[logger] = true
            out[#out + 1] = logger
        end
    end
    table.sort(out)
    return out
end

function logtap.query(minRank: integer, contains: string, logger: string,
        after: integer, since: number, limit: integer):
    {{string: any}}, integer, integer, integer, integer
    if limit < 1 then limit = 1 elseif limit > logtap.CAP then limit = logtap.CAP end
    local queriedAt = now()
    local containsLower = contains and contains:lower()
    local loggerLower = logger and logger:lower()
    local matched: {{string: any}} = {}
    for i = 1, #capturedLogs do
        local e = capturedLogs[i]
        local r = rank[e.level as string] or 2
        local age = math.max(0, queriedAt - (e.capturedAt as number))
        local messageLower = (e.message as string):lower()
        local entryLoggerLower = (e.logger as string):lower()
        local levelLower = (e.level as string):lower()
        local loggerMatches = true
        if loggerLower then
            loggerMatches = entryLoggerLower:find(loggerLower, 1, true) ~= nil
        end
        local textMatches = true
        if containsLower then
            textMatches = messageLower:find(containsLower, 1, true) ~= nil
                or entryLoggerLower:find(containsLower, 1, true) ~= nil
                or levelLower:find(containsLower, 1, true) ~= nil
        end
        if (e.seq as integer) > after and r >= minRank
            and (not since or since <= 0 or age <= since)
            and loggerMatches and textMatches then
            matched[#matched + 1] = {
                seq = e.seq,
                time = e.time,
                logger = e.logger,
                level = e.level,
                message = e.message,
                age = age,
            }
        end
    end
    -- Newest last; return at most `limit` from the tail.
    local total = #matched
    local out = matched
    if total > limit then
        out = {}
        for i = total - limit + 1, total do out[#out + 1] = matched[i] end
    end
    return out, total, #capturedLogs, logsDropped, logSeq
end

return logtap

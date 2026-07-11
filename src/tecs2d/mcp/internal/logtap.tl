--- Log capture ring backing the get_logs tool: a tee sink forwards every
--- line to the original sink and keeps a bounded ring. Installed once per
--- process; log writes are level-gated and not hot, so the extra table
--- insert per line is negligible.

local logging <const> = require("tecs.utils.logging")

local record logtap
    CAP: integer
    install: function()
    --- Empty the ring and reset the dropped counter; returns the number of
    --- lines cleared.
    clear: function(): integer
    --- Rank for a level name (DEBUG=1 .. ERROR=4); nil when unknown.
    levelRank: function(level: string): integer
    --- Filter captured lines by minimum rank, substring, and seq cursor,
    --- returning at most `limit` from the tail (newest last) plus the
    --- matched total, captured count, dropped count, and latest seq.
    query: function(minRank: integer, contains: string, after: integer, limit: integer):
        {{string: any}}, integer, integer, integer, integer
end

logtap.CAP = 500

local capturedLogs: {{string: any}} = {}
local logsDropped = 0
local logSeq = 0
local installed = false

local rank <const>: {string: integer} = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}

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

function logtap.query(minRank: integer, contains: string, after: integer, limit: integer):
    {{string: any}}, integer, integer, integer, integer
    if limit < 1 then limit = 1 elseif limit > logtap.CAP then limit = logtap.CAP end
    local matched: {{string: any}} = {}
    for i = 1, #capturedLogs do
        local e = capturedLogs[i]
        local r = rank[e.level as string] or 2
        if (e.seq as integer) > after and r >= minRank and (not contains
            or (e.message as string):find(contains, 1, true)
            or (e.logger as string):find(contains, 1, true)) then
            matched[#matched + 1] = e
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

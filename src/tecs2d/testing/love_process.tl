--- Launches a LÖVE app in the background for integration tests.
--- The app is started detached with its output redirected to a log file and
--- its pid captured, so tests can poll liveness, read diagnostics on
--- failure, and escalate from MCP quit to SIGTERM/SIGKILL on cleanup.
--- POSIX-only (darwin/linux), matching where make test-love runs.

local socket <const> = require("socket")
-- The socket.d.tl stub types sleep as integer-only; it accepts fractions.
local sleep <const> = socket.sleep as function(number)

local record love_process
    record Options
        --- Path to the love executable.
        loveBin: string
        --- Game directory to launch.
        appDir: string
        --- File that captures the app's stdout+stderr.
        logPath: string
        --- Extra environment variables for the app.
        env: {string: string}
    end

    record Proc
        pid: integer
        logPath: string

        isRunning: function(self: Proc): boolean
        waitExit: function(self: Proc, seconds: number): boolean
        signal: function(self: Proc, sig: string)
        --- Force the process down: TERM, short grace, then KILL.
        stop: function(self: Proc)
        readLog: function(self: Proc): string
    end

    start: function(opts: Options): Proc
end

local ProcImpl = {}
local procMt <const> = {__index = ProcImpl}

local function shellQuote(s: string): string
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function love_process.start(opts: love_process.Options): love_process.Proc
    if not opts or not opts.loveBin or not opts.appDir or not opts.logPath then
        error("love_process.start requires loveBin, appDir, and logPath")
    end

    local envPrefix = ""
    if opts.env then
        local parts: {string} = {}
        for key, value in pairs(opts.env) do
            parts[#parts + 1] = key .. "=" .. shellQuote(value)
        end
        envPrefix = table.concat(parts, " ") .. " "
    end

    local cmd = string.format(
        "%s%s %s > %s 2>&1 & echo $!",
        envPrefix,
        shellQuote(opts.loveBin),
        shellQuote(opts.appDir),
        shellQuote(opts.logPath)
    )

    local pipe = io.popen(cmd)
    if not pipe then
        error("io.popen failed for: " .. cmd)
    end
    local pidLine = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pidLine)
    if not pid then
        error("could not read pid from launch, got: " .. tostring(pidLine))
    end

    local proc: love_process.Proc = setmetatable({
        pid = pid as integer,
        logPath = opts.logPath,
    } as love_process.Proc, procMt as metatable<love_process.Proc>)
    return proc
end

function ProcImpl.isRunning(self: love_process.Proc): boolean
    local status = os.execute("kill -0 " .. tostring(self.pid) .. " 2>/dev/null")
    return (status as integer) == 0
end

function ProcImpl.waitExit(self: love_process.Proc, seconds: number): boolean
    local deadline = socket.gettime() + seconds
    while socket.gettime() < deadline do
        if not self:isRunning() then
            return true
        end
        sleep(0.05)
    end
    return not self:isRunning()
end

function ProcImpl.signal(self: love_process.Proc, sig: string)
    os.execute("kill -" .. sig .. " " .. tostring(self.pid) .. " 2>/dev/null")
end

function ProcImpl.stop(self: love_process.Proc)
    if not self:isRunning() then return end
    self:signal("TERM")
    if self:waitExit(2) then return end
    self:signal("KILL")
    self:waitExit(2)
end

function ProcImpl.readLog(self: love_process.Proc): string
    local fh = io.open(self.logPath, "r")
    if not fh then return "" end
    local contents = fh:read("*a")
    fh:close()
    return contents or ""
end

return love_process

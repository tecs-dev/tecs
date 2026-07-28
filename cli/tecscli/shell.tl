--- Running other programs, and becoming one.
---
--- Two shapes, and the difference matters.
---
--- `shell.run` starts a child, lets it inherit this process's terminal, waits,
--- and answers its exit status. That is what a formatter or a compiler wants:
--- its diagnostics belong on the user's screen unaltered, and capturing them
--- to print them again only loses the colours.
---
--- `shell.become` does not start anything. It replaces this process with the
--- program named, so a game launched by `tecs run` is not a child of the CLI
--- at all: one process id, one exit status, and a Control-C that reaches the
--- game rather than the tool that started it. `tecs.proc` is deliberately not
--- used here for the same reason; it exists to run a child without stalling a
--- frame, and a command line tool has no frame to stall.

local ffi <const> = require("ffi")

ffi.cdef([[
int execv(const char *path, char *const argv[]);
int setenv(const char *name, const char *value, int overwrite);
int chdir(const char *path);
]])

-- Named one at a time rather than reached through an open namespace, because
-- an open FFI namespace types as `any` and an `any` is not callable in Teal.
local C <const> = ffi.C as {string: any}
local execv <const> = C.execv as function(string, any): integer
local setenv <const> = C.setenv as function(string, string, integer): integer
local chdir <const> = C.chdir as function(string): integer

local record shell
end

--- Quotes one argument for `/bin/sh`.
---
--- Single quotes, with an embedded single quote closed and reopened around an
--- escaped one, which is the only form that needs no knowledge of what is
--- inside. A project path holds spaces more often than anything else here, and
--- a path holding a quote is rare enough to be the case that gets this wrong
--- silently if it is not handled.
function shell.quote(argument: string): string
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end

--- One command line from a program and its arguments.
function shell.line(args: {string}): string
    local parts: {string} = {}
    for index, argument in ipairs(args) do
        parts[index] = shell.quote(argument)
    end
    return table.concat(parts, " ")
end

--- The exit code behind whatever `os.execute` answered.
---
--- It answers differently depending on how LuaJIT was configured: 5.1 hands
--- back the raw `system` status, whose low byte is the signal and whose high
--- byte is the code, and a 5.2-compatible build hands back a boolean, a reason
--- and the code. Both are read rather than one being assumed, because assuming
--- the wrong one turns every success into a failure or every failure into a
--- success, and only one of those is noticed.
local function status(first: any, second: any, third: any): integer
    local _ = second
    if first is boolean then
        return first and 0 or (third as integer or 1)
    end
    local raw = first as integer
    if raw == nil then
        return 1
    end
    if raw >= 256 then
        return math.floor(raw / 256)
    end
    return raw
end

--- Runs `args` and answers the child's exit code.
--- @param cwd Directory to run in. Omitted inherits this process's.
function shell.run(args: {string}, cwd?: string): integer
    local line = shell.line(args)
    if cwd ~= nil and cwd ~= "" then
        line = "cd " .. shell.quote(cwd) .. " && " .. line
    end
    return status(os.execute(line))
end

--- Whether a program can be found on `PATH`.
---
--- The shell's own `command -v`, with its answer discarded: what is wanted is
--- the status, and printing the path it found would put a line of noise in
--- front of every formatter that is installed.
function shell.onPath(program: string): boolean
    return status(os.execute("command -v " .. shell.quote(program) .. " >/dev/null 2>&1")) == 0
end

--- Sets an environment variable for this process and everything it starts.
function shell.setenv(name: string, value: string)
    setenv(name, value, 1)
end

--- Changes this process's working directory.
function shell.chdir(path: string): boolean
    return chdir(path) == 0
end

--- Replaces this process with `args[1]`, which never returns on success.
---
--- Returns only when the executable could not be run at all, since a successful
--- `execv` has already discarded the code that would have read its result.
function shell.become(args: {string}): string
    local count = #args
    local argv = ffi.new("char *[?]", count + 1) as {integer: any}
    -- Kept alive for the length of the call: `ffi.cast` on a Lua string
    -- borrows the string's own bytes, and a temporary would be collectable
    -- between filling the array and reaching `execv`.
    local held: {integer: any} = {}
    for index = 1, count do
        held[index] = ffi.new("char[?]", #args[index] + 1)
        ffi.copy(held[index] as string, args[index])
        argv[index - 1] = held[index]
    end
    argv[count] = nil

    execv(args[1], argv)
    return ("cannot execute %s"):format(args[1])
end

return shell

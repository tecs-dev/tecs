--- Open a file with the OS default handler, robustly. love.system.openURL is
--- picky about file:// URLs (spaces in the macOS save directory break the raw
--- form; some handlers reject the escaped form), so this tries raw, then
--- percent-escaped, then the platform's native opener command.

local record osopen
    --- Shell-quote a string for POSIX sh (single quotes, ' escaped).
    shellQuote: function(s: string): string

    --- Open an absolute path with the OS default handler.
    --- Returns true, or false plus a detail string describing every attempt.
    open: function(absPath: string): boolean, string
end

function osopen.shellQuote(s: string): string
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function doubleQuote(s: string): string
    -- cmd.exe ignores backslash escapes; a doubled quote is the escape it honors.
    return '"' .. s:gsub('"', '""') .. '"'
end

local function fileUrl(absPath: string): string
    return "file://" .. absPath:gsub("([^%w%._~/%-:])", function(c: string): string
        return string.format("%%%02X", string.byte(c))
    end)
end

local function nativeOpenCommand(absPath: string): string
    local osName = love.system.getOS()
    if osName == "OS X" or osName == "macOS" then
        return "open " .. osopen.shellQuote(absPath)
    elseif osName == "Linux" then
        return "xdg-open " .. osopen.shellQuote(absPath) .. " >/dev/null 2>&1"
    elseif osName == "Windows" then
        return "start \"\" " .. doubleQuote(absPath)
    end
    return ""
end

local function commandSucceeded(ok: any): boolean
    return ok == true or ok == 0
end

local function tryUrl(url: string): boolean, string
    local ok, opened = pcall(function(): boolean
        return love.system.openURL(url)
    end)
    if ok and opened ~= false then return true, nil end
    return false, ok and "love.system.openURL returned false" or tostring(opened)
end

function osopen.open(absPath: string): boolean, string
    local rawOk, rawErr = tryUrl("file://" .. absPath)
    if rawOk then return true, nil end
    local escOk, escErr = tryUrl(fileUrl(absPath))
    if escOk then return true, nil end
    local detail = "raw openURL failed: " .. rawErr .. "; escaped openURL failed: " .. escErr
    local cmd = nativeOpenCommand(absPath)
    if cmd == "" then
        return false, detail .. "; no native opener for " .. love.system.getOS()
    end
    if commandSucceeded(os.execute(cmd) as any) then
        return true, nil
    end
    return false, detail .. "; native opener failed"
end

return osopen

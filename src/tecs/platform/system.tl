--- Small operating-system services SDL presents consistently.
---
--- These are process-wide queries and requests rather than application
--- lifecycle. They therefore live together instead of being methods on a
--- window or on `Application`.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local record WindowLike
    handle: loader.CPtr
end

local record Locale
    --- ISO 639 language code, such as `"en"`.
    language: string
    --- ISO 3166 country code, such as `"US"`, or an empty string when the
    --- platform names only a language.
    country: string
end

local record Power
    --- `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
    --- `"charged"` or `"error"`.
    state: string
    --- Seconds of battery life remaining, or -1 when unavailable.
    seconds: integer
    --- Charge percentage in 0..100, or -1 when unavailable.
    percent: integer
end

local record system
    Locale: Locale
    Power: Power
end

local countOut <const> = loader.newArray("int[1]")
local secondsOut <const> = loader.newArray("int[1]")
local percentOut <const> = loader.newArray("int[1]")

local POWER_STATES <const>: {integer: string} = {
    [tonumber(C.SDL_POWERSTATE_ERROR) as integer] = "error",
    [tonumber(C.SDL_POWERSTATE_UNKNOWN) as integer] = "unknown",
    [tonumber(C.SDL_POWERSTATE_ON_BATTERY) as integer] = "onBattery",
    [tonumber(C.SDL_POWERSTATE_NO_BATTERY) as integer] = "noBattery",
    [tonumber(C.SDL_POWERSTATE_CHARGING) as integer] = "charging",
    [tonumber(C.SDL_POWERSTATE_CHARGED) as integer] = "charged",
}

local MESSAGE_FLAGS <const>: {string: integer} = {
    error = K.SDL_MESSAGEBOX_ERROR,
    warning = K.SDL_MESSAGEBOX_WARNING,
    info = K.SDL_MESSAGEBOX_INFORMATION,
}

--- Opens a URL with the operating system's preferred handler.
function system.openURL(url: string): boolean, string
    if url == nil or url == "" then
        return false, "a URL is required"
    end
    if not C.SDL_OpenURL(url) then
        return false, sdl.error()
    end
    return true, nil
end

--- Preferred locales in the user's priority order.
function system.preferredLocales(): {Locale}
    local out: {Locale} = {}
    local locales = C.SDL_GetPreferredLocales(countOut)
    if locales == nil then
        return out
    end
    local list = locales as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local locale = list[index] as loader.CStruct
        if locale ~= nil then
            out[#out + 1] = {
                language = loader.toString(locale.language as loader.CValue),
                country = loader.toString(locale.country as loader.CValue),
            }
        end
    end
    C.SDL_free(locales)
    return out
end

--- Current battery or external-power state.
function system.power(): Power
    secondsOut[0], percentOut[0] = -1, -1
    local state = tonumber(C.SDL_GetPowerInfo(secondsOut, percentOut)) as integer
    return {
        state = POWER_STATES[state] or "unknown",
        seconds = secondsOut[0] as integer,
        percent = percentOut[0] as integer,
    }
end

--- Shows a native informational, warning or error dialog.
---
--- This is intentionally the simple blocking form. File pickers are
--- asynchronous and live in `tecs.dialogs`.
function system.messageBox(kind: string, title: string, message: string, window?: WindowLike): boolean, string
    local flags = MESSAGE_FLAGS[kind]
    if flags == nil then
        return false, ("unknown message-box kind %q"):format(tostring(kind))
    end
    local handle = window ~= nil and window.handle or nil
    if not C.SDL_ShowSimpleMessageBox(flags, title or "", message or "", handle) then
        return false, sdl.error()
    end
    return true, nil
end

return system

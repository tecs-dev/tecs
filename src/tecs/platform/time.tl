--[=[
Platform clocks, calendar time, blocking delays, and frame timing.

The application calls `step` once per iteration and passes the result to the
world. `maxDelta` clamps long stalls before simulation sees them. Game code
may read `now`, but it must not call `step` because that moves the frame
baseline.

`now` is monotonic and is the clock for elapsed time and deadlines. `wallNow`
reads the adjustable realtime clock instead and returns an exact Unix
timestamp:

```teal
local stamp <const> = assert(tecs.platform.time.wallNow())
local localTime <const> = assert(tecs.platform.time.toDateTime(stamp, true))
print(("%04d-%02d-%02d %02d:%02d"):format(
    localTime.year,
    localTime.month,
    localTime.day,
    localTime.hour,
    localTime.minute
))
```

The delay functions block the calling thread. They belong in startup,
headless tools, and measurements, not in a frame. `delayPrecise` may busy
wait to approach its requested duration.

SDL's callback timer registration is deliberately absent. SDL invokes those
callbacks from a timer thread, which cannot safely enter LuaJIT. Game timers
store deadlines against `now` and dispatch from a system, or use
`tecs.sequence` when they belong to simulated time.

Install a provider to replace measured frame deltas during replay:

```teal
local recorded <const>: {number} = {1 / 60, 1 / 60, 1 / 30}
local frame = 0

tecs.platform.time.provider = function(realDt: number): number
    frame = frame + 1
    -- Nil keeps the measurement, so a run past the end of the recording is
    -- live again.
    return recorded[frame]
end
```

Returning nil keeps the measured delta. Pair this provider with
`tecs.platform.events.source` to replay frame timing and platform events together.
`now` always reads the monotonic platform clock and ignores the replay
provider.
]=]

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- Represents an exact instant on the Unix realtime clock.
local record Timestamp
    --- Caller-writable. Sets whole seconds since 1970-01-01 00:00:00 UTC. A
    --- negative value names an instant before the epoch.
    seconds: integer
    --- Caller-writable. Sets the normalized remainder within `seconds`, from
    --- zero through 999999999.
    nanosecond: integer
end

--- Represents a calendar date, time, and UTC offset.
local record DateTime
    --- Caller-writable. Sets the calendar year.
    year: integer
    --- Caller-writable. Sets the month from 1 through 12.
    month: integer
    --- Caller-writable. Sets the day of the month from 1 through 31, bounded
    --- further by the selected month and year.
    day: integer
    --- Caller-writable. Sets the hour from 0 through 23.
    hour: integer
    --- Caller-writable. Sets the minute from 0 through 59.
    minute: integer
    --- Caller-writable. Sets the second from 0 through 60. The last value
    --- represents a possible leap second.
    second: integer
    --- Caller-writable. Sets the fractional second from 0 through 999999999
    --- nanoseconds.
    nanosecond: integer
    --- Read-only. Reports the weekday from 0 through 6, with Sunday at zero.
    --- `fromDateTime` ignores this field.
    dayOfWeek: integer
    --- Caller-writable. Sets seconds east of UTC. A value of zero represents
    --- UTC, and `toDateTime` fills the platform's offset for local time.
    utcOffset: integer
end

--- Represents the current locale's preferred date and clock layouts.
local record LocalePreferences
    --- Read-only. Reports `"yearMonthDay"`, `"dayMonthYear"` or
    --- `"monthDayYear"`.
    dateFormat: string
    --- Read-only. Reports `"twentyFourHour"` or `"twelveHour"`.
    timeFormat: string
end

--- Represents the two exact words of a Windows FILETIME value.
local record WindowsTime
    --- Caller-writable. Sets the low unsigned 32 bits.
    low: integer
    --- Caller-writable. Sets the high unsigned 32 bits.
    high: integer
end

local record time
    --- Read-only. Exposes the exact Unix timestamp record.
    Timestamp: Timestamp
    --- Read-only. Exposes the calendar date and time record.
    DateTime: DateTime
    --- Read-only. Exposes the locale preference record.
    LocalePreferences: LocalePreferences
    --- Read-only. Exposes the Windows FILETIME record.
    WindowsTime: WindowsTime

    --- Caller-writable. Installs a replay hook that receives the measured
    --- frame delta. Returning a number replaces it; returning nil keeps it.
    ---
    --- @param realDt The application supplies the measured frame delta in seconds.
    --- @return A number replaces the measured delta, while nil keeps it.
    provider: function(realDt: number): number

    --- Caller-writable. Sets the nominal frame delta in seconds. The
    --- application initializes it from the target frame rate.
    nominal: number

    --- Caller-writable. Sets the longest frame delta in seconds that `step`
    --- returns.
    maxDelta: number

    --- Read-only. Reports the number of milliseconds in one second.
    millisecondsPerSecond: integer
    --- Read-only. Reports the number of microseconds in one second.
    microsecondsPerSecond: integer
    --- Read-only. Reports the number of nanoseconds in one second.
    nanosecondsPerSecond: integer
    --- Read-only. Reports the number of nanoseconds in one millisecond.
    nanosecondsPerMillisecond: integer
    --- Read-only. Reports the number of nanoseconds in one microsecond.
    nanosecondsPerMicrosecond: integer
end

time.nominal = 1.0 / 60.0
time.maxDelta = 0.25
time.millisecondsPerSecond = K.SDL_MS_PER_SECOND
time.microsecondsPerSecond = K.SDL_US_PER_SECOND
time.nanosecondsPerSecond = K.SDL_NS_PER_SECOND
time.nanosecondsPerMillisecond = K.SDL_NS_PER_MS
time.nanosecondsPerMicrosecond = K.SDL_NS_PER_US

local frequency: number = 0.0
local last: number = 0.0

local floor <const> = math.floor
local MAX_SAFE_INTEGER <const> = 9007199254740991
local MAX_U32 <const> = 4294967295
local MIN_TIMESTAMP_SECOND <const> = -9223372037
local MAX_TIMESTAMP_SECOND <const> = 9223372036
local MIN_TIMESTAMP_NANOSECOND <const> = 145224192
local MAX_TIMESTAMP_NANOSECOND <const> = 854775807

local record I64
    metamethod __add: function(self: I64, other: I64): I64
    metamethod __div: function(self: I64, other: I64): I64
    metamethod __mod: function(self: I64, other: I64): I64
    metamethod __mul: function(self: I64, other: I64): I64
end

local i64 <const> = ffi.typeof("int64_t") as function(value: number): I64
local billion <const> = i64(time.nanosecondsPerSecond)

local DATE_FORMATS <const>: {integer: string} = {
    [tonumber(C.SDL_DATE_FORMAT_YYYYMMDD) as integer] = "yearMonthDay",
    [tonumber(C.SDL_DATE_FORMAT_DDMMYYYY) as integer] = "dayMonthYear",
    [tonumber(C.SDL_DATE_FORMAT_MMDDYYYY) as integer] = "monthDayYear",
}

local TIME_FORMATS <const>: {integer: string} = {
    [tonumber(C.SDL_TIME_FORMAT_24HR) as integer] = "twentyFourHour",
    [tonumber(C.SDL_TIME_FORMAT_12HR) as integer] = "twelveHour",
}

local function isInteger(value: number): boolean
    return value ~= nil and value == floor(value)
end

local function validTimestamp(timestamp: Timestamp): boolean, string
    if timestamp == nil then
        return false, "timestamp is required"
    end
    local seconds = timestamp.seconds
    local nanosecond = timestamp.nanosecond
    if not isInteger(seconds) then
        return false, "timestamp seconds must be an integer"
    end
    if not isInteger(nanosecond) or nanosecond < 0 or nanosecond >= time.nanosecondsPerSecond then
        return false, "timestamp nanosecond must be an integer from 0 through 999999999"
    end
    if
        seconds < MIN_TIMESTAMP_SECOND
        or seconds > MAX_TIMESTAMP_SECOND
        or (seconds == MIN_TIMESTAMP_SECOND and nanosecond < MIN_TIMESTAMP_NANOSECOND)
        or (seconds == MAX_TIMESTAMP_SECOND and nanosecond > MAX_TIMESTAMP_NANOSECOND)
    then
        return false, "timestamp is outside the range SDL_Time represents"
    end
    return true, nil
end

local function toTicks(timestamp: Timestamp): I64, string
    local valid, reason = validTimestamp(timestamp)
    if not valid then
        return nil, reason
    end
    return i64(timestamp.seconds) * billion + i64(timestamp.nanosecond), nil
end

local function fromTicks(value: loader.CValue): Timestamp
    local ticks = value as I64
    local seconds = tonumber(ticks / billion) as integer
    local nanosecond = tonumber(ticks % billion) as integer
    if nanosecond < 0 then
        seconds = seconds - 1
        nanosecond = nanosecond + time.nanosecondsPerSecond
    end
    return {
        seconds = seconds,
        nanosecond = nanosecond,
    }
end

local function validUnsigned(value: number, maximum: number, name: string, level: integer): number
    if not isInteger(value) or value < 0 or value > maximum then
        error(("tecs: %s must be an integer from 0 through %.0f"):format(name, maximum), level)
    end
    return value
end

--- Reads the monotonic counter in seconds. Not affected by the provider.
---
--- @return A high-resolution elapsed-time reading with an arbitrary origin.
function time.now(): number
    if frequency == 0.0 then
        frequency = tonumber(C.SDL_GetPerformanceFrequency()) as number
    end
    return (tonumber(C.SDL_GetPerformanceCounter()) as number) / frequency
end

--- Reads milliseconds elapsed since SDL initialized.
---
--- @return A monotonic millisecond count. Its origin differs from `now`, so
---     values from the two functions are not directly comparable.
function time.ticksMilliseconds(): number
    return tonumber(C.SDL_GetTicks()) as number
end

--- Reads nanoseconds elapsed since SDL initialized.
---
--- A Lua number stops distinguishing adjacent nanoseconds after about 104
--- days, while elapsed differences remain useful at the precision its
--- magnitude permits.
---
--- @return A monotonic nanosecond count. Its origin differs from `now`, so
---     values from the two functions are not directly comparable.
function time.ticksNanoseconds(): number
    return tonumber(C.SDL_GetTicksNS()) as number
end

--- Reads the platform's raw high-resolution counter.
---
--- Prefer `now` for intervals. A raw counter may lose low bits when converted
--- from SDL's unsigned 64-bit value to a Lua number.
---
--- @return A platform-specific count with an arbitrary origin.
function time.performanceCounter(): number
    return tonumber(C.SDL_GetPerformanceCounter()) as number
end

--- Reads the frequency of the platform's high-resolution counter.
---
--- @return Raw counter units per second.
function time.performanceFrequency(): number
    return tonumber(C.SDL_GetPerformanceFrequency()) as number
end

--- Reads the adjustable realtime clock.
---
--- @return An exact Unix timestamp on success, or nil on failure.
--- @return The SDL error when no timestamp is available.
function time.wallNow(): Timestamp, string
    local out = loader.newArray("SDL_Time[1]")
    if not C.SDL_GetCurrentTime(out) then
        return nil, sdl.error()
    end
    return fromTicks(out[0] as loader.CValue), nil
end

--- Converts an exact Unix timestamp to calendar fields.
---
--- @param timestamp The caller supplies a normalized value returned here or
---     built within the range from about 1677 through 2262.
--- @param localTime The caller requests local time when true. Omitted or false
---     requests UTC.
--- @return A fresh calendar record on success, or nil for an invalid or
---     unsupported timestamp.
--- @return The validation or SDL error when no record is returned.
function time.toDateTime(timestamp: Timestamp, localTime?: boolean): DateTime, string
    local valid, reason = validTimestamp(timestamp)
    if not valid then
        return nil, reason
    end
    local ticks: I64
    local normalizeMinimum = timestamp.seconds == MIN_TIMESTAMP_SECOND
    if normalizeMinimum then
        ticks = (toTicks(timestamp))
    else
        -- SDL's Unix backend divides negative nanoseconds toward zero and can
        -- return 1970-01-01 with a negative nanosecond for an instant just
        -- before the epoch. Ask it for the exact whole second and retain the
        -- already-normalized fractional part ourselves.
        ticks = i64(timestamp.seconds) * billion
    end
    local out = loader.newArray("SDL_DateTime[1]")
    if not C.SDL_TimeToDateTime(ticks, out, localTime == true) then
        return nil, sdl.error()
    end
    local value = out[0] as loader.CStruct
    local year = tonumber(value.year) as integer
    local month = tonumber(value.month) as integer
    local day = tonumber(value.day) as integer
    local hour = tonumber(value.hour) as integer
    local minute = tonumber(value.minute) as integer
    local second = tonumber(value.second) as integer
    local dayOfWeek = tonumber(value.day_of_week) as integer
    if normalizeMinimum and tonumber(value.nanosecond) < 0 then
        second = second - 1
        if second < 0 then
            second = 59
            minute = minute - 1
            if minute < 0 then
                minute = 59
                hour = hour - 1
                if hour < 0 then
                    hour = 23
                    day = day - 1
                    dayOfWeek = (dayOfWeek + 6) % 7
                    if day < 1 then
                        month = month - 1
                        if month < 1 then
                            month = 12
                            year = year - 1
                        end
                        day = tonumber(C.SDL_GetDaysInMonth(year, month)) as integer
                    end
                end
            end
        end
    end
    return {
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        nanosecond = timestamp.nanosecond,
        dayOfWeek = dayOfWeek,
        utcOffset = tonumber(value.utc_offset) as integer,
    }, nil
end

--- Converts calendar fields to an exact Unix timestamp.
---
--- `utcOffset` defaults to zero. `hour`, `minute`, `second`, and `nanosecond`
--- also default to zero. SDL ignores `dayOfWeek`.
---
--- @param dateTime The caller supplies a valid Gregorian calendar date and
---     seconds east of UTC.
--- @return A normalized timestamp on success, or nil for invalid fields or a
---     date outside SDL's range.
--- @return The SDL error when no timestamp is returned.
function time.fromDateTime(dateTime: DateTime): Timestamp, string
    if dateTime == nil then
        return nil, "date time is required"
    end
    local value = loader.newArray("SDL_DateTime[1]")
    local out = loader.newArray("SDL_Time[1]")
    local fields = value[0] as loader.CStruct
    fields.year = dateTime.year
    fields.month = dateTime.month
    fields.day = dateTime.day
    fields.hour = dateTime.hour or 0
    fields.minute = dateTime.minute or 0
    fields.second = dateTime.second or 0
    fields.nanosecond = dateTime.nanosecond or 0
    fields.utc_offset = dateTime.utcOffset or 0
    if not C.SDL_DateTimeToTime(value, out) then
        return nil, sdl.error()
    end
    return fromTicks(out[0] as loader.CValue), nil
end

--- Converts an exact Unix timestamp to a Windows FILETIME.
---
--- FILETIME counts 100-nanosecond intervals since 1601, so this conversion
--- discards the last two decimal digits of `nanosecond`.
---
--- @param timestamp The caller supplies a normalized timestamp in SDL's
---     representable range.
--- @return The exact high and low FILETIME words, or nil for an invalid
---     timestamp.
--- @return The validation error when no words are returned.
function time.toWindowsTime(timestamp: Timestamp): WindowsTime, string
    local ticks, reason = toTicks(timestamp)
    if ticks == nil then
        return nil, reason
    end
    local low = loader.newArray("uint32_t[1]")
    local high = loader.newArray("uint32_t[1]")
    C.SDL_TimeToWindows(ticks, low, high)
    return {
        low = tonumber(low[0]) as integer,
        high = tonumber(high[0]) as integer,
    }, nil
end

--- Converts a Windows FILETIME to an exact Unix timestamp.
---
--- SDL clamps a FILETIME outside its roughly 1677 through 2262 range. The
--- resulting nanoseconds are a multiple of 100.
---
--- @param windowsTime The caller supplies exact unsigned 32-bit words.
--- @return A normalized timestamp.
function time.fromWindowsTime(windowsTime: WindowsTime): Timestamp
    if windowsTime == nil then
        error("tecs: Windows time is required", 2)
    end
    local low = validUnsigned(windowsTime.low, MAX_U32, "Windows time low word", 3)
    local high = validUnsigned(windowsTime.high, MAX_U32, "Windows time high word", 3)
    return fromTicks(C.SDL_TimeFromWindows(low, high))
end

--- Reads the current locale's preferred date order and clock layout.
---
--- The platform query may be slow and preferences may change outside the
--- process. A caller that needs the result frequently should cache it and
--- refresh deliberately.
---
--- @return A fresh preference record on success, or nil on failure.
--- @return The SDL error when preferences are unavailable.
function time.localePreferences(): LocalePreferences, string
    local dateFormat = loader.newArray("SDL_DateFormat[1]")
    local timeFormat = loader.newArray("SDL_TimeFormat[1]")
    if not C.SDL_GetDateTimeLocalePreferences(dateFormat, timeFormat) then
        return nil, sdl.error()
    end
    return {
        dateFormat = DATE_FORMATS[tonumber(dateFormat[0]) as integer],
        timeFormat = TIME_FORMATS[tonumber(timeFormat[0]) as integer],
    }, nil
end

--- Returns the number of days in a calendar month.
---
--- @param year The caller supplies the year whose leap status controls
---     February.
--- @param month The caller supplies a month from 1 through 12.
--- @return The number of days on success, or nil for an invalid month.
--- @return The SDL error when no count is returned.
function time.daysInMonth(year: integer, month: integer): integer, string
    local days = tonumber(C.SDL_GetDaysInMonth(year, month)) as integer
    if days < 0 then
        return nil, sdl.error()
    end
    return days, nil
end

--- Returns the zero-based day within a calendar year.
---
--- @param year The caller supplies the calendar year.
--- @param month The caller supplies a month from 1 through 12.
--- @param day The caller supplies a valid day within that month.
--- @return A value from 0 through 365 on success, or nil for an invalid date.
--- @return The SDL error when no value is returned.
function time.dayOfYear(year: integer, month: integer, day: integer): integer, string
    local index = tonumber(C.SDL_GetDayOfYear(year, month, day)) as integer
    if index < 0 then
        return nil, sdl.error()
    end
    return index, nil
end

--- Returns the weekday of a calendar date.
---
--- @param year The caller supplies the calendar year.
--- @param month The caller supplies a month from 1 through 12.
--- @param day The caller supplies a valid day within that month.
--- @return A value from 0 through 6, with Sunday at zero, or nil for an
---     invalid date.
--- @return The SDL error when no value is returned.
function time.dayOfWeek(year: integer, month: integer, day: integer): integer, string
    local index = tonumber(C.SDL_GetDayOfWeek(year, month, day)) as integer
    if index < 0 then
        return nil, sdl.error()
    end
    return index, nil
end

--- Converts whole seconds to nanoseconds.
---
--- @param seconds The caller supplies a nonnegative integer no larger than
---     9007199 so the integer result remains exact.
--- @return The same duration in nanoseconds.
function time.secondsToNanoseconds(seconds: integer): number
    return validUnsigned(
        seconds, floor(MAX_SAFE_INTEGER / time.nanosecondsPerSecond), "seconds", 3
    ) * time.nanosecondsPerSecond
end

--- Converts nanoseconds to seconds.
---
--- @param nanoseconds The caller supplies any numeric duration.
--- @return The duration divided by one billion.
function time.nanosecondsToSeconds(nanoseconds: number): number
    return nanoseconds / time.nanosecondsPerSecond
end

--- Converts whole milliseconds to nanoseconds.
---
--- @param milliseconds The caller supplies a nonnegative integer no larger
---     than 9007199254 so the integer result remains exact.
--- @return The same duration in nanoseconds.
function time.millisecondsToNanoseconds(milliseconds: integer): number
    return validUnsigned(
        milliseconds, floor(MAX_SAFE_INTEGER / time.nanosecondsPerMillisecond), "milliseconds", 3
    ) * time.nanosecondsPerMillisecond
end

--- Converts nanoseconds to milliseconds.
---
--- @param nanoseconds The caller supplies any numeric duration.
--- @return The duration divided by one million.
function time.nanosecondsToMilliseconds(nanoseconds: number): number
    return nanoseconds / time.nanosecondsPerMillisecond
end

--- Converts whole microseconds to nanoseconds.
---
--- @param microseconds The caller supplies a nonnegative integer no larger
---     than 9007199254740 so the integer result remains exact.
--- @return The same duration in nanoseconds.
function time.microsecondsToNanoseconds(microseconds: integer): number
    return validUnsigned(
        microseconds, floor(MAX_SAFE_INTEGER / time.nanosecondsPerMicrosecond), "microseconds", 3
    ) * time.nanosecondsPerMicrosecond
end

--- Converts nanoseconds to microseconds.
---
--- @param nanoseconds The caller supplies any numeric duration.
--- @return The duration divided by one thousand.
function time.nanosecondsToMicroseconds(nanoseconds: number): number
    return nanoseconds / time.nanosecondsPerMicrosecond
end

--- Blocks the calling thread for at least a number of milliseconds.
---
--- OS scheduling may make the delay longer. Do not call this from a frame.
---
--- @param milliseconds The caller supplies a nonnegative integer through
---     4294967295.
function time.delay(milliseconds: integer)
    C.SDL_Delay(validUnsigned(milliseconds, MAX_U32, "delay milliseconds", 3))
end

--- Blocks the calling thread for at least a number of nanoseconds.
---
--- OS scheduling may make the delay longer. Do not call this from a frame.
---
--- @param nanoseconds The caller supplies a nonnegative safe integer.
function time.delayNanoseconds(nanoseconds: number)
    C.SDL_DelayNS(validUnsigned(nanoseconds, MAX_SAFE_INTEGER, "delay nanoseconds", 3))
end

--- Blocks while approaching a nanosecond delay as closely as possible.
---
--- SDL may busy wait, and OS scheduling may still make the delay longer. Do
--- not call this from a frame.
---
--- @param nanoseconds The caller supplies a nonnegative safe integer.
function time.delayPrecise(nanoseconds: number)
    C.SDL_DelayPrecise(validUnsigned(nanoseconds, MAX_SAFE_INTEGER, "precise delay nanoseconds", 3))
end

--- Resets the baseline so the next `step` measures from now. Called after
--- startup so the first frame's dt excludes load time.
function time.reset()
    last = time.now()
end

--- Advances one frame and returns the dt the world should receive.
---
--- Clamps to `maxDelta`, then offers the value to `provider`.
---
--- @return The elapsed simulation time for this frame, in seconds.
function time.step(): number
    local now = time.now()
    if last == 0.0 then
        last = now
    end
    local dt = now - last
    last = now

    if dt > time.maxDelta then
        dt = time.maxDelta
    end

    local p = time.provider
    if p ~= nil then
        local override = p(dt)
        if override ~= nil then
            return override
        end
    end
    return dt
end

return time

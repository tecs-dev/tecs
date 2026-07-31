local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local time = require("tecs.platform.time")

describe("platform.time", function()
    it("keeps the monotonic readings ordered and their units consistent", function()
        local ticksMs = time.ticksMilliseconds()
        local ticksNs = time.ticksNanoseconds()
        local counter = time.performanceCounter()
        local frequency = time.performanceFrequency()
        local now = time.now()

        assert.is_true(ticksMs >= 0)
        assert.is_true(ticksNs >= ticksMs * time.nanosecondsPerMillisecond)
        assert.is_true(counter >= 0)
        assert.is_true(frequency > 0)
        assert.is_true(now > 0)

        local later = time.now()
        assert.is_true(later >= now)
    end)

    it("reports exact unit constants and conversions", function()
        assert.are.equal(1000, time.millisecondsPerSecond)
        assert.are.equal(1000000, time.microsecondsPerSecond)
        assert.are.equal(1000000000, time.nanosecondsPerSecond)
        assert.are.equal(1000000, time.nanosecondsPerMillisecond)
        assert.are.equal(1000, time.nanosecondsPerMicrosecond)

        assert.are.equal(2000000000, time.secondsToNanoseconds(2))
        assert.are.equal(2, time.nanosecondsToSeconds(2000000000))
        assert.are.equal(3000000, time.millisecondsToNanoseconds(3))
        assert.are.equal(3, time.nanosecondsToMilliseconds(3000000))
        assert.are.equal(4000, time.microsecondsToNanoseconds(4))
        assert.are.equal(4, time.nanosecondsToMicroseconds(4000))
    end)

    it("rejects durations that cannot cross the SDL boundary exactly", function()
        assert.has_error(function()
            time.delay(-1)
        end, "tecs: delay milliseconds must be an integer from 0 through 4294967295")
        assert.has_error(function()
            time.delayNanoseconds(0.5)
        end, "tecs: delay nanoseconds must be an integer from 0 through 9007199254740991")
        assert.has_error(function()
            time.secondsToNanoseconds(9007200)
        end, "tecs: seconds must be an integer from 0 through 9007199")
    end)

    it("blocks for the requested duration", function()
        local started = time.now()
        time.delay(2)
        assert.is_true(time.now() - started >= 0.002)

        time.delayNanoseconds(0)
        time.delayPrecise(0)
    end)

    it("round-trips the Unix epoch and its preceding nanosecond", function()
        local epoch, err = time.toDateTime({ seconds = 0, nanosecond = 0 })
        assert.is_nil(err)
        assert.same({
            year = 1970,
            month = 1,
            day = 1,
            hour = 0,
            minute = 0,
            second = 0,
            nanosecond = 0,
            dayOfWeek = 4,
            utcOffset = 0,
        }, epoch)

        local before, beforeErr = time.toDateTime({ seconds = -1, nanosecond = 999999999 })
        assert.is_nil(beforeErr)
        assert.same({
            year = 1969,
            month = 12,
            day = 31,
            hour = 23,
            minute = 59,
            second = 59,
            nanosecond = 999999999,
            dayOfWeek = 3,
            utcOffset = 0,
        }, before)

        local stamp, stampErr = time.fromDateTime(before)
        assert.is_nil(stampErr)
        assert.same({ seconds = -1, nanosecond = 999999999 }, stamp)
    end)

    it("uses the supplied UTC offset when converting calendar fields", function()
        local stamp, err = time.fromDateTime({
            year = 2024,
            month = 2,
            day = 29,
            hour = 12,
            minute = 34,
            second = 56,
            nanosecond = 123456789,
            utcOffset = 3600,
        })
        assert.is_nil(err)

        local utc, utcErr = time.toDateTime(stamp)
        assert.is_nil(utcErr)
        assert.same({
            year = 2024,
            month = 2,
            day = 29,
            hour = 11,
            minute = 34,
            second = 56,
            nanosecond = 123456789,
            dayOfWeek = 4,
            utcOffset = 0,
        }, utc)
    end)

    it("reports invalid calendar fields instead of normalizing them", function()
        local stamp, err = time.fromDateTime({
            year = 2023,
            month = 2,
            day = 29,
        })
        assert.is_nil(stamp)
        assert.matches("day of month out of range", err)

        local days, daysErr = time.daysInMonth(2024, 13)
        assert.is_nil(days)
        assert.matches("Month out of range", daysErr)

        local day, dayErr = time.dayOfWeek(2024, 2, 30)
        assert.is_nil(day)
        assert.matches("Day out of range", dayErr)
    end)

    it("reports leap years and zero-based calendar indexes", function()
        assert.are.equal(29, time.daysInMonth(2024, 2))
        assert.are.equal(28, time.daysInMonth(2100, 2))
        assert.are.equal(59, time.dayOfYear(2024, 2, 29))
        assert.are.equal(4, time.dayOfWeek(2024, 2, 29))
    end)

    it("round-trips Windows FILETIME words at their 100-nanosecond precision", function()
        local windows, err = time.toWindowsTime({ seconds = 0, nanosecond = 99 })
        assert.is_nil(err)
        assert.same({
            low = 3577643008,
            high = 27111902,
        }, windows)

        assert.same({
            seconds = 0,
            nanosecond = 0,
        }, time.fromWindowsTime(windows))
    end)

    it("validates exact timestamps before passing them to SDL", function()
        local dateTime, err = time.toDateTime({ seconds = 0, nanosecond = 1000000000 })
        assert.is_nil(dateTime)
        assert.matches("nanosecond", err)

        dateTime, err = time.toDateTime({
            seconds = 9223372036,
            nanosecond = 854775808,
        })
        assert.is_nil(dateTime)
        assert.matches("outside the range", err)
    end)

    it("converts both exact ends of SDL's signed timestamp range", function()
        local earliest, earliestErr = time.toDateTime({
            seconds = -9223372037,
            nanosecond = 145224192,
        })
        assert.is_nil(earliestErr)
        assert.same({
            year = 1677,
            month = 9,
            day = 21,
            hour = 0,
            minute = 12,
            second = 43,
            nanosecond = 145224192,
            dayOfWeek = 2,
            utcOffset = 0,
        }, earliest)

        local latest, latestErr = time.toDateTime({
            seconds = 9223372036,
            nanosecond = 854775807,
        })
        assert.is_nil(latestErr)
        assert.same({
            year = 2262,
            month = 4,
            day = 11,
            hour = 23,
            minute = 47,
            second = 16,
            nanosecond = 854775807,
            dayOfWeek = 5,
            utcOffset = 0,
        }, latest)
    end)

    it("reads wall time and locale preferences", function()
        local stamp, err = time.wallNow()
        assert.is_nil(err)
        assert.is_number(stamp.seconds)
        assert.is_true(stamp.nanosecond >= 0)
        assert.is_true(stamp.nanosecond < time.nanosecondsPerSecond)

        local preferences, preferencesErr = time.localePreferences()
        assert.is_nil(preferencesErr)
        assert.is_true(
            preferences.dateFormat == "yearMonthDay"
                or preferences.dateFormat == "dayMonthYear"
                or preferences.dateFormat == "monthDayYear"
        )
        assert.is_true(preferences.timeFormat == "twentyFourHour" or preferences.timeFormat == "twelveHour")
    end)
end)

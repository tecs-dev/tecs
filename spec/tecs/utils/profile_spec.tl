local profile <const> = require("tecs.utils.profile")

local zone = (function(name: string): any return require(name) end)("jit.zone") as any
local IS_WINDOWS <const> = package.config:sub(1, 1) == "\\"

if not IS_WINDOWS then
describe("profile.sample", function()

    describe("session lifecycle", function()

        it("returns a handle whose :stop() yields collapsed-stack text", function()
            local s = profile.sample()
            zone("hot")
            zone()
            local out = s:stop()
            assert.is_string(out)
        end)

        it("starting a second session while one is active errors", function()
            local s = profile.sample()
            assert.has_error(function() profile.sample() end)
            s:stop()
        end)

        it("session can be restarted after :stop()", function()
            local s1 = profile.sample()
            s1:stop()
            local s2 = profile.sample()
            assert.is_table(s2)
            s2:stop()
        end)

        it("calling :stop() twice errors", function()
            local s = profile.sample()
            s:stop()
            assert.has_error(function() s:stop() end)
        end)

        it(":pause() and :resume() are idempotent and allow :stop() afterwards", function()
            local s = profile.sample()
            s:pause()
            s:pause()
            s:resume()
            s:resume()
            s:stop()
        end)

        it(":pause() after :stop() errors", function()
            local s = profile.sample()
            s:stop()
            assert.has_error(function() s:pause() end)
            assert.has_error(function() s:resume() end)
        end)
    end)

    describe("zone wiring", function()

        it("zones are no-ops outside a session", function()
            zone("ignored")
            assert.equals(0, #zone)
            zone()
        end)

        it("zones are live during a session and drained after stop", function()
            local s = profile.sample()
            zone("live")
            assert.equals(1, #zone)
            assert.equals("live", zone[1])
            zone()
            assert.equals(0, #zone)
            s:stop()

            zone("post")
            assert.equals(0, #zone)
            zone()
        end)

        it("a no-op push followed by a real-stack pop does not crash", function()
            -- Models MCP starting a session inside a system: a push happened
            -- before the session enabled zones, so the matching pop sees an
            -- empty stack. Must not error.
            zone("noopPush")
            local s = profile.sample()
            assert.has_no.errors(function() zone() end)
            s:stop()
        end)

        it(":stop() drains outstanding pushes so the next session is clean", function()
            local s1 = profile.sample()
            zone("outer")
            zone("inner")
            assert.equals(2, #zone)
            s1:stop()
            assert.equals(0, #zone)

            local s2 = profile.sample()
            assert.equals(0, #zone)
            zone("fresh")
            assert.equals(1, #zone)
            assert.equals("fresh", zone[1])
            zone()
            s2:stop()
        end)
    end)

    describe("filename arg", function()

        it(":stop(filename) writes the collapsed text to disk and returns it", function()
            local path = os.tmpname()
            local s = profile.sample()
            zone("hot")
            zone()
            local ret = s:stop(path)
            assert.is_string(ret)
            local f = assert(io.open(path, "r"))
            local contents = f:read("*a")
            f:close()
            os.remove(path)
            assert.equals(ret, contents)
        end)

        it(":stop(filename) errors when the path is not writable", function()
            local s = profile.sample()
            assert.has_error(function() s:stop("/this/path/does/not/exist/foo.collapsed") end)
            -- session is now in a stopped+errored state; no need to clean up
        end)
    end)

    describe("zone filter", function()

        it("zone prefix passed at start filters the output", function()
            local s = profile.sample({zone = "zoneA"})
            zone("zoneA")
            local sum = 0
            for i = 1, 1000000 do sum = sum + math.sqrt(i) end
            zone()
            zone("zoneB")
            for i = 1, 1000000 do sum = sum + math.sqrt(i) end
            zone()
            local out = s:stop()
            -- Filter is best-effort: when no samples land in zoneB, the
            -- assertion is vacuously true. When they do, zoneB must be excluded.
            assert.is_nil(out:find("zoneB", 1, true))
        end)
    end)
end)
end

describe("profile.trace", function()

    describe("session lifecycle", function()

        it("returns a handle whose :stop() yields a TraceReport", function()
            local s = profile.trace()
            local report = s:stop()
            assert.is_table(report)
            assert.is_number(report.durationSec)
            assert.is_number(report.totalAborts)
            assert.is_number(report.blacklisted)
            assert.is_table(report.sites)
        end)

        it("starting a second trace session while one is active errors", function()
            local s = profile.trace()
            assert.has_error(function() profile.trace() end)
            s:stop()
        end)

        it("calling :stop() twice errors", function()
            local s = profile.trace()
            s:stop()
            assert.has_error(function() s:stop() end)
        end)

        it(":pause() and :resume() are idempotent and allow :stop() afterwards", function()
            local s = profile.trace()
            s:pause()
            s:pause()
            s:resume()
            s:resume()
            s:stop()
        end)

        it(":pause() after :stop() errors", function()
            local s = profile.trace()
            s:stop()
            assert.has_error(function() s:pause() end)
            assert.has_error(function() s:resume() end)
        end)

        if not IS_WINDOWS then
            it("can run alongside a sample session (independent channels)", function()
                local sampleSess = profile.sample()
                local traceSess = profile.trace()
                zone("both")
                zone()
                local report = traceSess:stop()
                local text = sampleSess:stop()
                assert.is_table(report)
                assert.is_string(text)
            end)
        end
    end)

    describe("report formatting", function()

        it("TraceReport renders as CSV via __tostring", function()
            local s = profile.trace()
            local report = s:stop()
            local rendered = tostring(report)
            assert.is_string(rendered)
            -- First line is the CSV header.
            local headerEnd = rendered:find("\n", 1, true) or #rendered + 1
            local header = rendered:sub(1, headerEnd - 1)
            assert.equals("severity,count,reason,location,zone", header)
        end)
    end)

    describe("filename arg", function()

        it(":stop(filename) writes the CSV report to disk and returns the report", function()
            local path = os.tmpname()
            local s = profile.trace()
            local report = s:stop(path)
            assert.is_table(report)
            assert.is_number(report.totalAborts)
            local f = assert(io.open(path, "r"))
            local contents = f:read("*a")
            f:close()
            os.remove(path)
            assert.equals(tostring(report), contents)
        end)

        it(":stop(filename) errors when the path is not writable", function()
            local s = profile.trace()
            assert.has_error(function() s:stop("/this/path/does/not/exist/foo.txt") end)
        end)
    end)
end)

if not IS_WINDOWS then
describe("profile zone refcounting", function()

    it("zones stay enabled while either session is live", function()
        local sampleSess = profile.sample()
        local traceSess = profile.trace()
        zone("attributed")
        assert.equals(1, #zone)
        zone()

        traceSess:stop()
        -- Sample session still keeps zones live.
        zone("stillLive")
        assert.equals(1, #zone)
        zone()

        sampleSess:stop()
        -- Both stopped: zones revert to no-op.
        zone("ignored")
        assert.equals(0, #zone)
        zone()
    end)
end)
end

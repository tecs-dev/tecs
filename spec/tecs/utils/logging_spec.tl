require("busted")
local logging <const> = require("tecs.utils.logging")
local luassert <const> = require("luassert")
local spy <const> = require("luassert.spy")

-- Capture original state so we can restore after each test.
local originalLevel <const> = logging.level
local originalSink <const> = logging.sink

describe("Logging module", function()

    local mockFile: FILE
    local writeSpy: any

    before_each(function()
        writeSpy = spy.new(function() end)
        mockFile = {
            write = writeSpy,
        } as FILE
        logging.setSink(mockFile)
        logging.setLevel("DEBUG")
    end)

    after_each(function()
        logging.sink = originalSink
        logging.level = originalLevel
    end)

    describe("getLogger", function()
        it("returns a logger with debug, info, warn, and error methods", function()
            local logger = logging.getLogger("test")
            luassert.is_function(logger.debug)
            luassert.is_function(logger.info)
            luassert.is_function(logger.warn)
            luassert.is_function(logger.error)
        end)

        it("returns the same instance for the same name", function()
            local a = logging.getLogger("cached")
            local b = logging.getLogger("cached")
            luassert.is_equal(a, b)
        end)

        it("returns different instances for different names", function()
            local a = logging.getLogger("one")
            local b = logging.getLogger("two")
            luassert.is_not_equal(a, b)
        end)
    end)

    describe("log output", function()
        it("writes info messages to the sink", function()
            local logger = logging.getLogger("output-info")
            logger:info("hello %s", "world")
            luassert.spy(writeSpy).was_called()
        end)

        it("formats messages with string.format specifiers", function()
            local logger = logging.getLogger("output-fmt")
            logger:info("count: %d, name: %s", 42, "test")

            -- The third arg to file:write is the prefix, fourth is the formatted message.
            local calls = writeSpy.calls
            local lastCall = calls[#calls]
            -- file:write(date, prefix, formatted, "\n")
            -- Find the formatted message in the write args.
            local found = false
            for _, arg in ipairs(lastCall.vals) do
                if type(arg) == "string" and string.find(arg, "count: 42, name: test") then
                    found = true
                    break
                end
            end
            luassert.is_true(found, "formatted message should appear in write output")
        end)

        it("includes the logger name in output", function()
            local logger = logging.getLogger("output-name")
            logger:info("test")

            local calls = writeSpy.calls
            local lastCall = calls[#calls]
            local found = false
            for _, arg in ipairs(lastCall.vals) do
                if type(arg) == "string" and string.find(arg, "output%-name") then
                    found = true
                    break
                end
            end
            luassert.is_true(found, "logger name should appear in write output")
        end)

        it("includes the level name in output", function()
            local logger = logging.getLogger("output-level")
            logger:warn("test")

            local calls = writeSpy.calls
            local lastCall = calls[#calls]
            local found = false
            for _, arg in ipairs(lastCall.vals) do
                if type(arg) == "string" and string.find(arg, "WARN") then
                    found = true
                    break
                end
            end
            luassert.is_true(found, "level name should appear in write output")
        end)

        it("calls tostring on non-string values via %%s", function()
            local logger = logging.getLogger("output-tostring")
            local t = {}
            logger:info("val: %s", t)

            local calls = writeSpy.calls
            local lastCall = calls[#calls]
            local found = false
            for _, arg in ipairs(lastCall.vals) do
                if type(arg) == "string" and string.find(arg, "val: table:") then
                    found = true
                    break
                end
            end
            luassert.is_true(found, "tostring should be called for %%s with a table")
        end)

        it("writes a newline at the end", function()
            local logger = logging.getLogger("output-newline")
            logger:info("test")

            local calls = writeSpy.calls
            local lastCall = calls[#calls]
            local lastArg = lastCall.vals[#lastCall.vals]
            luassert.is_equal("\n", lastArg)
        end)
    end)

    describe("log levels", function()
        it("DEBUG enables all levels", function()
            logging.setLevel("DEBUG")
            local logger = logging.getLogger("level-debug")
            logger:debug("d")
            logger:info("i")
            logger:warn("w")
            logger:error("e")
            luassert.spy(writeSpy).was_called(4)
        end)

        it("INFO disables debug", function()
            logging.setLevel("INFO")
            local logger = logging.getLogger("level-info")
            logger:debug("d")
            luassert.spy(writeSpy).was_called(0)
            logger:info("i")
            luassert.spy(writeSpy).was_called(1)
            logger:warn("w")
            luassert.spy(writeSpy).was_called(2)
            logger:error("e")
            luassert.spy(writeSpy).was_called(3)
        end)

        it("WARN disables debug and info", function()
            logging.setLevel("WARN")
            local logger = logging.getLogger("level-warn")
            logger:debug("d")
            logger:info("i")
            luassert.spy(writeSpy).was_called(0)
            logger:warn("w")
            luassert.spy(writeSpy).was_called(1)
            logger:error("e")
            luassert.spy(writeSpy).was_called(2)
        end)

        it("ERROR disables debug, info, and warn", function()
            logging.setLevel("ERROR")
            local logger = logging.getLogger("level-error")
            logger:debug("d")
            logger:info("i")
            logger:warn("w")
            luassert.spy(writeSpy).was_called(0)
            logger:error("e")
            luassert.spy(writeSpy).was_called(1)
        end)

        it("OFF disables all levels", function()
            logging.setLevel("OFF")
            local logger = logging.getLogger("level-off")
            logger:debug("d")
            logger:info("i")
            logger:warn("w")
            logger:error("e")
            luassert.spy(writeSpy).was_called(0)
        end)
    end)

    describe("setLevel", function()
        it("re-stamps existing loggers", function()
            logging.setLevel("INFO")
            local logger = logging.getLogger("restamp-level")

            -- info should work
            logger:info("before")
            luassert.spy(writeSpy).was_called(1)

            -- change to OFF, same logger reference should now be a no-op
            logging.setLevel("OFF")
            logger:info("after")
            luassert.spy(writeSpy).was_called(1)

            -- change back to DEBUG, debug should now work
            logging.setLevel("DEBUG")
            logger:debug("restored")
            luassert.spy(writeSpy).was_called(2)
        end)
    end)

    describe("setSink", function()
        it("re-stamps existing loggers to write to the new sink", function()
            local logger = logging.getLogger("restamp-sink")
            logger:info("to mock")
            luassert.spy(writeSpy).was_called(1)

            local writeSpy2 = spy.new(function() end)
            local mockFile2 = { write = writeSpy2 } as FILE
            logging.setSink(mockFile2)

            logger:info("to mock2")
            luassert.spy(writeSpy).was_called(1)
            luassert.spy(writeSpy2).was_called(1)
        end)
    end)

    describe("defaults", function()
        it("defaults to INFO level", function()
            luassert.is_equal("INFO", originalLevel)
        end)

        it("defaults to io.stderr as sink", function()
            luassert.is_equal(io.stderr, originalSink)
        end)
    end)
end)

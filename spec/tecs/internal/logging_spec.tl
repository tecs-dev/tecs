require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local spy <const> = require("luassert.spy")
local TestHelpers <const> = require("spec.tecs.test_helpers")

describe("Logging module", function()

    describe("Constants and exports", function()
        it("has correct level constants", function()
            luassert.is_equal(1, tecs.logging.DEBUG, "DEBUG level should be 1")
            luassert.is_equal(2, tecs.logging.INFO, "INFO level should be 2")
            luassert.is_equal(3, tecs.logging.WARN, "WARN level should be 3")
            luassert.is_equal(4, tecs.logging.ERROR, "ERROR level should be 4")
        end)

        it("exports a root logger", function()
            luassert.is_not_nil(tecs.logging.rootLogger, "rootLogger should be exported")
            luassert.is_equal("-", tecs.logging.rootLogger:getName(), "rootLogger should have the name '-'")
        end)

        it("exports the DEFAULT_FORMATTER", function()
            luassert.is_function(tecs.logging.DEFAULT_FORMATTER, "DEFAULT_FORMATTER should be a function")
        end)
    end)

    describe("LogSink implementations", function()
        local mockFile: FILE

        before_each(function()
            mockFile = {
                write = spy.new(function() end),
                flush = spy.new(function() end),
                close = spy.new(function() end)
            } as FILE
        end)

        it("creates a file sink", function()
            local sink = tecs.logging.newFileSink(mockFile)
            luassert.is_not_nil(sink, "newFileSink should return a non-nil value")

            -- Writing INFO does not auto-flush.
            sink:log(tecs.logging.INFO, "test", "Test message")
            luassert.spy(mockFile.write).was_called(1)
            luassert.spy(mockFile.flush).was_called(0)

            -- Writing WARN or ERROR does auto-flush.
            sink:log(tecs.logging.WARN, "test", "Warning message")
            luassert.spy(mockFile.write).was_called(2)
            luassert.spy(mockFile.flush).was_called(1)

            -- Manually flushing the sink.
            sink:flush()
            luassert.spy(mockFile.flush).was_called(2)

            -- Make sure it closes the file.
            sink:close()
            luassert.spy(mockFile.close).was_called(1)
        end)

        it("uses custom formatter with sinks", function()
            local formatterSpy = spy.new(function(): string
                return "CUSTOM FORMAT"
            end)
            local sink = tecs.logging.newFileSink(mockFile, formatterSpy)

            sink:log(tecs.logging.INFO, "test", "Test message")

            -- Make sure it used the formatter. The written text will be the return value of the formatter.
            luassert.spy(formatterSpy).was_called(1)
            luassert.spy(mockFile.write).was_called_with(mockFile, "CUSTOM FORMAT")
        end)

        it("validates file is not nil for file sink", function()
            luassert.has_error(function()
                tecs.logging.newFileSink(nil)
            end, "Invalid log file: file cannot be nil", "Should error when creating file sink with nil file")
        end)
    end)

    describe("Default formatter", function()
        it("formats messages properly", function()
            local result = tecs.logging.DEFAULT_FORMATTER(tecs.logging.INFO, "testLogger", "Test message")

            luassert.is_string(result, "Formatter should return a string")
            luassert.truthy(string.find(result, "%[info%]"), "Output should contain level name")
            luassert.truthy(string.find(result, "%[testLogger%]"), "Output should contain logger name")
            luassert.truthy(string.find(result, "Test message"), "Output should contain message")
        end)

        it("uses variable arguments for message formatting", function()
            local result = tecs.logging.DEFAULT_FORMATTER(tecs.logging.DEBUG, "test", "Value: %d, Name: %s", 42, "test")

            luassert.truthy(string.find(result, "Value: 42, Name: test"), "Output should contain formatted message")
        end)
    end)

    describe("Logger implementation", function()
        local mockSink: tecs.logging.LogSink

        before_each(function()
            mockSink = TestHelpers.createMockSink()
        end)

        it("creates a new logger with getLogger", function()
            local logger = tecs.logging.getLogger("test")
            luassert.is_not_nil(logger, "getLogger should return a non-nil value")
            luassert.is_equal("test", logger:getName(), "Logger should have the requested name")
        end)

        it("handles logging at different levels", function()
            local logger = tecs.logging.getLogger("test-levels")
            logger:setSink(mockSink)
            logger:setLevel(tecs.logging.INFO)

            logger:debug("Debug message")
            luassert.spy(mockSink.log).was_called(0)

            logger:info("Info message")
            luassert.spy(mockSink.log).was_called(1)

            logger:warn("Warning message")
            luassert.spy(mockSink.log).was_called(2)

            logger:error("Error message")
            luassert.spy(mockSink.log).was_called(3)
        end)

        it("validates logging level", function()
            local logger = tecs.logging.getLogger("validate-level")

            luassert.has_error(function()
                logger:setLevel(0)
            end, "Invalid logging level: level must be between DEBUG and ERROR", nil)

            luassert.has_error(function()
                logger:setLevel(5)
            end, "Invalid logging level: level must be between DEBUG and ERROR", nil)
        end)

        it("validates sink is not nil", function()
            local logger = tecs.logging.getLogger("validate-sink")

            luassert.has_error(function()
                logger:setSink(nil)
            end, "Invalid log sink: sink cannot be nil", "Should error when setting nil sink")
        end)
    end)

    describe("Logger hierarchy", function()
        local parentSink: tecs.logging.LogSink = nil
        local childSink: tecs.logging.LogSink = nil

        before_each(function()
            parentSink = {
                log = spy.new(function() end),
                flush = spy.new(function() end),
                close = spy.new(function() end)
            }

            childSink = {
                log = spy.new(function() end),
                flush = spy.new(function() end),
                close = spy.new(function() end)
            }
        end)

        it("creates parent-child relationships", function()
            local parent = tecs.logging.getLogger("parent")
            parent:setSink(parentSink)

            local child = parent:getChild("child")
            luassert.is_not_nil(child, "getChild should return a non-nil value")
            luassert.is_equal("parent.child", child:getName(), "Child logger should have fully qualified name")
        end)

        it("inherits level from parent", function()
            local parent = tecs.logging.getLogger("level-parent")
            parent:setLevel(tecs.logging.WARN)
            parent:setSink(parentSink)

            local child = parent:getChild("level-child")

            -- Child inherits parent's level
            luassert.is_equal(tecs.logging.WARN, child:getLevel(), "Child should inherit parent's level")

            -- Child logs only at warning level and above
            child:info("Info message")
            luassert.spy(parentSink.log).was_called(0)

            child:warn("Warning message")
            luassert.spy(parentSink.log).was_called(1)
        end)

        it("inherits sink from parent", function()
            local parent = tecs.logging.getLogger("sink-parent")
            parent:setSink(parentSink)

            local child = parent:getChild("sink-child")

            child:info("Info message")
            luassert.spy(parentSink.log).was_called(1)
        end)

        it("can override parent's level", function()
            local parent = tecs.logging.getLogger("override-parent")
            parent:setLevel(tecs.logging.ERROR)
            parent:setSink(parentSink)

            local child = parent:getChild("override-child")
            child:setLevel(tecs.logging.DEBUG)

            -- Child now has its own level
            luassert.is_equal(tecs.logging.DEBUG, child:getLevel(), "Child should use its own level when set")
            -- Parent still has its level
            luassert.is_equal(tecs.logging.ERROR, parent:getLevel(), "Parent should retain its level")

            child:debug("Debug message")
            luassert.spy(parentSink.log).was_called(1)
        end)

        it("can override parent's sink", function()
            local parent = tecs.logging.getLogger("override-sink-parent")
            parent:setLevel(tecs.logging.INFO)
            parent:setSink(parentSink)

            local child = parent:getChild("override-sink-child")
            child:setSink(childSink)

            child:info("Info message")
            luassert.spy(parentSink.log).was_called(0)
            luassert.spy(childSink.log).was_called(1)
        end)

        it("maintains logger identity", function()
            local parent = tecs.logging.getLogger("identity-parent")

            local child1 = parent:getChild("same-child")
            local child2 = parent:getChild("same-child")

            luassert.is_equal(child1, child2, "Multiple calls to getChild with same name should return same instance")
        end)
    end)

    describe("Root logger", function()
        it("is created with default level", function()
            luassert.is_not_nil(tecs.logging.rootLogger, "rootLogger should exist")
            luassert.is_equal(tecs.logging.INFO, tecs.logging.rootLogger:getLevel(), "rootLogger should have INFO level by default")
        end)

        it("creates child loggers", function()
            local child = tecs.logging.getLogger("root-child")

            luassert.is_not_nil(child, "getLogger should return a non-nil value")
            luassert.is_equal("root-child", child:getName(), "Logger should have the requested name")
        end)

        it("returns the same logger for the same name", function()
            local logger1 = tecs.logging.getLogger("singleton-test")
            local logger2 = tecs.logging.getLogger("singleton-test")

            luassert.is_equal(logger1, logger2, "Multiple calls to getLogger with same name should return same instance")
        end)
    end)

    describe("Flush and close behavior", function()
        local mockSink: tecs.logging.LogSink = nil

        before_each(function()
            mockSink = TestHelpers.createMockSink()
        end)

        it("flushes the sink", function()
            local logger = tecs.logging.getLogger("flush-test")
            logger:setSink(mockSink)

            logger:flush()
            luassert.spy(mockSink.flush).was_called(1)
        end)

        it("closes the sink", function()
            local logger = tecs.logging.getLogger("close-test")
            logger:setSink(mockSink)

            logger:close()
            luassert.spy(mockSink.close).was_called(1)
        end)

        it("safely handles flush without sink", function()
            local logger = tecs.logging.getLogger("no-sink-flush")

            -- Should not error when no sink is explicitly set
            luassert.has_no_errors(function()
                logger:flush()
            end, "flush should not error when sink is not explicitly set", nil)
        end)

        it("safely handles close without sink", function()
            local logger = tecs.logging.getLogger("no-sink-close")

            -- Should not error when no sink is explicitly set
            luassert.has_no_errors(function()
                logger:close()
            end, "close should not error when sink is not explicitly set", nil)
        end)
    end)
end)
-- Checked examples attached to the tecs.io.process reference.

-- #region tecs.io.process.new
tecs.scoped(function(scope: tecs.Scope)
    local child, reason = tecs.io.process.new({
        args = {"git", "rev-parse", "HEAD"},
        timeoutMs = 2000,
    })
    if child == nil then
        error(reason)
    end
    scope:own(child)

    local result, communicateReason = child:communicate()

    assert(result, communicateReason)
    assert(result:succeeded())
    print(result.output)
end)
-- #endregion tecs.io.process.new

-- #region tecs.io.process.Process.communicate
tecs.scoped(function(scope: tecs.Scope)
    local child, reason = tecs.io.process.new({args = {"/bin/cat"}})
    if child == nil then
        error(reason)
    end
    scope:own(child)

    local result, communicateReason = child:communicate({
        input = "request bytes\n",
        maxOutputBytes = 1024 * 1024,
    })

    assert(result, communicateReason)
    assert(result.output == "request bytes\n")
end)
-- #endregion tecs.io.process.Process.communicate

-- #region tecs.io.process.ProcessReader.readAvailable
tecs.scoped(function(scope: tecs.Scope)
    local child, reason = tecs.io.process.new({
        args = {"/bin/sh", "-c", "sleep 1; printf ready"},
    })
    if child == nil then
        error(reason)
    end
    scope:own(child)

    local chunk <const>, readReason = child.stdout:readAvailable()

    assert(chunk == nil)
    assert(readReason == nil)
end)
-- #endregion tecs.io.process.ProcessReader.readAvailable

-- #region tecs.io.process.ProcessReader.readInto
tecs.scoped(function(scope: tecs.Scope)
    local child, reason = tecs.io.process.new({args = {"/bin/echo", "bytes"}})
    if child == nil then
        error(reason)
    end
    scope:own(child)
    local output <const> = scope:own(tecs.io.newBuffer())

    local count <const>, readReason = child.stdout:readInto(output)

    assert(count, readReason)
    assert(output:getString() == "bytes\n")
end)
-- #endregion tecs.io.process.ProcessReader.readInto

-- #region tecs.io.process.ProcessWriter.writeFrom
tecs.scoped(function(scope: tecs.Scope)
    local child, reason = tecs.io.process.new({args = {"/bin/cat"}})
    if child == nil then
        error(reason)
    end
    scope:own(child)
    local input <const> = scope:own(tecs.io.newBuffer("buffer input"))

    local written <const>, writeReason = child.stdin:writeFrom(input)
    child.stdin:close()
    local output <const>, readReason = child.stdout:read(1024)

    assert(written == input:length(), writeReason)
    assert(output == "buffer input", readReason)
end)
-- #endregion tecs.io.process.ProcessWriter.writeFrom

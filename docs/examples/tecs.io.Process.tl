-- Checked examples attached to the tecs.io.Process reference.

-- #region tecs.io.Process.new
tecs.scoped(function(scope: tecs.Scope)
    local child <const> = scope:own(tecs.io.Process.new({
        args = {"git", "rev-parse", "HEAD"},
        timeoutMs = 2000,
    }))

    local result, communicateReason = child:communicate()

    assert(result, communicateReason)
    assert(result:succeeded())
    print(result.output)
end)
-- #endregion tecs.io.Process.new

-- #region tecs.io.Process.communicate
tecs.scoped(function(scope: tecs.Scope)
    local child <const> = scope:own(tecs.io.Process.new({args = {"/bin/cat"}}))

    local result, communicateReason = child:communicate({
        input = "request bytes\n",
        maxOutputBytes = 1024 * 1024,
    })

    assert(result, communicateReason)
    assert(result.output == "request bytes\n")
end)
-- #endregion tecs.io.Process.communicate

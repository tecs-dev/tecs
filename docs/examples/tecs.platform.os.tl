-- #region tecs.platform.os.newSignalListener
tecs.scoped(function(scope: tecs.Scope)
    local signals, reason = tecs.platform.os.newSignalListener({"interrupt", "terminate"})
    if signals == nil then
        error(reason)
    end
    scope:own(signals)

    local running = true
    local function update()
        local signal <const> = signals:next()
        if signal ~= nil then
            running = false
        end
    end

    while running do
        update()
    end
end)
-- #endregion tecs.platform.os.newSignalListener

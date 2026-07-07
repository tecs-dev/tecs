function love.conf(t: love.Configuration)
    t.window.title = "Tecs Retro Fixture"
    -- Deliberately NOT an integer multiple of the virtual height (60):
    -- 250 / 60 = 4.1667, so integer scaling uses 4x with letterboxing and
    -- the fractional-vs-integer zoom discrepancy is observable.
    t.window.width = 320
    t.window.height = 250
    t.window.vsync = 0
    t.window.resizable = false
end

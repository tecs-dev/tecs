function love.conf(t: love.Configuration)
    t.window = t.window or {}
    t.window.title = "Tecs Install Example"
    t.window.width = 800
    t.window.height = 400
    t.window.resizable = false
    t.window.vsync = 0
end
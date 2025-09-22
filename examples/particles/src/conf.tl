function love.conf(t: love.Configuration)
    t.identity = "tecs_particles"
    t.console = false

    t.window.title = "Tecs Particles Example"
    t.window.width = 800
    t.window.height = 600
    t.window.borderless = false
    t.window.resizable = true
    t.window.minwidth = 640
    t.window.minheight = 480
    t.window.fullscreen = false
    t.window.fullscreentype = "desktop"
    t.window.vsync = 1
    t.window.msaa = 0
    t.window.displayindex = 1
end

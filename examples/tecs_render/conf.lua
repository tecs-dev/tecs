function love.conf(t)
    t.identity = "tecs_render"
    t.version = "11.4"
    t.console = false

    t.window.title = "Tecs Render"
    t.window.width = 1280
    t.window.height = 720
    t.window.borderless = false
    t.window.resizable = true
    t.window.minwidth = 640
    t.window.minheight = 360
    t.window.fullscreen = false
    t.window.fullscreentype = "desktop"
    t.window.vsync = 0
    t.window.msaa = 0
    t.window.display = 1
end
function love.conf(t: love.Configuration)
    t.identity = "tecs.text-bench"
    t.version = "12.0"
    t.console = false

    t.window.title = "Text Benchmark"
    t.window.width = 1280
    t.window.height = 720
    t.window.borderless = false
    t.window.resizable = true
    t.window.minwidth = 640
    t.window.minheight = 360
    t.window.fullscreen = false
    t.window.fullscreentype = "desktop"
    t.window.vsync = 0
    t.window.msaa = 4
    t.window.displayindex = 1
end

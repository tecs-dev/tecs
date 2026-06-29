function love.conf(t: love.Configuration)
    t.identity = "tecs_sprite_throughput"
    t.window.title = "Tecs Sprite Throughput Benchmark"
    t.window.width = tonumber(os.getenv("BENCH_W")) or 1280
    t.window.height = tonumber(os.getenv("BENCH_H")) or 720
    t.window.resizable = false
    t.window.vsync = false
end

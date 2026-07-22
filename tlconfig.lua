return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "src/" },
    global_env_def = "love2d",
    dont_prune = {
        "test_deps",
        "test_deps/**/*",
        "*.rockspec",
        "*.tl",
        "tecs/tecs",
        "tecs2d/workers/internal/worker",
        "tecs2d/gfx/internal/gpu/shaders",
        "tecs2d/gfx/internal/gpu/shaders/*.glsl",
        "tecs2d/gfx/internal/**/*.glsl",
    },
}

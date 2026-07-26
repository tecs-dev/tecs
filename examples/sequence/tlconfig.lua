return {
    include_dir = { "src", "shared/lib", "shared/types", "shared/tecs_src" },
    source_dir = "src",
    build_dir = "build",
    gen_target = "5.1",
    gen_compat = "off",
    global_env_def = "love2d",
    dont_prune = {
        "tecs", "tecs/*", "tecs/**/*",
        "assets", "assets/*",
        "internal", "internal/*",
        "floor.lua",
    },
}

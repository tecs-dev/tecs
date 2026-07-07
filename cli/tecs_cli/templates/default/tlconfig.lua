return {
    build_dir = "build",
    source_dir = "src",
    include_dir = {
        "types/",
        "src/",
        "src/vendor/share/lua/5.1",
    },
    gen_target = "5.1",
    gen_compat = "off",
    global_env_def = "love2d",
}

return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "types/", "types/luajit", "src/" },
    global_env_def = "love2d",
    disable_warnings = {"redeclaration"},
    scripts = {
        build = {
            post = "cyan-plugins/generate_rockspecs.tl"
        }
    }
}

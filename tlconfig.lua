return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "src/", "vendor/tl/", "vendor/share/lua/5.1/" },
    dont_prune = {
        "tecs/ffi/*cdef.lua",
    },
}

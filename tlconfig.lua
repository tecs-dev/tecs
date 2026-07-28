return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "src/", "vendor/tl/", "vendor/share/lua/5.1/" },
    dont_prune = {
        "tecs/ffi/*cdef.lua",
    },
    cerulean = {
        indent_width = 4,
        max_line_width = 120,
        sort_requires = false,
        hug_first_argument = true,
    },
    tealdoc = {
        markdown = {
            type_links = {
                ["tecs.platform.system"] = "/modules/system#tecs.system",
                ["tecs.Future"] = "/modules/future#tecs.future.Future",
                ["tecs.platform.Window"] = "/modules/window#tecs.window.Window",
            },
        },
    },
}

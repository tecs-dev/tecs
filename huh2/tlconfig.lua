-- Configuration for the Teal compiler and for Cerulean, the formatter.
--
-- This is not what marks a project: `tecs.lua` is. The two are separate files
-- because they answer to different tools, and conflating them is what stopped
-- the previous command line tool from running anywhere but a project's root.
--
-- The engine's own type information is not named here. `tecs check` and
-- `tecs build` pass it, because only the running binary knows where it was
-- installed.
return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "src/" },

    cerulean = {
        indent_width = 4,
        max_line_width = 120,
        sort_requires = false,
        hug_single_argument = true,
    },
}

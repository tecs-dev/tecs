-- Configuration for the Teal compiler and for Cerulean, the formatter.
--
-- This is not what marks a project: `tecs.lua` is. The two are separate files
-- because they answer to different tools, and conflating them is what stopped
-- the previous command line tool from running anywhere but a project's root.
--
-- The engine's own type information is not named here. `tecs check` and
-- `tecs dist` pass it, because only the running binary knows where it was
-- installed.
return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    include_dir = { "src/" },

    -- Where the `tecs` global is declared, so a file can write
    -- `tecs.ecs.newWorld()` with no require line.
    --
    -- Here rather than only on the command line, because the compiler is not
    -- always run by tecs. An editor, a language server or a bare `tl` reads
    -- this file and nothing else, and without this key every use of the global
    -- in a fresh project is an unknown variable: 31 of them in the file next
    -- door. `tecs check` passed anyway, because it passes the same setting as
    -- an argument, and a check that is green only when tecs runs it is worse
    -- than one that is red.
    global_env_def = "tecs.global",

    cerulean = {
        indent_width = 4,
        max_line_width = 120,
        sort_requires = false,
    },
}

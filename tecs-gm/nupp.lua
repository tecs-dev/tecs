-- tecs-gm: a tecs audio extension, a top-level package of the monorepo
-- that a game opts into. Its native library builds with `nupp task extensions`
-- at the repository root, and its modules sit beside the tecs sources they
-- extend.
return {
    include = { "src", "tests", "../src" },
    build = {
        outDir = "../out/tecs-gm",
        default = "gm",
        targets = {
            gm = {
                kind = "modules",
                description = "Build the tecs-gm modules",
                entries = {
                    "tecs.gm",
                    "tecs.gm.midi",
                },
            },
        },
    },
    test = { build = "gm" },
}

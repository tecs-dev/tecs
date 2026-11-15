-- tecs-ymfm: a tecs audio extension, a top-level package of the monorepo
-- that a game opts into. Its native library builds with `nupp task extensions`
-- at the repository root, and its modules sit beside the tecs sources they
-- extend.
return {
    include = { "src", "tests", "../src" },
    -- This extension's library and the audio service its tests reach, as the
    -- root manifest names them.
    libraries = {
        tecs_ymfm = { env = "TECS_YMFM_LIBRARY", search = { "../target/release", "../target/debug" } },
        tecsaudio = { env = "TECS_AUDIO_LIBRARY", search = { "../target/release", "../target/debug" } },
    },
    build = {
        outDir = "../out/tecs-ymfm",
        default = "ymfm",
        targets = {
            ymfm = {
                kind = "modules",
                description = "Build the tecs-ymfm modules",
                entries = {
                    "tecs.ymfm",
                    "tecs.ymfm.music",
                    "tecs.ymfm.registerlog",
                    "tecs.ymfm.vgm",
                    "tecs.ymfm.dro",
                },
            },
        },
    },
    test = { build = "ymfm" },
}

-- tecs-pcm: encoded audio files for tecs, a top-level package of the monorepo
-- that a game opts into. Its native library builds with `nupp task extensions`
-- at the repository root, and its module sits beside the tecs sources it
-- extends.
return {
    include = { "src", "tests", "../src" },
    -- This extension's library and the audio service its tests reach, as the
    -- root manifest names them.
    libraries = {
        tecs_pcm = { env = "TECS_PCM_LIBRARY", search = { "../target/release", "../target/debug" } },
        tecsaudio = { env = "TECS_AUDIO_LIBRARY", search = { "../target/release", "../target/debug" } },
    },
    build = {
        outDir = "../out/tecs-pcm",
        default = "pcm",
        targets = {
            pcm = {
                kind = "modules",
                description = "Build the tecs-pcm module",
                entries = {
                    "tecs.pcm",
                },
            },
        },
    },
    test = { build = "pcm" },
}

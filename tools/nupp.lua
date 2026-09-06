-- Development dependencies stay outside the game component source set.
return {
    include = { "." },
    build = {
        outDir = "../out/dev",
        default = "tools",
        targets = { tools = { kind = "modules" } },
    },
    test = { build = "tools", argv = { "nupp", "test-runner" } },
}

-- What this project is. Both the marker and the manifest: `tecs` finds a
-- project by searching upward for this file, so every command works from any
-- directory inside it.
--
-- Every field but `name` has a default, and the defaults are what is written
-- out here so there is one place to change them rather than a file that says
-- nothing until something goes wrong.
return {
    name = "{{name}}",
    identifier = "{{identifier}}",

    entry = "src/main.tl",
    source = "src",
    assets = "assets",
    spec = "spec",
    build = "build",

    window = {
        title = "{{title}}",
        width = 1280,
        height = 720,
    },
}

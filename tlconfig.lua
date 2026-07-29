-- The Teal compiler's configuration, and the documentation site under
-- `tealdoc.site`.
--
-- One program owns both halves of a page. The prose above a page's
-- `<!-- @generated` marker is the page's own, and the reference below it is
-- rendered from the modules `api` names each time the site is built, so there
-- is no second copy of a signature for the first to drift from.
--
-- `cargo xtask docs-build` renders the site, `cargo xtask docs-dev` serves it
-- and rebuilds on a change, and `cargo xtask docs-check` builds it into a
-- scratch directory. What holds the site to the API it describes is
-- `before_build` at the bottom of this file.

-- Where this file is, so the checks below read the tree rather than whatever
-- directory tealdoc or the compiler was started in. Paths written into the
-- settings stay tree-relative, because tealdoc resolves those against this
-- file itself and hands them back already resolved.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."

--- Reads a path as given, which is what a page's `source` already is by the
--- time tealdoc hands it back.
local function read(path)
    local file = io.open(path, "rb")
    if not file then
        error("could not read " .. path, 0)
    end
    local text = file:read("*a")
    file:close()
    return text
end

--- Reads a path written relative to the tree, which is how this file writes
--- one.
local function readTree(path)
    return read(HERE .. "/" .. path)
end

local function isFile(path)
    local file = io.open(HERE .. "/" .. path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

--- The public surface, read out of the declaration rather than transcribed
--- beside it.
---
--- `SURFACE` in `src/tecs/init.tl` says which names a game can write and which
--- of them sit inside another, so the module pages are built from it. A module
--- renamed there fails this build rather than leaving a page nobody notices
--- has stopped describing anything.
---
--- The table is literal, so it is loaded rather than pattern-matched. What
--- Teal adds to the line is the `<const>` and the type, and both are ahead of
--- the `=`.
local function surface()
    local source = readTree("src/tecs/init.tl")
    local body = source:match("\nlocal SURFACE[^\n]*=%s*(%b{})")
    if not body then
        error("src/tecs/init.tl declares no SURFACE table; the shape must have changed", 0)
    end
    local chunk, message = (loadstring or load)("return " .. body)
    if not chunk then
        error("src/tecs/init.tl declares a SURFACE this cannot read: " .. tostring(message), 0)
    end
    return chunk()
end

local SURFACE = surface()

--- Where the module a require path names lives, as a path under `src`, and the
--- name tealdoc reads it under, which is that path with the separators written
--- as dots. A module that is a directory is its `init.tl` and carries the
--- `init` in its name.
local function moduleFile(name)
    local base = "src/" .. name:gsub("%.", "/")
    if isFile(base .. ".tl") then
        return base .. ".tl", name
    end
    if isFile(base .. "/init.tl") then
        return base .. "/init.tl", name .. ".init"
    end
    error("no file under src/ for module " .. name, 0)
end

-- The modules a page's reference is assembled from beyond the one `SURFACE`
-- names. A public name is a namespace and a module is a file, and the two do
-- not have to agree: `tecs.gfx.animation` hands out the sheet types that
-- `tecs.gfx.sheet` declares, and `tecs.input` the gamepad and the sensors.
-- `SURFACE` does not carry these because nothing resolves through them at run
-- time; each module re-exports those names on its own record, so one require
-- answers for both.
--
-- `tecs.gfx` is not here. It is the one namespace no single module answers, so
-- `SURFACE` already lists what it is assembled from, under `beside`.
--
-- Every entry goes away the day its namespace is one file.
local BESIDE = {
    ["tecs.gfx.animation"] = { "tecs.gfx.sheet" },
    ["tecs.input"] = { "tecs.platform.Gamepad", "tecs.platform.sensors" },
}

--- Orders names the way a listing presents them: alphabetically, ignoring
--- case, because that is how a name is looked up.
local function ordered(names)
    table.sort(names, function(left, right)
        local a, b = left:lower(), right:lower()
        if a == b then
            return left < right
        end
        return a < b
    end)
    return names
end

--- The page one public name gets: its route, the modules its reference renders
--- from, and the name those are rewritten to.
---
--- A `within` key has a page of its own only when it is a module, which is what
--- luacase says. A PascalCase one is a class reached through its namespace,
--- `tecs.gfx.Camera`, and belongs on the namespace's page.
local function modulePage(name, spec, parent)
    local public = "tecs." .. (parent and parent .. "." .. name or name)
    local route = "modules/" .. (parent and parent .. "/" .. name or name)
    local nested = false
    for key in pairs(spec.within or {}) do
        nested = nested or key:match("^[a-z]") ~= nil
    end
    local api = {}
    local function add(module)
        local _, read_as = moduleFile(module)
        table.insert(api, read_as)
    end
    for _, module in ipairs(spec.beside or {}) do
        add(module)
    end
    if spec.module then
        add(spec.module)
    end
    for _, module in ipairs(BESIDE[public] or {}) do
        add(module)
    end
    return {
        route = nested and route .. "/" or route,
        title = public,
        public = public,
        api = api,
    }
end

--- One page per public name, a parent ahead of the names inside it.
---
--- A descriptor naming a `member` is one function taken off a module rather
--- than a name of its own, so `tecs.newApplication` is documented on the page
--- of the module that declares it and has none here.
---
--- The PascalCase names come first, because they are types the root carries
--- rather than modules, and the sidebar groups them under `tecs` rather than
--- beside `tecs.assets`.
local function modulePages()
    local roots, modules = {}, {}
    for name, spec in pairs(SURFACE) do
        if not spec.member then
            table.insert(name:match("^[A-Z]") and roots or modules, name)
        end
    end
    local pages = {}
    for _, name in ipairs(ordered(roots)) do
        table.insert(pages, modulePage(name, SURFACE[name]))
    end
    for _, name in ipairs(ordered(modules)) do
        table.insert(pages, modulePage(name, SURFACE[name]))
        local below = {}
        for key in pairs(SURFACE[name].within or {}) do
            if key:match("^[a-z]") then
                table.insert(below, key)
            end
        end
        for _, key in ipairs(ordered(below)) do
            table.insert(pages, modulePage(key, SURFACE[name].within[key], name))
        end
    end
    return pages
end

-- The pages, in the order the site reads them: the introduction, the tool, the
-- modules, then the ECS. A route ending in a slash is a section and is written
-- in that section's `index.md`; every other route is a file beside it.
--
-- A page's description is not here. It is the `description:` in the page's own
-- frontmatter, read in `before_build`, so the one copy of it lives where the
-- page it labels does.
local PAGES = {
    {
        route = "",
        title = "Tecs",
        layout = "home",
        hero_title = "Build games with LuaJIT",
        hero_text = "Typed. GPU-driven. Designed for humans and AI.",
        hero_image = "/images/tecs.png",
        hero_image_alt = "Tecs",
        hero_actions = {
            { text = "Get started", path = "getting-started", theme = "brand" },
            { text = "Modules", path = "modules", theme = "alt" },
            { text = "tecs.ecs", path = "ecs", theme = "alt" },
        },
        features = {
            {
                title = "Build with AI",
                details = "A [built-in MCP server](/modules/mcp) lets humans and agents inspect, freeze and edit"
                    .. " a running game.",
                icon = "🤖",
            },
            {
                title = "ECS built for LuaJIT",
                details = "An [archetype-based ECS](/ecs/archetype) with FFI components, contiguous columns, and a"
                    .. " dirty model the GPU reads.",
                icon = "⚡",
            },
            {
                title = "Batteries included",
                details = "[Physics](/modules/physics), [audio](/modules/audio),"
                    .. " [particles](/modules/gfx/particles), [text](/modules/gfx/),"
                    .. " [sequencing](/modules/sequence), [sprite sheets](/modules/gfx/animation) and hot reload"
                    .. " ship in the box, sharing one data model.",
                icon = "🔋",
            },
            {
                title = "Static typing",
                details = "Catch errors at compile time, not runtime. Tecs is designed from the ground up for"
                    .. " static typing with [Teal](https://github.com/teal-language/tl).",
                image = "/images/teal.svg",
            },
        },
    },
    { route = "getting-started", title = "Getting started" },
    { route = "modules/", title = "Modules" },

    { route = "cli/", title = "Tecs CLI" },
    { route = "cli/projects", title = "Projects" },
    { route = "cli/scope", title = "Scope" },
}

for _, page in ipairs(modulePages()) do
    table.insert(PAGES, page)
end

for _, page in ipairs({
    { route = "ecs/", title = "tecs.ecs", public = "tecs.ecs", api = { "tecs.ecs" } },
    { route = "ecs/archetype", title = "Archetypes" },
    { route = "ecs/builtins", title = "Builtins" },
    { route = "ecs/components/", title = "Components" },
    { route = "ecs/components/bundles", title = "Component Bundles" },
    { route = "ecs/components/construction", title = "Component Construction" },
    { route = "ecs/components/dirty-tracking", title = "Dirty Tracking" },
    { route = "ecs/components/ffi", title = "FFI Components" },
    { route = "ecs/components/scalar-components", title = "Scalar Components" },
    { route = "ecs/components/serialization", title = "Component Serialization" },
    { route = "ecs/components/table-components", title = "Table Components" },
    { route = "ecs/components/tag-components", title = "Tag Components" },
    { route = "ecs/events", title = "Events" },
    { route = "ecs/mutation-model", title = "Mutation model" },
    { route = "ecs/phases", title = "Phases" },
    { route = "ecs/plugins", title = "Plugins" },
    { route = "ecs/profiling", title = "Profiling" },
    { route = "ecs/queries/", title = "Queries" },
    { route = "ecs/queries/callbacks", title = "Query callbacks" },
    { route = "ecs/queries/grouping", title = "Query grouping" },
    { route = "ecs/random", title = "tecs.ecs.random" },
    { route = "ecs/relationships/", title = "Relationships" },
    { route = "ecs/relationships/ffi", title = "FFI Relationships" },
    { route = "ecs/save-games", title = "Save games" },
    { route = "ecs/states", title = "State stack" },
    { route = "ecs/systems", title = "Systems" },
    { route = "ecs/world", title = "World" },
}) do
    table.insert(PAGES, page)
end

-- The sidebar, written out rather than derived from the routes.
--
-- One row per page, and no row for anything smaller. The sidebar moves a
-- reader between pages; a function lives on the page that documents it and is
-- reached through that page's own outline. Three rows that land in the same
-- place teach a reader that the sidebar does not know where things are.
--
-- Alphabetical ignoring case, and spelled the way a game writes it. A reader
-- looking for `tecs.filesystem.watch` scans for that string; a thematic
-- grouping makes them guess which of four headings somebody filed it under
-- first. The name a group carries is the prefix of every name inside it, so a
-- closed group still tells a reader scanning for a name whether to open it.
--
-- The one nesting is the real one. A module that sits inside another is a row
-- inside its parent's group, because that is where its name puts it: a reader
-- holding `tecs.gfx.layers` reads it left to right and finds `tecs.gfx` first.
-- A group that names a page carries that page as the first row inside it.
local SIDEBAR = {
    {
        text = "Introduction",
        items = {
            { text = "Getting started", path = "getting-started" },
            { text = "Modules", path = "modules" },
        },
    },
    -- The CLI is a group rather than a row under the introduction, because it
    -- is a tool with a surface of its own rather than one more thing to read
    -- once.
    {
        text = "CLI",
        items = {
            { text = "Overview", path = "cli" },
            { text = "Projects", path = "cli/projects" },
            { text = "Scope", path = "cli/scope" },
        },
    },
    {
        text = "Modules",
        items = {
            -- `Application` and `Future` are types on the root rather than
            -- modules, so they sit under `tecs` rather than beside
            -- `tecs.assets`. The group is the page.
            {
                text = "tecs",
                path = "modules",
                items = {
                    { text = "tecs.Application", path = "modules/Application" },
                    { text = "tecs.Future", path = "modules/Future" },
                },
            },
            { text = "tecs.assets", path = "modules/assets" },
            { text = "tecs.audio", path = "modules/audio" },
            { text = "tecs.data", path = "modules/data" },
            { text = "tecs.events", path = "modules/events" },
            {
                text = "tecs.filesystem",
                path = "modules/filesystem",
                items = {
                    { text = "tecs.filesystem.watch", path = "modules/filesystem/watch" },
                },
            },
            {
                text = "tecs.gfx",
                path = "modules/gfx",
                items = {
                    { text = "tecs.gfx.animation", path = "modules/gfx/animation" },
                    { text = "tecs.gfx.layers", path = "modules/gfx/layers" },
                    { text = "tecs.gfx.materials", path = "modules/gfx/materials" },
                    { text = "tecs.gfx.particles", path = "modules/gfx/particles" },
                },
            },
            { text = "tecs.input", path = "modules/input" },
            { text = "tecs.log", path = "modules/log" },
            { text = "tecs.math", path = "modules/math" },
            { text = "tecs.mcp", path = "modules/mcp" },
            {
                text = "tecs.net",
                path = "modules/net",
                items = {
                    { text = "tecs.net.http", path = "modules/net/http" },
                },
            },
            { text = "tecs.physics", path = "modules/physics" },
            { text = "tecs.regex", path = "modules/regex" },
            { text = "tecs.sequence", path = "modules/sequence" },
            { text = "tecs.system", path = "modules/system" },
            { text = "tecs.time", path = "modules/time" },
            { text = "tecs.window", path = "modules/window" },
            { text = "tecs.workers", path = "modules/workers" },
        },
    },
    -- The concept pages, under the module that holds the ECS rather than under
    -- an invented category. `tecs.ecs` is one table: an engine module requires
    -- it, a game reads it off `tecs`, and both reach what is listed here.
    {
        text = "tecs.ecs",
        path = "ecs",
        items = {
            { text = "Archetypes", path = "ecs/archetype" },
            { text = "Builtins", path = "ecs/builtins" },
            {
                text = "Components",
                path = "ecs/components",
                collapsed = true,
                items = {
                    { text = "Bundles", path = "ecs/components/bundles" },
                    { text = "Construction", path = "ecs/components/construction" },
                    { text = "Dirty tracking", path = "ecs/components/dirty-tracking" },
                    { text = "FFI components", path = "ecs/components/ffi" },
                    { text = "Scalar components", path = "ecs/components/scalar-components" },
                    { text = "Serialization", path = "ecs/components/serialization" },
                    { text = "Table components", path = "ecs/components/table-components" },
                    { text = "Tag components", path = "ecs/components/tag-components" },
                },
            },
            { text = "Events", path = "ecs/events" },
            { text = "Mutation model", path = "ecs/mutation-model" },
            { text = "Phases", path = "ecs/phases" },
            { text = "Plugins", path = "ecs/plugins" },
            { text = "Profiling", path = "ecs/profiling" },
            {
                text = "Queries",
                path = "ecs/queries",
                collapsed = true,
                items = {
                    { text = "Callbacks", path = "ecs/queries/callbacks" },
                    { text = "Grouping", path = "ecs/queries/grouping" },
                },
            },
            { text = "Random", path = "ecs/random" },
            {
                text = "Relationships",
                path = "ecs/relationships",
                collapsed = true,
                items = {
                    { text = "FFI relationships", path = "ecs/relationships/ffi" },
                },
            },
            { text = "Save games", path = "ecs/save-games" },
            { text = "States", path = "ecs/states" },
            { text = "Systems", path = "ecs/systems" },
            { text = "World", path = "ecs/world" },
        },
    },
}

-- Every group starts closed, and tealdoc opens the ones that hold the page
-- being read. Opened all at once the sidebar is a hundred and fifty rows, and
-- the reader scrolls past the whole surface to reach the part they are in.
-- Written here rather than on each group so a group added later gets it, and
-- set only where a group has not asked for something else.
local function collapseGroups(items)
    for _, item in ipairs(items) do
        if item.items then
            if item.collapsed == nil then
                item.collapsed = true
            end
            collapseGroups(item.items)
        end
    end
end

collapseGroups(SIDEBAR)

--- The value fields of `record tecs`, in the three groups a listing presents
--- them in: the modules a game reaches directly, the modules that sit inside
--- one of those, and the types and functions on `tecs` itself.
---
--- A field is a module when it is luacase and declared as the type of its own
--- name, which is what tells `assets: assets` from `version: string`. The
--- alias usually matches the public name and may differ to avoid shadowing a
--- standard-library global, so `math: vectorMath` is a module too. The nesting
--- comes out of `SURFACE`, where it is declared.
local function publicNames()
    local source = readTree("src/tecs/init.tl")
    local aliases = {}
    for statement in source:gmatch("\nlocal ([^\n]*)") do
        local alias, path = statement:match('^type ([%a_][%w_]*) = require%("(tecs%.[%w_.]+)"%)$')
        if not alias then
            alias, path = statement:match('^([%a_][%w_]*) <const> = require%("(tecs%.[%w_.]+)"%)$')
        end
        if alias then
            aliases[alias] = path:match("([%w_]+)$")
        end
    end

    local top, root = {}, {}
    local inside = false
    for line in source:gmatch("[^\n]*") do
        if line == "local record tecs" then
            inside = true
        elseif inside and line == "end" then
            inside = false
        elseif inside then
            local name, declared = line:match("^    ([%a_][%w_]*): (.*)$")
            if name and name:match("^[a-z]") and (declared == name or aliases[declared] == name) then
                table.insert(top, name)
            elseif name then
                table.insert(root, name)
            end
        end
    end
    if #top == 0 then
        error("no public names were found in src/tecs/init.tl; the record shape must have changed", 0)
    end

    local sub = {}
    for name, spec in pairs(SURFACE) do
        for key in pairs(spec.within or {}) do
            if key:match("^[a-z]") then
                table.insert(sub, name .. "." .. key)
            end
        end
    end
    return ordered(top), ordered(sub), ordered(root)
end

--- The names a listing writes, one per line, as ``- [`tecs.name`](link)`` or
--- as a table row. Both are matched at the start of a line, so a name
--- mentioned in prose is not mistaken for an entry.
local function listed(markdown)
    local names = {}
    for line in markdown:gmatch("[^\n]+") do
        local name = line:match("^%- %[`tecs%.([%a_][%w_.]*)`%]") or line:match("^| %[`tecs%.([%a_][%w_.]*)`%]")
        if name then
            table.insert(names, name)
        end
    end
    return names
end

--- Fills each page's description in from the page's own frontmatter, so a
--- description is written once, where the page it labels is, and
--- `scripts/check-docs-descriptions.sh` gates the one copy.
local function describePages(context)
    for _, page in ipairs(context.pages) do
        local frontmatter = read(page.source):match("^%-%-%-\n(.-)\n%-%-%-\n")
        local description = frontmatter and ("\n" .. frontmatter .. "\n"):match("\ndescription: *(.-) *\n")
        if not description or description == "" then
            error(page.source .. " has no description in its frontmatter", 0)
        end
        page.description = description:match('^"(.*)"$') or description
    end
end

--- Holds the site to the API it describes, and fails the build rather than
--- publishing one that has quietly lost a page.
---
--- Four things: every public name has a page, no page outlives the module it
--- documents, both listings of the modules agree with `src/tecs/init.tl` and
--- with each other, and the sidebar has one row per page. A fifth, that a
--- page's committed reference matches a fresh render, went with the thing it
--- checked: the render happens here now, so there is no second copy to drift.
local function checkPages(context)
    local top, sub, root = publicNames()

    local documented, route = {}, {}
    for _, page in ipairs(context.pages) do
        if page.public then
            documented[page.public] = true
            route[page.public] = page.path
        end
        for _, module in ipairs(page.api or {}) do
            if not context.env.registry["$" .. module] then
                error("/" .. page.path .. " names a module nothing read: " .. module, 0)
            end
        end
    end

    local missing = {}
    for _, group in ipairs({ top, sub }) do
        for _, name in ipairs(group) do
            if not documented["tecs." .. name] then
                table.insert(missing, "tecs." .. name)
            end
        end
    end
    if #missing > 0 then
        error(
            "public names in src/tecs/init.tl with no page: "
                .. table.concat(missing, ", ")
                .. "\nEvery name a game can write needs somewhere to read about it. Add a"
                .. "\npage under docs/modules/ and a row in both listings.",
            0
        )
    end

    local known = {}
    for _, group in ipairs({ top, sub, root }) do
        for _, name in ipairs(group) do
            known["tecs." .. name] = true
        end
    end
    local orphans = {}
    for name in pairs(documented) do
        if not known[name] then
            table.insert(orphans, name .. " (/" .. route[name] .. ")")
        end
    end
    if #orphans > 0 then
        error(
            "pages naming nothing public: "
                .. table.concat(ordered(orphans), ", ")
                .. "\nThe module moved and the page did not. Delete it, or rename it to"
                .. "\nthe field that replaced it.",
            0
        )
    end

    local expected = {}
    for _, group in ipairs({ top, sub, root }) do
        for _, name in ipairs(group) do
            table.insert(expected, name)
        end
    end
    expected = table.concat(expected, "\n")
    for _, listing in ipairs({ "docs/modules/index.md", "docs/index.md" }) do
        local names = table.concat(listed(readTree(listing)), "\n")
        if names ~= expected then
            error(
                listing
                    .. " does not list the modules in the expected order.\n"
                    .. "One alphabetical list, ignoring case, in both places. Expected:\n"
                    .. expected
                    .. "\n\nFound:\n"
                    .. names,
                0
            )
        end
    end

    local navigable = {}
    local function walk(items)
        for _, item in ipairs(items) do
            if item.path then
                navigable[item.path] = true
            end
            walk(item.items or {})
        end
    end
    walk(context.settings.sidebar)
    local unreachable = {}
    for _, page in ipairs(context.pages) do
        -- The home page is the site root, reached from the header rather than
        -- navigated to from the sidebar.
        if page.path ~= "" and not navigable[page.path] then
            table.insert(unreachable, "/" .. page.path)
        end
    end
    if #unreachable > 0 then
        error(
            "pages the sidebar does not reach: "
                .. table.concat(ordered(unreachable), ", ")
                .. "\nOne sidebar row per page. Add each to SIDEBAR in tlconfig.lua.",
            0
        )
    end
end

local pages = {}
for _, entry in ipairs(PAGES) do
    local source = "docs/index.md"
    if entry.route ~= "" then
        source = "docs/" .. (entry.route:match("/$") and entry.route .. "index.md" or entry.route .. ".md")
    end
    table.insert(pages, {
        path = (entry.route:gsub("/$", "")),
        title = entry.title,
        source = source,
        api = entry.api,
        public = entry.public,
        layout = entry.layout,
        hero_title = entry.hero_title,
        hero_text = entry.hero_text,
        hero_image = entry.hero_image,
        hero_image_alt = entry.hero_image_alt,
        hero_actions = entry.hero_actions,
        features = entry.features,
    })
end

-- Every file a page's reference renders from, gathered from the pages above so
-- that a module reaches the site by being named on one of them and no other
-- way.
local sources = {}
local staged = {}
for _, page in ipairs(pages) do
    for _, module in ipairs(page.api or {}) do
        if not staged[module] then
            staged[module] = true
            table.insert(sources, (moduleFile((module:gsub("%.init$", "")))))
        end
    end
end
table.sort(sources)

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
        -- AGENTS.md puts a name's documentation on its declaration, which is
        -- the record field, and leaves the implementation below it silent.
        -- This is what makes tealdoc keep the same copy.
        doc_precedence = "declaration",
        site = {
            title = "Tecs",
            description = "Typed entity component system and game engine for Lua.",
            site_url = "https://tecs.dev",
            -- No logo: the wordmark in `docs/site.css` is the mark, and an
            -- image beside it would say the name twice.
            favicon = "/images/logo.svg",
            github = "https://github.com/tecs-dev/tecs",
            public = "docs/public",
            custom_css = "docs/site.css",
            social_image = "/images/tecs.png",
            copyright = "Copyright Michael Dowling",
            license = "MIT or Apache-2.0, at your option",
            -- No row for MIT and Apache-2.0: the license line above already
            -- names both, and a footer that says a thing twice reads as a
            -- footer that was not looked at.
            footer_links = {
                {
                    text = "Third-party notices",
                    path = "https://github.com/tecs-dev/tecs/blob/main/THIRD_PARTY_NOTICES.md",
                },
            },
            nav = {
                { text = "Get started", path = "getting-started" },
                { text = "Modules", path = "modules" },
                { text = "tecs.ecs", path = "ecs" },
                { text = "CLI", path = "cli" },
            },
            -- The display face, asked for here rather than through an
            -- `@import` in `docs/site.css`. An import is found only once that
            -- sheet has been fetched and parsed, so the request for the font
            -- queued behind it and a reader watched the page repaint out of
            -- the fallback face. From the head it goes out with everything
            -- else. The two preconnects open the connections while the CSS
            -- that needs them is still in flight; `fonts.gstatic.com` serves
            -- the font files themselves and is reached anonymously, which is
            -- what `crossorigin` says here.
            head = {
                {
                    tag = "link",
                    attributes = {
                        rel = "preconnect",
                        href = "https://fonts.googleapis.com",
                    },
                },
                {
                    tag = "link",
                    attributes = {
                        rel = "preconnect",
                        href = "https://fonts.gstatic.com",
                        crossorigin = "",
                    },
                },
                {
                    tag = "link",
                    attributes = {
                        rel = "stylesheet",
                        href = "https://fonts.googleapis.com/css2"
                            .. "?family=Jersey+15&display=swap",
                    },
                },
            },
            sources = sources,
            pages = pages,
            sidebar = SIDEBAR,
            before_build = function(context)
                describePages(context)
                checkPages(context)
            end,
        },
    },
}

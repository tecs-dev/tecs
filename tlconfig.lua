-- The Teal compiler's configuration, and the documentation site under
-- `tealdoc.site`.
--
-- One program owns a module page. Its Markdown source carries metadata and a
-- title; its Teal modules carry the introduction, examples, and declaration
-- reference. Tealdoc composes them each time the site is built, so there is no
-- second copy of a contract to drift from the source.
--
-- `cargo xtask docs-build` renders the site, `cargo xtask docs-dev` serves it
-- and rebuilds on a change, and `cargo xtask docs-check` builds it into a
-- scratch directory. What holds the site to the API it describes is
-- the checks in `before_build` at the bottom of this file.

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

--- Where the module a require path names lives as a path under `src`.
---
--- Tealdoc names a directory module after its physical `init.tl` path. The
--- site publishes it under the require path instead, matching Teal and Lua.
local DIRECTORY_MODULES = {}
local function moduleFile(name)
    local base = "src/" .. name:gsub("%.", "/")
    if isFile(base .. ".tl") then
        return base .. ".tl", name
    end
    if isFile(base .. "/init.tl") then
        DIRECTORY_MODULES[name] = name .. ".init"
        return base .. "/init.tl", name
    end
    error("no file under src/ for module " .. name, 0)
end

--- Makes Tealdoc's physical names for directory modules available under the
--- require names used by API projections.
local function prepareDirectoryModules(context)
    for public, physical in pairs(DIRECTORY_MODULES) do
        context.env.registry["$" .. public] =
            assert(context.env.registry["$" .. physical], "Tealdoc did not read directory module " .. physical)
        context.env.registry[public] =
            assert(context.env.registry[physical], "Tealdoc did not export directory module " .. physical)
    end
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
    ["tecs.io"] = { "tecs.io.types" },
}

-- A PascalCase child normally renders on its parent namespace page. These
-- three are complete class modules with their own source files and pages.
local CHILD_PAGES = {
    ["tecs.io.Path"] = true,
    ["tecs.io.Process"] = true,
    ["tecs.io.URI"] = true,
}

local function childHasPage(parent, name, spec)
    local public = "tecs." .. parent .. "." .. name
    return not spec.member and (name:match("^[a-z]") ~= nil or CHILD_PAGES[public])
end

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
--- A `within` key has a page of its own when it is a luacase module or an
--- explicitly independent class module.
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
        api = #api > 0 and api or nil,
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
        for key, spec in pairs(SURFACE[name].within or {}) do
            if childHasPage(name, key, spec) then
                table.insert(below, key)
            end
        end
        for _, key in ipairs(ordered(below)) do
            table.insert(pages, modulePage(key, SURFACE[name].within[key], name))
        end
    end
    return pages
end

-- Tealdoc discovers every Markdown page below `docs`. These entries add only
-- the generated API projections and home-page presentation that cannot be
-- inferred from a Markdown path or its frontmatter.
local PAGE_OVERRIDES = {
    {
        route = "",
        title = "Tecs",
        layout = "home",
        hero_title = "Build games with LuaJIT",
        hero_text = "Typed. GPU-driven. One data model.",
        hero_image = "/images/tecs.png",
        hero_image_alt = "Tecs",
        hero_actions = {
            { text = "Get started", path = "getting-started", theme = "brand" },
            { text = "Modules", path = "modules", theme = "alt" },
        },
        features = {
            {
                title = "Live inspection",
                details = "Inspect, freeze, and edit a running game through the"
                    .. " [built-in MCP server](/modules/io/mcp).",
                icon = "🤖",
            },
            {
                title = "ECS built for LuaJIT",
                details = "An [archetype-based ECS](/modules/ecs/archetype) with FFI components,"
                    .. " contiguous columns, and a dirty model the GPU reads.",
                icon = "⚡",
            },
            {
                title = "Batteries included",
                details = "[Physics](/modules/physics), [audio](/modules/audio),"
                    .. " [particles](/modules/gfx/particles), [text](/modules/gfx/),"
                    .. " [retained UI](/ui/), [sequences](/modules/sequence),"
                    .. " [sprite sheets](/modules/gfx/animation), and hot reload share the ECS.",
                icon = "🔋",
            },
            {
                title = "Static typing",
                details = "[Teal](https://github.com/teal-language/tl) checks component, query, system, and"
                    .. " engine APIs before the game runs.",
                image = "/images/teal.svg",
            },
        },
    },
    {
        route = "modules/",
        public = "tecs",
        api = {
            {
                module = "tecs.init",
                include = { "newApplication", "version" },
            },
            {
                module = "tecs.batch",
                public = "tecs",
                include = { "batch" },
            },
            {
                module = "tecs.scope",
                public = "tecs",
                include = { "Scope", "scoped" },
            },
            {
                module = "tecs.types",
                public = "tecs",
                include = { "Closeable" },
            },
        },
    },
    {
        route = "modules/ecs/",
        public = "tecs.ecs",
        api = {
            "tecs.ecs",
            {
                module = "tecs.types",
                public = "tecs",
                include = { "World", "Query", "System", "Plugin" },
            },
        },
    },
}

for _, page in ipairs(modulePages()) do
    table.insert(PAGE_OVERRIDES, page)
end

table.insert(PAGE_OVERRIDES, {
    route = "modules/ecs/random",
    public = "tecs.ecs.random",
    api = { "tecs.random" },
})

-- Public modules normally resolve through `SURFACE`. `tecs.ecs.random` is the
-- exception: `tecs.ecs` owns it directly because engine modules also require
-- that same table, so it never passes through the root resolver.
local DIRECT_PUBLIC_MODULES = {
    ["tecs.ecs.random"] = true,
}

--- The value fields of `record tecs`, in the three groups a listing presents
--- them in: the modules a game reaches directly, the modules that sit inside
--- one of those, and the types and functions on `tecs` itself.
---
--- A field is a module when it is luacase and declared as the type of its own
--- name, which is what tells `assets: assets` from `version: string`. The
--- alias usually matches the public name and may differ to avoid shadowing a
--- standard-library global, so `math: angleMath` is a module too. The nesting
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
        for key, child in pairs(spec.within or {}) do
            if childHasPage(name, key, child) then
                table.insert(sub, name .. "." .. key)
            end
        end
    end
    for name in pairs(DIRECT_PUBLIC_MODULES) do
        local public = name:gsub("^tecs%.", "")
        table.insert(sub, public)
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

local BANNED_HEADINGS = {
    What = true,
    How = true,
    Why = true,
    Where = true,
    Who = true,
}

local BANNED_HEADING_TITLES = {
    ["Basic usage"] = true,
    ["Core concepts"] = true,
    ["Example code"] = true,
    ["Practices worth keeping"] = true,
    Related = true,
    Submodule = true,
    Submodules = true,
}

--- Rejects writing patterns that have no place in the public documentation.
local function checkWriting(context)
    local function checkText(path, text)
        local lineNumber = 0
        for line in (text .. "\n"):gmatch("(.-)\n") do
            lineNumber = lineNumber + 1
            if line:find("—", 1, true) then
                error(path .. ":" .. lineNumber .. " uses an em dash", 0)
            end
            local heading = line:match("^#+%s+(.+)$")
            local first = heading and heading:match("^([%a]+)")
            if first and BANNED_HEADINGS[first] then
                error(path .. ":" .. lineNumber .. " uses a generic " .. first .. " heading", 0)
            end
            if heading and BANNED_HEADING_TITLES[heading] then
                error(path .. ":" .. lineNumber .. " uses the generic heading " .. heading, 0)
            end
        end
    end

    for _, page in ipairs(context.pages) do
        local text = read(page.source)
        checkText(page.source, text)

        if page.api and #page.api > 0 then
            local body = text
            if body:sub(1, 4) == "---\n" then
                local ending = body:find("\n---\n", 5, true)
                if ending then
                    body = body:sub(ending + 5)
                end
            end
            body = body:gsub("^%s+", "")
            local title, remainder = body:match("^# ([^\n]+)\n?(.*)$")
            if not title or remainder:match("%S") then
                error(
                    page.source
                        .. " is a module page; keep only frontmatter and its H1"
                        .. " so the generated reference starts at the top",
                    0
                )
            end
        end
    end

    for _, path in ipairs({ "README.md", "CONTRIBUTING.md", "STYLE.md" }) do
        checkText(path, readTree(path))
    end

    local checked = {}
    for _, page in ipairs(context.pages) do
        for _, api in ipairs(page.api or {}) do
            local module = type(api) == "table" and api.module or api
            local item = context.env.registry["$" .. module]
            local path = item and item.location and item.location.filename
            if path and not checked[path] then
                checked[path] = true
                local source = read(path)
                local equals = source:match("^%-%-%[(=*)%[")
                if equals == nil then
                    error(path .. " must start with a long module doc comment", 0)
                end
                local opening = source:find("\n", 1, true)
                local closing = source:find("\n]" .. equals .. "]", opening + 1, true)
                if not closing then
                    error(path .. " has an unterminated long module doc comment", 0)
                end
                checkText(path, source:sub(opening + 1, closing - 1))
            end
        end
    end
end

--- Holds the site to the API it describes, and fails the build rather than
--- publishing one that has quietly lost a page.
---
--- Three things: every public name has a page, no page outlives the module it
--- documents, and the homepage listing agrees with `src/tecs/init.tl`. A fourth,
--- that a page's committed reference
--- matches a fresh render, went with the thing it checked: the render happens
--- here now, so there is no second copy to drift.
local function checkPages(context)
    local top, sub, root = publicNames()

    local documented, route = {}, {}
    for _, page in ipairs(context.pages) do
        if page.public then
            documented[page.public] = true
            route[page.public] = page.path
        end
        for _, api in ipairs(page.api or {}) do
            local module = type(api) == "table" and api.module or api
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
    known["tecs"] = true
    for name in pairs(DIRECT_PUBLIC_MODULES) do
        known[name] = true
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
    local names = table.concat(listed(readTree("docs/index.md")), "\n")
    if names ~= expected then
        error(
            "docs/index.md does not list the modules in the expected order.\n"
                .. "List every public name alphabetically, ignoring case. Expected:\n"
                .. expected
                .. "\n\nFound:\n"
                .. names,
            0
        )
    end
end

--- Gives documentation examples the preloaded `tecs` global used by games.
---
--- Engine sources deliberately do not inherit that global: modules below
--- `src/tecs` must keep declaring every dependency. Tealdoc validates examples
--- after this hook, so replacing only its parser environment keeps those two
--- compilation contexts separate.
local function prepareExampleTypes(context)
    local parser = context.env.parser_registry[".tl"]
    if not parser then
        error("Tealdoc did not register its Teal parser", 0)
    end
    local validate = parser.validate
    parser.validate = function(self, text, path)
        return validate(self, 'local tecs <const> = require("tecs")\n' .. text, path)
    end
end

--- Makes a public builtin name resolve to the record that owns its declaration.
---
--- Builtins return their constructors from `tecs.internal.builtins`, while
--- `tecs.ecs` binds the same values as its public names. Tealdoc otherwise
--- sees only that binding and drops the nested record beneath it. Copy the
--- original declaration subtree under the public name rather than declaring a
--- second record merely for documentation.
local function publishBuiltinTypes(context)
    local registry = context.env.registry
    local function copy(sourcePath, publicPath, parent, ownership)
        local source = assert(registry[sourcePath], "Tealdoc did not read " .. sourcePath)
        local item = {}
        for key, value in pairs(source) do
            item[key] = value
        end
        setmetatable(item, getmetatable(source))
        item.path = publicPath
        item.parent = parent
        item.children = {}
        if item.kind == "variable" or item.kind == "field" then
            item.text = ownership .. " " .. (item.text or "Reports this public value.")
        end
        registry[publicPath] = item
        for _, childPath in ipairs(source.children or {}) do
            local child = assert(registry[childPath], "Tealdoc lost " .. childPath)
            local childPublic = publicPath .. "." .. child.name
            copy(childPath, childPublic, publicPath, ownership)
            table.insert(item.children, childPublic)
        end
    end

    for _, name in ipairs({
        "Transform2D",
        "Transform3D",
        "RelativeTransform2D",
        "TTL",
        "OnSpawn",
        "OnDespawn",
        "ArchetypeCreated",
        "StateEnter",
        "StateExit",
        "StateBlur",
        "StateFocus",
        "OnSnapshotSave",
        "StartSnapshotLoad",
        "FinishSnapshotLoad",
    }) do
        local ownership = (
            name == "TTL"
            or name:match("^On")
            or name:match("^State")
            or name == "ArchetypeCreated"
            or name:match("SnapshotLoad$")
        )
                and "Engine-owned."
            or "Caller-writable."
        copy("tecs.internal.builtins." .. name, "tecs.ecs." .. name, "tecs.ecs", ownership)
    end
end

local pages = { "docs" }
for _, entry in ipairs(PAGE_OVERRIDES) do
    table.insert(pages, {
        path = (entry.route:gsub("/$", "")),
        title = entry.title,
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

return {
    build_dir = "build",
    source_dir = "src",
    gen_target = "5.1",
    gen_compat = "off",
    global_env_def = "tecs.global",
    include_dir = { "src/", "vendor/tl/", "vendor/share/lua/5.1/" },
    dont_prune = {
        "tecs/ffi/*cdef.lua",
    },
    cerulean = {
        indent_width = 4,
        max_line_width = 120,
        sort_requires = false,
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
            -- The mark is a controller on a 32 by 32 grid, which is the grid
            -- the wordmark beside it implies: Jersey 15 is a pixel face. It
            -- sits beside that wordmark rather than replacing it, so the two
            -- together are the whole identity.
            --
            -- The favicon is the PNG rather than the SVG, and the SVG is
            -- offered beside it in `head` below. An SVG icon on its own is
            -- the whole icon or nothing: a browser that will not render one
            -- has no second choice and falls back to its default globe, and
            -- there is no /favicon.ico here to catch it.
            logo = "/images/controller.svg",
            favicon = "/images/controller-32.png",
            github = "https://github.com/tecs-dev/tecs",
            public = "docs/public",
            -- The wordmark is visible in the first paint. Start its tiny local
            -- Latin face with the document instead of discovering it after
            -- the stylesheet arrives.
            head = {
                -- Offered to browsers that render SVG icons, which scale it
                -- cleanly past 32. The PNG above is what everything else gets.
                {
                    tag = "link",
                    attributes = {
                        rel = "icon",
                        type = "image/svg+xml",
                        href = "/images/controller.svg",
                    },
                },
                -- The touch icon carries its own near-black ground, because a
                -- home screen composites a transparent icon against whatever
                -- it likes. Its two recesses are lifted off that ground for
                -- the same reason they are sunk into the body everywhere else:
                -- at #110f0d on #110f0d they would not be there at all.
                {
                    tag = "link",
                    attributes = {
                        rel = "apple-touch-icon",
                        sizes = "180x180",
                        href = "/images/controller-180.png",
                    },
                },
                {
                    tag = "link",
                    attributes = {
                        rel = "preload",
                        href = "/fonts/jersey-15/jersey-15-latin.woff2",
                        as = "font",
                        type = "font/woff2",
                        crossorigin = "anonymous",
                    },
                },
            },
            -- The generated declarations go through Cerulean, so a signature
            -- on a page is formatted the way the same code would be in the
            -- tree. It loads from the runtime's own `package.path`, which the
            -- `vendor/bin/tealdoc` wrapper already points at this tree, so the
            -- formatter here is the one `product.rs` pins. Authored fences are
            -- left as written.
            format_generated_code = true,
            constructor_pattern = "^new",
            custom_css = "docs/site.css",
            -- Scintillua's lexers, installed by `cargo xtask dev-tools` at
            -- the revision `product.rs` pins. They cover every language on
            -- this site that is not Teal; Teal keeps the compiler's own lexer,
            -- because that is what turns a type name in a code block into a
            -- link. Absent, those blocks render unhighlighted.
            lexers = "vendor/scintillua/lexers",
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
                { text = "CLI", path = "cli" },
            },
            pages = pages,
            sidebar_open = { "modules" },
            before_build = function(context)
                prepareDirectoryModules(context)
                publishBuiltinTypes(context)
                checkWriting(context)
                checkPages(context)
                prepareExampleTypes(context)
            end,
        },
    },
}

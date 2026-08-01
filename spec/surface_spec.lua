-- Every public name, walked and resolved.
--
-- `src/tecs/init.tl` says what is public in two places that have to agree. The
-- record is the declaration a game is type-checked against; the SURFACE table
-- below it is what a name resolves through at runtime. Nothing connects them.
-- A field with no descriptor is nil where it is read, a descriptor with no
-- field is a name no game can be type-checked into writing, and a descriptor
-- pointing at the wrong module resolves to a table carrying none of the members
-- the record promised. None of the three is a type error, and none of them
-- appears anywhere but at the call site of whoever needed the name first.
--
-- So this walks the declaration and holds the resolver to it. It reads init.tl
-- rather than listing the names again: a list kept here would be a third copy
-- to disagree with the other two, and the failure it is meant to catch is
-- exactly a hand-written name going wrong.
--
-- What "the thing it claims" means, without restating the descriptors. A name
-- that resolves to a module resolves to that module itself rather than a copy
-- of it, and the module's path ends in the name it is reached by:
-- `tecs.assets` is the table `require` answers for a path ending `.assets`. A
-- descriptor pointing `assets` at `tecs.workers` still resolves to a table with
-- functions in it, and fails here. A name that resolves to a namespace has no
-- module of its own, so it is held to its members instead: everything the
-- record declares on it is reachable.
--
-- The cost is that this loads every engine module in one process, which is why
-- it is its own file: `spec/headless_spec.lua` asserts the opposite property,
-- that naming nothing loads nothing, and it has to run somewhere nothing has
-- been named.

local tecs = require("tecs")

local INIT = "src/tecs/init.tl"

--- The value fields of every top-level record in init.tl, keyed by the record's
--- name and in declaration order, each with the type it was declared as.
---
--- A `type X = ...` line is a type re-export rather than a value and does not
--- match, which is the distinction being checked: a name written `X: T` claims
--- something is there to read, and a name written `type X = T` claims only that
--- an annotation may say it.
local function recordsIn(path)
    local found = {}
    local current = nil
    for line in assert(io.lines(path)) do
        local record = line:match("^local record ([%a_][%w_]*)$")
        if record then
            current = {}
            found[record] = current
        elseif current and line == "end" then
            current = nil
        elseif current then
            local field, declared = line:match("^    ([%a_][%w_]*): (.+)$")
            if field then
                current[#current + 1] = { name = field, declared = declared }
            end
        end
    end
    return found
end

--- The names SURFACE describes, which is what the resolver reads: every
--- top-level name, each carrying the names its `within` puts one level down.
---
--- Scanned by brace depth rather than by indentation, because a descriptor is
--- written on one line while it fits and wraps when it does not, and the
--- nesting is what says which name is under which. An identifier followed by
--- `=` and then `{` opens a table: at depth one that is a public name, and at
--- depth three under a `within` it is a public name one level down. Nothing in
--- the table holds a brace inside a string, so no quoting is tracked.
local function surfaceNames(path)
    local text = {}
    local inside = false
    for line in assert(io.lines(path)) do
        if line:match("^local SURFACE") then
            inside = true
        elseif inside and line == "}" then
            inside = false
        elseif inside then
            text[#text + 1] = line
        end
    end

    local found = {}
    local names = {}
    local token, last, key = "", "", ""
    local depth = 0
    for character in table.concat(text):gmatch(".") do
        if character:match("[%w_]") then
            token = token .. character
        else
            if token ~= "" then
                last, token = token, ""
            end
            if character == "=" then
                key, last = last, ""
            elseif character == "{" then
                depth = depth + 1
                names[depth], key, last = key, "", ""
                if depth == 1 then
                    found[names[1]] = {}
                elseif depth == 3 and names[2] == "within" then
                    found[names[1]][names[3]] = true
                end
            elseif character == "}" then
                depth, key, last = depth - 1, "", ""
            end
        end
    end
    return found
end

--- Every path `require` has this exact table cached under, which is empty for a
--- table the resolver built itself. Identity rather than equality: telling a
--- module from a namespace is the whole question, and the two are the same
--- shape.
local function pathsOf(value)
    local found = {}
    if type(value) ~= "table" then
        return found
    end
    for path, module in pairs(package.loaded) do
        if rawequal(module, value) then
            found[#found + 1] = path
        end
    end
    return found
end

--- Whether one of those paths ends in `name`, which is the claim a public name
--- makes about the module behind it.
local function endsIn(paths, name)
    for _, path in ipairs(paths) do
        if path:match("([%a_][%w_]*)$") == name then
            return true
        end
    end
    return false
end

local records = recordsIn(INIT)
local top = records.tecs
local described = surfaceNames(INIT)

--- The three names on `tecs` that no descriptor answers, and why each is
--- direct. `ecs` reaches nothing below Lua, so it is assigned as the module
--- returns rather than resolved; `Transform` comes off it and so is already
--- loaded whenever `tecs` is; `version` is a string.
local DIRECT = { ecs = true, version = true, Transform = true }

--- Teal type names that are a Lua type, and the Lua type each of them is. A
--- field declared one of these carries a value rather than a module, so it is
--- held to its type and nothing else.
local PRIMITIVE = { string = "string", number = "number", integer = "number", boolean = "boolean" }

describe("the public surface", function()
    it("was read out of init.tl", function()
        -- Everything below is generated from this, so a parse that found
        -- nothing would pass every test by having none to run.
        assert.is_not_nil(top, INIT .. " declares no `local record tecs`")
        -- A floor catches a parser that found a handful of names and then
        -- passed every generated test by having almost none to run.
        assert.is_true(#top > 10, "only " .. #top .. " public names were parsed from " .. INIT)
    end)

    it("declares every name the resolver answers, and no more", function()
        assert.is_true(next(described) ~= nil, "no descriptors were parsed from " .. INIT)

        local declared = {}
        for _, field in ipairs(top) do
            declared[field.name] = true
        end

        for name in pairs(described) do
            assert.is_true(declared[name], "SURFACE describes `" .. name .. "`, which `record tecs` does not declare")
        end
        for _, field in ipairs(top) do
            local answered = described[field.name] ~= nil or DIRECT[field.name] == true
            assert.is_true(answered, "`record tecs` declares `" .. field.name .. "`, which no descriptor answers")
        end
    end)

    -- One test per name, so a failure says which name rather than which loop
    -- iteration. Reading a name is what resolves it, so each of these is also
    -- the first read of the module behind it.
    for _, field in ipairs(top) do
        local name = field.name
        it("resolves tecs." .. name .. " to what it claims", function()
            local value = tecs[name]
            assert.is_not_nil(value, "tecs." .. name .. " resolves to nil")

            -- A name declared as a function is one member lifted off a module
            -- rather than the module itself, which is what a root-level
            -- constructor is: `tecs.newApplication` is the function
            -- `tecs.Application` declares, and reading it loads that module
            -- and nothing else.
            if field.declared:match("^function%(") then
                assert.are.equal("function", type(value), "tecs." .. name .. " is not the function it declares")
                return
            end

            local primitive = PRIMITIVE[field.declared]
            if primitive then
                assert.are.equal(
                    primitive,
                    type(value),
                    "tecs." .. name .. " is not the " .. field.declared .. " it declares"
                )
                return
            end

            -- A name declared as something the ECS carries is republished off
            -- it rather than resolved, so what it is held to is being that
            -- exact value. `tecs.Transform` is the one there is: a component,
            -- so neither a module nor a namespace, and the check that matters
            -- is that the root and `tecs.ecs` name one component rather than
            -- two tables that look alike.
            local republished = field.declared:match("^ecs%.([%a_][%w_]*)$")
            if republished then
                assert.is_true(
                    rawequal(value, require("tecs.ecs")[republished]),
                    "tecs." .. name .. " is not the same value as tecs.ecs." .. republished
                )
                return
            end

            local paths = pathsOf(value)
            if #paths > 0 then
                assert.is_true(endsIn(paths, name), "tecs." .. name .. " is the module " .. table.concat(paths, ", "))
                -- A module answering a public name carries the names below it
                -- as fields of its own, hung there by the resolver. Nothing
                -- else declares them, so this is where they are held: the
                -- record that types the module is the module's own.
                for member in pairs(described[name] or {}) do
                    local held = value[member]
                    assert.is_not_nil(held, "tecs." .. name .. "." .. member .. " resolves to nil")
                    if type(held) == "function" then
                        assert.is_function(held, "tecs." .. name .. "." .. member .. " is not a function")
                    else
                        assert.is_true(
                            endsIn(pathsOf(held), member),
                            "tecs." .. name .. "." .. member .. " is not the module it names"
                        )
                    end
                end
                return
            end

            -- Not a module, so it is a namespace the resolver built, and its
            -- members are what it can be held to. A class inside one is a
            -- module in its own right and is held to its path like the names
            -- above.
            assert.is_table(value, "tecs." .. name .. " is neither a module nor a namespace")
            local members = records[name]
            assert.is_not_nil(members, "tecs." .. name .. " resolves to a table no record declares")
            for _, member in ipairs(members) do
                local held = value[member.name]
                assert.is_not_nil(held, "tecs." .. name .. "." .. member.name .. " resolves to nil")
                local inner = pathsOf(held)
                if #inner > 0 then
                    assert.is_true(
                        endsIn(inner, member.name),
                        "tecs." .. name .. "." .. member.name .. " is the module " .. table.concat(inner, ", ")
                    )
                end
            end
        end)
    end

    describe("a module inside a namespace", function()
        it("is the module itself and not a copy of it", function()
            assert.is_true(rawequal(tecs.gfx.layers, require("tecs.gfx.layers")))
        end)

        it("resolves once and answers the same table afterwards", function()
            assert.is_true(rawequal(tecs.gfx.layers, tecs.gfx.layers))
            -- Held beside the namespace rather than on it. The table a caller
            -- holds stays empty so that both metamethods keep being consulted;
            -- a member written onto it would stop `__index` firing, and with it
            -- the write-through that sends a write to whichever of the modules
            -- below reads it back.
            assert.is_nil(rawget(tecs.gfx, "layers"))
        end)

        it("answers nil for a name it does not carry", function()
            assert.is_nil(tecs.gfx.nosuchthing)
        end)

        it("carries a class beside the modules below it", function()
            -- A PascalCase `within` name is a class reached through its
            -- namespace rather than a module wanting a page of its own, and it
            -- resolves to the module that declares it rather than a copy.
            assert.is_true(rawequal(tecs.gfx.Camera, require("tecs.gfx.Camera")))
            assert.is_true(rawequal(tecs.gfx.Renderer, require("tecs.Renderer")))
            -- The constructor sits on the namespace, not on the class, which
            -- is what `newCamera` means: the module owns the type.
            assert.are.equal(require("tecs.gfx.Camera").newCamera, tecs.gfx.newCamera)
            assert.are.equal(require("tecs.Renderer").newRenderer, tecs.gfx.newRenderer)
        end)
    end)

    describe("the root", function()
        it("carries the constructor rather than the module that declares it", function()
            -- One function, reached one way. `tecs.Application` types what a
            -- plugin is handed and declares no constructor of its own, so
            -- there is no second spelling for a game to write.
            assert.are.equal(require("tecs.Application").newApplication, tecs.newApplication)
        end)

        it("carries the two classes that belong to no subsystem", function()
            assert.is_true(rawequal(tecs.Application, require("tecs.Application")))
            assert.is_true(rawequal(tecs.Future, require("tecs.Future")))
        end)

        it("exposes generic event construction", function()
            local events = require("tecs.events")

            assert.is_true(rawequal(tecs.events, events))
            assert.is_function(events.newEvent)
            assert.is_function(events.newFFIEvent)
            assert.is_function(events.newMessageBus)
        end)
    end)

    describe("the platform namespace", function()
        it("hangs platform facilities below their parent", function()
            assert.is_true(rawequal(tecs.platform.events, require("tecs.platform.events")))
            assert.is_true(rawequal(tecs.platform.os, require("tecs.platform.os")))
            assert.is_true(rawequal(tecs.platform.time, require("tecs.platform.time")))
            assert.is_true(rawequal(tecs.platform.window, require("tecs.platform.window")))
            assert.is_nil(rawget(tecs.platform, "events"))
            assert.is_nil(rawget(tecs.platform, "os"))
            assert.is_nil(rawget(tecs.platform, "time"))
            assert.is_nil(rawget(tecs.platform, "window"))
            assert.is_true(rawequal(tecs.input, require("tecs.input")))
        end)
    end)

    describe("a module inside a module", function()
        it("hangs vector math below angle math", function()
            assert.is_true(rawequal(tecs.math, require("tecs.math")))
            assert.is_true(rawequal(tecs.math.vec2, require("tecs.math.vec2")))
            assert.is_true(rawequal(rawget(tecs.math, "vec2"), require("tecs.math.vec2")))
        end)

        it("answers with the parent module rather than a table in front of it", function()
            assert.is_true(rawequal(tecs.io, require("tecs.io")))
        end)

        it("hangs child modules and constructors below the parent, once", function()
            assert.is_true(rawequal(tecs.io.files, require("tecs.io.files")))
            assert.is_true(rawequal(tecs.io.path, require("tecs.io.path")))
            assert.is_true(rawequal(tecs.io.process, require("tecs.io.process")))
            assert.is_true(rawequal(tecs.io.uri, require("tecs.io.uri")))
            assert.is_true(rawequal(tecs.io.watcher, require("tecs.io.watcher")))
            -- Written onto the module after the first read, which a namespace
            -- cannot do: there the table has to stay empty so `__index` keeps
            -- firing. A module owns every name it answers, so there is nothing
            -- to route and nothing to keep consulting.
            assert.is_true(rawequal(rawget(tecs.io, "files"), require("tecs.io.files")))
            assert.is_true(rawequal(rawget(tecs.io, "path"), require("tecs.io.path")))
            assert.is_true(rawequal(rawget(tecs.io, "process"), require("tecs.io.process")))
            assert.is_true(rawequal(rawget(tecs.io, "uri"), require("tecs.io.uri")))
            assert.is_true(rawequal(rawget(tecs.io, "watcher"), require("tecs.io.watcher")))
            assert.is_true(rawequal(tecs.io.newPath, tecs.io.path.newPath))
            assert.is_true(rawequal(tecs.io.newURI, tecs.io.uri.newURI))
            assert.is_function(tecs.io.watcher.isInstalled)
            assert.is_nil(tecs.io.watcher.installed)
        end)

        it("hangs MCP below io and nowhere deeper", function()
            assert.is_true(rawequal(tecs.io.mcp, require("tecs.io.mcp")))
            assert.is_true(rawequal(rawget(tecs.io, "mcp"), require("tecs.io.mcp")))
            assert.are.equal("function", type(tecs.io.mcp.tools))
            assert.is_false(rawequal(tecs.io.mcp.tools, require("tecs.io.mcp.tools")))
            assert.is_nil(tecs.io.mcp.transport)
            assert.is_nil(tecs.io.mcp.sandbox)
            assert.is_nil(tecs.io.mcp.world)
        end)

        it("exposes preference configuration on the principal module", function()
            assert.is_function(tecs.io.files.setPreferenceIdentity)
            assert.is_function(tecs.io.files.preferenceIdentity)
            assert.is_function(tecs.io.files.append)
            assert.is_function(tecs.io.files.lines)
            assert.is_function(tecs.io.files.load)
            assert.is_function(tecs.io.files.isSymlink)
            assert.is_nil(tecs.io.files.organization)
            assert.is_nil(tecs.io.files.application)
            assert.is_nil(tecs.io.files.loaded)
            assert.is_nil(tecs.io.files.note)
            assert.is_nil(tecs.io.files.resetPaths)
        end)

        it("answers nil for a name neither it nor the names below it carry", function()
            assert.is_nil(tecs.io.nosuchthing)
            assert.is_nil(tecs.io.files.watch)
        end)
    end)
end)

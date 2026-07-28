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

--- The names SURFACE describes, which is what the resolver reads.
---
--- Matched on indentation. A name one level down sits inside the line of the
--- name that carries it, so it is not mistaken for a name of its own here; the
--- record is what declares those, and they are checked through it.
local function surfaceNames(path)
    local found = {}
    local inside = false
    for line in assert(io.lines(path)) do
        if line:match("^local SURFACE") then
            inside = true
        elseif inside and line == "}" then
            inside = false
        elseif inside then
            local name = line:match("^    ([%a_][%w_]*) = {")
            if name then
                found[name] = true
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

--- The two names on `tecs` that no descriptor answers, and why each is direct.
--- `ecs` reaches nothing below Lua, so it is assigned as the module returns
--- rather than resolved; `version` is a string.
local DIRECT = { ecs = true, version = true }

--- Teal type names that are a Lua type, and the Lua type each of them is. A
--- field declared one of these carries a value rather than a module, so it is
--- held to its type and nothing else.
local PRIMITIVE = { string = "string", number = "number", integer = "number", boolean = "boolean" }

describe("the public surface", function()
    it("was read out of init.tl", function()
        -- Everything below is generated from this, so a parse that found
        -- nothing would pass every test by having none to run.
        assert.is_not_nil(top, INIT .. " declares no `local record tecs`")
        -- A floor rather than a count: the surface is being reorganised into
        -- fewer, larger modules, so what this guards against is a parse that
        -- found a handful of names and then passed every test below by having
        -- almost none to run.
        assert.is_true(#top > 10, "only " .. #top .. " public names were parsed from " .. INIT)
    end)

    it("declares every name the resolver answers, and no more", function()
        local described = surfaceNames(INIT)
        assert.is_true(next(described) ~= nil, "no descriptors were parsed from " .. INIT)

        local declared = {}
        for _, field in ipairs(top) do
            declared[field.name] = true
        end

        for name in pairs(described) do
            assert.is_true(declared[name], "SURFACE describes `" .. name .. "`, which `record tecs` does not declare")
        end
        for _, field in ipairs(top) do
            local answered = described[field.name] or DIRECT[field.name]
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

            local primitive = PRIMITIVE[field.declared]
            if primitive then
                assert.are.equal(
                    primitive,
                    type(value),
                    "tecs." .. name .. " is not the " .. field.declared .. " it declares"
                )
                return
            end

            local paths = pathsOf(value)
            if #paths > 0 then
                assert.is_true(endsIn(paths, name), "tecs." .. name .. " is the module " .. table.concat(paths, ", "))
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

    describe("a module inside a module", function()
        it("is the module itself and not a copy of it", function()
            assert.is_true(rawequal(tecs.gfx.layers, require("tecs.gfx.layers")))
        end)

        it("resolves once and answers the same table afterwards", function()
            assert.is_true(rawequal(tecs.gfx.layers, tecs.gfx.layers))
            -- Held beside the namespace rather than on it. The table a caller
            -- holds stays empty so that both metamethods keep being consulted;
            -- a member written onto it would stop `__index` firing, and with it
            -- the write-through that sends `tecs.filesystem.organisation` to
            -- the module that reads it back.
            assert.is_nil(rawget(tecs.gfx, "layers"))
        end)

        it("does not answer at the root it moved off", function()
            -- No alias and no shim: the old spelling is a nil like any name
            -- that was never public.
            assert.is_nil(tecs.layers)
        end)

        it("answers nil for a name it does not carry", function()
            assert.is_nil(tecs.gfx.nosuchthing)
            assert.is_nil(tecs.gfx.Camera)
        end)
    end)
end)

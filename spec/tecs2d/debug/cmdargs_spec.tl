require("busted")

local luassert <const> = require("luassert")

local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")

-- A goto-style schema: a required target given as a name or an id, sharing one
-- positional slot via a synthetic arg.
local gotoSchema: cmdargs.Schema = {
    args = {
        name = {help = "mark name", forward = "target"},
        id = {help = "entity id", default = 0, forward = "target"},
        target = {synthetic = {"name", "id"}, required = true, help = "entity to act on"},
    },
    positional = {"target"},
}

-- A record-style schema: positional seconds/name plus named tuning and a flag.
local recordSchema: cmdargs.Schema = {
    args = {
        seconds = {default = 0, help = "auto-stop after N seconds"},
        name = {help = "output filename"},
        fps = {default = 30, help = "capture frame rate"},
        scale = {default = 1, help = "output scale"},
        debug = {default = false, help = "keep the debugger visible"},
    },
    positional = {"seconds", "name"},
}

describe("tecs2d.debug.internal.cmdargs", function()
    describe("validate", function()
        it("accepts reciprocal forward/synthetic edges", function()
            luassert.has_no.errors(function() cmdargs.validate(gotoSchema) end)
            luassert.has_no.errors(function() cmdargs.validate(recordSchema) end)
        end)

        it("rejects a forward without the reciprocal synthetic edge", function()
            local broken: cmdargs.Schema = {
                args = {
                    name = {forward = "target"},
                    target = {synthetic = {}},
                },
                positional = {"target"},
            }
            luassert.has_error(function() cmdargs.validate(broken) end)
        end)

        it("rejects a synthetic source that does not forward back", function()
            local broken: cmdargs.Schema = {
                args = {
                    name = {},
                    target = {synthetic = {"name"}},
                },
                positional = {"target"},
            }
            luassert.has_error(function() cmdargs.validate(broken) end)
        end)
    end)

    describe("tokenize", function()
        it("keeps quoted spans together and strips quotes", function()
            luassert.same({"a", "b c", "d"}, (cmdargs.tokenize('a "b c" d')))
            luassert.same({"name=my clip"}, (cmdargs.tokenize('name="my clip"')))
        end)

        it("errors on an unterminated quote", function()
            local toks, err = cmdargs.tokenize('"oops')
            luassert.is_nil(toks)
            luassert.matches("unterminated", err)
        end)
    end)

    describe("signature", function()
        it("joins synthetic sources with a bar", function()
            luassert.equals("<name|id>", cmdargs.signature(gotoSchema))
        end)

        it("brackets optional positionals and appends sorted named args", function()
            luassert.equals("[seconds] [name] [debug] [fps=N] [scale=N]",
                cmdargs.signature(recordSchema))
        end)

        it("hints named-arg values by kind", function()
            local schema: cmdargs.Schema = {
                args = {
                    mode = {enum = {"fast", "slow"}, help = "speed"},
                    tags = {kind = "list", help = "tag list"},
                    fields = {kind = "table", help = "field object"},
                    label = {help = "free text"},
                },
                positional = {},
            }
            cmdargs.validate(schema)
            luassert.equals("[fields={}] [label=...] [mode=fast|slow] [tags=a,b]",
                cmdargs.signature(schema))
        end)
    end)

    describe("parse (goto: name or id share a slot)", function()
        local cases = {
            {name = "positional number binds to id", tokens = {"5"}, expect = {id = 5, target = 5}},
            {name = "positional word binds to name", tokens = {"boss"}, expect = {name = "boss", target = "boss"}},
            {name = "explicit id=", tokens = {"id=7"}, expect = {id = 7, target = 7}},
            {name = "explicit name=", tokens = {"name=boss"}, expect = {name = "boss", target = "boss"}},
            {name = "quoted name with spaces", tokens = {"name=big boss"}, expect = {name = "big boss", target = "big boss"}},
        }
        for _, case in ipairs(cases) do
            it(case.name, function()
                local v, err = cmdargs.parse(gotoSchema, case.tokens)
                luassert.is_nil(err)
                luassert.equals(case.expect.id, v.id)
                luassert.equals(case.expect.name, v.name)
                luassert.equals(case.expect.target, v.target)
            end)
        end

        it("requires the synthetic target", function()
            local v, err = cmdargs.parse(gotoSchema, {})
            luassert.is_nil(v)
            luassert.matches("missing required argument 'target'", err)
        end)

        it("rejects conflicting sources for one slot", function()
            local v, err = cmdargs.parse(gotoSchema, {"id=1", "name=boss"})
            luassert.is_nil(v)
            luassert.matches("conflicting", err)
        end)
    end)

    describe("parse (record: positional + named + flag + defaults)", function()
        it("applies defaults for unset args", function()
            local v = cmdargs.parse(recordSchema, {})
            luassert.equals(0, v.seconds)
            luassert.equals(30, v.fps)
            luassert.equals(1, v.scale)
            luassert.equals(false, v.debug)
            luassert.is_nil(v.name)
        end)

        it("reads positionals, named tuning, and a bare flag", function()
            local v = cmdargs.parse(recordSchema, {"30", "clip", "fps=60", "debug"})
            luassert.equals(30, v.seconds)
            luassert.equals("clip", v.name)
            luassert.equals(60, v.fps)
            luassert.is_true(v.debug)
        end)

        local rejects = {
            {name = "a positional after a named arg", tokens = {"fps=60", "30"}, err = "after a named argument"},
            {name = "an unknown arg", tokens = {"bogus=1"}, err = "unknown argument 'bogus'"},
            {name = "a non-numeric fps", tokens = {"fps=fast"}, err = "fps must be a number"},
            {name = "a non-boolean debug", tokens = {"debug=maybe"}, err = "debug must be true or false"},
            {name = "too many positionals", tokens = {"30", "clip", "extra"}, err = "unexpected argument 'extra'"},
        }
        for _, case in ipairs(rejects) do
            it("rejects " .. case.name, function()
                local v, err = cmdargs.parse(recordSchema, case.tokens)
                luassert.is_nil(v)
                luassert.matches(case.err, err)
            end)
        end
    end)

    describe("parse (kind: optional typed args, no default)", function()
        local lightSchema: cmdargs.Schema = {
            args = {
                r = {kind = "number", help = "red"},
                g = {kind = "number", help = "green"},
                b = {kind = "number", help = "blue"},
            },
            positional = {"r", "g", "b"},
        }

        it("leaves omitted typed args nil (keep current value)", function()
            local v = cmdargs.parse(lightSchema, {"1", "0.5"})
            luassert.equals(1, v.r)
            luassert.equals(0.5, v.g)
            luassert.is_nil(v.b)
        end)

        it("accepts named channels in any order", function()
            local v = cmdargs.parse(lightSchema, {"b=0.2"})
            luassert.is_nil(v.r)
            luassert.equals(0.2, v.b)
        end)

        it("still type-checks a provided value", function()
            local v, err = cmdargs.parse(lightSchema, {"r=nope"})
            luassert.is_nil(v)
            luassert.matches("r must be a number", err)
        end)
    end)

    describe("parse (bloom: a number or an on/off toggle share one slot)", function()
        local schema: cmdargs.Schema = {
            args = {
                intensity = {kind = "number", forward = "level", help = "strength"},
                on = {kind = "boolean", forward = "level", help = "on/off"},
                level = {synthetic = {"intensity", "on"}, help = "intensity or on/off"},
                radius = {kind = "number", help = "radius"},
            },
            positional = {"level", "radius"},
        }

        it("binds a number to intensity, not the boolean", function()
            local v = cmdargs.parse(schema, {"1", "2"})
            luassert.equals(1, v.intensity)
            luassert.equals(2, v.radius)
            luassert.is_nil(v.on)
        end)

        it("binds on/off to the toggle", function()
            luassert.is_true((cmdargs.parse(schema, {"on"})).on)
            luassert.is_false((cmdargs.parse(schema, {"off"})).on)
        end)
    end)

    describe("argHelp", function()
        it("lists user-facing args with defaults, hiding synthetics", function()
            local lines = cmdargs.argHelp(recordSchema)
            local joined = table.concat(lines, "\n")
            luassert.matches("fps\t.*%(default: 30%)", joined)
            luassert.matches("debug\t", joined)
            luassert.is_nil(joined:find("target"))
        end)
    end)

    describe("rest args", function()
        local noteSchema: cmdargs.Schema = {
            args = { msg = {rest = true, help = "free text"} },
            positional = {"msg"},
        }

        it("validates and signs as a tail", function()
            luassert.has_no.errors(function() cmdargs.validate(noteSchema) end)
            luassert.equals("[msg...]", cmdargs.signature(noteSchema))
        end)

        it("captures the remainder of the line", function()
            local v = cmdargs.parse(noteSchema, {"needs", "review", "fps=60"})
            luassert.equals("needs review fps=60", v.msg)
        end)

        it("keeps quoted spacing inside one token", function()
            local toks = cmdargs.tokenize('"a  b" c')
            local v = cmdargs.parse(noteSchema, toks)
            luassert.equals("a  b c", v.msg)
        end)

        it("must be the last positional slot", function()
            local broken: cmdargs.Schema = {
                args = {
                    msg = {rest = true},
                    after = {},
                },
                positional = {"msg", "after"},
            }
            luassert.has_error(function() cmdargs.validate(broken) end)
        end)

        it("still parses declared flags that follow the text", function()
            local schema: cmdargs.Schema = {
                args = {
                    expr = {rest = true, required = true, help = "expression"},
                    invert = {default = false, help = "invert"},
                },
                positional = {"expr"},
            }
            local v = cmdargs.parse(schema, {"Position", "Velocity", "invert=true"})
            luassert.equals("Position Velocity", v.expr)
            luassert.is_true(v.invert)
            local bare = cmdargs.parse(schema, {"Dead", "invert"})
            luassert.equals("Dead", bare.expr)
            luassert.is_true(bare.invert)
        end)
    end)

    describe("brace expressions", function()
        it("keeps a balanced {...} span as one verbatim token", function()
            local toks = cmdargs.tokenize("set 5 Transform {x = 10, y = {a = 1}}")
            luassert.same({"set", "5", "Transform", "{x = 10, y = {a = 1}}"}, toks)
        end)

        it("respects quotes inside a brace span", function()
            local toks = cmdargs.tokenize('spawn Label {msg = "a } b"}')
            luassert.equals('{msg = "a } b"}', toks[#toks])
        end)

        it("errors on an unterminated brace", function()
            local toks, err = cmdargs.tokenize("set 5 Foo {x = 1")
            luassert.is_nil(toks)
            luassert.matches("unterminated { expression", err)
        end)
    end)

    describe("parseValues (typed args, e.g. MCP JSON)", function()
        it("binds a typed source and forwards to the synthetic", function()
            local v, err = cmdargs.parseValues(gotoSchema, {id = 5})
            luassert.is_nil(err)
            luassert.equals(5, v.id)
            luassert.equals(5, v.target)
            local v2 = cmdargs.parseValues(gotoSchema, {name = "boss"})
            luassert.equals("boss", v2.name)
            luassert.equals("boss", v2.target)
        end)

        it("requires exactly one source for a required synthetic", function()
            local v, err = cmdargs.parseValues(gotoSchema, {})
            luassert.is_nil(v)
            luassert.matches("provide exactly one of", err)
            local v2, err2 = cmdargs.parseValues(gotoSchema, {id = 1, name = "b"})
            luassert.is_nil(v2)
            luassert.matches("conflicting", err2)
        end)

        it("rejects naming the synthetic directly", function()
            local v, err = cmdargs.parseValues(gotoSchema, {target = 5})
            luassert.is_nil(v)
            luassert.matches("unknown argument 'target'", err)
        end)

        it("type-checks values instead of coercing", function()
            local v, err = cmdargs.parseValues(recordSchema, {fps = "fast"})
            luassert.is_nil(v)
            luassert.matches("fps must be a number", err)
        end)

        it("rejects unknown args and applies defaults", function()
            local v, err = cmdargs.parseValues(recordSchema, {bogus = 1})
            luassert.is_nil(v)
            luassert.matches("unknown argument 'bogus'", err)
            local v2 = cmdargs.parseValues(recordSchema, {})
            luassert.equals(0, v2.seconds)
            luassert.equals(30, v2.fps)
            luassert.equals(false, v2.debug)
        end)
    end)

    describe("toolSchema (MCP projection)", function()
        it("projects args with types, defaults, and no synthetics", function()
            local ts = cmdargs.toolSchema(recordSchema)
            luassert.equals("object", ts.type)
            local props = ts.properties as {string: {string: any}}
            luassert.equals("number", props.fps.type)
            luassert.matches("default: 30", props.fps.description as string)
            luassert.equals("boolean", props.debug.type)
            luassert.is_nil(ts.required)
        end)

        it("documents one-of groups on the sources and hides the synthetic", function()
            local ts = cmdargs.toolSchema(gotoSchema)
            local props = ts.properties as {string: {string: any}}
            luassert.is_nil(props.target)
            luassert.equals("number", props.id.type)
            luassert.equals("string", props.name.type)
            luassert.matches("exactly one of", props.id.description as string)
        end)

        it("lists required non-synthetic args", function()
            local schema: cmdargs.Schema = {
                args = { name = {required = true, help = "x"} },
                positional = {"name"},
            }
            local ts = cmdargs.toolSchema(schema)
            local req = ts.required as {string}
            luassert.same({"name"}, req)
        end)
    end)
end)

describe("cmdargs rich kinds", function()
    local schema <const>: cmdargs.Schema = {
        args = {
            mode = {enum = {"fast", "slow"}, help = "speed"},
            tags = {kind = "list", help = "names"},
            data = {kind = "table", rest = true, help = "fields"},
            count = {kind = "number", min = 0, max = 10, help = "bounded"},
        },
        positional = {"mode", "count", "data"},
    }
    cmdargs.validate(schema)

    it("enforces enums on both parse paths", function()
        local v = cmdargs.parse(schema, {"fast"})
        luassert.equals("fast", v.mode)
        local _, err = cmdargs.parse(schema, {"turbo"})
        luassert.matches("must be one of fast, slow", err)
        local _, jerr = cmdargs.parseValues(schema, {mode = "turbo"})
        luassert.matches("must be one of", jerr)
    end)

    it("enforces numeric bounds on both parse paths", function()
        luassert.equals(10, (cmdargs.parse(schema, {"fast", "10"})).count)
        local _, err = cmdargs.parse(schema, {"fast", "11"})
        luassert.matches("at most 10", err)
        local _, jerr = cmdargs.parseValues(schema, {count = -1})
        luassert.matches("at least 0", jerr)
    end)

    it("lists split from commas and accept JSON arrays", function()
        local typed = cmdargs.parse(schema, {"fast", "1", "tags=a,b,c"})
        luassert.same({"a", "b", "c"}, typed.tags)
        local viaArray = cmdargs.parseValues(schema, {tags = {"a", "b"}})
        luassert.same({"a", "b"}, viaArray.tags)
        local viaString = cmdargs.parseValues(schema, {tags = "a,b"})
        luassert.same({"a", "b"}, viaString.tags)
        local _, err = cmdargs.parseValues(schema, {tags = {1, 2}})
        luassert.matches("array of strings", err)
    end)

    it("tables stay raw expressions on the line and accept JSON objects", function()
        local typed = cmdargs.parse(schema, {"fast", "1", "{x = 5}"})
        luassert.equals("{x = 5}", typed.data)
        local viaObject = cmdargs.parseValues(schema, {data = {x = 5}})
        luassert.equals(5, (viaObject.data as {string: any}).x)
        local _, err = cmdargs.parseValues(schema, {data = 7})
        luassert.matches("JSON object", err)
    end)

    it("projects the new kinds into the tool schema", function()
        local tool = cmdargs.toolSchema(schema)
        local props = tool.properties as {string: {string: any}}
        luassert.same({"fast", "slow"}, props.mode.enum)
        luassert.equals("array", props.tags.type)
        luassert.equals("object", props.data.type)
        luassert.equals(0, props.count.minimum)
        luassert.equals(10, props.count.maximum)
    end)
end)

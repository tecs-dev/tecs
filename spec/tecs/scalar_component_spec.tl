require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")

describe("scalar components", function()
    it("supports set(entity, component, value) and get(entity, component)", function()
        local Health = tecs.newScalarComponent({
            name = "ScalarSpecHealth",
            kind = "number",
            default = 100,
        })

        local world = tecs.newWorld()
        local e = world:spawn()
        world:commit()

        world:set(e, Health, 42)
        world:commit()

        local v = world:get(e, Health)
        luassert.equals(42, v)
    end)

    it("uses default value when added without explicit scalar payload", function()
        local Ammo = tecs.newScalarComponent({
            name = "ScalarSpecAmmo",
            kind = "number",
            default = 12,
        })

        local world = tecs.newWorld()
        local e = world:spawn()
        world:commit()

        world:set(e, Ammo)
        world:commit()

        luassert.equals(12, world:get(e, Ammo))
    end)

    it("stores scalar values directly in query columns", function()
        local Heat = tecs.newScalarComponent({
            name = "ScalarSpecHeat",
            kind = "number",
            default = 0,
        })

        local world = tecs.newWorld()
        local e = world:spawn()
        world:commit()
        world:set(e, Heat, 7)
        world:commit()

        local q = world:query({ include = {Heat} })
        local saw = false
        for arch, len in q:iter() do
            local col = arch:get(Heat)
            luassert.equals(1, len)
            luassert.equals(7, col[1])
            saw = true
        end
        luassert.is_true(saw)
    end)

    it("uses implicit zero defaults by kind", function()
        local Flag = tecs.newScalarComponent({
            name = "ScalarSpecFlag",
            kind = "boolean",
        })
        local Label = tecs.newScalarComponent({
            name = "ScalarSpecLabel",
            kind = "string",
        })

        local world = tecs.newWorld()
        local e = world:spawn()
        world:commit()

        world:set(e, Flag)
        world:set(e, Label)
        world:commit()

        luassert.equals(false, world:get(e, Flag))
        luassert.equals("", world:get(e, Label))
    end)

    it("supports scalar instances directly in spawn(...)", function()
        local Tag = tecs.newScalarComponent({
            name = "ScalarSpecSpawnTag",
            kind = "string",
        })

        local world = tecs.newWorld()
        local e = world:spawn(Tag("hero"))
        world:commit()

        luassert.equals("hero", world:get(e, Tag))
    end)

    it("supports mixing scalar and table components in spawn(...)", function()
        local Score = tecs.newScalarComponent({
            name = "ScalarSpecSpawnScore",
            kind = "number",
            default = 0,
        })
        local Label = tecs.newScalarComponent({
            name = "ScalarSpecSpawnLabel",
            kind = "string",
        })

        local world = tecs.newWorld()
        local e = world:spawn(
            tecs.builtins.Transform(1, 2),
            Score(99),
            Label("boss")
        )
        world:commit()

        luassert.equals(99, world:get(e, Score))
        luassert.equals("boss", world:get(e, Label))
        local t = world:get(e, tecs.builtins.Transform)
        luassert.equals(1, t.x)
        luassert.equals(2, t.y)
    end)

    it("supports 2-arg set with a scalar instance wrapper", function()
        local Mana = tecs.newScalarComponent({
            name = "ScalarSpecSetMana",
            kind = "number",
            default = 0,
        })

        local world = tecs.newWorld()
        local e = world:spawn()
        world:commit()

        world:set(e, Mana(50))
        world:commit()

        luassert.equals(50, world:get(e, Mana))
    end)

    it("returns the raw scalar value (not a wrapper) from world:get", function()
        local Title = tecs.newScalarComponent({
            name = "ScalarSpecRawGet",
            kind = "string",
        })

        local world = tecs.newWorld()
        local e = world:spawn(Title("Knight"))
        world:commit()

        local v = world:get(e, Title)
        luassert.equals("string", type(v))
        luassert.equals("Knight", v)
    end)

    it("reuses wrapper instances for repeated string values", function()
        local Tag = tecs.newScalarComponent({
            name = "ScalarSpecCache",
            kind = "string",
        })

        local a = Tag("frank")
        local b = Tag("frank")
        luassert.is_true(rawequal(a, b))
    end)

    it("serialize unwraps wrapper instances and raw column reads", function()
        local Title: tecs.ScalarComponent<string> = tecs.newScalarComponent({
            name = "ScalarSpecSerializeShape",
            kind = "string",
        })

        -- Wrapper instance from `__call` must serialize as `{value = "x"}`,
        -- not `{value = {componentType=..., value="x"}}`.
        luassert.same({ value = "Frank" }, Title.serialize(Title("Frank")))

        -- Raw column reads (snapshot writer's path) still produce the same
        -- shape.
        local serializeAny = Title.serialize as function(any): {string:any}
        luassert.same({ value = "Frank" }, serializeAny("Frank"))
    end)

    it("exports as a typed module field without a custom container", function()
        -- Recommended pattern: declare the field type on the owning
        -- module record, assign a cast registration result to it. The
        -- cast is required — Teal does not infer the scalar T from
        -- `default` or `kind` on its own.
        local record fakeModule
            Stamina: tecs.ScalarComponent<number>
            Title: tecs.ScalarComponent<string>
        end

        -- With `default` present, the typed field target binds T directly;
        -- no cast needed.
        fakeModule.Stamina = tecs.newScalarComponent({
            name = "ScalarSpecModuleStamina",
            kind = "number",
            default = 50,
        })
        -- Without `default`, the literal has no T-typed value, so T can't
        -- bind from the target either; cast the result.
        fakeModule.Title = tecs.newScalarComponent({
            name = "ScalarSpecModuleTitle",
            kind = "string",
        }) as tecs.ScalarComponent<string>

        local world = tecs.newWorld()
        local e = world:spawn(fakeModule.Stamina(80), fakeModule.Title("hero"))
        world:commit()

        luassert.equals(80, world:get(e, fakeModule.Stamina))
        luassert.equals("hero", world:get(e, fakeModule.Title))

        -- Default flows through `world:set` 2-arg type-only form.
        local e2 = world:spawn()
        world:commit()
        world:set(e2, fakeModule.Stamina)
        world:commit()
        luassert.equals(50, world:get(e2, fakeModule.Stamina))
    end)

    it("works with builtins.Name as a scalar in spawn", function()
        local world = tecs.newWorld()
        local e = world:spawn(tecs.builtins.Name("Frank"))
        world:commit()

        luassert.equals("Frank", world:get(e, tecs.builtins.Name))
    end)

end)

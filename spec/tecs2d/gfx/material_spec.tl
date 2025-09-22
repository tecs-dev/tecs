require("busted")

-- Set up Love2D mock before requiring anything else
rawset(_G, "love", require("spec.love2d.love2d_mock"))

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local Material <const> = require("tecs2d.gfx.internal.Material")
local registry <const> = require("tecs2d.gfx.internal.material_registry")

-- Paths to test material .glsl files
local TEST_MATERIAL_PATH <const> = "spec/fixtures/test_material.glsl"
local TEST_VERTEX_MATERIAL_PATH <const> = "spec/fixtures/test_vertex_material.glsl"

-- Counter for unique material names across tests
local nameCounter = 0
local function uniqueName(base: string): string
    nameCounter = nameCounter + 1
    return base .. "_" .. tostring(nameCounter)
end

describe("Material", function()
    describe("component creation", function()
        it("creates a Material with default params", function()
            local m = Material(1)
            luassert.equals(1, m.materialId)
            luassert.equals(0, m.p0)
            luassert.equals(0, m.p1)
            luassert.equals(0, m.p2)
            luassert.equals(0, m.p3)
        end)

        it("creates a Material with explicit params", function()
            local m = Material(5, 0.5, 1.0, 2.0, 3.0)
            luassert.equals(5, m.materialId)
            luassert.is_near(0.5, m.p0, 0.001)
            luassert.is_near(1.0, m.p1, 0.001)
            luassert.is_near(2.0, m.p2, 0.001)
            luassert.is_near(3.0, m.p3, 0.001)
        end)

        it("creates a Material with zero materialId", function()
            local m = Material(0)
            luassert.equals(0, m.materialId)
        end)
    end)

    describe("withParams", function()
        it("returns a new Material with same id but different params", function()
            local m = Material(3, 0, 0, 0, 0)
            local m2 = m:withParams(1.0, 2.0, 3.0, 4.0)
            luassert.equals(3, m2.materialId)
            luassert.is_near(1.0, m2.p0, 0.001)
            luassert.is_near(2.0, m2.p1, 0.001)
            luassert.is_near(3.0, m2.p2, 0.001)
            luassert.is_near(4.0, m2.p3, 0.001)
        end)

        it("does not modify the original Material", function()
            local m = Material(3, 0.1, 0.2, 0.3, 0.4)
            local _ = m:withParams(9.0, 8.0, 7.0, 6.0)
            luassert.is_near(0.1, m.p0, 0.001)
            luassert.is_near(0.2, m.p1, 0.001)
            luassert.is_near(0.3, m.p2, 0.001)
            luassert.is_near(0.4, m.p3, 0.001)
        end)

        it("defaults missing params to 0", function()
            local m = Material(1)
            local m2 = m:withParams(5.0)
            luassert.is_near(5.0, m2.p0, 0.001)
            luassert.equals(0, m2.p1)
            luassert.equals(0, m2.p2)
            luassert.equals(0, m2.p3)
        end)
    end)

    describe("ECS integration", function()
        local world: tecs.World

        before_each(function()
            world = tecs.newWorld()
        end)

        after_each(function()
            if world then
                world:shutdown()
            end
        end)

        it("can be spawned on entities", function()
            local m = Material(1, 0.5, 0, 0, 0)
            local e = world:spawn(tecs.builtins.Transform(0, 0), m)
            world:commit()

            local retrieved = world:get(e, Material)
            luassert.is_not_nil(retrieved)
            luassert.equals(1, retrieved.materialId)
            luassert.is_near(0.5, retrieved.p0, 0.001)
        end)

        it("can be added and removed from entities", function()
            local e = world:spawn(tecs.builtins.Transform(0, 0))
            world:commit()

            world:set(e, Material(2, 1.0, 0, 0, 0))
            world:commit()

            local retrieved = world:get(e, Material)
            luassert.is_not_nil(retrieved)
            luassert.equals(2, retrieved.materialId)

            world:remove(e, Material)
            world:commit()

            retrieved = world:get(e, Material)
            luassert.is_nil(retrieved)
        end)
    end)
end)

describe("material_registry", function()
    describe("register", function()
        it("registers a material and returns a Material component", function()
            local name = uniqueName("test_mat")
            local m = registry.register(name, { fragment = TEST_MATERIAL_PATH })
            luassert.is_not_nil(m)
            luassert.is_true(m.materialId > 0)
        end)

        it("assigns sequential IDs", function()
            local name1 = uniqueName("seq")
            local name2 = uniqueName("seq")
            local m1 = registry.register(name1, { fragment = TEST_MATERIAL_PATH })
            local m2 = registry.register(name2, { fragment = TEST_MATERIAL_PATH })
            luassert.equals(m1.materialId + 1, m2.materialId)
        end)

        it("rejects duplicate names", function()
            local name = uniqueName("dup")
            registry.register(name, { fragment = TEST_MATERIAL_PATH })
            luassert.has_error(function()
                registry.register(name, { fragment = TEST_MATERIAL_PATH })
            end)
        end)

        it("rejects missing name", function()
            luassert.has_error(function()
                registry.register(nil as string, { fragment = TEST_MATERIAL_PATH })
            end)
        end)

        it("rejects missing fragment", function()
            luassert.has_error(function()
                registry.register(uniqueName("nofrag"), {} as registry.MaterialOpts)
            end)
        end)

        it("rejects non-existent fragment file", function()
            luassert.has_error(function()
                registry.register(uniqueName("badfile"), { fragment = "nonexistent_file_12345.glsl" })
            end)
        end)

        it("reads fragment source from file", function()
            local name = uniqueName("readsrc")
            registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local def = registry.getByName(name)
            luassert.is_not_nil(def)
            luassert.is_not_nil(def.fragmentSource)
            luassert.is_truthy(def.fragmentSource:find("standardMaterial"))
        end)

        it("accepts inline fragment source", function()
            local name = uniqueName("inlinefrag")
            local src = [[
                MaterialOutput material(MaterialInput i) {
                    MaterialOutput o = standardMaterial(i);
                    o.albedo.rgb = vec3(1.0, 0.0, 0.0);
                    return o;
                }
            ]]
            registry.register(name, { fragment = src })
            local def = registry.getByName(name)
            luassert.is_not_nil(def.fragmentSource)
            luassert.is_truthy(def.fragmentSource:find("standardMaterial"))
            luassert.is_nil(def.fragmentPath)
        end)

        it("accepts inline vertex source", function()
            local name = uniqueName("inlinevert")
            local src = [[
                vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
                    return worldPos + vec2(1.0, 0.0);
                }
            ]]
            registry.register(name, { fragment = TEST_MATERIAL_PATH, vertex = src })
            local def = registry.getByName(name)
            luassert.is_not_nil(def.vertexSource)
            luassert.is_truthy(def.vertexSource:find("materialVertex"))
            luassert.is_nil(def.vertexPath)
        end)

        it("defaults fragment to standardMaterial when only vertex provided", function()
            local name = uniqueName("vertonly")
            registry.register(name, { vertex = TEST_VERTEX_MATERIAL_PATH })
            local def = registry.getByName(name)
            luassert.is_not_nil(def.fragmentSource)
            luassert.is_truthy(def.fragmentSource:find("standardMaterial"))
            luassert.is_not_nil(def.vertexSource)
            luassert.is_nil(def.fragmentPath)
        end)

        it("errors when neither fragment nor vertex provided", function()
            luassert.has_error(function()
                registry.register(uniqueName("empty"), {} as material_registry.MaterialOpts)
            end)
        end)

        it("stores unlit flag", function()
            local name = uniqueName("unlit")
            registry.register(name, { fragment = TEST_MATERIAL_PATH, unlit = true })
            local def = registry.getByName(name)
            luassert.is_true(def.unlit)
        end)

        it("reads vertex source from file", function()
            local name = uniqueName("vertexsrc")
            registry.register(name, {
                fragment = TEST_MATERIAL_PATH,
                vertex = TEST_VERTEX_MATERIAL_PATH,
            })
            local def = registry.getByName(name)
            luassert.is_not_nil(def)
            luassert.is_not_nil(def.vertexSource)
            luassert.is_truthy(def.vertexSource:find("materialVertex"))
        end)

        it("vertex source is nil when not provided", function()
            local name = uniqueName("novertex")
            registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local def = registry.getByName(name)
            luassert.is_nil(def.vertexSource)
        end)

        it("errors on bad vertex file path", function()
            luassert.has_error(function()
                registry.register(uniqueName("badvert"), {
                    fragment = TEST_MATERIAL_PATH,
                    vertex = "nonexistent_vertex_file_12345.glsl",
                })
            end)
        end)

        it("stores texture paths", function()
            local name = uniqueName("textures")
            registry.register(name, {
                fragment = TEST_MATERIAL_PATH,
                textures = { MaterialTex0 = "assets/noise.png" },
            })
            local def = registry.getByName(name)
            luassert.equals("assets/noise.png", def.texturePaths["MaterialTex0"])
        end)
    end)

    describe("lookup", function()
        it("retrieves by ID", function()
            local name = uniqueName("byid")
            local m = registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local def = registry.getById(m.materialId)
            luassert.is_not_nil(def)
            luassert.equals(name, def.name)
        end)

        it("retrieves by name", function()
            local name = uniqueName("byname")
            registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local def = registry.getByName(name)
            luassert.is_not_nil(def)
            luassert.equals(name, def.name)
        end)

        it("returns nil for unknown ID", function()
            local def = registry.getById(999)
            luassert.is_nil(def)
        end)

        it("returns nil for unknown name", function()
            local def = registry.getByName("nonexistent_material_xyz")
            luassert.is_nil(def)
        end)

        it("getAll returns all registered materials", function()
            local all = registry.getAll()
            luassert.is_not_nil(all)
            -- At least the materials registered in earlier tests should be present
            local count = 0
            for _, _ in pairs(all) do
                count = count + 1
            end
            luassert.is_true(count > 0)
        end)
    end)

    describe("variants", function()
        it("returns nil for unset variant", function()
            local name = uniqueName("novariant")
            local m = registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local shader = registry.getVariant(m.materialId, "rectangle")
            luassert.is_nil(shader)
        end)

        it("stores and retrieves variants", function()
            local name = uniqueName("variant")
            local m = registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local mockShader = {} as love.graphics.Shader
            registry.setVariant(m.materialId, "rectangle", mockShader)
            local retrieved = registry.getVariant(m.materialId, "rectangle")
            luassert.equals(mockShader, retrieved)
        end)

        it("stores variants per shape type independently", function()
            local name = uniqueName("multishape")
            local m = registry.register(name, { fragment = TEST_MATERIAL_PATH })
            local shaderRect = {} as love.graphics.Shader
            local shaderCircle = {} as love.graphics.Shader
            registry.setVariant(m.materialId, "rectangle", shaderRect)
            registry.setVariant(m.materialId, "circle", shaderCircle)
            luassert.equals(shaderRect, registry.getVariant(m.materialId, "rectangle"))
            luassert.equals(shaderCircle, registry.getVariant(m.materialId, "circle"))
        end)
    end)
end)

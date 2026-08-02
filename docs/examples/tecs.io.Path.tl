-- Checked examples attached to the tecs.io.Path reference.

-- #region tecs.io.Path.new
local shader <const> = tecs.io.Path.new("assets", "shaders", "sprite.glsl")

assert(shader:fileName() == "sprite.glsl")
-- #endregion tecs.io.Path.new

-- #region tecs.io.Path.join
local assets <const> = tecs.io.Path.new("assets")
local shader <const> = assets:join("shaders", "sprite.glsl")

assert(tostring(assets) == "assets")
assert(shader:toString() == tecs.io.Path.new("assets", "shaders", "sprite.glsl"):toString())
-- #endregion tecs.io.Path.join

-- #region tecs.io.Path.normalize
local configured <const> = tecs.io.Path.new("assets", ".", "shaders", "..", "sprite.glsl")
local normalized <const> = configured:normalize()

assert(normalized == tecs.io.Path.new("assets", "sprite.glsl"))
-- #endregion tecs.io.Path.normalize

-- #region tecs.io.Path.resolve
local output, reason = tecs.io.Path.new("build", "game.pack"):resolve()
if output == nil then
    error(reason)
end

assert(output:isAbsolute())
-- #endregion tecs.io.Path.resolve

-- #region tecs.io.Path.canonicalize
local executable, reason = tecs.io.Path.new("."):canonicalize()
if executable == nil then
    error(reason)
end

print(executable)
-- #endregion tecs.io.Path.canonicalize

-- #region tecs.io.Path.relativeTo
local root <const> = tecs.io.Path.new("assets")
local sprite <const> = root:join("sprites", "hero.png")
local relative, reason = sprite:relativeTo(root)
if relative == nil then
    error(reason)
end

assert(relative == tecs.io.Path.new("sprites", "hero.png"))
-- #endregion tecs.io.Path.relativeTo

-- #region tecs.io.Path.withExtension
local source <const> = tecs.io.Path.new("shaders", "sprite.glsl")
local compiled <const> = source:withExtension("spv")

assert(source:extension() == "glsl")
assert(compiled:fileName() == "sprite.spv")
-- #endregion tecs.io.Path.withExtension

-- #region tecs.io.files.writeAtomic
local save <const> = tecs.io.Path.new(tecs.io.files.writablePath("saves"), "slot1.bin")
local ok, reason = tecs.io.files.writeAtomic(save, "snapshot bytes")
if not ok then
    error(reason)
end
-- #endregion tecs.io.files.writeAtomic

-- #region tecs.io.Process.new
tecs.scoped(
    "inspect repository",
    function(scope: tecs.Scope)
        local child <const> = scope:own(tecs.io.Process.new({
            args = {"git", "status", "--porcelain"},
            cwd = tecs.io.Path.new("workspace"),
        }))

        local result, communicateReason = child:communicate()

        assert(result, communicateReason)
    end
)
-- #endregion tecs.io.Process.new

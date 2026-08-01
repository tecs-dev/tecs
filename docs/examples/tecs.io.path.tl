-- Checked examples attached to the tecs.io.path reference.

-- #region tecs.io.newPath
local shader <const> = tecs.io.newPath("assets", "shaders", "sprite.glsl")

assert(shader:fileName() == "sprite.glsl")
-- #endregion tecs.io.newPath

-- #region tecs.io.path.Path.join
local assets <const> = tecs.io.newPath("assets")
local shader <const> = assets:join("shaders", "sprite.glsl")

assert(tostring(assets) == "assets")
assert(shader:toString() == tecs.io.newPath("assets", "shaders", "sprite.glsl"):toString())
-- #endregion tecs.io.path.Path.join

-- #region tecs.io.path.Path.normalize
local configured <const> = tecs.io.newPath("assets", ".", "shaders", "..", "sprite.glsl")
local normalized <const> = configured:normalize()

assert(normalized == tecs.io.newPath("assets", "sprite.glsl"))
-- #endregion tecs.io.path.Path.normalize

-- #region tecs.io.path.Path.resolve
local output, reason = tecs.io.newPath("build", "game.pack"):resolve()
if output == nil then
    error(reason)
end

assert(output:isAbsolute())
-- #endregion tecs.io.path.Path.resolve

-- #region tecs.io.path.Path.canonicalize
local executable, reason = tecs.io.newPath("."):canonicalize()
if executable == nil then
    error(reason)
end

print(executable)
-- #endregion tecs.io.path.Path.canonicalize

-- #region tecs.io.path.Path.relativeTo
local root <const> = tecs.io.newPath("assets")
local sprite <const> = root:join("sprites", "hero.png")
local relative, reason = sprite:relativeTo(root)
if relative == nil then
    error(reason)
end

assert(relative == tecs.io.newPath("sprites", "hero.png"))
-- #endregion tecs.io.path.Path.relativeTo

-- #region tecs.io.path.Path.withExtension
local source <const> = tecs.io.newPath("shaders", "sprite.glsl")
local compiled <const> = source:withExtension("spv")

assert(source:extension() == "glsl")
assert(compiled:fileName() == "sprite.spv")
-- #endregion tecs.io.path.Path.withExtension

-- #region tecs.io.files.writeAtomic
local save <const> = tecs.io.newPath(tecs.io.files.writablePath("saves"), "slot1.bin")
local ok, reason = tecs.io.files.writeAtomic(save, "snapshot bytes")
if not ok then
    error(reason)
end
-- #endregion tecs.io.files.writeAtomic

-- #region tecs.io.process.new
local child, reason = tecs.io.process.new({
    args = {"git", "status", "--porcelain"},
    cwd = tecs.io.newPath("workspace"),
})
if child == nil then
    error(reason)
end

local result, communicateReason = child:communicate()

assert(result, communicateReason)

child:close()
-- #endregion tecs.io.process.new

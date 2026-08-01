-- #region tecs.io.files.glob
local files <const> = tecs.io.files
tecs.scoped(function(scope: tecs.Scope)
    local stream, reason = files.glob(files.assetPath("levels"), nil, {maxDepth = 2})
    if stream == nil then
        error(reason)
    end
    scope:own(stream)
    while true do
        local entry, nextReason = stream:next()
        if entry == nil then
            if nextReason ~= nil then
                error(nextReason)
            end
            break
        end
        print(entry.depth, entry.path)
        if entry.kind == "directory" and entry.name == "generated" then
            stream:skipDirectory()
        end
    end
end)
-- #endregion tecs.io.files.glob

-- #region tecs.io.files.lines
local files <const> = require("tecs.io.files")
local nextLine <const> = assert(files.lines("save.txt"))

for line in nextLine do
    print(line)
end
-- #endregion tecs.io.files.lines

-- #region tecs.io.files.open
local files <const> = require("tecs.io.files")
local file, reason = files.open("world.pack", "w+")
if file == nil then
    error(reason)
end

local wrote, writeReason = file:write("HEADpayload bytes")
if not wrote then
    file:close()
    error(writeReason)
end
local position, seekReason = file:seek("start")
if position == nil then
    file:close()
    error(seekReason)
end
local header <const> = assert(file:read(4))
assert(header == "HEAD")

local closed, closeReason = file:close()
assert(closed, closeReason)
-- #endregion tecs.io.files.open

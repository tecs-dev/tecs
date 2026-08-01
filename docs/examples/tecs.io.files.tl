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

-- #region tecs.io.files.openWrite
local files <const> = require("tecs.io.files")
local writer <const> = assert(files.openWrite("save.txt", "append"))

assert(writer:write("checkpoint"))
assert(writer:close())
-- #endregion tecs.io.files.openWrite

-- #region tecs.io.files.openSeekableWrite
local writer, reason = tecs.io.files.openSeekableWrite("world.pack")
if writer == nil then
    error(reason)
end

local wrote, writeReason = writer:write("HEADpayload bytes")
if not wrote then
    writer:close()
    error(writeReason)
end
local position, seekReason = writer:seek("start", 0)
if position == nil then
    writer:close()
    error(seekReason)
end
wrote, writeReason = writer:write("PACK")
if not wrote then
    writer:close()
    error(writeReason)
end

local closed, closeReason = writer:close()
if not closed then
    error(closeReason)
end
-- #endregion tecs.io.files.openSeekableWrite

-- #region tecs.io.files.openRead
local files <const> = require("tecs.io.files")
local reader <const> = assert(files.openRead("world.pack"))

assert(reader:seek("start", 4096))
local header <const> = assert(reader:read(32))

print(#header)
reader:close()
-- #endregion tecs.io.files.openRead

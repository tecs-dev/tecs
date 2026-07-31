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

-- #region tecs.io.files.openRead
local files <const> = require("tecs.io.files")
local reader <const> = assert(files.openRead("world.pack"))

assert(reader:seek("start", 4096))
local header <const> = assert(reader:read(32))

print(#header)
reader:close()
-- #endregion tecs.io.files.openRead

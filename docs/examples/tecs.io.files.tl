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

-- Headless LÖVE entry point that boots the embedded, dependency-free Tecs CLI.
_G.TECS_LOVE_CLI = true

package.preload.argparse = function()
    return require("tecs_cli.vendor.argparse")
end
package.preload.lfs = function()
    return require("tecs_cli.vendor.lfs_love")
end

local lfs = require("tecs_cli.vendor.lfs_love")
local cli = require("tecs_cli.cli")

local project
local cliArgs = {}
local i = 2
while i <= #arg do
    if arg[i] == "--tecs-project" then
        i = i + 1
        project = arg[i]
    else
        cliArgs[#cliArgs + 1] = arg[i]
    end
    i = i + 1
end

project = project or love.filesystem.getWorkingDirectory()
local changed, changeErr = lfs.setRoot(project)
if not changed then
    io.stderr:write("tecs: cannot enter project directory: " .. tostring(changeErr) .. "\n")
end

local exitCode = 1
if changed then
    local ok, err = cli.run(cliArgs)
    if ok then
        exitCode = 0
    else
        io.stderr:write("tecs: " .. tostring(err) .. "\n")
    end
end

function love.run()
    return function()
        return exitCode
    end
end

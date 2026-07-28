--- `tecs info`: versions, the pins, the project, and what can be built here.
---
--- Four blocks, and each answers a question a developer actually asks. What
--- version is this. Which type checker and formatter will run, since both are
--- compiled in at a commit and a pin nobody can read is a pin nobody can
--- verify. Whether the working directory is inside a project. And what this
--- machine can package for, with a reason beside every target it cannot,
--- because a reason is what tells someone what to do next.

local tecs <const> = require("tecs")
local layout <const> = require("tecscli.layout")
local project <const> = require("tecscli.project")
local targets <const> = require("tecscli.targets")
local toolchain <const> = require("tecscli.toolchain")

local record report
end

--- The first twelve characters of a commit, which is what a person reads.
local function short(commit: string): string
    if commit == nil or #commit <= 12 then
        return commit or "unknown"
    end
    return commit:sub(1, 12)
end

--- Writes the report.
function report.write(paths: layout, out: function(string))
    out(("tecs %s"):format(tecs.version))
    out(("  binary:    %s"):format(layout.self()))
    out(("  content:   %s"):format(paths.root))
    out(("  types:     %s"):format(paths.teal))
    out("")

    out("pinned toolchain")
    out(("  teal:      %s"):format(short(toolchain.pins.teal)))
    out(("  cerulean:  %s"):format(short(toolchain.pins.cerulean)))
    out("  Both are compiled in at those commits. A formatter resolved at run")
    out("  time can change under you without saying so, and one did.")
    out("")

    local found, reason = project.find()
    out("project")
    if found == nil then
        out(("  none: %s"):format(reason))
        out("  Run `tecs new <directory>` to make one.")
    else
        out(("  name:      %s"):format(found.name))
        out(("  root:      %s"):format(found.root))
        out(("  entry:     %s"):format(found.entry))
        if found.native ~= nil then
            out("  native:    declared; a build needs a C toolchain")
        end
    end
    out("")

    out(("packaging targets, from a %s host"):format(targets.host()))
    for _, target in ipairs(targets.all()) do
        if target.available then
            out(("  %-14s %s"):format(target.name, target.description))
        else
            out(("  %-14s unavailable: %s"):format(target.name, target.reason))
        end
    end
end

return report

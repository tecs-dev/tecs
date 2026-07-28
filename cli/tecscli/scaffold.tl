--- `tecs new`: a working game written out of the binary.
---
--- **Nothing is fetched.** The templates are files inside the installed tree,
--- copied out, so a machine that has just installed `tecs` and has no network
--- can scaffold, check, build and run. That was the previous tool's one rule
--- worth keeping, and it is the reason the binary is as large as it is.
---
--- **A project is not scaffolded inside a project.** An agent asked to create
--- a game inside a generated project should implement in `src/` rather than
--- lay a second template over the first, and the refusal says so rather than
--- saying "exists".
---
--- Two names in the templates are rewritten rather than left as defaults, and
--- both matter for the same reason the previous tool substituted them: the
--- window title is what a player sees, and the identifier is what the save
--- directory is derived from, so two generated games that shared one would
--- overwrite each other's saves.

local files <const> = require("tecscli.files")
local project <const> = require("tecscli.project")

local record scaffold
end

--- Template paths that are written out under a different name.
---
--- All three for the same reason: a dot-prefixed name inside this repository
--- would be read by the tool that owns it here. `.github` would be a workflow
--- this project runs, `.prettierrc` would reformat this tree by the generated
--- project's rules, and `.gitignore` would hide the template tree from `git
--- ls-files`, which is what decides what gets formatted.
local RENAMES <const>: {string: string} = {
    ["gitignore"] = ".gitignore",
    ["github"] = ".github",
    ["prettierrc"] = ".prettierrc",
}

--- Applies the renames to one relative path.
local function destinationOf(relative: string): string
    local parts: {string} = {}
    for part in relative:gmatch("[^/]+") do
        parts[#parts + 1] = RENAMES[part] or part
    end
    return table.concat(parts, "/")
end

--- A safe reverse-DNS identifier from a project name.
local function identifierOf(name: string): string
    local cleaned = name:lower():gsub("[^%w]", "")
    if cleaned == "" then
        cleaned = "game"
    end
    return "com.example." .. cleaned
end

--- Substitutes the project's own names into a template.
local function fill(text: string, name: string): string
    local values <const>: {string: string} = {
        name = name,
        identifier = identifierOf(name),
        title = name,
    }
    return (text:gsub("{{(%w+)}}", function(key: string): string return values[key] or ("{{" .. key .. "}}") end))
end

--- Writes a project into `directory`.
---
--- @param templates Where the template tree is.
--- @return Whether it was written, and the reason it was not.
function scaffold.write(templates: string, directory: string, name: string, force: boolean): boolean, string
    local existing = project.find(directory)
    if existing ~= nil and not force then
        return false, ("%s is already inside the project at %s.\n"):format(directory, existing.root)
            .. "A game is implemented in its src/, not scaffolded a second time inside itself.\n"
            .. "Pass --force if a nested project is really what you want."
    end

    if not files.ensure(directory) then
        return false, ("cannot create %s"):format(directory)
    end

    local written = 0
    for _, relative in ipairs(files.walk(templates)) do
        local target = directory .. "/" .. destinationOf(relative)
        if not force and files.read(target) ~= nil then
            return false, ("%s already exists; pass --force to overwrite"):format(target)
        end
        local body = files.read(templates .. "/" .. relative)
        if body == nil then
            return false, ("cannot read the template %s"):format(relative)
        end
        local ok, reason = files.write(target, fill(body, name))
        if not ok then
            return false, ("cannot write %s: %s"):format(target, reason or "unknown")
        end
        written = written + 1
    end

    if written == 0 then
        return false, ("no templates found at %s"):format(templates)
    end
    return true
end

return scaffold

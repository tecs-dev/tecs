-- Bundled agent guides and offline framework documentation for the Tecs CLI.

local M = {}

function M.new(options)
    local fileSystem = assert(options.fileSystem)
    local isLoveCli = options.isLoveCli
    local loveApi = options.loveApi
    local docs = {}

    function docs.agentDocDescription(content)
        for line in content:gmatch("[^\r\n]+") do
            if not line:match("^#") and line:match("%S") then
                return (line:gsub("^%s+", ""):gsub("%s+$", ""))
            end
        end
        return ""
    end

    function docs.listBundledDocs(subdir, label)
        local bundled = {}
        if isLoveCli and loveApi then
            for _, entry in ipairs(loveApi.filesystem.getDirectoryItems("tecs_cli/" .. subdir)) do
                local name = entry:match("^(.+)%.md$")
                if name then
                    local content, err = loveApi.filesystem.read("tecs_cli/" .. subdir .. "/" .. entry)
                    if not content then
                        error("could not read embedded " .. label .. " " .. entry .. ": " .. tostring(err), 0)
                    end
                    bundled[#bundled + 1] = {name = name, content = content}
                end
            end
        else
            local modulePath = fileSystem.sourcePath()
            local dir = modulePath and fileSystem.pathJoin(fileSystem.dirname(modulePath), subdir)
            if dir and fileSystem.isDir(dir) then
                for _, file in ipairs(fileSystem.walkFiles(dir, {})) do
                    local name = fileSystem.basename(file):match("^(.+)%.md$")
                    if name then
                        local handle = assert(io.open(file, "rb"))
                        local content = handle:read("*a")
                        handle:close()
                        bundled[#bundled + 1] = {name = name, content = content}
                    end
                end
            end
        end
        table.sort(bundled, function(a, b) return a.name < b.name end)
        return bundled
    end

    function docs.listAgentDocs()
        return docs.listBundledDocs("agents", "agent doc")
    end

    function docs.readDocBundle(name)
        if isLoveCli and loveApi then
            local content, err = loveApi.filesystem.read("tecs_cli/docs/" .. name)
            if not content then
                error("could not read bundled doc " .. name .. ": " .. tostring(err), 0)
            end
            return content
        end
        local modulePath = fileSystem.sourcePath()
        local path = modulePath and fileSystem.pathJoin(fileSystem.dirname(modulePath), "docs", name)
        local handle = path and io.open(path, "rb")
        if not handle then
            error("docs bundle missing; run `scripts/gen-docs-bundle.sh` (needs a Tecs checkout and Node)", 0)
        end
        local content = handle:read("*a")
        handle:close()
        return content
    end

    function docs.docPagesByUrl(full)
        local marks = {}
        local init = 1
        while true do
            local startAt, endAt, url = full:find("\n?%-%-%-\nurl:%s*([^\n]+)\n", init)
            if not startAt then break end
            marks[#marks + 1] = {start = startAt, url = (url:gsub("%s+$", ""))}
            init = endAt + 1
        end
        local pages = {}
        for i = 1, #marks do
            local stop = (marks[i + 1] and marks[i + 1].start - 1) or #full
            pages[marks[i].url] = (full:sub(marks[i].start, stop):gsub("^\n", ""))
        end
        return pages
    end

    return docs
end

return M

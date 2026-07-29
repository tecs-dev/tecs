--- Types for the generated `tecscli/toolchain.lua`.
---
--- The module itself is written by the Cargo build from the formatter and
--- revision tables it owns. There is no `.tl` for it because there is no
--- separate source for it. This declares its shape so everything reading it
--- is checked.

local record toolchain
    --- What gets formatted and by what, as the Cargo build describes it.
    record Format
        --- Path prefixes nothing formats.
        excluded: {string}
        --- What a generated file says about itself in its opening lines.
        generatedMarkers: {string}
        --- How many lines are read looking for one.
        generatedScanLines: integer
        --- File suffix to language key.
        suffixes: {string: string}
        --- Exact file name to language key, for the ones with no suffix.
        names: {string: string}
        --- Language key to how it is formatted.
        tools: {string: Tool}
    end

    --- One language's formatter.
    record Tool
        --- The program, named separately so a missing one reports as itself.
        tool: string
        --- Argument vector that formats in place.
        apply: {string}
        --- Argument vector that reports and writes nothing.
        check: {string}
        --- Lua module the CLI runs in process instead, where there is one.
        module: string
    end

    --- The revisions this binary carries.
    record Pins
        teal: string
        cerulean: string
    end

    format: Format
    pins: Pins
end

return toolchain

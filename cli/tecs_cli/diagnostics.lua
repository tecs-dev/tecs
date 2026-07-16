-- Check diagnostics for the Tecs CLI: collection from the Teal compiler
-- (syntax/type/warning classification, stable ordering) and remediation hints
-- that attach a known fix to a diagnostic at the moment of the error. The
-- same diagnostics flow through `tecs check --json` and the MCP `check` tool.

local M = {}

function M.new(options)
    local withTealEnv = options.withTealEnv
    local luaModulePath = options.luaModulePath

    -- Love2D events are re-exported from tecs2d as TYPES; passing one as a value
    -- (e.g. world:observe(0, tecs2d.MousePressed, ...)) fails to type-check. Used to
    -- attach a remediation hint to exactly that diagnostic.
    local EVENT_EXPORTS = {
        Quit = true, KeyPressed = true, KeyReleased = true, MousePressed = true,
        MouseReleased = true, MouseMoved = true, WheelMoved = true,
        JoystickAdded = true, JoystickRemoved = true, DirectoryDropped = true,
        FileDropped = true, Focus = true, MouseFocus = true, Resize = true,
        Visible = true, Exposed = true, Occluded = true, LocaleChanged = true,
        ThemeChanged = true, DropBegan = true, DropMoved = true, DropCompleted = true,
        AudioDisconnected = true, SensorUpdated = true, JoystickSensorUpdated = true,
        TouchPressed = true, TouchMoved = true, TouchReleased = true,
    }

    local function nthLine(path, n)
        local file = io.open(path, "rb")
        if not file then return nil end
        local i = 0
        for text in file:lines() do
            i = i + 1
            if i == n then file:close(); return text end
        end
        file:close()
        return nil
    end

    -- Framework aliases that are directly usable as `tecs api` module addresses.
    local API_HINT_MODULES = {
        tecs = true, tecs2d = true, gfx = true, input = true, events = true,
    }

    -- Primitive type names that never resolve to an API symbol, so an invalid-key
    -- diagnostic against one gets no `tecs api` hint.
    local API_HINT_PRIMITIVES = {
        number = true, integer = true, string = true, boolean = true, table = true,
        thread = true, userdata = true, ["function"] = true, ["nil"] = true,
        any = true, nominal = true,
    }

    -- Derive a `tecs api` address from the target of a failing call, or nil when
    -- the target does not look like a framework or project symbol (locals, Lua
    -- stdlib). `receiver:method` is already an api address; `world.getMut` becomes
    -- the method form; a known module alias keeps its dotted address; otherwise a
    -- capitalized name (a constructor like Health or gfx.Rectangle's last segment)
    -- resolves as a bare symbol, project tier first.
    local function apiAddressForCall(target)
        if target:find(":", 1, true) then return target end
        local first, rest = target:match("^([%a_][%w_]*)%.([%w_%.]+)$")
        if first then
            if first == "world" and not rest:find(".", 1, true) then
                return "world:" .. rest
            end
            if API_HINT_MODULES[first] then return target end
            local last = rest:match("([%w_]+)$")
            if last and last:match("^%u") then return last end
            return nil
        end
        if target:match("^%u") then return target end
        return nil
    end

    -- Derive a `tecs api` address from a type name in a Teal error message.
    local function apiAddressForType(typeName)
        local last = typeName:match("([%w_]+)$")
        if not last or API_HINT_PRIMITIVES[last:lower()] then return nil end
        return last
    end

    -- The call expression a diagnostic points into: the identifier chain of the
    -- call starting closest to (at or before) the diagnostic column, falling back
    -- to the line's first call.
    local function callTargetAt(lineText, column)
        local best
        local init = 1
        while true do
            local s, e, name = lineText:find("([%a_][%w_%.:]*)%s*%(", init)
            if not s then break end
            if not best or s <= column then best = name end
            init = e + 1
        end
        return best
    end

    -- Attach {hint, docs} remediation to diagnostics whose fix is well known, so an
    -- agent gets a fix at the moment of the error instead of only if it pre-read the
    -- right page. The same diagnostics flow through the MCP `check` tool, so this
    -- covers CLI and MCP agents. Matchers must be zero-false-positive: match the
    -- exact message and verify the offending source token.
    local function attachRemediation(diagnostics)
        for _, d in ipairs(diagnostics) do
            if d.kind == "type"
                and d.message:find("type definition as a concrete value", 1, true) then
                local line = nthLine(d.file, d.line)
                local event = line and line:match("tecs2d%.(%u[%w]*)")
                if event and EVENT_EXPORTS[event] then
                    d.hint = "Love2D events are exported as types; pass the value: "
                        .. 'local events = require("tecs2d.events") -- then events.'
                        .. event .. " as the observe argument."
                    d.docs = "tecs2d/events"
                end
            end

            -- Unknown field or method: the message names the record type, which is
            -- exactly what `tecs api` renders. Anchored patterns keep this off
            -- structural types (maps, generics), whose names would not resolve.
            if not d.hint and d.kind == "type" then
                local key, typeName =
                    d.message:match("^invalid key '([%w_]+)' in .- type ([%w_%.]+)$")
                if not key then
                    key, typeName =
                        d.message:match("^cannot index key '([%w_]+)' in .- type ([%w_%.]+)$")
                end
                local addr = typeName and apiAddressForType(typeName)
                if key and addr then
                    d.hint = "'" .. key .. "' does not exist on " .. typeName
                        .. ". Run `tecs api " .. addr
                        .. "` (CLI or the MCP api tool) for its real fields and signatures."
                end
            end

            -- Indexing with a non-integer number: the fix is always the same on
            -- the LuaJIT/5.1 target (no // operator), so say it outright.
            if not d.hint and d.kind == "type"
                and (d.message:match("^cannot index object of type .* with number$")
                    or d.message:match("^wrong index type: got number, expected integer$")) then
                d.hint = "Lua array indexes must be integers and this target has no `//`: "
                    .. "wrap the index expression in math.floor(...)."
            end

            -- Bare "syntax error" pointing into `local x: Type<T> <const>`: Teal
            -- cannot parse an attribute after a generic annotation, and the bare
            -- message sends readers to the wrong construct. Name the fix.
            if not d.hint and d.kind == "syntax" and d.message == "syntax error" then
                local line = nthLine(d.file, d.line)
                if line and line:match("^%s*local%s+[%w_]+%s*:%s*[%w_%.]+%s*%b<>%s*<%s*const%s*>") then
                    d.hint = "Teal cannot parse `<const>` after a generic type annotation. "
                        .. "Drop the annotation and cast the value instead: "
                        .. "`local KEY <const> = tecs.newKey(\"name\") as tecs.Key<T>`."
                end
            end

            -- Wrong arity or argument type: the message does not name the callee,
            -- so read it off the offending source line and point `tecs api` at it.
            if not d.hint and d.kind == "type"
                and (d.message:match("^wrong number of arguments %(given ")
                    or d.message:match("^argument %d+: ")) then
                local line = nthLine(d.file, d.line)
                local target = line and callTargetAt(line, d.column)
                local addr = target and apiAddressForCall(target)
                if addr then
                    d.hint = "Verify the exact signature: `tecs api " .. addr
                        .. "` (CLI or the MCP api tool)."
                end
            end
        end
    end

    -- Type-check sources through the Teal compiler API and return ok plus a flat
    -- diagnostic list, instead of tlcli's human-readable report. Mirrors tlcli's
    -- rules: syntax errors suppress a file's other diagnostics, disabled warnings
    -- are dropped, and warnings promoted by warning_error fail the check.
    local function collectCheckDiagnostics(sources)
        local diagnostics = {}
        local checkOk = true

        local function add(err, severity, diagKind)
            diagnostics[#diagnostics + 1] = {
                file = luaModulePath(err.filename or ""),
                line = tonumber(err.y) or 0,
                column = tonumber(err.x) or 0,
                severity = severity,
                kind = diagKind,
                message = err.msg or "",
            }
            if err.tag then
                diagnostics[#diagnostics].tag = err.tag
            end
        end

        local code = withTealEnv(function()
            local configuration = require("tlcli.configuration")
            local driver = require("tlcli.driver")
            local tlconfig = configuration.get()
            configuration.merge_config_and_args(tlconfig, {include_dir = {}})
            local compiler = driver.setup_compiler(tlconfig)

            for _, source in ipairs(sources) do
                local _, _, err = driver.process_module(compiler, source)
                if err then
                    checkOk = false
                    add({filename = source, msg = err}, "error", "load")
                end
            end

            for name in compiler:loaded_files() do
                local _, errs = compiler:recall(name)
                if errs then
                    if errs.syntax_errors and #errs.syntax_errors > 0 then
                        checkOk = false
                        for _, err in ipairs(errs.syntax_errors) do
                            add(err, "error", "syntax")
                        end
                    else
                        for _, err in ipairs(errs.type_errors or {}) do
                            checkOk = false
                            add(err, "error", "type")
                        end
                        for _, warning in ipairs(errs.warnings or {}) do
                            if not tlconfig._disabled_warnings_set[warning.tag] then
                                if tlconfig._warning_errors_set[warning.tag] then
                                    checkOk = false
                                    add(warning, "error", "type")
                                else
                                    add(warning, "warning", "warning")
                                end
                            end
                        end
                    end
                end
            end
        end)
        if code ~= 0 then
            error("Teal failed with exit code " .. tostring(code), 0)
        end

        attachRemediation(diagnostics)
        table.sort(diagnostics, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            if a.line ~= b.line then return a.line < b.line end
            if a.column ~= b.column then return a.column < b.column end
            return a.message < b.message
        end)
        return checkOk, diagnostics
    end

    return {
        attachRemediation = attachRemediation,
        collectCheckDiagnostics = collectCheckDiagnostics,
    }
end

return M

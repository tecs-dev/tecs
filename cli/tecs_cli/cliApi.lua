-- API index generation, symbol resolution, and rendering for the Tecs CLI.

local M = {}

function M.new(options)
    local VERSION = options.version
    local isLoveCli = options.isLoveCli
    local loveApi = options.loveApi
    local tecsDir = options.tecsDir
    local userDataDir = options.userDataDir
    local loadTealApi = options.loadTealApi
    local ensureVendor = options.ensureVendor
    local jsonModule = options.jsonModule
    local pathJoin = options.pathJoin
    local dirname = options.dirname
    local sourcePath = options.sourcePath
    local isDir = options.isDir
    local exists = options.exists
    local fileMtime = options.fileMtime
    local luaModulePath = options.luaModulePath
    local listTealSources = options.listTealSources
    local listFiles = options.listFiles
    local normalize = options.normalize
    local remove = options.remove
    local mkdir = options.mkdir
    local copyDir = options.copyDir
    local copyLoveDir = options.copyLoveDir
    local vendorLua = options.vendorLua

    --------------------------------------------------------------------------------
    -- `tecs api`: symbol lookup over a type index.
    --
    -- Two tiers, merged at query time:
    --   * the framework tier -- generated at runtime by running the bundled apidocs
    --     extractor over the framework's public modules (staged by ensureVendor,
    --     exactly like `check`), then cached at the user level keyed by the CLI
    --     version (api-framework-index-<VERSION>.json). A cache hit is instant with
    --     no type-check; nothing is committed or bundled as a prebuilt index.
    --   * a dynamic project overlay -- the same extractor run over the project's own
    --     src/, cached under build/api-index.json keyed by the Teal source mtimes
    --     and rebuilt when stale. Degrades gracefully: an unrelated type error never
    --     fails a lookup.
    --
    -- Both tiers need no build and no running game. The same core backs the CLI
    -- command and the MCP `api` tool (buildMcpContext exposes apiInvoke as ctx.api);
    -- there is one resolver, one renderer.
    --------------------------------------------------------------------------------

    -- The framework's public modules, as apidocs specs. `file` is src-relative; the
    -- runtime generator remaps it onto the vendored framework tree (or the Tecs
    -- checkout in source mode). The extractor documents each module's full public
    -- surface and derives per-type method receivers.
    local FRAMEWORK_API_MODULES = {
        { module = "tecs",          file = "src/tecs/init.tl",      prefix = "tecs." },
        { module = "tecs.types",    file = "src/tecs/types.tl" },
        -- The public require path is tecs.builtins (re-exported from init.tl);
        -- the extractor needs the defining file. Transform is the first component
        -- every agent looks up, so this module must resolve.
        { module = "tecs.builtins", file = "src/tecs/internal/builtins.tl" },
        { module = "tecs2d",        file = "src/tecs2d/init.tl",    prefix = "tecs2d." },
        { module = "tecs2d.gfx",    file = "src/tecs2d/gfx/init.tl", prefix = "gfx." },
        { module = "tecs2d.input",  file = "src/tecs2d/input.tl",   prefix = "input." },
        { module = "tecs2d.events", file = "src/tecs2d/events.tl",  prefix = "events." },
    }

    -- Load the bundled apidocs extractor (tecs_cli/apidocs.lua). Requires the Teal
    -- compiler modules, so loadTealApi() runs first to put them on the search path.
    local apidocsModule
    local function loadApidocs()
        if apidocsModule then return apidocsModule end
        loadTealApi()
        local chunk
        if isLoveCli and loveApi then
            local src = loveApi.filesystem.read("tecs_cli/apidocs.lua")
            if not src then error("bundled apidocs.lua missing from payload", 0) end
            chunk = assert(loadstring(src, "@tecs_cli/apidocs.lua"))
        else
            local modulePath = sourcePath()
            local p = modulePath and pathJoin(dirname(modulePath), "apidocs.lua")
            local fh = p and io.open(normalize(p), "rb")
            if not fh then
                error("tecs_cli/apidocs.lua not found next to cli.lua", 0)
            end
            local src = fh:read("*a"); fh:close()
            chunk = assert(loadstring(src, "@" .. luaModulePath(p)))
        end
        apidocsModule = chunk()
        return apidocsModule
    end

    -- Stage the framework sources and type declarations into a scratch tree under
    -- the user data dir. Used when `tecs api` runs outside a project, so a
    -- framework-tier build never writes src/vendor into an arbitrary cwd.
    local function stageFrameworkScratch()
        local root = pathJoin(userDataDir(), "api-framework-src")
        -- Start clean so files deleted from a newer framework never linger.
        remove(root)
        mkdir(root)
        if tecsDir then
            copyDir(pathJoin(tecsDir, "src/tecs"), pathJoin(root, "tecs"))
            copyDir(pathJoin(tecsDir, "src/tecs2d"), pathJoin(root, "tecs2d"))
        else
            copyLoveDir("payload/framework/tecs", pathJoin(root, "tecs"))
            copyLoveDir("payload/framework/tecs2d", pathJoin(root, "tecs2d"))
        end
        copyLoveDir("payload/types", root)
        return root
    end

    -- The root under which the framework's Teal sources live. Inside a project the
    -- vendored tree staged by ensureVendor is reused (exactly as `check` does);
    -- outside one the payload is staged under the user data dir instead. nil when
    -- neither the payload nor a Tecs checkout is available.
    local function apiFrameworkRoot()
        if isLoveCli then
            if exists("tlconfig.lua") then
                ensureVendor()
                return vendorLua
            end
            return stageFrameworkScratch()
        elseif tecsDir then
            return pathJoin(tecsDir, "src")
        end
        return nil
    end

    -- Package.path roots that make the framework and its type declarations
    -- resolvable while the extractor type-checks a module set. `frameworkRoot` is
    -- wherever apiFrameworkRoot found (or staged) the framework; a source checkout
    -- additionally needs the CLI's own runtime type declarations.
    local function apiSearchRoots(frameworkRoot)
        local roots = {}
        if frameworkRoot then roots[#roots + 1] = frameworkRoot end
        if not isLoveCli then
            local modulePath = sourcePath()
            if modulePath then
                local rt = pathJoin(dirname(modulePath), "runtime/types")
                if isDir(rt) then roots[#roots + 1] = rt end
            end
        end
        return roots
    end

    -- Run the vendored extractor over `specs` with the framework rooted at
    -- `frameworkRoot` on the search path. Shared by the framework tier and the
    -- project overlay.
    local function buildApiIndex(specs, frameworkRoot)
        local apidocs = loadApidocs()
        local roots = apiSearchRoots(frameworkRoot)

        local templates = { "src/?.lua", "src/?/init.lua" }
        for _, root in ipairs(roots) do
            local base = luaModulePath(root)
            templates[#templates + 1] = base .. "/?.lua"
            templates[#templates + 1] = base .. "/?/init.lua"
            templates[#templates + 1] = base .. "/?.tl"
            templates[#templates + 1] = base .. "/?/init.tl"
        end

        local previousPath = package.path
        package.path = table.concat(templates, ";") .. ";" .. previousPath
        local ok, result = pcall(function()
            return apidocs.build_index({ modules = specs, tolerant = true })
        end)
        package.path = previousPath
        if not ok then error(result, 0) end
        return result
    end

    -- Framework module specs with `file` remapped onto `root`.
    local function frameworkModuleSpecs(root)
        local specs = {}
        for _, m in ipairs(FRAMEWORK_API_MODULES) do
            local rel = m.file:gsub("^src/", "")
            specs[#specs + 1] = { module = m.module, prefix = m.prefix,
                file = pathJoin(root, rel) }
        end
        return specs
    end

    -- Every buildable project module as an apidocs spec: module name derived from
    -- the path under src/ (foo/init.tl -> "foo", bar/baz.tl -> "bar.baz").
    local function projectModuleSpecs()
        local specs = {}
        for _, src in ipairs(listTealSources()) do
            local n = normalize(src)
            local rel = n:gsub("^src[/\\]", ""):gsub("%.tl$", "")
            rel = rel:gsub("[/\\]init$", "")
            local module = rel:gsub("[/\\]", ".")
            if module ~= "" then
                specs[#specs + 1] = { module = module, file = n }
            end
        end
        return specs
    end

    -- Run the extractor over the project. Returns the structured overlay index.
    -- Only called inside a project, where the project's own vendored tree (staged
    -- by ensureVendor, and also carrying any extra rocks the project vendored) is
    -- the right resolver root for its sources.
    local function buildProjectOverlay()
        local root
        if isLoveCli then
            ensureVendor()
            root = vendorLua
        elseif tecsDir then
            root = pathJoin(tecsDir, "src")
        end
        return buildApiIndex(projectModuleSpecs(), root)
    end

    -- With a local framework checkout (TECS_DIR) the framework sources can change
    -- without the CLI version changing, so the framework cache is additionally
    -- keyed by their paths + mtimes. nil for the payload framework, which is
    -- invariant per CLI version.
    local function frameworkSourceSignature()
        if not tecsDir then return nil end
        local parts = {}
        for _, f in ipairs(listFiles(pathJoin(tecsDir, "src"), ".tl")) do
            local n = normalize(f)
            parts[#parts + 1] = n .. ":" .. tostring(fileMtime(n))
        end
        table.sort(parts)
        return table.concat(parts, ";")
    end

    -- The runtime framework tier: served from a user-level cache keyed by the CLI
    -- version (plus the checkout signature under TECS_DIR), or generated
    -- (type-checked once) and cached on a miss. Returns the index and an optional
    -- note (set when generation failed or was incomplete).
    local function frameworkApiIndex()
        local cachePath = pathJoin(userDataDir(), "api-framework-index-" .. VERSION .. ".json")
        local sig = frameworkSourceSignature()

        local fh = io.open(normalize(cachePath), "rb")
        if fh then
            local data = fh:read("*a"); fh:close()
            local ok, parsed = pcall(jsonModule().parse, data)
            if ok and type(parsed) == "table" and type(parsed.symbols) == "table"
                and type(parsed.modules) == "table" and parsed.signature == sig then
                return parsed, nil
            end
        end

        local ok, index = pcall(function()
            local root = apiFrameworkRoot()
            if not root then
                error("framework sources unavailable (set TECS_DIR or run through the launcher)", 0)
            end
            return buildApiIndex(frameworkModuleSpecs(root), root)
        end)
        if not ok then
            return { symbols = {}, modules = {} },
                "framework API index unavailable (" .. tostring(index) .. ")"
        end

        -- A framework module failing to extract is a packaging (or checkout) bug:
        -- serve what resolved, say so, and skip the cache so a fixed framework is
        -- picked up on the next run.
        if index.errors and #index.errors > 0 then
            return index, "framework API index incomplete ("
                .. index.errors[1].module .. ": " .. tostring(index.errors[1].error) .. ")"
        end

        pcall(function()
            mkdir(dirname(cachePath))
            local out = io.open(normalize(cachePath), "wb")
            if out then
                out:write(jsonModule().serialize({
                    symbols = index.symbols, modules = index.modules, signature = sig,
                }))
                out:close()
            end
        end)
        return index, nil
    end

    -- A signature of the project's Teal source set (paths + mtimes) so the overlay
    -- cache invalidates when any source changes.
    local function projectSourceSignature()
        local parts = {}
        for _, src in ipairs(listTealSources()) do
            local n = normalize(src)
            parts[#parts + 1] = n .. ":" .. tostring(fileMtime(n))
        end
        table.sort(parts)
        return table.concat(parts, ";")
    end

    -- The user-facing caveat when some project modules were skipped. Extraction
    -- only fails on syntax errors or a crashed check -- plain type errors do not
    -- block a module's symbols -- so this fires for genuinely unreadable modules.
    local function overlayDegradedNote(overlay)
        if overlay.errors and #overlay.errors > 0 then
            return "some project modules could not be analyzed; their symbols may be missing"
        end
        return nil
    end

    -- Read the cached overlay if fresh, else rebuild and cache. Returns the overlay
    -- index and an optional note (set when the build failed or was degraded, on
    -- cache hits too, so a lookup still serves the framework tier).
    local function cachedProjectOverlay()
        local cachePath = pathJoin("build", "api-index.json")
        local sig = projectSourceSignature()

        local fh = io.open(normalize(cachePath), "rb")
        if fh then
            local data = fh:read("*a"); fh:close()
            local ok, parsed = pcall(jsonModule().parse, data)
            if ok and type(parsed) == "table" and parsed.signature == sig
                and type(parsed.index) == "table" then
                return parsed.index, overlayDegradedNote(parsed.index)
            end
        end

        local ok, overlay = pcall(buildProjectOverlay)
        if not ok then
            return { symbols = {}, modules = {} },
                "project overlay unavailable (" .. tostring(overlay)
                    .. "); serving the framework tier only"
        end

        pcall(function()
            mkdir(dirname(cachePath))
            local out = io.open(normalize(cachePath), "wb")
            if out then
                out:write(jsonModule().serialize({ signature = sig, index = overlay }))
                out:close()
            end
        end)

        return overlay, overlayDegradedNote(overlay)
    end

    -- Merge the framework tier (base) with the project overlay. The overlay adds
    -- and overrides by (module, symbol). Returns the merged index, an optional
    -- note, and the framework/project module-name sets (for grouped listing).
    local function mergedApiIndex()
        local base, baseNote = frameworkApiIndex()
        local frameworkMods = {}
        for m in pairs(base.modules or {}) do frameworkMods[m] = true end

        local overlay, overlayNote
        if exists("tlconfig.lua") and isDir("src") then
            overlay, overlayNote = cachedProjectOverlay()
        end
        local notes = {}
        if baseNote then notes[#notes + 1] = baseNote end
        if overlayNote then notes[#notes + 1] = overlayNote end
        local note = #notes > 0 and table.concat(notes, "; ") or nil

        -- Project symbols come first so a bare-name lookup that matches both tiers
        -- resolves to the project's own symbol; the first entry per (module,
        -- symbol) key wins, which also lets the overlay override the base.
        local symbols = {}
        local byKey = {}
        local function add(sym)
            local key = sym.module .. "\0" .. sym.symbol
            if not byKey[key] then
                byKey[key] = true
                symbols[#symbols + 1] = sym
            end
        end

        local modules = {}
        for m, names in pairs(base.modules or {}) do modules[m] = names end

        local projectMods = {}
        if overlay then
            for _, s in ipairs(overlay.symbols or {}) do add(s) end
            for m, names in pairs(overlay.modules or {}) do
                modules[m] = names
                if not frameworkMods[m] then projectMods[m] = true end
            end
        end
        for _, s in ipairs(base.symbols or {}) do add(s) end

        return { symbols = symbols, modules = modules }, note, frameworkMods, projectMods
    end

    ----------------------------------------------------------------------
    -- Resolution
    ----------------------------------------------------------------------

    local function apiFindSymbol(index, moduleName, symbolName)
        for _, s in ipairs(index.symbols) do
            if s.module == moduleName and s.symbol == symbolName then return s end
        end
        return nil
    end

    -- Resolve a module name or short alias (last dotted segment) to its canonical
    -- name. Returns the name, or nil (with a list of ambiguous matches when a short
    -- alias is shared by more than one module).
    local function apiResolveModule(index, name)
        if index.modules[name] then return name end
        local matches = {}
        for m in pairs(index.modules) do
            if m:match("[^.]+$") == name then matches[#matches + 1] = m end
        end
        if #matches == 1 then return matches[1] end
        return nil, matches
    end

    -- Symbols matching a bare name, by symbol name or record receiver (so `world`
    -- finds the World record whose receiver is "world"). Case-insensitive fallback.
    local function apiFindByName(index, name)
        local exact, ci = {}, {}
        local lname = name:lower()
        for _, s in ipairs(index.symbols) do
            if s.symbol == name or s.receiver == name then
                exact[#exact + 1] = s
            elseif s.symbol:lower() == lname or (s.receiver and s.receiver:lower() == lname) then
                ci[#ci + 1] = s
            end
        end
        if #exact > 0 then return exact end
        return ci
    end

    local function apiFindMethod(sym, method)
        for _, m in ipairs(sym.methods or {}) do
            if m.name == method then return m end
        end
        return nil
    end

    -- Levenshtein distance, for did-you-mean ranking.
    local function apiEditDistance(a, b)
        local la, lb = #a, #b
        if la == 0 then return lb end
        if lb == 0 then return la end
        local prev, cur = {}, {}
        for j = 0, lb do prev[j] = j end
        for i = 1, la do
            cur[0] = i
            local ai = a:byte(i)
            for j = 1, lb do
                local cost = (ai == b:byte(j)) and 0 or 1
                local del, ins, sub = prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost
                local m = del < ins and del or ins
                cur[j] = m < sub and m or sub
            end
            for j = 0, lb do prev[j] = cur[j] end
        end
        return prev[lb]
    end

    -- Up to three closest candidates to `target`, ranked by edit distance. A
    -- candidate is a plain string, or {name, display} to match on `name` but
    -- report `display` -- a fully addressable form like `tecs2d.gfx.Rectangle` or
    -- `world:getMut`, so a suggestion can be reused verbatim as the next query.
    local function apiSuggest(target, candidates)
        local scored = {}
        local lt = target:lower()
        for _, c in ipairs(candidates) do
            local name = type(c) == "table" and c.name or c
            local display = type(c) == "table" and c.display or c
            scored[#scored + 1] = { display = display, d = apiEditDistance(lt, name:lower()) }
        end
        table.sort(scored, function(x, y)
            if x.d ~= y.d then return x.d < y.d end
            return x.display < y.display
        end)
        local out, seen = {}, {}
        local limit = #target + 2
        for _, s in ipairs(scored) do
            if #out >= 3 or s.d > limit then break end
            if not seen[s.display] then
                seen[s.display] = true
                out[#out + 1] = s.display
            end
        end
        return out
    end

    local function apiModuleSymbolNames(index, moduleName)
        return index.modules[moduleName] or {}
    end

    -- Every symbol as a did-you-mean candidate, module-qualified for display.
    local function apiSymbolCandidates(index)
        local out = {}
        for _, s in ipairs(index.symbols) do
            out[#out + 1] = { name = s.symbol, display = s.module .. "." .. s.symbol }
        end
        return out
    end

    -- A known module's symbols as candidates, module-qualified for display.
    local function apiModuleSymbolCandidates(index, moduleName)
        local out = {}
        for _, n in ipairs(apiModuleSymbolNames(index, moduleName)) do
            out[#out + 1] = { name = n, display = moduleName .. "." .. n }
        end
        return out
    end

    -- True when two symbols with the same bare name are the same underlying API --
    -- a re-export (tecs2d.TouchPressed vs tecs2d.events.TouchPressed) rather than a
    -- genuine name collision. Compares structure, never module, so only real
    -- alternatives are reported as `also matches`.
    local function apiSameSymbol(a, b)
        if a.kind ~= b.kind then return false end
        if a.kind == "function" then
            local ap, bp = a.params or {}, b.params or {}
            if #ap ~= #bp then return false end
            for i = 1, #ap do
                if ap[i].type ~= bp[i].type
                    or (ap[i].optional and true or false) ~= (bp[i].optional and true or false)
                    or (ap[i].vararg and true or false) ~= (bp[i].vararg and true or false) then
                    return false
                end
            end
            local ar, br = a.returns or {}, b.returns or {}
            if #ar ~= #br then return false end
            for i = 1, #ar do
                if ar[i] ~= br[i] then return false end
            end
            return true
        end
        if a.kind == "type" then
            -- signature is "<prefix><name>: <type>"; compare the type part so the
            -- module prefix does not make re-exports look different.
            local at = (a.signature or ""):match("^[^:]*:%s*(.*)$")
            local bt = (b.signature or ""):match("^[^:]*:%s*(.*)$")
            return at ~= nil and at == bt
        end
        -- record/component: fields, methods, and constructor must all agree.
        local af, bf = a.fields or {}, b.fields or {}
        if #af ~= #bf then return false end
        for i = 1, #af do
            if af[i].name ~= bf[i].name or af[i].type ~= bf[i].type then return false end
        end
        local am, bm = a.methods or {}, b.methods or {}
        if #am ~= #bm then return false end
        for i = 1, #am do
            if am[i].signature ~= bm[i].signature then return false end
        end
        local ac, bc = a.constructor, b.constructor
        if (ac == nil) ~= (bc == nil) then return false end
        if ac and ac.signature ~= bc.signature then return false end
        return true
    end

    -- Kind bucket for a resolved top-level symbol.
    local function apiSymbolKind(sym)
        if sym.kind == "function" then return "function" end
        if sym.kind == "type" then return "value" end
        return "type"
    end

    -- Resolve one query string to a descriptor:
    --   {kind="module", module=}
    --   {kind="type"|"value"|"function", symrec=}
    --   {kind="method", symrec=, methodrec=}
    -- or a miss {miss=true, message=, suggestions={}}.
    local function apiResolveQuery(index, query)
        local left, method = query:match("^([^:]+):(.+)$")
        if not left then left = query end

        if method then
            -- Left names a type (module.Type, or a bare type/receiver).
            local sym
            local modPart, symPart = left:match("^(.+)%.([^.]+)$")
            if modPart then
                local mod = apiResolveModule(index, modPart)
                if mod then sym = apiFindSymbol(index, mod, symPart) end
            end
            if not sym then
                local matches = apiFindByName(index, left)
                for _, s in ipairs(matches) do
                    if s.methods and #s.methods > 0 then sym = s; break end
                end
                sym = sym or matches[1]
                -- Prefer the defining (deepest) module among re-exports of the
                -- same type, e.g. tecs.types.World over the tecs re-export.
                for _, s in ipairs(matches) do
                    if sym and s ~= sym and apiSameSymbol(sym, s)
                        and #s.module > #sym.module then
                        sym = s
                    end
                end
            end
            if not sym then
                return { miss = true, message = "no type '" .. left .. "'",
                    suggestions = apiSuggest(left, apiSymbolCandidates(index)) }
            end
            local m = apiFindMethod(sym, method)
            if not m then
                local names = {}
                local rcv = sym.receiver or sym.symbol
                for _, mm in ipairs(sym.methods or {}) do
                    names[#names + 1] = { name = mm.name, display = rcv .. ":" .. mm.name }
                end
                return { miss = true,
                    message = "no method '" .. method .. "' on " .. sym.symbol,
                    suggestions = apiSuggest(method, names) }
            end
            return { kind = "method", symrec = sym, methodrec = m }
        end

        -- No method. A full module name (e.g. `tecs.types`, `tecs2d.gfx`) wins over
        -- a module.Type split, so it lists the module rather than looking for a
        -- symbol named after its last segment.
        local wholeMod = apiResolveModule(index, left)
        if wholeMod then return { kind = "module", module = wholeMod } end

        -- Otherwise treat a dotted address as module.Type.
        local modPart, symPart = left:match("^(.+)%.([^.]+)$")
        if modPart then
            local mod = apiResolveModule(index, modPart)
            if mod then
                local sym = apiFindSymbol(index, mod, symPart)
                if sym then return { kind = apiSymbolKind(sym), symrec = sym } end
                return { miss = true,
                    message = "no symbol '" .. symPart .. "' in " .. mod,
                    suggestions = apiSuggest(symPart, apiModuleSymbolCandidates(index, mod)) }
            end
        end

        -- Dotted address reaching INTO a record: module.Record.Member
        -- (tecs.phases.Startup). Resolve everything before the last dot as a
        -- symbol address, then answer from that record's nested types/fields.
        if modPart then
            local parent
            local pmod, psym = modPart:match("^(.+)%.([^.]+)$")
            if pmod then
                local mod = apiResolveModule(index, pmod)
                if mod then parent = apiFindSymbol(index, mod, psym) end
            end
            if not parent then
                local matches = apiFindByName(index, modPart)
                parent = matches[1]
                for i = 2, #matches do
                    if parent and apiSameSymbol(parent, matches[i])
                        and #matches[i].module > #parent.module then
                        parent = matches[i]
                    end
                end
            end
            if parent then
                for _, t in ipairs(parent.types or {}) do
                    if t.name == symPart then
                        return { kind = "member", symrec = parent, memberrec = t,
                            memberkind = "type" }
                    end
                end
                for _, f in ipairs(parent.fields or {}) do
                    if f.name == symPart then
                        return { kind = "member", symrec = parent, memberrec = f,
                            memberkind = "field" }
                    end
                end
            end
        end

        -- Bare symbol. Project symbols order first in the merged index, so a name
        -- the framework also uses resolves to the project's own symbol; genuinely
        -- different alternatives (not same-type re-exports) are reported alongside
        -- the hit as `also`.
        local matches = apiFindByName(index, left)
        if #matches >= 1 then
            local primary = matches[1]
            local also = {}
            for i = 2, #matches do
                if apiSameSymbol(primary, matches[i]) then
                    -- Same API through a re-export: report the defining (deepest)
                    -- module as the canonical address, e.g. tecs2d.events over the
                    -- tecs2d aggregate.
                    if #matches[i].module > #primary.module then primary = matches[i] end
                else
                    also[#also + 1] = matches[i].module .. "." .. matches[i].symbol
                end
            end
            local res = { kind = apiSymbolKind(primary), symrec = primary }
            if #also > 0 then res.also = also end
            return res
        end

        local pool = apiSymbolCandidates(index)
        for m in pairs(index.modules) do pool[#pool + 1] = m end
        return { miss = true, message = "no symbol or module '" .. left .. "'",
            suggestions = apiSuggest(left, pool) }
    end

    ----------------------------------------------------------------------
    -- Rendering (Teal-style text)
    ----------------------------------------------------------------------

    local function apiHasField(fields, name)
        if not fields then return true end
        for _, f in ipairs(fields) do if f == name then return true end end
        return false
    end

    -- Render function(params): returns from structured params/returns arrays.
    local function apiRenderFnType(params, returns)
        local ps = {}
        for _, p in ipairs(params or {}) do
            if p.vararg then
                ps[#ps + 1] = "...: " .. p.type
            else
                ps[#ps + 1] = p.type .. (p.optional and "?" or "")
            end
        end
        local body = "function(" .. table.concat(ps, ", ") .. ")"
        local rs = returns or {}
        if #rs == 1 then
            body = body .. ": " .. rs[1]
        elseif #rs > 1 then
            body = body .. ": (" .. table.concat(rs, ", ") .. ")"
        end
        return body
    end

    local function apiSeeLine(sym)
        if not sym.see or #sym.see == 0 then return nil end
        return "see: " .. table.concat(sym.see, ", ")
    end

    -- Projected (non-full) render of a type: emit only the requested parts, as
    -- plain lines (no `record ... end` wrapper), so `--fields signature` prints just
    -- the signature and `--fields methods` prints just the method list.
    local function apiRenderTypeProjected(sym, fields)
        local out = {}
        if apiHasField(fields, "signature") then
            out[#out + 1] = sym.signature
        end
        if apiHasField(fields, "fields") then
            for _, f in ipairs(sym.fields or {}) do
                local line = f.name .. ": " .. f.type
                if f.doc then line = line .. "  -- " .. f.doc end
                out[#out + 1] = line
            end
        end
        if apiHasField(fields, "types") then
            for _, t in ipairs(sym.types or {}) do
                local line = "type " .. t.name .. ": " .. t.type
                if t.doc then line = line .. "  -- " .. t.doc end
                out[#out + 1] = line
            end
        end
        if apiHasField(fields, "constructor") and sym.constructor then
            out[#out + 1] = "metamethod __call: "
                .. apiRenderFnType(sym.constructor.params, sym.constructor.returns)
        end
        if apiHasField(fields, "methods") then
            for _, m in ipairs(sym.methods or {}) do
                out[#out + 1] = m.name .. ": " .. apiRenderFnType(m.params, m.returns)
            end
        end
        if apiHasField(fields, "doc") and sym.doc then
            out[#out + 1] = sym.doc
        end
        if apiHasField(fields, "see") then
            local see = apiSeeLine(sym)
            if see then out[#out + 1] = see end
        end
        return table.concat(out, "\n")
    end

    local function apiRenderTypeBlock(sym, fields)
        if fields then
            return apiRenderTypeProjected(sym, fields)
        end

        local out = {}
        out[#out + 1] = "record " .. sym.symbol
        for _, t in ipairs(sym.types or {}) do
            local line = "  type " .. t.name .. ": " .. t.type
            if t.doc then line = line .. "  -- " .. t.doc end
            out[#out + 1] = line
        end
        for _, f in ipairs(sym.fields or {}) do
            local line = "  " .. f.name .. ": " .. f.type
            if f.doc then line = line .. "  -- " .. f.doc end
            out[#out + 1] = line
        end
        if sym.constructor then
            out[#out + 1] = "  metamethod __call: "
                .. apiRenderFnType(sym.constructor.params, sym.constructor.returns)
        end
        for _, m in ipairs(sym.methods or {}) do
            out[#out + 1] = "  " .. m.name .. ": " .. apiRenderFnType(m.params, m.returns)
        end
        out[#out + 1] = "end"

        if sym.doc then
            out[#out + 1] = ""
            out[#out + 1] = sym.doc
        end
        local see = apiSeeLine(sym)
        if see then out[#out + 1] = ""; out[#out + 1] = see end
        return table.concat(out, "\n")
    end

    local function apiRenderCallable(sym, fields)
        local out = {}
        if fields == nil or apiHasField(fields, "signature") then
            out[#out + 1] = sym.signature
        end
        if fields and apiHasField(fields, "params") then
            for _, p in ipairs(sym.params or {}) do
                out[#out + 1] = "param: " .. p.type .. (p.optional and " (optional)" or "")
            end
        end
        if fields and apiHasField(fields, "returns") and sym.returns and #sym.returns > 0 then
            out[#out + 1] = "returns: " .. table.concat(sym.returns, ", ")
        end
        if (fields == nil or apiHasField(fields, "doc")) and sym.doc then
            out[#out + 1] = ""
            out[#out + 1] = sym.doc
        end
        if fields == nil or apiHasField(fields, "see") then
            local see = apiSeeLine(sym)
            if see then out[#out + 1] = ""; out[#out + 1] = see end
        end
        return table.concat(out, "\n")
    end

    local function apiRenderMethod(m, fields)
        local out = {}
        if fields == nil or apiHasField(fields, "signature") then
            out[#out + 1] = m.signature
        end
        if fields and apiHasField(fields, "params") then
            for _, p in ipairs(m.params or {}) do
                out[#out + 1] = "param: " .. p.type .. (p.optional and " (optional)" or "")
            end
        end
        if fields and apiHasField(fields, "returns") and m.returns and #m.returns > 0 then
            out[#out + 1] = "returns: " .. table.concat(m.returns, ", ")
        end
        if (fields == nil or apiHasField(fields, "doc")) and m.doc then
            out[#out + 1] = ""
            out[#out + 1] = m.doc
        end
        return table.concat(out, "\n")
    end

    local function apiRenderModuleSymbols(index, moduleName)
        local rows = {}
        local width = 0
        for _, s in ipairs(index.symbols) do
            if s.module == moduleName then
                width = math.max(width, #s.symbol)
            end
        end
        for _, s in ipairs(index.symbols) do
            if s.module == moduleName then
                rows[#rows + 1] = string.format("  %-" .. width .. "s  %-9s %s",
                    s.symbol, s.kind, s.signature)
            end
        end
        table.sort(rows)
        local out = { moduleName, "" }
        for _, r in ipairs(rows) do out[#out + 1] = r end
        return table.concat(out, "\n")
    end

    local function apiSortedKeys(set)
        local names = {}
        for m in pairs(set) do names[#names + 1] = m end
        table.sort(names)
        return names
    end

    local function apiRenderModuleList(index, frameworkMods, projectMods, note)
        local out = {}
        if note then out[#out + 1] = "note: " .. note; out[#out + 1] = "" end

        out[#out + 1] = "Framework modules:"
        for _, m in ipairs(apiSortedKeys(frameworkMods)) do
            out[#out + 1] = "  " .. m
        end

        local projList = {}
        for _, m in ipairs(apiSortedKeys(projectMods)) do
            if #apiModuleSymbolNames(index, m) > 0 then projList[#projList + 1] = m end
        end
        if #projList > 0 then
            out[#out + 1] = ""
            out[#out + 1] = "Project modules:"
            for _, m in ipairs(projList) do out[#out + 1] = "  " .. m end
        end

        out[#out + 1] = ""
        out[#out + 1] = "Use `tecs api <module>` to list a module's symbols, "
            .. "`tecs api <module>.<Type>` for a type."
        return table.concat(out, "\n")
    end

    local function apiRenderMiss(query, res)
        local out = { "no match for '" .. query .. "'" }
        if res.message then out[1] = res.message end
        if res.suggestions and #res.suggestions > 0 then
            out[#out + 1] = "did you mean: " .. table.concat(res.suggestions, ", ") .. "?"
        end
        return table.concat(out, "\n")
    end

    ----------------------------------------------------------------------
    -- Structured projection (for --json)
    ----------------------------------------------------------------------

    -- Copy `record` (all keys, or just `fields`) into a fresh table the callers
    -- can annotate (note, also) without mutating the in-memory index. Identity
    -- keys are always kept so a projected result stays addressable.
    local function apiProjectKeys(record, fields)
        local out = {}
        if fields then
            for _, f in ipairs(fields) do
                if record[f] ~= nil then out[f] = record[f] end
            end
            out.symbol = record.symbol
            out.module = record.module
            out.type = record.type
            out.name = record.name
        else
            for k, v in pairs(record) do out[k] = v end
        end
        return out
    end

    local function apiResultJson(index, res, fields)
        if res.kind == "module" then
            return { module = res.module, symbols = apiModuleSymbolNames(index, res.module) }
        elseif res.kind == "method" then
            local m = res.methodrec
            local rec = {
                module = res.symrec.module,
                type = res.symrec.symbol,
                name = m.name,
                signature = m.signature,
                params = m.params,
                returns = m.returns,
                doc = m.doc,
                see = m.see,
            }
            return apiProjectKeys(rec, fields)
        elseif res.kind == "member" then
            local m = res.memberrec
            return apiProjectKeys({
                module = res.symrec.module,
                parent = res.symrec.symbol,
                name = m.name,
                type = m.type,
                doc = m.doc,
                memberkind = res.memberkind,
            }, fields)
        end
        return apiProjectKeys(res.symrec, fields)
    end

    -- The canonical module-qualified address of a resolved symbol or method,
    -- usable verbatim as a `tecs api` query.
    local function apiCanonicalAddress(res)
        local addr = res.symrec.module .. "." .. res.symrec.symbol
        if res.kind == "method" then
            return addr .. ":" .. res.methodrec.name
        elseif res.kind == "member" then
            return addr .. "." .. res.memberrec.name
        end
        return addr
    end

    local function apiResultText(index, res, fields)
        if res.kind == "module" then
            return apiRenderModuleSymbols(index, res.module)
        end
        -- Every hit opens with its canonical address, so a bare-name lookup always
        -- shows which module answered.
        local body
        if res.kind == "method" then
            body = apiRenderMethod(res.methodrec, fields)
        elseif res.kind == "type" then
            body = apiRenderTypeBlock(res.symrec, fields)
        elseif res.kind == "member" then
            local m = res.memberrec
            local line = (res.memberkind == "type" and "type " or "")
                .. m.name .. ": " .. m.type
            if m.doc then line = line .. "  -- " .. m.doc end
            body = line .. "\nnested in: tecs api "
                .. res.symrec.module .. "." .. res.symrec.symbol
        else
            body = apiRenderCallable(res.symrec, fields)
        end
        return "-- " .. apiCanonicalAddress(res) .. "\n" .. body
    end

    -- The shared core. params: {query?, queries?, json?, fields?}. Returns
    --   {ok=bool, text=string, json=<lua value>}
    -- text is rendered Teal; json is the structured payload (both honor `fields`).
    -- Never raises for a miss; a miss sets ok=false and reports suggestions.
    local function apiInvoke(params)
        params = params or {}
        local index, note, frameworkMods, projectMods = mergedApiIndex()
        local fields = params.fields
        if fields and #fields == 0 then fields = nil end

        local queries = params.queries
        local single = false
        if not queries then
            if params.query and params.query ~= "" then
                queries = { params.query }
                single = true
            else
                queries = {}
            end
        end

        -- Module listing (no query).
        if #queries == 0 then
            return {
                ok = true,
                text = apiRenderModuleList(index, frameworkMods, projectMods, note),
                json = { modules = index.modules, note = note },
            }
        end

        -- Surface an overlay note (build failed, or some project modules did not
        -- type-check) on symbol lookups too, not just the bare module list, so an
        -- agent learns the project overlay is degraded even on a hit or a miss.
        local function noteText(text)
            if note and note ~= "" then return "note: " .. note .. "\n\n" .. text end
            return text
        end

        -- Rendered hit plus any shadowed alternatives from a bare-name lookup.
        local function hitText(item)
            local text = apiResultText(index, item.res, fields)
            if item.res.also and #item.res.also > 0 then
                text = text .. "\n\nalso matches: " .. table.concat(item.res.also, ", ")
            end
            return text
        end

        local resolved = {}
        local allOk = true
        for _, qy in ipairs(queries) do
            local r = apiResolveQuery(index, qy)
            resolved[#resolved + 1] = { query = qy, res = r }
            if r.miss then allOk = false end
        end

        if single then
            local item = resolved[1]
            if item.res.miss then
                return {
                    ok = false,
                    text = noteText(apiRenderMiss(item.query, item.res)),
                    json = { query = item.query, ok = false,
                        error = item.res.message, suggestions = item.res.suggestions,
                        note = note },
                }
            end
            local json = apiResultJson(index, item.res, fields)
            json.also = item.res.also
            if note then json.note = note end
            return {
                ok = true,
                text = noteText(hitText(item)),
                json = json,
            }
        end

        -- Batch: one entry per query, never short-circuiting on a miss.
        local textParts, jsonArr = {}, {}
        for _, item in ipairs(resolved) do
            if item.res.miss then
                textParts[#textParts + 1] = "# " .. item.query .. "\n"
                    .. apiRenderMiss(item.query, item.res)
                jsonArr[#jsonArr + 1] = { query = item.query, ok = false,
                    error = item.res.message, suggestions = item.res.suggestions }
            else
                textParts[#textParts + 1] = "# " .. item.query .. "\n" .. hitText(item)
                jsonArr[#jsonArr + 1] = { query = item.query, ok = true,
                    also = item.res.also,
                    result = apiResultJson(index, item.res, fields) }
            end
        end
        return {
            ok = allOk,
            text = noteText(table.concat(textParts, "\n\n")),
            json = { results = jsonArr, note = note },
        }
    end


    return {
        invoke = apiInvoke,
    }
end

return M

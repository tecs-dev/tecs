--- Structural snapshot diff for the debugger's `diff` command. Compares two
--- snapshot tables (the JSON-compatible `saveSnapshot({format = "table"})`
--- form) normalized by entity id and component name, so archetype order and
--- column indices can never produce false differences.
---
--- Output is RFC 6902-flavored: add/remove/replace operations with JSON
--- Pointer paths (~0/~1 escaped; integer keys emit 0-based indices so
--- pointers read naturally against the JSON artifact). The comparison is
--- read-only; it never touches a live world.

local json <const> = require("tecs.utils.json")

local record diff
    record Options
        -- nil = all entities; otherwise only these ids.
        entityFilter: {integer: boolean}
        -- nil = all components; otherwise exactly this one.
        component: string
        -- Component names excluded from the comparison.
        ignore: {string: boolean}
        -- Absolute tolerance for numeric leaf comparisons (0 = exact).
        epsilon: number
        -- Max detailed changes returned; 0 = summary only. Summary counts
        -- always cover the complete diff.
        limit: integer
    end

    --- Flatten a snapshot table's archetype frames into
    --- {entityId: {componentName: value}} plus a meta table (nextEntityId,
    --- stateStack). Column indices resolve through the snapshot's component
    --- table, so snapshots with different archetype layouts normalize
    --- identically. Tag components and serialize holes normalize to `true`
    --- so presence still diffs.
    normalize: function(snap: {string: any}): {integer: {string: any}}, {string: any}

    --- Compare two normalized sides across metadata, entity presence, and
    --- component fields. Component fields produce recursive RFC 6902-style
    --- operations. Changes sort by scope, entity, component, and path; the
    --- summary always covers the complete diff even when `limit` truncates
    --- the detailed list. Returns summary, changes, totalChanges, and
    --- truncated fields ready for JSON.
    compare: function(fromEntities: {integer: {string: any}}, fromMeta: {string: any},
        toEntities: {integer: {string: any}}, toMeta: {string: any},
        opts: Options): {string: any}

end

-- RFC 6901 escaping: ~ becomes ~0 and / becomes ~1.
local function escapeSegment(seg: string): string
    return (seg:gsub("~", "~0"):gsub("/", "~1"))
end

-- Path segment for a table key: integer keys emit 0-based indices so the
-- pointer matches the JSON artifact's arrays.
local function keySegment(k: any): string
    if type(k) == "number" and math.floor(k as number) == k and (k as number) >= 1 then
        return tostring((k as number) - 1)
    end
    return escapeSegment(tostring(k))
end

function diff.normalize(snap: {string: any}): {integer: {string: any}}, {string: any}
    local names: {integer: string} = {}
    local compTable = snap.componentTable as {any}
    for i = 1, #compTable do
        names[i] = (compTable[i] as {string: any}).name as string
    end
    local entities: {integer: {string: any}} = {}
    local archetypes = snap.archetypes as {any}
    for a = 1, #archetypes do
        local arch = archetypes[a] as {string: any}
        local cols = arch.columnIndices as {integer}
        local rows = arch.entities as {{any}}
        for r = 1, #rows do
            local row = rows[r]
            local id = row[1] as integer
            local comps: {string: any} = {}
            for c = 1, #cols do
                local v = row[c + 1]
                if v == nil then v = true end
                comps[names[cols[c]]] = v
            end
            entities[id] = comps
        end
    end
    local meta: {string: any} = {nextEntityId = snap.nextEntityId}
    local data = snap.data as {any}
    local customData = false
    for i = 1, (data and #data or 0) do
        local entry = data[i] as {string: any}
        local key = entry.key as string
        if key == "__tecs.stateStack" then
            meta.stateStack = entry.value
        elseif key ~= "__tecs.pipeline" then
            -- Custom snapshot-handler data cannot survive a scratch-world
            -- round trip symmetrically; the comparison skips it.
            customData = true
        end
    end
    meta.hasCustomData = customData
    return entities, meta
end

local function isNum(v: any): boolean
    return type(v) == "number"
end

-- json.NULL and json.EMPTY_OBJECT are empty sentinel tables; recursing into
-- them erases kind changes (null vs {} vs []).
local function isEmptyContainer(v: any): boolean
    return type(v) == "table" and v ~= json.NULL and next(v as {any: any}) == nil
end

-- The union of both tables' keys in a deterministic order, so change lists
-- are stable across runs and comparable between calls.
local function sortedKeys(a: {any: any}, b: {any: any}): {any}
    local seen: {any: boolean} = {}
    local keys: {any} = {}
    for k in pairs(a or {}) do
        seen[k] = true
        keys[#keys + 1] = k
    end
    for k in pairs(b or {}) do
        if not seen[k] then keys[#keys + 1] = k end
    end
    table.sort(keys, function(x: any, y: any): boolean
        return tostring(x) < tostring(y)
    end)
    return keys
end

function diff.compare(fromEntities: {integer: {string: any}}, fromMeta: {string: any},
        toEntities: {integer: {string: any}}, toMeta: {string: any},
        opts: diff.Options): {string: any}
    local epsilon = opts.epsilon or 0
    local ignore = opts.ignore or {}
    local changes: {{string: any}} = {}
    local byComponent: {string: {string: integer}} = {}
    local entitiesAdded, entitiesRemoved = 0, 0

    local function bump(comp: string, kind: string)
        local c = byComponent[comp]
        if not c then
            c = {}
            byComponent[comp] = c
        end
        c[kind] = (c[kind] or 0) + 1
    end

    -- Entity-level payloads honor the same filters as field diffs.
    local function filteredComponents(comps: {string: any}): {string: any}
        if opts.component then
            return {[opts.component] = comps[opts.component]}
        end
        if next(ignore) == nil then return comps end
        local out: {string: any} = {}
        for name, v in pairs(comps) do
            if not ignore[name] then out[name] = v end
        end
        return out
    end

    local function leafEqual(a: any, b: any): boolean
        if a == b then return true end
        if epsilon > 0 and isNum(a) and isNum(b) then
            return math.abs((a as number) - (b as number)) <= epsilon
        end
        return false
    end

    local function push(change: {string: any})
        changes[#changes + 1] = change
    end

    -- Recursive field diff of one component present on both sides.
    local function diffValue(entity: integer, comp: string, path: string, before: any, after: any)
        if before == after then return end
        -- null vs any container is a kind change, and two empty containers
        -- (object or array, indistinguishable in Lua) are equal.
        if before == json.NULL or after == json.NULL then
            bump(comp, "changed")
            push({operation = "replace", entity = entity, component = comp,
                path = path, before = before, after = after})
            return
        end
        if isEmptyContainer(before) and isEmptyContainer(after) then return end
        if type(before) == "table" and type(after) == "table" then
            local keys = sortedKeys(before as {any: any}, after as {any: any})
            for i = 1, #keys do
                local k = keys[i]
                local bv = (before as {any: any})[k]
                local av = (after as {any: any})[k]
                local p = path .. "/" .. keySegment(k)
                if bv == nil then
                    bump(comp, "changed")
                    push({operation = "add", entity = entity, component = comp,
                        path = p, after = av})
                elseif av == nil then
                    bump(comp, "changed")
                    push({operation = "remove", entity = entity, component = comp,
                        path = p, before = bv})
                else
                    diffValue(entity, comp, p, bv, av)
                end
            end
            return
        end
        if not leafEqual(before, after) then
            bump(comp, "changed")
            push({operation = "replace", entity = entity, component = comp,
                path = path, before = before, after = after})
        end
    end

    -- Meta scope. Entity and component filters ask about specific data, so
    -- world-level meta changes are excluded under them.
    local stateChanges: {string: integer} = nil
    if not opts.entityFilter and not opts.component then
        if not leafEqual(fromMeta.nextEntityId, toMeta.nextEntityId) then
            push({operation = "replace", path = "/nextEntityId",
                before = fromMeta.nextEntityId, after = toMeta.nextEntityId})
        end
        diffValue(nil, "__stateStack", "/stateStack",
            fromMeta.stateStack, toMeta.stateStack)
        -- State-stack field counts should not pollute the component summary.
        stateChanges = byComponent["__stateStack"]
        byComponent["__stateStack"] = nil
    end

    -- Entity scope: union of ids, filtered.
    local ids: {integer} = {}
    do
        local seen: {integer: boolean} = {}
        for id in pairs(fromEntities) do
            seen[id] = true
            ids[#ids + 1] = id
        end
        for id in pairs(toEntities) do
            if not seen[id] then ids[#ids + 1] = id end
        end
        table.sort(ids)
    end

    for i = 1, #ids do
        local id = ids[i]
        if not opts.entityFilter or opts.entityFilter[id] then
            local ea = fromEntities[id]
            local eb = toEntities[id]
            if ea and not eb then
                if not opts.component or ea[opts.component] ~= nil then
                    entitiesRemoved = entitiesRemoved + 1
                    push({operation = "remove", entity = id, path = "",
                        before = filteredComponents(ea)})
                end
            elseif eb and not ea then
                if not opts.component or eb[opts.component] ~= nil then
                    entitiesAdded = entitiesAdded + 1
                    push({operation = "add", entity = id, path = "",
                        after = filteredComponents(eb)})
                end
            else
                local comps = sortedKeys(ea as {any: any}, eb as {any: any})
                for c = 1, #comps do
                    local comp = comps[c] as string
                    if not ignore[comp]
                        and (not opts.component or comp == opts.component) then
                        local va = ea[comp]
                        local vb = eb[comp]
                        if va == nil then
                            bump(comp, "added")
                            push({operation = "add", entity = id, component = comp,
                                path = "", after = vb})
                        elseif vb == nil then
                            bump(comp, "removed")
                            push({operation = "remove", entity = id, component = comp,
                                path = "", before = va})
                        else
                            diffValue(id, comp, "", va, vb)
                        end
                    end
                end
            end
        end
    end

    -- Deterministic order: meta first, then entity-level, then per-component
    -- changes, by entity id, component name, and path.
    local function rank(ch: {string: any}): integer
        if ch.entity == nil then return 0 end
        if ch.component == nil then return 1 end
        return 2
    end
    table.sort(changes, function(a: {string: any}, b: {string: any}): boolean
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        local ea = (a.entity as integer) or -1
        local eb = (b.entity as integer) or -1
        if ea ~= eb then return ea < eb end
        local ca = (a.component as string) or ""
        local cb = (b.component as string) or ""
        if ca ~= cb then return ca < cb end
        return (a.path as string) < (b.path as string)
    end)

    local total = #changes
    local limit = opts.limit or 100
    local limited: {{string: any}} = {}
    for i = 1, math.min(total, limit) do
        limited[i] = changes[i]
    end

    local skipped: {string} = {}
    if fromMeta.hasCustomData or toMeta.hasCustomData then
        skipped[#skipped + 1] = "custom snapshot data (not decodable from binary refs)"
    end

    return {
        summary = {
            entitiesAdded = entitiesAdded,
            entitiesRemoved = entitiesRemoved,
            byComponent = byComponent,
            stateStackChanges = stateChanges and (stateChanges.changed or 0) or 0,
        },
        changes = limited,
        totalChanges = total,
        truncated = total > #limited,
        skipped = (#skipped > 0) and skipped or nil,
    }
end

return diff

--- Compiled debugger breakpoints over committed entity/archetype and
--- state-stack transitions. A manager installs the world's cold transition
--- observer only while at least one breakpoint is enabled.

local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")
local componentregistry <const> = require("tecs.internal.components")
local suspension <const> = require("tecs2d.internal.suspension")

local type Component = tecs.Component
local type Archetype = internal.ArchetypeInternal

local record breakpoints
    record Term
        key: string
        values: {string}
        components: {Component}
    end

    record Branch
        terms: {Term}
        stateTransition: boolean
        explicitEntityEvent: boolean
    end

    record Selector
        source: string
        branches: {Branch}
    end

    record Breakpoint
        id: integer
        source: string
        selector: Selector
        enabled: boolean
        hits: integer
    end

    record Trigger
        breakpointId: integer
        selector: string
        entity: integer
        description: string
    end

    record Manager
        world: tecs.World
        controller: suspension.Controller
        entries: {Breakpoint}
        byId: {integer: Breakpoint}
        nextId: integer
        pending: Trigger
        observer: internal.TransitionObserver

        add: function(self: Manager, source: string): Breakpoint, string
        remove: function(self: Manager, id: integer): boolean
        clear: function(self: Manager): integer
        setEnabled: function(self: Manager, id: integer,
            enabled: boolean): boolean
        list: function(self: Manager): {Breakpoint}
        consume: function(self: Manager): Trigger
        detach: function(self: Manager)
    end

    KEY: tecs.Key<Manager>
    parse: function(source: string): Selector, string
    new: function(world: tecs.World,
        controller: suspension.Controller): Manager
    completionCandidates: function(world: tecs.World): {string}
end

breakpoints.KEY = tecs.newKey("tecs2d.debug.breakpoints")

local VALID_KEYS <const>: {string: boolean} = {
    has = true,
    lacks = true,
    added = true,
    removed = true,
    life = true,
    state = true,
    pushed = true,
    popped = true,
}

local COMPONENT_KEYS <const>: {string: boolean} = {
    has = true,
    lacks = true,
    added = true,
    removed = true,
}

local ENTITY_KEYS <const>: {string: boolean} = {
    has = true,
    lacks = true,
    added = true,
    removed = true,
    life = true,
}

local EVENT_KEYS <const>: {string: boolean} = {
    added = true,
    removed = true,
    life = true,
}

local STATE_EVENT_KEYS <const>: {string: boolean} = {
    pushed = true,
    popped = true,
}

local function trim(value: string): string
    return value:match("^%s*(.-)%s*$")
end

local function scan(source: string): {string}, string
    local out: {string} = {}
    local current: {string} = {}
    local quoted = false
    local escaped = false
    local i = 1
    local function flush()
        if #current > 0 then
            out[#out + 1] = table.concat(current)
            current = {}
        end
    end
    while i <= #source do
        local ch = source:sub(i, i)
        local nextCh = source:sub(i + 1, i + 1)
        if escaped then
            current[#current + 1] = ch
            escaped = false
        elseif quoted and ch == "\\" then
            escaped = true
            current[#current + 1] = ch
        elseif ch == '"' then
            quoted = not quoted
            current[#current + 1] = ch
        elseif not quoted and ch == "|" and nextCh == "|" then
            flush()
            out[#out + 1] = "||"
            i = i + 1
        elseif not quoted and ch:match("%s") then
            flush()
        else
            current[#current + 1] = ch
        end
        i = i + 1
    end
    if quoted then return nil, "unterminated quoted value" end
    flush()
    return out, nil
end

local function splitValues(value: string): {string}, string
    local out: {string} = {}
    local start = 1
    local quoted = false
    local escaped = false
    for i = 1, #value do
        local ch = value:sub(i, i)
        if escaped then
            escaped = false
        elseif quoted and ch == "\\" then
            escaped = true
        elseif ch == '"' then
            quoted = not quoted
        elseif not quoted and ch == "|" then
            out[#out + 1] = value:sub(start, i - 1)
            start = i + 1
        end
    end
    out[#out + 1] = value:sub(start)

    for i = 1, #out do
        local item = trim(out[i])
        if item:sub(1, 1) == '"' then
            if item:sub(-1) ~= '"' or #item < 2 then
                return nil, "malformed quoted value"
            end
            item = item:sub(2, -2)
            item = item:gsub('\\"', '"'):gsub("\\\\", "\\")
        elseif item:find('"', 1, true) then
            return nil, "quotes must surround the whole value"
        end
        if item == "" then return nil, "empty alternative" end
        out[i] = item
    end
    return out, nil
end

local function compileTerm(token: string): breakpoints.Term, string
    local key, raw = token:match("^([%a][%w]*)=(.+)$")
    if not key then
        return nil, "expected key=value, got '" .. token .. "'"
    end
    if not VALID_KEYS[key] then
        return nil, "unknown selector key '" .. key .. "'"
    end
    local values, err = splitValues(raw)
    if not values then return nil, err end
    local term: breakpoints.Term = {
        key = key,
        values = values,
        components = nil,
    }
    if COMPONENT_KEYS[key] then
        term.components = {}
        for i = 1, #values do
            local component = componentregistry.registeredComponents[values[i]]
            if not component then
                return nil, "unknown component '" .. values[i] .. "'"
            end
            term.components[i] = component
        end
    elseif key == "life" then
        for i = 1, #values do
            if values[i] ~= "spawn" and values[i] ~= "despawn" then
                return nil, "life must be spawn or despawn"
            end
        end
    end
    return term, nil
end

local function validateBranch(branch: breakpoints.Branch): string
    local hasEntity = false
    local hasStateEvent = false
    for i = 1, #branch.terms do
        local key = branch.terms[i].key
        if ENTITY_KEYS[key] then hasEntity = true end
        if STATE_EVENT_KEYS[key] then hasStateEvent = true end
        if EVENT_KEYS[key] then branch.explicitEntityEvent = true end
    end
    if hasEntity and hasStateEvent then
        return "entity and state-transition terms cannot share an AND branch"
    end
    if not hasEntity and not hasStateEvent then
        return "a branch needs an entity or pushed/popped transition term"
    end
    branch.stateTransition = hasStateEvent
    return nil
end

function breakpoints.parse(source: string): breakpoints.Selector, string
    source = trim(source or "")
    if source == "" then return nil, "selector is empty" end
    local tokens, scanErr = scan(source)
    if not tokens then return nil, scanErr end
    local selector: breakpoints.Selector = {source = source, branches = {}}
    local branch: breakpoints.Branch = {
        terms = {},
        stateTransition = false,
        explicitEntityEvent = false,
    }
    selector.branches[1] = branch
    for i = 1, #tokens do
        local token = tokens[i]
        if token == "||" then
            if #branch.terms == 0 then return nil, "empty OR branch" end
            local branchErr = validateBranch(branch)
            if branchErr then return nil, branchErr end
            branch = {
                terms = {},
                stateTransition = false,
                explicitEntityEvent = false,
            }
            selector.branches[#selector.branches + 1] = branch
        else
            local term, termErr = compileTerm(token)
            if not term then return nil, termErr end
            branch.terms[#branch.terms + 1] = term
        end
    end
    if #branch.terms == 0 then return nil, "empty OR branch" end
    local branchErr = validateBranch(branch)
    if branchErr then return nil, branchErr end
    return selector, nil
end

local function archHas(arch: Archetype, component: Component): boolean
    return arch ~= nil and arch.columns[component] ~= nil
end

local function hasValue(values: {string}, value: string): boolean
    for i = 1, #values do
        if values[i] == value then return true end
    end
    return false
end

local function hasAnyComponent(arch: Archetype,
    components: {Component}): boolean
    for i = 1, #components do
        if archHas(arch, components[i]) then return true end
    end
    return false
end

local function termMatchesEntity(term: breakpoints.Term, before: Archetype,
    after: Archetype, state: string): boolean
    local key = term.key
    local target = after or before
    if key == "has" then
        return hasAnyComponent(target, term.components)
    elseif key == "lacks" then
        for i = 1, #term.components do
            if not archHas(target, term.components[i]) then return true end
        end
        return false
    elseif key == "added" then
        for i = 1, #term.components do
            local component = term.components[i]
            if not archHas(before, component) and archHas(after, component) then
                return true
            end
        end
        return false
    elseif key == "removed" then
        for i = 1, #term.components do
            local component = term.components[i]
            if archHas(before, component) and not archHas(after, component) then
                return true
            end
        end
        return false
    elseif key == "life" then
        return (before == nil and after ~= nil and hasValue(term.values, "spawn"))
            or (before ~= nil and after == nil
                and hasValue(term.values, "despawn"))
    elseif key == "state" then
        return state ~= nil and hasValue(term.values, state)
    end
    return false
end

local function branchMatchesEntity(branch: breakpoints.Branch,
    before: Archetype, after: Archetype, state: string): boolean
    for i = 1, #branch.terms do
        if not termMatchesEntity(branch.terms[i], before, after, state) then
            return false
        end
    end
    if branch.explicitEntityEvent then return true end
    if after == nil then return false end
    if before == nil then return true end
    for i = 1, #branch.terms do
        local term = branch.terms[i]
        if term.key == "has" or term.key == "lacks" then
            if not termMatchesEntity(term, nil, before, state) then
                return true
            end
        end
    end
    return false
end

local function branchMatchesState(branch: breakpoints.Branch, kind: string,
    after: string, changed: string): boolean
    for i = 1, #branch.terms do
        local term = branch.terms[i]
        if term.key == "pushed" then
            if kind ~= "push" or not hasValue(term.values, changed) then
                return false
            end
        elseif term.key == "popped" then
            if kind ~= "pop" or not hasValue(term.values, changed) then
                return false
            end
        elseif term.key == "state" then
            if after == nil or not hasValue(term.values, after) then
                return false
            end
        end
    end
    return true
end

local function entityDescription(before: Archetype,
    after: Archetype): string
    if before == nil then return "spawn" end
    if after == nil then return "despawn" end
    local added: {string} = {}
    local removed: {string} = {}
    for i = 1, after.columnsCount do
        local component = after.componentList[i]
        if not archHas(before, component) then
            added[#added + 1] = component.componentName
        end
    end
    for i = 1, before.columnsCount do
        local component = before.componentList[i]
        if not archHas(after, component) then
            removed[#removed + 1] = component.componentName
        end
    end
    local parts: {string} = {}
    if #added > 0 then parts[#parts + 1] = "added " .. table.concat(added, ", ") end
    if #removed > 0 then
        parts[#parts + 1] = "removed " .. table.concat(removed, ", ")
    end
    return table.concat(parts, "; ")
end

local function sync(manager: breakpoints.Manager)
    local active = false
    for i = 1, #manager.entries do
        if manager.entries[i].enabled then
            active = true
            break
        end
    end
    local world = manager.world as internal.WorldImpl
    if active then
        local existing = world._transitionObserver
        if existing and existing ~= manager.observer then
            error("world transition observer already installed")
        end
        world._transitionObserver = manager.observer
    elseif world._transitionObserver == manager.observer then
        world._transitionObserver = nil
    end
end

local function latch(manager: breakpoints.Manager,
    breakpoint: breakpoints.Breakpoint, entity: integer, description: string)
    breakpoint.hits = breakpoint.hits + 1
    if manager.pending then return end
    manager.pending = {
        breakpointId = breakpoint.id,
        selector = breakpoint.source,
        entity = entity,
        description = description,
    }
    manager.controller:suspend("debugger")
end

function breakpoints.new(world: tecs.World,
    controller: suspension.Controller): breakpoints.Manager
    local manager: breakpoints.Manager = {
        world = world,
        controller = controller,
        entries = {},
        byId = {},
        nextId = 1,
        pending = nil,
        observer = nil,
    }
    setmetatable(manager as {string: any}, {__index = breakpoints.Manager})

    manager.observer = {
        entity = function(id: integer, before: Archetype, after: Archetype)
            local state = world:peekState()
            for i = 1, #manager.entries do
                local breakpoint = manager.entries[i]
                if breakpoint.enabled then
                    local branches = breakpoint.selector.branches
                    for j = 1, #branches do
                        local branch = branches[j]
                        if not branch.stateTransition
                            and branchMatchesEntity(branch, before, after, state)
                        then
                            latch(manager, breakpoint, id,
                                entityDescription(before, after))
                            break
                        end
                    end
                end
            end
        end,
        state = function(kind: string, _before: string, after: string,
            changed: string)
            for i = 1, #manager.entries do
                local breakpoint = manager.entries[i]
                if breakpoint.enabled then
                    local branches = breakpoint.selector.branches
                    for j = 1, #branches do
                        local branch = branches[j]
                        if branch.stateTransition
                            and branchMatchesState(branch, kind, after, changed)
                        then
                            local description = kind == "push"
                                and ("pushed " .. changed)
                                or ("popped " .. changed)
                            latch(manager, breakpoint, nil, description)
                            break
                        end
                    end
                end
            end
        end,
    }
    return manager
end

function breakpoints.Manager:add(source: string): breakpoints.Breakpoint, string
    local selector, err = breakpoints.parse(source)
    if not selector then return nil, err end
    local breakpoint: breakpoints.Breakpoint = {
        id = self.nextId,
        source = selector.source,
        selector = selector,
        enabled = true,
        hits = 0,
    }
    self.nextId = self.nextId + 1
    self.entries[#self.entries + 1] = breakpoint
    self.byId[breakpoint.id] = breakpoint
    sync(self)
    return breakpoint, nil
end

function breakpoints.Manager:remove(id: integer): boolean
    local breakpoint = self.byId[id]
    if not breakpoint then return false end
    self.byId[id] = nil
    for i = 1, #self.entries do
        if self.entries[i] == breakpoint then
            table.remove(self.entries, i)
            break
        end
    end
    sync(self)
    return true
end

function breakpoints.Manager:clear(): integer
    local count = #self.entries
    self.entries = {}
    self.byId = {}
    sync(self)
    return count
end

function breakpoints.Manager:setEnabled(id: integer, enabled: boolean): boolean
    local breakpoint = self.byId[id]
    if not breakpoint then return false end
    breakpoint.enabled = enabled
    sync(self)
    return true
end

function breakpoints.Manager:list(): {breakpoints.Breakpoint}
    return self.entries
end

function breakpoints.Manager:consume(): breakpoints.Trigger
    local trigger = self.pending
    self.pending = nil
    return trigger
end

function breakpoints.Manager:detach()
    local world = self.world as internal.WorldImpl
    if world._transitionObserver == self.observer then
        world._transitionObserver = nil
    end
end

function breakpoints.completionCandidates(world: tecs.World): {string}
    local out: {string} = {
        "added=", "has=", "lacks=", "life=despawn", "life=spawn",
        "popped=", "pushed=", "removed=", "state=", "||",
    }
    local names: {string} = {}
    for name in pairs(componentregistry.registeredComponents) do
        names[#names + 1] = name
    end
    table.sort(names)
    local componentKeys <const> = {"added", "has", "lacks", "removed"}
    for i = 1, #componentKeys do
        for j = 1, #names do
            out[#out + 1] = componentKeys[i] .. "=" .. names[j]
        end
    end
    local stateNames: {string} = {}
    for name in pairs((world as internal.WorldImpl)._stateComponents) do
        stateNames[#stateNames + 1] = name
    end
    table.sort(stateNames)
    local stateKeys <const> = {"popped", "pushed", "state"}
    for i = 1, #stateKeys do
        for j = 1, #stateNames do
            out[#out + 1] = stateKeys[i] .. "=" .. stateNames[j]
        end
    end
    return out
end

return breakpoints

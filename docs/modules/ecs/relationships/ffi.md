---
description: "FFI struct-backed relationships via newFFIRelationship with packed field types and target semantics"
outline: deep
---

# FFI relationships

`newFFIRelationship` stores an edge and its payload in a LuaJIT FFI struct.
Use it for fixed-size numeric data that a hot loop or native API reads:

```teal
local record Follows is tecs.ecs.Relationship
    delay: number
    maxDistance: number

    metamethod __call: function(
        self,
        target: integer,
        delay?: number,
        maxDistance?: number
    ): Follows
end

tecs.ecs.newFFIRelationship({
    name = "Follows",
    container = Follows,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"},
    },
    defaults = {0.5, 100},
})

world:set(follower, Follows(leader, 0.25, 50))
world:set(follower, Follows.new({
    target = leader,
    delay = 0.25,
    maxDistance = 50,
}))
```

Use [`newRelationship`](/modules/ecs/relationships/) for a target-only edge or a
payload that needs strings, tables, functions, or other Lua values.

## Struct layout

Tecs prepends this field to the generated struct:

```c
double target;
```

Do not declare `target` in `fields`. Tecs owns the field; callers must treat it
as read-only and replace the edge through `world:set`. An entity ID packs a
22-bit slot with a generation, so a 32-bit integer would truncate a valid ID.
The positional constructor takes the target first; `.new` reads it from the
`target` key. Callers may mutate dense payload fields through `getMut`. For
sparse storage, replace the edge through `world:set` instead.

Each entry in `fields` contains a C identifier and a type string. Tecs passes
the type string to LuaJIT's `ffi.cdef`. Common choices include `float`,
`double`, the fixed-width integer types, `bool`, and fixed arrays such as
`float[4]`.

Registration rejects an empty or duplicate field name, an invalid C
identifier, and an empty type. Registration requires `name`, `container`, and
`fields`.

## Initialization

`fields` defines the positional order and lets Tecs generate `.new`. `defaults`
fills omitted payload fields in that same order. `init` runs after Tecs writes
the target, generated fields, and defaults:

```teal
tecs.ecs.newFFIRelationship({
    name = "SafeFollows",
    container = SafeFollows,
    fields = {
        {"delay", "float"},
        {"maxDistance", "float"},
    },
    init = function(
        edge: SafeFollows,
        _target: integer,
        delay: number,
        maxDistance: number
    )
        edge.delay = math.max(0.1, delay)
        edge.maxDistance = math.max(1, maxDistance)
    end,
})
```

An `init` hook needs `fields` or an explicit `new`; otherwise Tecs cannot map a
table to the hook's positional arguments. A custom `__call` replaces the
generated constructor and does not run `init`. Call shared initialization
explicitly from that hook.

[Component construction](/modules/ecs/components/construction) covers the shared
constructor rules.

## Relationship behavior

FFI relationships support `exclusive`, `sparse`, `reverseIndex`, and
`cascadeDelete` with the same rules as
[other relationships](/modules/ecs/relationships/). Storage changes the payload
layout, not query or lifecycle behavior.

Snapshots write `target` and every declared field, then restore the edge
through `.new(data)`. A custom serializer cannot accompany
`transient = true`.

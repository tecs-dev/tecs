---
description: "Worlds, entities, components, queries, systems and durable state"
order: 20
---

# Entity component system

Entities are the interface. Components hold entity data; systems bind component
columns from matching archetypes and update their rows. A world owns the entities,
schedule, queries, observers, resources and state stack.

- [World](world.md): lifecycle, entity IDs, spawning and structural transactions.
- [Builtins](builtins.md): the components, events and systems every world installs.
- [Components](components/index.md): record values, scalars, tags and dependencies.
- [Component construction](components/construction.md): inputs, defaults and validation.
- [Record components](components/table-components.md), [scalars](components/scalar-components.md), and [tags](components/tag-components.md).
- [Bundles](components/bundles.md): reusable entity templates.
- [Dirty tracking](components/dirty-tracking.md): declare writes so incremental consumers see them.
- [Archetypes](archetype.md) and [queries](queries/index.md): contiguous rows and iteration.
- [Relationships](relationships/index.md): targets, reverse lookup and cascade delete.
- [Systems](systems.md) and [plugins](plugins.md): frame placement and composition.
- [Phases](phases.md): lifecycle groups, engine ordering and fixed clocks.
- [Events](events.md): world and entity addresses, observers and typed payloads.
- [State stack](states.md): menus, pause, lifecycle policies and state tags.
- [Save games](save-games.md): durable components, snapshots and resource handlers.

The [generated ECS reference](tecs.ecs) owns individual method signatures.

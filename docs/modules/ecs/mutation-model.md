---
description: "Structural transactions, publication barriers, value writes, and visibility guarantees"
outline: deep
---

# Mutation model

Tecs has one structural mutation model. Spawns, despawns, component additions,
component removals, bundle spawns, and every batch operation stage work into the
world's current transaction. They never change archetype rows before returning.

The pipeline owns normal publication. It settles the transaction before
lifecycle dispatch and after each non-empty phase. A system may declare an
unconditional additional barrier with `commitBefore` or `commitAfter`, and
`world:enqueueCommit()` requests a conditional safe-point barrier.

## Mutation classes

| Class          | APIs                                                                  | Visibility                           |
| -------------- | --------------------------------------------------------------------- | ------------------------------------ |
| Structural     | `spawn`, `despawn`, structural `set`, `remove`, bundles, and `batch*` | Next pipeline barrier                |
| Value          | `set` for a component already present                                 | Before return                        |
| Mutable access | `world:getMut` and `archetype:getMut`                                 | The returned live value is immediate |
| Explicit ID    | `spawnAt`, `batchSpawnAt`, and snapshot restore                       | Next owning internal barrier         |
| Sparse         | Sparse relationship `set` and `remove`                                | Last step of transaction settle      |

`getMut` is immediate because it cannot change an entity's archetype. It marks
the component column dirty before returning the live value. Any other side
effect performed through that value also happens immediately; Tecs does not
attempt to roll value writes back when later structural work fails.

`set` has the same fast path when the committed entity already owns the
component. Once that entity has a pending structural change, later values join
its staged destination so the transaction still has one final result.

## Publication ownership

The standard lifecycle publishes at these points:

1. `startup`, `update`, `runPhase`, and `shutdown` publish work queued before
   dispatch begins.
2. Systems in one phase normally run against the same committed structure.
3. The pipeline publishes after each non-empty phase.
4. A system with `commitBefore = true` adds a barrier before its `runIf` and
   `run`. A system with `commitAfter = true` adds one after its dispatch.
5. `enqueueCommit()` called by a system coalesces into one barrier after that
   system returns and before the next system runs.

The declarations are scheduler metadata for unconditional dependencies.
`enqueueCommit()` is the conditional form: it sets one request bit during
system dispatch, so calling it more than once still creates only one barrier.
The requesting system retains its stable view and cannot observe the structural
work it just staged. If it is the last system, the request is honored before
the ordinary phase-end barrier, which then has nothing left to publish.

Use `commitBefore` when a system consumes archetype membership produced by an
earlier system in the same phase. Use `commitAfter` when a later system in that
phase must consume this system's structural output. Prefer a later phase when
the dependency is part of the frame's normal architecture. Call
`enqueueCommit()` inside `run` only when whether the next system needs the
output is known at runtime.

```teal
world:addSystem({
    name = "game.ResolveSpawns",
    phase = tecs.ecs.phases.Update,
    commitBefore = true,
    run = resolveSpawns,
})
```

`runIf` should remain a predicate. A declared pre-barrier runs before it, and a
declared post-barrier runs after the dispatch slot even when the predicate
skips the system, so the publication schedule does not depend on dynamic code.

Outside system dispatch, `enqueueCommit()` publishes synchronously before it
returns. Tests use that behavior to inspect a settled world, and the built-in
MCP mutation tools use it so their responses describe the mutation they just
performed. This is still the one deferred structural model: each operation
stages first, and the explicit request only selects its publication boundary.

## Entity transaction states

One transaction places each entity ID in exactly one state:

| State          | Meaning                                                               |
| -------------- | --------------------------------------------------------------------- |
| Committed      | The entity occupies an archetype and has no staged structural change. |
| Staged spawn   | The transaction reserved the ID but has not placed the entity.        |
| Staged mutate  | A committed entity has a staged component addition or removal.        |
| Staged despawn | The transaction recorded despawn but has not removed the row.         |

| State          | `isAlive` | `get` and `has`           | Queries                        |
| -------------- | --------- | ------------------------- | ------------------------------ |
| Committed      | `true`    | See committed values.     | Match committed structure.     |
| Staged spawn   | `false`   | Return `nil` and `false`. | Do not match.                  |
| Staged mutate  | `true`    | See committed structure.  | Match the committed archetype. |
| Staged despawn | `true`    | See committed values.     | Match until row removal.       |

Publication clears every staged state. A spawn returns its reserved ID
immediately, so later calls in the same transaction may modify or cancel it.
Pass final values to `spawn` when code needs them before the next barrier;
`getMut` cannot return a value for a staged spawn.

## Operations across states

`set` behaves as follows:

- A committed value replacement writes immediately and marks its column dirty.
- A committed component addition stages an archetype move.
- A staged spawn or mutate updates its final staged shape and value.
- A staged despawn ignores the call.

`remove` stages a move for a committed entity, edits the final shape of a
staged spawn or mutate, and ignores a staged despawn.

`despawn` stages removal for a committed entity, cancels placement of a staged
spawn, replaces a staged move with removal, and ignores a repeated despawn.

`spawnAt` requires a non-live ID. It revives a free slot and reconciles
allocator state. Passing a live ID violates the caller contract.

## Settle order

One publication drains dirty archetypes in fixed-point waves:

1. Despawns remove rows and free capacity.
2. Bundle queues, batch queues, explicit-ID batches, and ordinary spawns place
   rows.
3. Structural moves relocate rows and write final component values.
4. Batch `set` and `remove` operations run in call order.
5. Sparse relationship writes flush to their stores.

Observers and query callbacks may stage more work during settle. That work
starts another wave. The drain stops at a fixed point or raises after 64 waves
with a likely observer-cascade error.

The settle guarantees that despawns precede spawns within a wave, the last
staged write wins, net-zero remove/add changes keep their row, despawn cancels
other staged work for that entity, and recycled slots cannot inherit sparse
writes from their previous entity.

Sparse structural moves use a compact list of touched slots when the changed
set is small relative to its source archetype. Dense changes retain a linear
descending scan. Spawn staging transfers packed value arrays directly and
stores no payload for tags. These are settle implementation details; neither
changes transaction ordering or visibility.

## Query iteration

Query iteration does not own transaction lifetime. `query:iter()`, grouped
iteration, and cursors read committed archetypes while structural calls stage
for a later pipeline barrier. Breaking or returning early cannot leave the
world in a special mutation mode.

Use `query:newCursor()` only when code needs an explicitly closable traversal
object. `cursor:close()` stops that traversal and does not publish mutations.

Columns and entity arrays are live archetype storage. They remain valid until a
later publication changes that archetype. Outside a system,
`enqueueCommit()` may publish immediately, so finish manual traversal and
release retained archetype storage before calling it. Inside a system the
request waits until the system returns and is safe in a query loop.

## Dead and stale entity IDs

Entity generations reject a handle after slot reuse:

| Operation                                 | Dead or stale ID                   |
| ----------------------------------------- | ---------------------------------- |
| `get`, `getMut`                           | Return `nil`.                      |
| `has`, `isAlive`                          | Return `false`.                    |
| `markComponentDirty`, `remove`, `despawn` | Do nothing.                        |
| `set`                                     | Raise `Entity ID not found: <id>`. |

## Lifecycle events

`spawn`, `spawnAt`, and bundle spawn emit `OnSpawn` once per entity during the
call, after its final initial shape has been staged. The entity is not alive or
queryable yet, but observers may stage more mutations against its ID.

`despawn` and `batchDespawn` emit `OnDespawn` once at the entity address and
once at address `0` before physical removal. The entity remains alive and
readable during dispatch. Tecs clears entity-address observers after fan-out.

`batchSpawn` and `batchSpawnAt` emit neither lifecycle event. Use their fill
callback or archetype `onEntitiesAdded` notification. Query callbacks run when
settle actually adds or removes matching rows.

## Dirty tracking

Dirty bits belong to an archetype and component. Mutation paths maintain them;
callers still owe these access rules:

- Read through `get`; take `getMut` only when code will write.
- A direct cdata write through `get` needs
  `markComponentDirty(entity, Component)`.
- `world:update` clears dirty bits after the pipeline, once every consumer has
  had a chance to observe them.
- `batchSpawn` runs no component constructors and applies only `requires`
  defaults before its callback. The callback must write every field it uses.

## Structural invariants

Every membership path honors the same rules:

- Adding a component includes its transitive `requires` closure in one final
  archetype transition. Caller values override required defaults.
- A dense relationship instance adds its wildcard container.
- Spawn paths add the active state tag; `set` and `remove` do not.
- Key claiming rejects duplicate live values before visibility. Bulk spawn
  paths reject `EntityKey`.
- Scalar columns store raw values, and tags store no per-row value.
- Table defaults and bundle factories create a fresh table per row.
- Sparse relationships route through the world store. Exclusive edges evict
  the prior target, reverse indexes unlink before linking, and cascade delete
  recursively stages source despawns.
- Value writes dirty component columns; placements and moves dirty archetypes.
- Entity-address observers never survive slot reuse.

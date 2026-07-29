---
description: "Mutation paths, entity lifecycle states, commit drain ordering, and visibility guarantees"
outline: deep
---

# Mutation model

This page defines mutation timing, visibility, and ordering. When another page
disagrees with this specification, this page wins.

## Execution paths

| Path        | APIs                                                                        | Applied                  |
| ----------- | --------------------------------------------------------------------------- | ------------------------ |
| Instant     | `spawn`, `set`, `remove`, and `despawn` at depth 0                          | Before return            |
| Staged      | The same APIs in a [deferred scope](/modules/ecs/world#deferred-operations) | At commit                |
| Batch       | The `batch*` APIs                                                           | At the outer boundary    |
| Bundle      | Bundle spawn APIs                                                           | Immediately or at commit |
| Explicit ID | `spawnAt`, `batchSpawnAt`, and snapshot load                                | At placement             |
| Sparse      | Sparse relationship `set` and `remove`                                      | Last in the drain        |

Every path must produce the same post-commit state for the same logical
operations. The instant path optimizes staged semantics.

An instant call may route through staging when a transaction already includes
the entity, when spawn observers exist, when despawn needs cleanup or cascade
work, or when sparse storage requires a store flush. Callers cannot rely on
which implementation path runs.

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

Commit clears every staged state.

## Operations across states

**`set`**

- Committed: Writes a value immediately or stages an archetype move.
- Staged spawn: Updates the staged shape and value.
- Staged mutate: Restages the destination and value.
- Staged despawn: Does nothing.

**`remove`**

- Committed: Stages a move when the component exists.
- Staged spawn: Removes the component from the staged shape.
- Staged mutate: Restages the destination.
- Staged despawn: Does nothing.

**`despawn`**

- Committed: Runs cleanup and events, then records row removal.
- Staged spawn: Cancels placement but still emits `OnDespawn`.
- Staged mutate: Cancels the move and records removal.
- Staged despawn: Does nothing.

`spawnAt` requires a non-live ID. The function revives a free slot and
reconciles allocator state. A live ID violates the caller contract.

## Commit drain {#commit-drain}

The outermost scope closes by draining dirty archetypes in waves:

1. Despawns remove rows and free capacity.
2. Spawns place bundle queues, batch queues, explicit-ID batches, then
   per-entity staged spawns.
3. Moves relocate rows and write final component values.
4. Batch `set` and `remove` calls run in call order.
5. Sparse relationship writes flush to their stores.

Observers and query callbacks may stage more work during any phase. That work
starts another wave. The drain stops at a fixed point or raises after 64 waves
with a likely observer-cascade error.

The drain guarantees:

- Despawns precede spawns within one wave, so spawns may reuse freed rows.
- The last staged write wins for one entity and component.
- A remove followed by an add of the same component keeps the row in place and
  fires no match-set callback when the net signature stays unchanged.
- Despawn cancels staged spawn, move, and sparse writes for that entity.
- Slot recycling cannot revive a sparse write from the previous entity.

## Scope ownership

These operations raise scope depth:

- An archetype-level query iterator, from its first step through exhaustion.
- The commit drain while it invokes query callbacks.
- Every batch call for the duration of that call.
- `world:defer()` until the matching `world:commit()`.

Leaving `query:iter()` early skips the iterator step that closes its scope.
Every later structural mutation then stages silently. Use a cursor for loops
that may `break` or return, and call `cursor:close()`.

`world:unwind()` closes all scopes and drains pending work after an exception.
`world:update()` calls it before pipeline dispatch. Closing a cursor after an
unwind remains safe because scope pops clamp at zero.

## Visibility inside a scope

- Every spawn path returns an ID immediately. Later staged calls may use it.
- Structural changes remain invisible to `get`, `has`, `isAlive`, and queries
  until the drain applies them.
- `set` writes through immediately when the committed entity already has the
  component and no staged structural change exists for that entity.
- After an entity acquires staged structure, later values wait for commit.
- Query callbacks may read the supplied archetype and row range until the
  callback returns.

Only mid-scope reads distinguish immediate value writes from staged values.
Post-commit state always follows last-write-wins.

## Dead and stale entity IDs

Entity generations reject a handle after slot reuse:

| Operation                                 | Dead or stale ID                   |
| ----------------------------------------- | ---------------------------------- |
| `get`, `getMut`                           | Return `nil`.                      |
| `has`, `isAlive`                          | Return `false`.                    |
| `markComponentDirty`, `remove`, `despawn` | Do nothing.                        |
| `set`                                     | Raise `Entity ID not found: <id>`. |

## Lifecycle event timing

- `spawn`, `spawnAt`, and bundle spawn emit `OnSpawn` once per entity.
- `despawn` and `batchDespawn` emit `OnDespawn` once at the entity address and
  once at address `0`.
- `batchSpawn` and `batchSpawnAt` emit neither event. Use the fill callback or
  `onEntitiesAdded`.

`OnSpawn` runs during the spawn call while the entity remains staged.
Observers may stage mutations against the pending ID.

`OnDespawn` runs before physical removal. The entity remains alive, readable,
and queryable during dispatch. Tecs clears observers at the entity address
after fan-out.

Query callbacks run when rows enter or leave matching archetypes. The instant
path invokes them inline; the staged path invokes them during drain.

## Dirty tracking

Dirty bits belong to an archetype and component. Mutation paths maintain them;
callers still owe these access rules:

- Read through `get`; take `getMut` only when code will write.
- A direct cdata write through `get` needs
  `markComponentDirty(entity, Component)`.
- `world:update` clears dirty bits after the pipeline, once extraction has
  consumed them.
- `batchSpawn` runs no component constructors and applies only
  `requires` defaults before its callback. The callback must write every field
  it depends on.

Tecs owns dirty state. Callers declare write intent; they must not mutate the
dirty metadata itself. [Dirty tracking](/modules/ecs/components/dirty-tracking)
covers consumer-side iteration.

## Mutation-path requirements

Every spawn or membership path must honor these invariants:

- Adding a component includes its transitive `requires` closure in one
  archetype transition. Caller values override required defaults.
- A dense relationship instance adds its wildcard container.
- Spawn paths add the active state tag; `set` and `remove` do not.
- Key claiming rejects duplicate live values before visibility. Bulk spawn
  paths reject `EntityKey`.
- Scalar columns store raw values, and tags store no per-row value.
- Table defaults and bundle factories create a fresh table per row.
- Sparse relationships route through the world store. Exclusive edges evict
  the prior target. Reverse indexes unlink old values before linking new ones.
  Cascade delete recursively despawns sources.
- Value writes dirty component columns; placements and moves dirty archetypes.
- Entity-address observers never survive slot reuse.
- Staged moves reserve destination capacity before the drain starts.

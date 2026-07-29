---
description: "Normative specification of instant versus staged mutation paths, entity lifecycle states, commit drain ordering, and visibility guarantees"
outline: deep
---

# Mutation model

This page is the normative specification of how entity and component mutations execute in Tecs: when a change
applies, what readers observe in between, and the guarantees every mutation path provides. Other pages describe
the individual APIs; when they disagree with this page, this page wins.

## Execution paths

Tecs executes mutations through several specialized paths:

| Path                | APIs                                                                        | How it applies                                               |
| ------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Instant             | `spawn` / `set` / `remove` / `despawn` at scope depth 0                     | In place, before the call returns                            |
| Staged              | the same APIs inside a [deferred scope](/ecs/world#deferred-operations)     | Staged, applied by the commit drain                          |
| Batch               | `batchSpawn` / `batchSpawnAt` / `batchSet` / `batchRemove` / `batchDespawn` | Stage internally; drain when the outermost scope closes      |
| Bundle              | `bundle:spawn` / `world:spawnBundle`                                        | Codegen-specialized spawn; instant or staged by scope depth  |
| Explicit id         | `spawnAt`, `batchSpawnAt`, snapshot load                                    | Staged placement at caller-supplied ids                      |
| Sparse relationship | `set` / `remove` of sparse relationship instances                           | External store; staged writes commit at the end of the drain |

::: info The convergence rule
Every path produces the same observable post-commit state for the same logical operations. The instant path is
an optimization of the staged path, not a separate semantic.

This rule is load-bearing because the instant path reroutes to the staged path silently: when the target entity
is already part of the current transaction, when `OnSpawn` observers exist (spawn), when despawn cleanup,
cascade deletes, or `OnDespawn` observers are involved (despawn), and for components whose behavior requires
staging (sparse relationships). Callers cannot predict which path runs, so any semantic difference between
paths is a bug.
:::

## Entity lifecycle states

Within one transaction (the window between the first staged mutation and its commit), every entity id is in
exactly one of four states:

| State          | Meaning                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| Committed      | Placed in an archetype; no staged changes this transaction                 |
| Staged spawn   | Spawned this transaction; not yet placed in an archetype                   |
| Staged mutate  | Committed entity with a staged structural change (component add or remove) |
| Staged despawn | Despawn requested this transaction; row not yet removed                    |

All staged state resets when the transaction commits. Reads behave per state:

| State              | **`isAlive`**        | **`get` / `has`**                                                  | **Queries**           |
| ------------------ | -------------------- | ------------------------------------------------------------------ | --------------------- |
| **Committed**      | `true`               | committed value                                                    | matches               |
| **Staged spawn**   | `false` until commit | `nil` / `false`                                                    | no match until commit |
| **Staged mutate**  | `true`               | committed structure (see [Visibility](#visibility-inside-a-scope)) | committed archetype   |
| **Staged despawn** | `true` until commit  | committed value                                                    | matches until commit  |

## Operations by state

Staged semantics; the instant path converges to the same post-commit result.

| Operation     | Committed                                                                                                  | Staged spawn                                                   | Staged mutate                                         | Staged despawn                 |
| ------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------ |
| **`set`**     | Writes the value in place when the archetype already has the component; otherwise stages a structural move | Updates the staged archetype and staged value                  | Restages the move target; the value applies at commit | Ignored                        |
| **`remove`**  | Stages a move out (no-op when the component is absent)                                                     | Shrinks the staged archetype                                   | Restages the move target                              | Ignored                        |
| **`despawn`** | Records despawn, runs component cleanup, emits `OnDespawn`, queues row removal                             | Cancels the spawn; nothing is placed (`OnDespawn` still fires) | Cancels the staged move and queues removal            | Ignored (double-despawn guard) |

`spawnAt` requires the id to not be live; it revives ids sitting on the free stack and reconciles the
allocator. Passing a live id is caller error with undefined results.

## Commit drain

When the outermost scope closes on a dirty world, the transaction drains. The drain runs in **waves** over the
dirty archetype list, and each wave applies phases in this order:

1. **Despawns**: staged despawns remove rows (and whole-archetype clears from `batchDespawn` truncate), so
   later phases can reuse the space.
2. **Spawns**: per dirty archetype, in this order: bundle spawn queues, `batchSpawn` queues, `batchSpawnAt`
   queues, then per-entity staged spawns.
3. **Moves**: staged component adds and removes relocate rows between archetypes, applying staged values onto
   the destination rows.

Observers and query callbacks fire during these phases. Mutations they stage mark new archetypes dirty and form
the next wave. When a wave completes with no new structural work, two one-shot phases run:

4. **Batch mutations**: `batchSet` / `batchRemove` entries apply in the order the calls were made.
5. **Sparse relationship commits**: staged sparse writes flush to their relationship stores.

Phases 4 and 5 can stage new structural work, which starts another wave. The drain loops to a fixed point,
bounded at 64 iterations; exceeding the bound raises
`"_drain exceeded MAX_DRAIN_ITERATIONS; likely an observer cascade with no fixed point"`.

**Ordering guarantees:**

- Despawns apply before spawns within a wave; rows freed by despawns are reusable by spawns in the same wave.
- For one entity and one component, the last staged write wins at commit.
- Staged operations that net out structurally (remove then re-add of the same component) leave the entity's
  row in place and apply the final value there; no query callbacks fire because the archetype never changes.
- A staged despawn cancels every other staged operation for that entity: staged spawns are never placed, staged
  moves never run, and staged sparse writes are discarded.
- Sparse writes staged by an entity that despawns in the same transaction are discarded, including when the
  slot is recycled mid-transaction.

## Who holds a scope

Scope depth decides staging, and iteration is what usually raises it:

- A [query](/ecs/queries/) iterator pushes a scope on its first step and pops it when the loop runs out of
  archetypes, so mutations made inside the loop stage and apply after it.
- Query callbacks run inside the drain that triggered them, which holds a scope for its whole duration.
- Each batch call holds a scope for the duration of the call.
- `world:defer()` and `world:commit()` open and close one explicitly.

This makes leaving an archetype-level `query:iter()` loop early a real hazard: the pop that ends the loop never
runs, the world stays deferred, and every later mutation stages silently instead of applying. Use `query:iter()`
for loops that run to exhaustion; when a loop may `break` or return early, take a `query:cursor()` and call
`cursor:close()` after the loop or immediately before returning. Closing a cursor is safe before iteration,
after natural exhaustion, and more than once.

`world:unwind()` is the recovery path for the case nothing else covers: a throw part way through a frame skips
the pop that ends the loop's scope. `unwind` closes every open scope and drains what they staged; at depth zero
it is the same drain `commit` performs. `world:update` calls it at the start of every frame, so a frame that
threw cannot leave the frames after it staging. Popping a query scope is clamped at zero, so a cursor closed
after an unwind cannot push the depth negative.

## Visibility inside a scope

- Entity ids returned by any spawn path are valid immediately: they accept `set` / `remove` / `despawn` and
  resolve correctly at commit.
- **Structure never appears early.** Component adds, removes, spawns, and despawns are invisible to `get`,
  `has`, `isAlive`, and queries until the drain applies them.
- **Values can appear early.** A `set` of a component the entity already has, on an entity with no staged
  structural change, writes through to the column immediately at any scope depth. Once the entity has a staged
  structural change, subsequent `set` calls stage and apply at commit. Either way the post-commit value follows
  last-write-wins; only mid-scope reads can tell the difference.
- Inside query callbacks (`onEntitiesAdded` / `onEntitiesRemoved`), reading the passed archetype's columns over
  the given row range is always current. See [Query callbacks](/ecs/queries/callbacks).

## Dead and stale handles

Entity ids carry a generation; a recycled slot rejects handles from its previous entity. The policy is
identical at every scope depth and on every path:

| Operation on a dead or stale id | Behavior                             |
| ------------------------------- | ------------------------------------ |
| `get` / `getMut`                | Returns `nil`                        |
| `has`                           | Returns `false`                      |
| `isAlive`                       | Returns `false`                      |
| `markComponentDirty`            | No-op                                |
| `set`                           | Raises `"Entity ID not found: <id>"` |
| `remove`                        | No-op                                |
| `despawn`                       | No-op                                |

## Event timing

| Path                             | `OnSpawn`                                                                    | `OnDespawn`                                                   |
| -------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **`spawn`, `spawnAt`**           | Once per entity                                                              | n/a                                                           |
| **`despawn`**                    | n/a                                                                          | Once per entity, to the entity address and the global address |
| **`batchSpawn`, `batchSpawnAt`** | Not emitted, by design; use the fill callback or a query's `onEntitiesAdded` | n/a                                                           |
| **`batchDespawn`**               | n/a                                                                          | Once per entity                                               |
| **Bundle spawn**                 | Once per entity, same contract as `spawn`                                    | n/a                                                           |

- `OnSpawn` is emitted during the spawn call while the entity is staged: `isAlive` returns `false`, and
  mutations made by observers stage against the pending entity.
- `OnDespawn` is emitted during the despawn call, before physical removal: `isAlive` returns `true`, components
  are still readable through `get`, and the entity still matches queries. After the fan-out, all observers on
  the entity's address are cleared so they never fire for a future entity recycled into the same slot.
- Query callbacks fire per contiguous row range when rows are physically added or removed: inline on the
  instant path, during the drain otherwise.

## Dirty state

Dirty bits are per archetype and per component, and the renderer is the consumer that makes them matter. The
extractor installs a system named `tecs.SyncRenderState` in the `RenderFirst` phase, so it runs inside
`world:update`. It walks the archetypes its renderable query matches and rewrites a run into GPU staging only
when that archetype's `Transform`, `Tint`, `Sprite`, `Material`, `Clip` or sprite-sheet `Pivot` column is
dirty, when its rows moved, or when interpolation moved the drawn position. An archetype nothing touched costs the comparison
and nothing else, which is what makes a large world affordable. `renderer.rewritten` reports how many rows the
last frame rewrote.

The mutation paths maintain the bits; the rules below are what a caller still owes.

- Read through `archetype:get` / `world:get`, write through `archetype:getMut` / `world:getMut`, which marks
  the component's column dirty on the archetype. Never call `getMut` in a loop that might not write: taking it
  to read marks the component dirty on every archetype every frame, and the extractor then rewrites the whole
  scene.
- The render components that carry data are FFI components, so a write through `world:get` goes straight into C
  memory and marks nothing. Follow it with `world:markComponentDirty(id, Component)` or the row is never re-synced.
- Dirty bits clear at the end of each `world:update`, after the pipeline finishes, which is after extraction
  has read them.
- `world:batchSpawn` writes only the `requires`-supplied defaults before handing you the row range; component
  constructors and their defaults do not run. Set every field you depend on in the callback.

See [Dirty tracking](/ecs/components/dirty-tracking) for the reader side.

## Obligations of every mutation path

Every path that spawns entities or changes component membership honors all of the following. This is the
conformance checklist for adding or changing a mutation path.

- **`requires` closure**: adding a component pulls its transitive [`requires`](/ecs/components/) closure into
  the same archetype transition, writing default values for components the entity lacks. User-supplied values
  win over required defaults.
- **Wildcard containers**: setting a dense relationship instance also adds its container component, so
  wildcard queries match.
- **State auto-tagging**: spawn-family paths add the active [state component](/ecs/states); `set` / `remove`
  never do.
- **`Key` claiming**: a key is claimed (and duplicate live keys rejected) before the entity becomes visible,
  and released on despawn. Bulk spawn paths reject `Key` up front because keys are per entity.
- **Scalar unwrapping**: columns store raw scalar values; wrapper instances are unwrapped at the API boundary.
- **Tags**: tag components carry no per-row value on any path.
- **Table-storage defaults**: required defaults and bundle `with` factories produce a fresh table per row;
  other storages share one resolved value across a batch.
- **Relationship behaviors**: sparse instances route to the relationship store (the archetype only carries the
  container marker); exclusive relationships evict the prior sibling; reverse-indexed relationships read the
  old value before unlinking and link after the new value is written; `cascadeDelete` recursively despawns
  sources when their target despawns.
- **Dirty tracking**: value writes mark the component column dirty; placements and moves mark the archetype
  dirty.
- **Observer hygiene**: per-entity observers never survive into a recycled slot.
- **Reservation accounting**: staged moves reserve destination capacity so drains do not reallocate mid-pass.

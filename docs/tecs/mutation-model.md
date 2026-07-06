---
outline: deep
---

# Mutation model

This page is the authoritative specification of how entity and component mutations execute in Tecs: when a
change applies, what readers observe in between, and the guarantees every mutation path provides. Other pages
describe the individual APIs; when they disagree with this page, this page wins.

## Execution paths

Tecs executes mutations through several specialized paths:

| Path | APIs | How it applies |
| ---- | ---- | -------------- |
| Instant | `spawn` / `set` / `remove` / `despawn` at scope depth 0 | In place, before the call returns |
| Staged | the same APIs inside a [deferred scope](/tecs/world#deferred-operations) | Staged, applied by the commit drain |
| Batch | `batchSpawn` / `batchSpawnAt` / `batchSet` / `batchRemove` / `batchDespawn` | Stage internally; drain when the outermost scope closes |
| Bundle | `bundle:spawn` / `world:spawnBundle` | Codegen-specialized spawn; instant or staged by scope depth |
| Explicit id | `spawnAt`, `batchSpawnAt`, snapshot load | Staged placement at caller-supplied ids |
| Sparse relationship | `set` / `remove` of sparse relationship instances | External store; staged writes commit at the end of the drain |

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

| State | Meaning |
| ----- | ------- |
| Committed | Placed in an archetype; no staged changes this transaction |
| Staged spawn | Spawned this transaction; not yet placed in an archetype |
| Staged mutate | Committed entity with a staged structural change (component add or remove) |
| Staged despawn | Despawn requested this transaction; row not yet removed |

All staged state resets when the transaction commits. Reads behave per state:

| State | **`isAlive`** | **`get` / `has`** | **Queries** |
| ----- | ------------- | ----------------- | ----------- |
| **Committed** | `true` | committed value | matches |
| **Staged spawn** | `false` until commit | `nil` / `false` | no match until commit |
| **Staged mutate** | `true` | committed structure (see [Visibility](#visibility-inside-a-scope)) | committed archetype |
| **Staged despawn** | `true` until commit | committed value | matches until commit |

## Operations by state

Staged semantics; the instant path converges to the same post-commit result.

| Operation | Committed | Staged spawn | Staged mutate | Staged despawn |
| --------- | --------- | ------------ | ------------- | -------------- |
| **`set`** | Writes the value in place when the archetype already has the component; otherwise stages a structural move | Updates the staged archetype and staged value | Restages the move target; the value applies at commit | Ignored |
| **`remove`** | Stages a move out (no-op when the component is absent) | Shrinks the staged archetype | Restages the move target | Ignored |
| **`despawn`** | Records despawn, runs component cleanup, emits `OnDespawn`, queues row removal | Cancels the spawn; nothing is placed (`OnDespawn` still fires) | Cancels the staged move and queues removal | Ignored (double-despawn guard) |

`spawnAt` requires the id to not be live; it revives ids sitting on the free stack and reconciles the
allocator. Passing a live id is caller error with undefined results.

## The commit drain

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
`"_drain exceeded MAX_DRAIN_ITERATIONS — likely an observer cascade with no fixed point"`.

**Ordering guarantees:**

- Despawns apply before spawns within a wave; rows freed by despawns are reusable by spawns in the same wave.
- For one entity and one component, the last staged write wins at commit.
- A staged despawn cancels every other staged operation for that entity: staged spawns are never placed, staged
  moves never run, and staged sparse writes are discarded.
- Sparse writes staged by an entity that despawns in the same transaction are discarded, including when the
  slot is recycled mid-transaction.

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
  the given row range is always current. See [Query callbacks](/tecs/queries/callbacks#deferred-scope).

## Dead and stale handles

Entity ids carry a generation; a recycled slot rejects handles from its previous entity. The policy is
identical at every scope depth and on every path:

| Operation on a dead or stale id | Behavior |
| ------------------------------- | -------- |
| `get` / `getMut` | Returns `nil` |
| `has` | Returns `false` |
| `isAlive` | Returns `false` |
| `set` | Raises `"Entity ID not found: <id>"` |
| `remove` | No-op |
| `despawn` | No-op |

## Event timing

| Path | `OnSpawn` | `OnDespawn` |
| ---- | --------- | ----------- |
| **`spawn`, `spawnAt`** | Once per entity | n/a |
| **`despawn`** | n/a | Once per entity, to the global and the entity address |
| **`batchSpawn`, `batchSpawnAt`** | Not emitted, by design; use the fill callback or a query's `onEntitiesAdded` | n/a |
| **`batchDespawn`** | n/a | Once per entity |
| **Bundle spawn** | See [Conformance status](#conformance-status) | n/a |

- `OnSpawn` is emitted during the spawn call while the entity is staged: `isAlive` returns `false`, and
  mutations made by observers stage against the pending entity.
- `OnDespawn` is emitted during the despawn call, before physical removal: `isAlive` returns `true`, components
  are still readable through `get`, and the entity still matches queries. After the fan-out, all observers on
  the entity's address are cleared so they never fire for a future entity recycled into the same slot.
- Query callbacks fire per contiguous row range when rows are physically added or removed: inline on the
  instant path, during the drain otherwise.

## Obligations of every mutation path

Every path that spawns entities or changes component membership honors all of the following. This is the
conformance checklist for adding or changing a mutation path.

- **`requires` closure**: adding a component pulls its transitive
  [`requires`](/tecs/components/#auto-dependencies-with-requires) closure into the same archetype transition,
  writing default values for components the entity lacks. User-supplied values win over required defaults.
- **Wildcard containers**: setting a dense relationship instance also adds its container component, so
  wildcard queries match.
- **State auto-tagging**: spawn-family paths add the active [state component](/tecs/states); `set` / `remove`
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
  dirty. See [Dirty tracking](/tecs/components/dirty-tracking).
- **Observer hygiene**: per-entity observers never survive into a recycled slot.
- **Reservation accounting**: staged moves reserve destination capacity so drains do not reallocate mid-pass.

## Conformance status

::: warning Known divergences
The following behaviors currently diverge from this specification. Each is a bug with a planned fix; do not
rely on the divergent behavior.

1. **Staged `set` and `batchSet` skip the `requires` closure.** A structural add through `world:set` inside a
   scope, or through `batchSet`, does not pull in required components; the instant path and all spawn paths
   do. Fix: apply the closure on the staged and batch structural-add paths.
2. **Bundle spawns skip `Key`.** A `Key` component in a bundle is written as a plain column value: the key
   index is not updated and duplicate live keys are not rejected. Until fixed, do not put `Key` in bundles;
   claim keys with `world:set` after spawning.
3. **Bundle spawns do not emit `OnSpawn`.** `world:spawn` and `world:spawnAt` emit it; bundle spawns will after
   the fix.
4. **Staged remove-then-set of the same component corrupts the archetype.** Removing a component and re-adding
   it in one scope stages a self-move; when the drain relocates every row of the source archetype, the entity
   ends up alive but matching no queries. Until fixed, avoid remove-then-set of one component in a single
   scope; set the new value directly instead.
:::

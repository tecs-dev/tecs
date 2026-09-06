---
description: MCP compatibility decisions, restored tools, and concrete contracts for deferred host features.
---

# MCP migration contracts

The historical `tools/list` response at `70549c8e` contained 49 tools. The
current server implements 43 of those plus `clear_crash`. The six deferred
tools below are absent from `tools/list`; they are not successful no-op handlers.
The captured argument schemas are retained in
`tests/fixtures/mcp/historical-tools.json`. Tests pin the restored input schemas
and every active tool name. Device event vocabulary follows the documented
winit/gilrs migration; it is not an SDL name translation layer.

`help`, `describe` and `capabilities` remain because historical callers use all
three. They derive their answers from the live tool registry. A family such as
`snapshot` describes its `snapshot_save` and `snapshot_load` verbs. The command
presentation is now one Tools section; the removed console grammar and its
aliases are not recreated. The 22 restored tools retain their input schemas;
output observations describe the retained implementation, without advertising
old SDL GPU counters as if wgpu had supplied them.

## Tool disposition

| Historical tool   | Argument keys                                                                                                                                                                          | Disposition              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `ping`            | None                                                                                                                                                                                   | Retained                 |
| `context`         | None                                                                                                                                                                                   | Retained                 |
| `get_logs`        | `after`, `contains`                                                                                                                                                                    | Retained                 |
| `screenshot`      | `name`                                                                                                                                                                                 | Deferred; contract below |
| `sample_pixels`   | `points`                                                                                                                                                                               | Deferred; contract below |
| `send_event`      | `button`, `clicks`, `data1`, `data2`, `flipped`, `kind`, `penState`, `recording`, `repeated`, `scale`, `scancode`, `wheelTicksX`, `wheelTicksY`, `wheelX`, `wheelY`, `which`, `x`, `y` | Retained                 |
| `audio`           | None                                                                                                                                                                                   | Retained                 |
| `reload_shaders`  | None                                                                                                                                                                                   | Deferred; contract below |
| `reload_image`    | `path`                                                                                                                                                                                 | Deferred; contract below |
| `reload_sound`    | `path`                                                                                                                                                                                 | Retained                 |
| `watch`           | `enabled`, `poll`                                                                                                                                                                      | Deferred; contract below |
| `run_lua`         | `code`                                                                                                                                                                                 | Retained                 |
| `components_info` | None                                                                                                                                                                                   | Retained                 |
| `query`           | `include`, `limit`, `values`                                                                                                                                                           | Retained                 |
| `info`            | `entity`                                                                                                                                                                               | Retained                 |
| `spawn`           | `components`                                                                                                                                                                           | Retained                 |
| `set`             | `component`, `entity`, `values`                                                                                                                                                        | Retained                 |
| `modify`          | `component`, `entity`, `values`                                                                                                                                                        | Retained                 |
| `remove`          | `component`, `entity`                                                                                                                                                                  | Retained                 |
| `despawn`         | `entity`                                                                                                                                                                               | Retained                 |
| `help`            | `command`                                                                                                                                                                              | Retained                 |
| `describe`        | `command`                                                                                                                                                                              | Retained                 |
| `capabilities`    | None                                                                                                                                                                                   | Retained                 |
| `camera_info`     | None                                                                                                                                                                                   | Retained                 |
| `camera_move`     | `rotation`, `x`, `y`, `zoom`                                                                                                                                                           | Retained                 |
| `render_info`     | None                                                                                                                                                                                   | Retained                 |
| `layers_list`     | None                                                                                                                                                                                   | Retained                 |
| `layers_info`     | `layer`                                                                                                                                                                                | Retained                 |
| `archetypes_list` | `empty`, `limit`                                                                                                                                                                       | Retained                 |
| `archetypes_info` | `id`                                                                                                                                                                                   | Retained                 |
| `stats`           | None                                                                                                                                                                                   | Retained                 |
| `resources_list`  | None                                                                                                                                                                                   | Retained                 |
| `resources_info`  | `name`                                                                                                                                                                                 | Retained                 |
| `materials_list`  | None                                                                                                                                                                                   | Retained                 |
| `materials_info`  | `name`                                                                                                                                                                                 | Retained                 |
| `snapshot_save`   | `name`                                                                                                                                                                                 | Retained                 |
| `snapshot_load`   | `path`                                                                                                                                                                                 | Retained                 |
| `profile_start`   | `intervalMs`, `zone`                                                                                                                                                                   | Retained                 |
| `profile_stop`    | `name`                                                                                                                                                                                 | Retained                 |
| `physics_info`    | None                                                                                                                                                                                   | Retained                 |
| `physics_raycast` | `categoryBits`, `maskBits`, `x1`, `x2`, `y1`, `y2`                                                                                                                                     | Retained                 |
| `physics_debug`   | `on`                                                                                                                                                                                   | Deferred; contract below |
| `systems_list`    | `disabled`, `phase`                                                                                                                                                                    | Retained                 |
| `systems_info`    | `name`                                                                                                                                                                                 | Retained                 |
| `systems_stop`    | `name`                                                                                                                                                                                 | Retained                 |
| `systems_start`   | `name`                                                                                                                                                                                 | Retained                 |
| `states_info`     | None                                                                                                                                                                                   | Retained                 |
| `states_push`     | `name`                                                                                                                                                                                 | Retained                 |
| `states_pop`      | None                                                                                                                                                                                   | Retained                 |

## Inspection and mutation

Archetype inspection includes empty archetypes on request and reports detached
component/dirty-column metadata. Resource inspection includes anonymous occupied
keys as `#<id>` and reports type information without serializing live resources.
Camera inspection and mutation select the lowest entity carrying ActiveCamera,
falling back to the lowest camera entity, as frame extraction does. An implicit
camera can be inspected but must be made into a Camera2D entity before it can
be moved. Diagnostic queries are temporary; repeated inspection does not register
permanent queries with the world.

`render_info` reports the CPU-side configuration and explicitly lists unavailable
GPU observations. `frame` is an Application turn counter, not proof of a presented
frame. Physics inspection reports committed Body components and effective solver
settings; raycasts use the installed solver and world-pixel coordinates. Audio
inspection and sound reload use the world's installed Audio instance.

World-touching tools are refused while lifecycle work is parked or after a crash.
Discovery and the process sampler may run in either state. Read-only annotations
alone grant no access to an incomplete world.

## Snapshot files and profiling

Snapshot tools use World.saveSnapshot and World.loadSnapshot. Files start with
`TECS-SNAPSHOT` and a version byte of 1, followed by a `nupp.data.binary` NVB
version 1 document. Arbitrary binary handler data, including Rapier state, and
numeric table keys survive the round trip. Save writes atomically beneath the
writable root. Load requires an absolute path, bounds file size before reading,
and decodes the complete document before touching the world. Malformed framing
or codec bytes leave the world untouched. A subsystem handler that fails during
restoration still follows World.loadSnapshot's failure contract; this tool does
not claim transactional rollback of arbitrary handlers.

Legacy Teal string.buffer snapshots are a different wire format and are refused
explicitly. They need conversion in the old runtime to detached component data,
followed by migration of backend-specific state. Rapier state is not compatible
with the old Box2D state; no byte-level converter can infer that migration.
Persisted component and snapshot-handler names remain unchanged.

The codec limits each document to 64 MiB, one million values including keys,
and 128 nested tables. Snapshots carry finite numbers and detached plain values.
The sampler is process-wide, uses Nupp profiling and accepts the historical zone
prefix and interval arguments. A fractional interval is rounded down to whole
milliseconds. Stop writes collapsed stacks beneath the writable root; stopping
before a sample arrives produces a valid empty report.

## Deferred host contracts

### `screenshot`

GPU readback: the Rust host must return a completed presented-frame ID, dimensions, row stride and pixel format, plus an owned byte payload or output path. Pending, failed and cancelled requests must release staging buffers during shutdown and device loss.

### `sample_pixels`

Uses the same completed-frame readback contract as screenshot. Coordinates are pixel coordinates in that returned frame, bounds are checked, and RGBA channel order and color space must be stated. A request must never sample whichever frame happens to finish later.

### `reload_shaders`

The host must validate a replacement compiled shader pack against material names/IDs and frame-packet version, build pipelines before publication, and replace the pack at a safe submission boundary. Failure keeps the prior pack active.

### `reload_image`

Application-owned asset lookup must resolve a path to a unique live image request. Loader-local names reject duplicates. A replacement upload must publish its residency revision atomically and retain the old GPU resource until in-flight frames release it. No process-global asset registry is introduced.

### `watch`

The tool must own an Application-scoped watcher subscription and route changes to supported asset reload operations. `enabled` controls that subscription and `poll` requests one nonblocking drain. Shutdown cancels the subscription and queued reloads. Existing tecs.watch functionality remains; this orchestration tool waits for the image/shader reload contracts.

### `physics_debug`

Retain collider geometry for a read-only outline view, map it through the same pixels/meters and camera/layer transforms as rendering, distinguish sensors, and own overlay entities/resources per world. `on` sets visibility, omission toggles it, and shutdown/snapshot restoration must remove stale outlines.

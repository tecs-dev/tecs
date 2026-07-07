# tecs2d Systematic Code Review (2026-07-06)

Eleven parallel review passes over all of `src/tecs2d` (~38k lines of Teal plus GLSL).
Findings verified against the code with file:line references. Items already fixed in
this pass are in the first section; everything else is an open checklist, ordered by
priority. Line numbers reflect the tree as of this review.

## Fixed in this pass (all verified by `make all`: 1477 tests green)

- [x] `internal/handlers.tl:53` wheel events overwrote instead of accumulating per frame; trackpads dropped events. Added `spec/tecs2d/input_spec.tl`.
- [x] `controller.tl:385` hat bindings could not parse two-char diagonals (`hat:1lu` silently never fired); malformed bindings now error. Tests added in `controller_spec.tl`.
- [x] `controller.tl:739` `onJoystickRemoved` only cleared the first controller sharing a joystick.
- [x] `audio/init.tl:295` `audio.UpdateListener` returned from inside `query:iter()`, leaving the world deferred every frame a listener existed.
- [x] `audio/init.tl:230` failed audio asset handles (`isComplete` + `err`) crashed `initializeSource` via `.value` every frame.
- [x] `tween.tl:959` `playbackFor` re-fetched after a deferred `world:set`, returning nil and crashing `addCursor` when a tween started inside query iteration or an observer. (Edge remaining: two `play` calls on the same entity in one deferred scope create two instances; last set wins.)
- [x] `tween.tl:509,997` eager-concat asserts on the play path replaced with `if not x then error(...) end`.
- [x] `physics.tl:496` invalid `smoothing` string silently disabled transform sync; now errors at `physics.new`.
- [x] `physicsDebug.tl:96` `Config.debug = true` was dead; debug overlay now seeds `enabled` from it.
- [x] `mcp/init.tl` malformed JSON-RPC envelopes (non-table body, missing `params`/`name`, non-table `params`) crashed the game loop; guards added in `processMessage`, `handleToolsCall`, `handleInitialize`.
- [x] `mcp/init.tl:548,995` `query`/`query_in_bounds` registered a permanent query per call (unbounded leak) and `break` at the row limit leaked query scope; now `temp = true` and iterate-to-exhaustion.
- [x] `mcp/init.tl:762` `run_lua` code ending in a `--` comment swallowed the closing `end`; wrapper now uses a newline.
- [x] `gfx/internal/pipeline.tl:406` primary camera missing from `_camerasByName`, so snapshot load never restored it and `getCamera("__primary")` returned nil.
- [x] `gfx/internal/sprite/init.tl:642` `gotoFrame` on a playing sprite never marked the Sprite column dirty (no visual effect); `pause`/`pauseAtEnd`/`gotoFrame` also crashed on zero-initialized (batchSpawn) sprites — guards added.
- [x] `gfx/internal/circle/circle_cull.glsl:96` mirrored circles (negative scale) were culled; now uses scale magnitude like every other shape. **Needs a visual check** (GPU specs are pending without LÖVE 12).
- [x] `gfx/internal/arc/arc.glsl:124` full-circle arcs (including default `Arc(r)`) discarded nearly all pixels because a 2π sweep normalizes to a zero-width range. **Needs a visual check.**
- [x] `types/love2d.d.tl:841` + `gpu/buffer.tl` + `spec/love2d/love2d_mock.tl` declared `setArrayData(data, destIndex, srcIndex, count)`; actual LÖVE 12 order is `(data, srcIndex, destIndex, count)` (verified against `wrap_Buffer.cpp`). Declarations corrected so nobody "fixes" the correct call sites in `shadow_buffer.tl:117` / `archetype_shadow_set.tl:174`.
- [x] Stale defaults arrays in arc/ellipse/rectangle components (extra trailing `-1` from a removed field).
- [x] Wrong/stale/historical comments: assets worker path message, audio manager, physics (x2), MCP (x3), stats `gcFrequency`, LayoutBox origin docs (x3), `Light.penumbra` default, RoundedCorners `requires` claim.

## P0 — GPU memory safety and render-wrong (open)

- [ ] **Drop-shadow fan-out writes past buffer capacity.** `sprite_cull.glsl:398` guards only against a hardcoded `MaxDropShadows = 65536` (`sprite/init.tl:1249`), but on the bucket path `dropShadowOutputBuffer` is sized to the live entity count (`bucket_sync.tl:186-189`). N sprites x M lights overruns the SSBO: GPU corruption/driver crash. Size with a fan-out multiplier and send the real capacity as `MaxDropShadows`.
- [ ] **TextEffects std430 stride mismatch (68 vs 80 bytes).** CPU packs 17 tight floats (`gpu/std430.tl:113-125,703-711`); `text_cull.glsl:48-54` declares vec4-grouped struct with std430 array stride 80. Every row past the first reads misaligned. Pad to 80 on all three layers or declare 17 scalars everywhere.
- [ ] **Blend-batch cull binds a 1-element dummy as `MaterialParamsOutput`** while cull shaders write it per visible instance (`gpu/shape_utils.tl:176-178`): OOB write for any blend batch with >1 visible entity. Bind the sized buffer or gate the write on `MaterialPass >= 0`.
- [ ] **Buffer grow without pinning (known UAF class), several sites.** `gpu/buffer.tl:158-206` (also no initial-capacity floor: grow chains 1→4→16 in one frame), `render_column.tl:158-192`, `bucket_sync.tl:182-191`, `sprite/shadow_dispatch.tl:184-203`, `mesh/definition.tl:120-134`, `tilechunk/init.tl:274-297`, `shadow_plugin.tl:159` (2x growth vs the adopted 4x policy), `shadow_buffer.tl:120-149`, `physicsDebug.tl:130` (mesh release mid-frame). Decide once: a one-frame retire list for replaced GPU buffers, applied everywhere.
- [ ] **CPU Draw-phase content renders twice when screen layers exist.** `currentLayerMin/Max` is never narrowed per phase in the single-pass path (`pipeline.tl:1283,1743,1651-1652`); the screen pass re-runs the same `gBufferCb` with an identity camera, ghosting particles and `worldShader()` draws. Set the range for world and screen passes explicitly. Related: screen-phase CPU draws inherit world camera rotation (`pipeline.tl:494`), and layer-effect groups span the screen boundary (`layer_effects.tl:142-212` vs `pipeline.tl:1476-1647`).
- [ ] **Tiled crashes:** `map:toJSON()` puts the FFI tile pointer straight into the serializer and throws for every map with a tile layer (`tiled/internal/parser.tl:222`); infinite maps (`chunks` array) nil-index at spawn instead of a clear error (`parser.tl:711-759`); CSV branch has an unbounded FFI write (heap corruption) and wrong type assumption (`parser.tl:739-748`).

## P1 — Major correctness (open)

### Rendering pipeline / camera
- [ ] Removing a `Light` component (vs despawn) leaves a phantom light forever; slots only freed on despawn (`Light.tl:396-402`).
- [ ] `lightingMode = "none"` still pays tile-cull reset + compute dispatch + full light GPUSync every frame; `lightCullShader` compiled at require time (`Light.tl:12,225-249,337-393`).
- [ ] `setPixelMode` never resizes layer-effects canvases; toggling retro off clips the frame to a virtual-res corner (`pipeline.tl:517,666-676`).
- [ ] Retro mode: `Camera:updateBounds` stomps the render-corrected transform each frame, so `toWorld`/`toScreen` are off by the fractional scale + letterbox offset during gameplay (`Camera.tl:694-697`, `pipeline.tl:1325-1346`). Same class: `queryLightAt` mapping ignores `_intOffsetX/Y` (`pipeline.tl:1860`).
- [ ] Standalone `gfx.newCamera` without `virtualHeight` crashes in the constructor (`Camera.tl:398,658`).
- [ ] Disabled entities keep rendering and casting shadows: the shadow-column registries bypass queries and never exclude `Disabled` (`gpu/shadow_plugin.tl:228`; audit sprite/mesh/text `shadow_setup.tl` too).

### Sprites
- [ ] Play-once clamp is dead on the GPU: the `pausedFrame <= -2` sentinel is never written and the shader never reads `pauseAtFrame`; `pauseAtEnd()` visibly loops forever (`sprite_cull.glsl:294-304`, `sprite/init.tl:615-627`).
- [ ] `sprite.PlayOnce` dirties every sprite archetype every frame while any callback is pending, forcing full world re-sync (`sprite/init.tl:1386-1394`).
- [ ] `textureSlice` float packing corrupts layer bits at generation >= 256; the bucket_manager comment asserting safety is wrong (`bucket_sync.tl:521`, `bucket_manager.tl:399-403`). Note `Manager:remove` currently has no caller, so generations never increment — decide whether eviction is real, then fix packing accordingly (`bucket_manager.tl:387-410`).
- [ ] Aseprite `reverse`/`pingpong` tag directions silently play forward on the GPU path (`sprite/init.tl:373-378` vs `sheet.tl:374-430`).
- [ ] Grid-UV math walks off the sheet edge for tags starting mid-row that wrap (`sprite.glsl:89-97`, `drop_shadow_sprite.glsl:87-93`).
- [ ] Replacing a Sprite via `world:set` on an entity that already has one leaks the instance refcount and keeps stale bucket tags (`sprite/init.tl:1316-1345`).
- [ ] Drop-shadow cull reads tile-light SSBOs that may be unbound when lighting is off (`sprite/init.tl:1251-1257`, `sprite_cull.glsl:376-383`).

### Text / materials
- [ ] No UTF-8 decoding: layout iterates bytes, so any non-ASCII text renders wrong glyphs (`text/glyph_slab.tl:140-141`).
- [ ] Multi-font atlases broken twice: UVs normalized per-font but sampled from a max-sized array (`text/sync.tl:254-284` vs `glyph_slab.tl:186-189`), and a single global `PxRange` means the last-registered SDF font wins (`sync.tl:251-306`; `sdfDistanceRanges` written, never read).
- [ ] Text sync re-copies all glyphs for a whole archetype when ANY column (e.g. Transform) is dirty, and re-dirties Text via `getMut`, forcing full re-upload every frame for moving text (`text/sync.tl:207-215,137`).
- [ ] Slab dedup key `face .. page` collides across distinct fonts with generic atlas names (`glyph_slab.tl:265`); collision probing is write-only so dedup degrades permanently after one collision (`glyph_slab.tl:277-283`).
- [ ] Material-variant text loses drop shadows (no ShadowPass=1 dispatch in the variant loop) and blend+material text renders nothing (`text/render_plugin.tl:175-260`).
- [ ] Effects with width but no color are invisible (alpha defaults 0) (`text/effects.tl:62-70`).

### Shapes / mesh / tilechunk
- [ ] Cull-vs-render mismatches: ellipse bounds ignore Pivot (`ellipse_cull.glsl:91`), rect bounds ignore pivot-relative rotation (`rect_cull.glsl:186-200`), line bounds use unrotated endpoints (`line_cull.glsl:77-80`). All pop visibly on-screen entities.
- [ ] Mesh Pivot is wrong twice (normalized value subtracted from local units; ignored in cull bounds) (`mesh/mesh.glsl:55`, `mesh_cull.glsl:105-143`).
- [ ] Arc registers Pivot but never applies it, and rotation only rotates the angular range, not elliptical geometry (`arc/init.tl:73`, `arc.glsl:51-64,121`).
- [ ] Ellipse/arc missed the packed-BlendId migration: blend routing comments point at an empty mechanism; forward blend can `send` an inactive uniform (LÖVE error) (`ellipse_cull.glsl:10-12,111`, `arc_cull.glsl:10-12,115`, `shape_utils.tl:318-322`).
- [ ] Tilechunk occluder height unit confusion: 0-1 normalized with `Occluder` present, 64 px without; `Occluder.tl` docs self-contradictory (`tilechunk/init.tl:652-660`, `Occluder.tl`).

### Tiled
- [ ] External tileset image paths resolved relative to the map instead of the .tsj (`tiled/init.tl:486`); unreadable `.tsj` fails silently (`init.tl:463-481`); same audit needed in `assets/internal/threaded.tl:963`.
- [ ] D+H and D+V flip combinations are swapped for animated tile sprites (`tiled/internal/chunk.tl:339-346`).
- [ ] Chunk collision ignores the tilemap entity's Transform: visuals and physics disagree by exactly the offset (`tiled/collision.tl:297-298`, `init.tl:592-599`).
- [ ] `mergeShapes = false` is a no-op: both branches identical, comments wrong, no collinear merging exists anywhere (`collision.tl:475-495,548-566`).
- [ ] Zero-duration tile animations hang the engine (`tiled/internal/animation.tl:38-40`).
- [ ] Chunked collision leaves ghost-collision seams at chunk borders (`collision.tl:249-334`).
- [ ] Collision chunk size hardcodes 16 next to `gfx.TILE_CHUNK_SIZE` with only a comment tying them (`collision.tl:40-41`); also hardcoded `256` in `chunk.tl:250,406`.

### UI / core runtime
- [ ] `ApplyScrollOffset`/`ApplyClipBounds` walk every `ChildOf+Transform` entity per frame with `world:walkUp`, plus per-frame ClipBounds set/remove churn, even with zero UI (`ui/internal/LayoutNode.tl:131-141,180-193`). Early-out on empty maps and scope the query.
- [ ] Scroll offset drifts entities lacking `RelativeTransform` (subtract re-applied every frame) (`LayoutNode.tl:131-141`).
- [ ] `ui.RelativeTransform` re-composes every parented entity per frame (up to 32 passes) with unconditional `getMut`, duplicating the core pass (`ui/internal/LayoutBox.tl:214-276`).
- [ ] FitContent writes render components via `world:get` without marking dirty (`ui/internal/FitContent.tl:215-222`; also `ui/init.tl:64-84`).
- [ ] Unconditional `getMut` defeats dirty-skip across UI systems (`LayoutBox.tl:178-180`, `FitContent.tl:171`, `Anchor.tl:105`), audio (`audio/init.tl:314,357`), tiled `AssetLoader` (`tiled/init.tl:546`), `particles.tl:268`, `sprite.CollisionSetup` (`sprite/init.tl:1416-1464`).

### Audio / assets
- [ ] `muteGroup("master")` doesn't silence other groups; mutes overridden by in-progress fades; component sources skipped (`audio/internal/manager.tl:153-168`). Route through `applyVolumeToSources`.
- [ ] `setGroupVolume` during a fade-out retargets it upward: paused flag desyncs, stops fade up before cutting (`manager.tl:113-120`).
- [ ] `pitchVariance` is wiped one frame after playback starts; re-rolled every frame while stopped (`audio/init.tl:265-272`).
- [ ] Non-looping component sources retrigger forever (nothing clears `playing`) (`audio/init.tl:277-286`).
- [ ] A throwing `observe` callback permanently corrupts `_runningCount`: `isLoading()` stuck true, `wait()` never returns (`assets/internal/threaded.tl:600-604`).
- [ ] Failed loads cached forever; the "cache on success" block is dead and its comment wrong (`threaded.tl:429-430,606-610`). Decide the retry policy.
- [ ] Worker ships whole video/font files across the channel only to discard them (`worker.tl:34-52` vs `threaded.tl:517-551`).
- [ ] `getFont` misses `loadImageFont` entries despite its doc (`threaded.tl:465-471`).
- [ ] `shutdown()` leaves `_runningTasks` unresolved: blocking `.value` spins forever (`threaded.tl:662-696`); `wait()`/blocking `.value` also busy-spin at 100% CPU (`threaded.tl:644-649,275`).
- [ ] `removeGroupEffect` leaks the global LÖVE effect slot (`manager.tl:565-588`).

### MCP
- [ ] `debug_draw` stores unvalidated args that detonate in the render system every frame, forever (`mcp/init.tl:1273-1292,2001`). Validate at the boundary.
- [ ] `screenshot` region args unvalidated; errors fire in the capture callback outside pcall and wedge `pendingScreenshotId`/the connection (`init.tl:182-207`).
- [ ] `patch_entities` queued op runs unprotected in the drain (bad ids crash a frame after the client got `queued=true`); per-entity results only go to the log (`init.tl:852-888,158-169`).
- [ ] `toggle_system` wrapper accumulation when original `runIf` was nil: each disable/enable cycle nests another per-frame closure (`init.tl:1078-1113`).
- [ ] Partial/timed-out socket sends ignored: multi-MB responses silently truncate (`init.tl:111`); request-body read discards partials on a >50ms stall (`init.tl:1786-1789`).
- [ ] `tools/list` hand-built JSON breaks for string/missing ids (`init.tl:1711`); the whole hand-rolled serializer in `tools.tl:418-474` is obsoleted by `json.EMPTY_OBJECT`.
- [ ] `snapshot_save` layer mask corrupted by duplicate layers; 0..31 unvalidated (`init.tl:1507`); json inline path serializes the snapshot twice (`init.tl:1459-1496`).
- [ ] `cleanup` leaves stale module state (paused, debug commands, pending responses) for a second world in-process (`init.tl:1888-1899`).

### Physics / tween
- [ ] Finished tween slots re-apply and re-dirty components every frame until the timeline ends (`tween.tl:1272-1289`).
- [ ] `physics.applyTransform` writes and dirties Transform for every collider every frame, including sleeping bodies (`physics.tl:904-940`).
- [ ] Child pingPong cycles fire all emits in a burst each reverse cycle (`tween.tl:1330-1339`).
- [ ] Snapshot restore + replay duplicates nested run-timeline templates (`tween.tl:861-941`; `objectIds` not repopulated).
- [ ] Looping absolute single-slot tweens freeze after one cycle (re-capture semantics) — document or fix (`tween.tl:543-577,1367-1382`).
- [ ] Collider `restitution`/`friction` can never act as fallbacks for dynamic bodies despite the comment (`physics.tl:66-67,814`); shape user data (layer/filters) frozen at creation with no update path (`physics.tl:686-692`).

## P2 — Performance (open, mostly dirty-skip and per-frame allocation)

- [ ] `light.GPUSync` rewrites and re-uploads every light every frame, no change detection (`Light.tl:337-393`).
- [ ] Text `countLive` walks every text row every frame (`text/render_plugin.tl:72-95`); mesh `countLivePerDefinition` same pattern plus a table per frame (`mesh/init.tl:145-178`); shadow_render_state per-row Material walk (`shadow_render_state.tl:77-87`); bucket_sync per-row material walk (`bucket_sync.tl:428-435`). All want incremental counts or dirty gates.
- [ ] `Registry:archetypes()` allocates a closure per call in per-frame paths; return a stateless iterator (`archetype_registry.tl:128-136`).
- [ ] Loop-invariant shader sends re-sent per archetype/pass/frame: shadow_dispatch (`gpu/shadow_dispatch.tl:183-211`, `text/shadow_dispatch.tl:226-237`, `mesh/shadow_dispatch.tl`), layer-effect uniforms via `pairs` per pass (`pipeline.tl:1547-1605`), forward-blend RenderParams re-populated per shape (`forward_blend.tl:122`, `shape_utils.tl:307`), `hasUniform` sniffs per frame (multiple), `setFilter`/`setWrap` per draw (`sprite/render_plugin.tl`, `text/render_plugin.tl`).
- [ ] Per-frame table allocations: `Renderer:cull()` 6 tables + `C.new` (`gpu/init.tl:278-341`), `setAmbientLight` (`pipeline.tl:737`), tween `emptyEntities` (`tween.tl:1500`), LayoutNode maps (`LayoutNode.tl:115-172`), tilechunk `toClean` (`tilechunk/init.tl:568`), tiled dirty-chunk string keys + iterator closures (`tiled/init.tl:368-376`, `chunk.tl:593-613`), physicsDebug per-frame `getBodies`/`getShapes`/points tables (`physicsDebug.tl:193-293`).
- [ ] Screen phase pays a full-res lighting pass just to hit the unlit early-exit (`pipeline.tl:1287-1291`); `renderShadowMask` redraws + blurs every frame with no change detection (`gpu/init.tl:520-587`).
- [ ] Dead VRAM: `screenAccumulator`/`screenEffectTemp`/`screenLitLayer` (~44MB at 1440p, never read) (`layer_effects.tl:94-96`); `pixelShadowMask` never used (`gpu/init.tl:208`); physicsDebug allocates 2MiB + 64k-vert mesh at install even if never enabled (`physicsDebug.tl:99-103`), full-capacity upload per frame (`physicsDebug.tl:325`).
- [ ] Audio: `sourceQuery` iterated twice per frame; merge the two systems (`audio/init.tl`). Tiled `AnimationUpdate` maintains state nothing reads (`tiled/init.tl:334-348`) — delete or fix external-tileset registration (`parser.tl:858` vs `init.tl:466`).
- [ ] MCP idle path is clean, but blocking reads on the frame thread cost 50-150ms per slow connection (`init.tl:1756-1782`).

## P3 — Cleanup: dead code, duplication, conventions

### Dead code (verified no callers)
- [ ] `gpu/render_column.tl` — entire module dead, with self-contradictory row convention. Delete or fix before it grows a caller.
- [ ] `gpu/types.tl` dead exports: `BlendBatch`, `SpriteTextureBatch`, `GPUSpriteMetadata`+format, `GPUTextGlyphInstance`+format, `GPUGlyphSlabEntry`+format, `registerForwardBlend`/`forwardBlendRenderers` (declared, implemented nowhere, declarations disagree).
- [ ] `forward_blend.makeSimpleShapeRenderer` + module doc describing a nonexistent registration API (`forward_blend.tl:5-7,129-176`).
- [ ] `Layer.draws`/`Layer.lights`, `ScaleMode` enum (`pipeline.tl:510`, `gfx/types.tl:10-15,368-372`); stale "CPU draw queue" header (`pipeline.tl:3`); dead retro-fallback branches (`pipeline.tl:1248-1251,1336-1345`); `screenAlbedo` fallback chains that are always nil (`pipeline.tl:1292,1421,1445`).
- [ ] `bucket_sync.getArraySyncs`/`getActiveTiers`, dead lazy-create branch + stale comment (`sprite/init.tl:1211-1222`), dead "default animation values" block (`sprite/init.tl:340-348`); GPU copy of RepeatedSprite stretching neutralized by CPU pre-scaling (`bucket_sync.tl:482-498` vs `sprite_cull.glsl:174-191`) — delete one.
- [ ] `shadow_render_state.newFrame`, `shadow_buffer.getCapacity`, `glyph_block` `initialGpuCapacity` param, `Cursor.target`, tween snapshot `nextId`, `_hasBlockedOnce`/`_channelId` in threaded.tl, `ControlManager:_hasJoystickActivity` dead nil-check, `composeTransformsWithOrigin` dead param + column fetch (`LayoutBox.tl:133,228`), mcp dead conditionals (`init.tl:334-340,1758-1762`), tiled debug dead polygon/polyline color branches (`tiled/internal/debug.tl:154-187`).

### Duplication worth collapsing
- [ ] Per-shape `init.tl` shader bootstrap (5 identical lines x5 shapes) → fold into `define_shape.register`. The observed drift bugs (circle abs-scale, arc pivot, ellipse/arc blendId) are the argument.
- [ ] Four shadow-mask shaders share quad/transform/encode epilogue; extract `shadow_mask_common.glsl`. Mask buffer block names inconsistent (`CircleOutput` vs `SpriteShadowOutput`).
- [ ] `mesh/shadow_setup+dispatch` near-clones of `gpu/shadow_plugin+dispatch`; third copy of `dummyFor` helper; mesh hand-copies modifier masks instead of `modifier_binding.bind` (`mesh/init.tl:107-135`).
- [ ] `setOrthographic` copy-pasted 3x (`pipeline.tl:32`, `Camera.tl:8`, `gpu/init.tl:17`/`forward_blend.tl:15`); shadow-VP construction duplicated between mask and lighting passes (`gpu/init.tl:547-555,650-657`).
- [ ] Resize observer duplicates `setScreenSize` verbatim (`pipeline.tl:595-611` vs `1065-1080`); layer-effect ping-pong blocks near-identical (`pipeline.tl:1541-1637`); `resolveLayer` block repeated 8x (`pipeline.tl:942-1058`).
- [ ] tiled: `collectEdges`/`collectChunkEdges` (~80 lines), `createColliders`/`createChunkCollider`, tileset back-search 3x bypassing the cached helper, `worldToTile`/`tileToWorld` implemented twice (init.tl vs parser.tl).
- [ ] physics: four near-identical Box2D contact callbacks (~100 lines); five copies of the "Shape and Fixture merged" comment.
- [ ] audio: `UpdateRelativeSources` two blocks line-identical; `applyGroupEffects` duplicates `registerComponentSource` loop; assets: 4 derived-handle constructors + 6 pcall wrappers (`threaded.tl`).
- [ ] mcp: `requireWorld`, `deserializeComponents`, `serializeRow`, `collectIds` helpers would remove ~24 copies of boilerplate; two inconsistent "world unavailable" messages.
- [ ] text: `setText`/`setScale` ~45 shared lines; `findFreeRange` byte-identical in slab and block; bmfont `loadText`/`loadJson`; material_compiler identical CALL_SITE strings.
- [ ] ui: `measureContent` vs FitContent `measureChild`; `stackVertical`/`stackHorizontal` axis mirrors; `SizableBox` subset of `SizableLayoutBox`.
- [ ] blend: `unifiedGroupBy` 14-branch chain reimplements `blend.groupBy` (`bucket_sync.tl:249-264`); tier detection written 3x in bucket_sync.

### Comment audit (wrong or historical; convention violations)
- [ ] Wrong struct/size comments in `gpu/types.tl` (:898, :905-908, :928, :949, :971, :995, :1018) and `gpu/std430.tl` (:175-180, :204-206, :536-543, :572-574, plus "All-scalar" on TextEffects).
- [ ] `buffer.tl:65` says grow "doubles"; code quadruples deliberately (Metal mitigation) — document the why.
- [ ] Shadow mask shader struct comments describe lanes that don't exist (`shadow_mask_circle.glsl:9`, `shadow_mask_sprite.glsl:15`); `cull_common.glsl:121-131` COMP list missing `SpriteData = 0x400` despite "must match" contract.
- [ ] Historical comments (convention: present tense only): shadow module headers (4 files), bucket_sync/sprite init "legacy slot" comments (~8 sites), shape GLSL "legacy sync.tl:NNN" citations (~10 sites), `text.glsl` (:4, :105, :321), tilechunk init (5 sites), `modifier_binding.tl:9,18`, `std430.tl:538`, `types.tl:37`.
- [ ] Misc wrong docs: `queryLightAt` stale doc block stacked on the correct one (`pipeline.tl:1831`); `setTimeScale` range docs disagree with clamp in two places (`gfx/types.tl:246`, mcp `tools.tl:285`); `shadowSteps` default 10 vs 24 (`gpu/types.tl:386` vs `gpu/init.tl:59`); `glyph_block.addFreeRange` claims coalescing it doesn't do (:84, and it should — free ranges never merge, GPU slots only grow); kerning string-key rationale false (`bmfont/init.tl:64-66,122`); `events.Focus.visible` misnamed field (`events.tl:163`); tiled `buildGidCache` name, chunk.tl orphaned comments (:310-314); threaded.tl `wait()` timeout comment; audio "immutable-after-init" contradiction (`manager.tl:695` vs `init.tl:251`).
- [ ] snake_case identifiers beyond module-alias convention: `quit_func` (handlers), `math_pi` etc. (tween), `cos_a/sin_a` (physicsDebug), `write_tile_data`/`ffi_offset_ptr` (tilechunk/buffer/std430), `::continue_arch::`, record names `layer_effects`/`pipeline_key`/`archetype_registry` leaking into type paths.
- [ ] Statements starting with `(cast)` (convention: bind a local): `tecs2d/init.tl:139-164,355,505` (26 re-export lines), `tiled/init.tl:490-527` (5 sites), `mcp/init.tl:1089-1099`.

## Recommendations (thematic, for iteration)

1. **Adopt one GPU-buffer lifecycle module.** The grow-without-pin bug exists in at least 8 places with 3 different growth factors (1x-exact, 2x, 4x). One `growBuffer(old, newCap)` helper with a frame-end retire list kills the whole class and encodes the 4x Metal policy.
2. **Make dirty-skip auditable.** The single most common defect (20+ findings) is `getMut`/unconditional writes defeating the per-archetype dirty model, or its inverse (writes via `get` that never mark dirty). Consider a debug validator that flags archetypes marked dirty every frame for N frames, and a lint for `getMut` in system loops that don't write.
3. **Collapse per-shape boilerplate into `define_shape`.** Every cross-shape drift bug found (circle scale, arc pivot, ellipse/arc blend, rect flags) lives in copy-pasted shape files/shaders. Shared includes + registration-driven bootstrap makes the next fix land everywhere.
4. **Harden the MCP boundary as a policy.** Every tool that stores state for later frames (debug_draw, screenshot, patch_entities) must validate at the handler and pcall at the consumer; nothing reachable from a socket should be able to raise inside the pipeline.
5. **Decide the screen-phase contract.** C1 (double render), M6 (rotation), M7 (layer-effect groups), and the wasted screen lighting pass are all symptoms of the screen phase reusing world-phase machinery without narrowing state. Worth one focused design pass.
6. **UTF-8 and multi-font support in text** are product-level gaps, not bugs; schedule deliberately.
7. **Tiled correctness sweep** (paths, flips, transforms, infinite maps) would benefit from a fixture-based spec suite using real Tiled exports; most bugs there are testable headless.
8. **Delete dead weight early**: `render_column.tl`, dead gpu/types exports, dead canvases, and the unused tiled animation system are pure risk with zero value.

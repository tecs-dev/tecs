--- GPU instance data types for instanced rendering.
--- These structs match the GLSL std430 layout exactly.

local C <const> = require("ffi")

-- Define FFI structs (must match GLSL shader layouts)
C.cdef[[
    // Transform instance data (32 bytes, vec4-aligned for Metal compatibility)
    // Cannot bulk-copy from ECS Transform (28 bytes) - must copy field-by-field.
    // Layout: 2x vec4 for std430 compatibility
    typedef struct {
        float x, y, z;              // position (12 bytes)
        float layerFloat;           // render layer as float (4 bytes) - total 16 bytes
        float rotation;             // rotation in radians (4 bytes)
        float scaleX, scaleY;       // scale factors (8 bytes)
        float flags;                // RenderFlags bitmask (4 bytes) - total 32 bytes
    } GPUTransformInstance;

    // Sprite metadata (128 bytes, 16-byte aligned for std430)
    // Synced only on entity add/move events via archetype callbacks.
    // Contains everything EXCEPT position data (which comes from Transform).
    typedef struct {
        float pivotX, pivotY;       // pivot point for rotation/scale (8 bytes)
        float width, height;        // sprite dimensions (8 bytes) - total 16 bytes
        float uvX, uvY, uvW, uvH;   // texture UV rect (16 bytes) - total 32 bytes
        float r, g, b, a;           // color (16 bytes) - total 48 bytes
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clip bounds (16 bytes) - total 64 bytes
        float animStartTime;        // when animation started (4 bytes)
        float animTotalDuration;    // total animation loop duration (4 bytes)
        float animFrameCount;       // number of frames (4 bytes)
        float animFrameWidth;       // frame width in UV space (4 bytes) - total 80 bytes
        float animColumnCount;      // frames per row for grid animation (4 bytes)
        float animFrameHeight;      // height of one frame in UV space (4 bytes)
        float animTimingOffset;     // offset into timing buffer (as float) (4 bytes)
        float animPausedFrame;      // paused frame index (-1 = not paused, >= 0 = paused at frame) - total 96 bytes
        float occluderHeight;       // height for shadow casting (4 bytes)
        float _padLM;              // padding (was lightMask) (4 bytes)
        float textureSlice;         // texture array slice index (4 bytes)
        float blendId;              // blend mode ID (0=alpha, 1-14=blend modes) - total 112 bytes
        float dropShadowHeight;     // entity height for shadow projection (4 bytes)
        float dropShadowOpacity;    // drop shadow darkness 0-1 (4 bytes)
        float _padDS1;              // padding (4 bytes)
        float _padDS2;              // padding (4 bytes) - total 128 bytes
    } GPUSpriteMetadata;

    // Sprite instance data for cull output (128 bytes, 16-byte aligned for std430)
    // Used by cull shader to write visible sprite data for rendering
    // Supports GPU-side animation: shader computes current frame from time
    // Supports grid-based sprite sheets (frames in rows, not just horizontal strip)
    typedef struct {
        float x, y, w, h;           // posSize (vec4)
        float r, g, b, a;           // color (vec4)
        float layer, z, animColumnCount, animFrameHeight;  // layerZ (vec4) - grid anim data
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float uvX, uvY, uvW, uvH;   // uvRect (vec4) - base UV (uvX is first frame's U)
        float animStartTime;        // when animation started (with random offset for desync)
        float animFrameDuration;    // duration per frame in seconds
        float animFrameCount;       // number of frames (1 for static sprites)
        float animFrameWidth;       // width of one frame in UV space
        float rotation, scaleX, scaleY, textureSlice;  // rotScale (vec4) - texture array slice
        float pivotX, pivotY, flags, screenSpaceFlags; // pivot (vec4) - render flags
    } GPUSpriteInstance;

    // Circle transform (32 bytes, 16-byte aligned for std430)
    // Synced every frame. Includes radius so it animates without dirty tracking.
    // Note: circles don't need rotation (a rotated circle looks identical), so we
    // repurpose that slot for radius, keeping the same 32-byte size as generic transforms.
    typedef struct {
        float x, y, z;              // position (12 bytes)
        float layerFloat;           // render layer as float (4 bytes) - total 16 bytes
        float radius;               // circle radius (4 bytes) - replaces rotation
        float scaleX, scaleY;       // scale factors (8 bytes)
        float flags;                // RenderFlags bitmask (4 bytes) - total 32 bytes
    } GPUCircleTransform;

    // Circle metadata (48 bytes, 16-byte aligned for std430)
    // Synced only when entity is dirty. Contains style properties.
    typedef struct {
        float lineWidth, occluderHeight, _padLM, blendId;  // lineWidth + occluder + pad + blendId (vec4)
        float r, g, b, a;           // color (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
    } GPUCircleMetadata;

    // Ellipse transform (32 bytes, 16-byte aligned for std430)
    // Synced every frame. Includes pre-scaled radii so they animate without dirty tracking.
    typedef struct {
        float x, y, z;              // position (12 bytes)
        float layerFloat;           // render layer as float (4 bytes) - total 16 bytes
        float scaledRadiusX;        // radiusX * scaleX (pre-computed CPU-side)
        float scaledRadiusY;        // radiusY * scaleY (pre-computed CPU-side)
        float rotation;             // rotation in radians (4 bytes)
        float flags;                // RenderFlags bitmask (4 bytes) - total 32 bytes
    } GPUEllipseTransform;

    // Ellipse metadata (64 bytes, 16-byte aligned for std430)
    // Synced only when entity is dirty. Contains style properties.
    typedef struct {
        float lineWidth, blendId, _pad1, _pad2;  // lineWidth + blendId (vec4)
        float r, g, b, a;           // color (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float pivotX, pivotY, _pad3, _pad4;  // pivot (vec4)
    } GPUEllipseMetadata;

    // Arc transform (48 bytes, 16-byte aligned for std430)
    // Synced every frame. Includes pre-scaled radii and angles so they animate without dirty tracking.
    typedef struct {
        float x, y, z;              // position (12 bytes)
        float layerFloat;           // render layer as float (4 bytes) - total 16 bytes
        float scaledRadiusX;        // radiusX * scaleX (pre-computed CPU-side)
        float scaledRadiusY;        // radiusY * scaleY (pre-computed CPU-side)
        float startAngle;           // arc start angle in radians
        float endAngle;             // arc end angle in radians - total 32 bytes
        float rotation;             // rotation in radians (4 bytes)
        float flags;                // RenderFlags bitmask (4 bytes)
        float _pad0, _pad1;         // padding to 48 bytes
    } GPUArcTransform;

    // Arc metadata (64 bytes, 16-byte aligned for std430)
    // Synced only when entity is dirty. Contains style properties.
    typedef struct {
        float lineWidth, blendId, _pad1, _pad2;  // lineWidth + blendId (vec4)
        float r, g, b, a;           // color (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float pivotX, pivotY, _pad3, _pad4;  // pivot (vec4)
    } GPUArcMetadata;

    // Line transform (32 bytes, 16-byte aligned for std430)
    // Synced every frame. Includes pre-computed world endpoints so they animate without dirty tracking.
    typedef struct {
        float worldX1, worldY1;     // scaled endpoint 1 (8 bytes)
        float worldX2, worldY2;     // scaled endpoint 2 (8 bytes) - total 16 bytes
        float z, layerFloat;        // depth info (8 bytes)
        float rotation, flags;      // rotation + flags (8 bytes) - total 32 bytes
    } GPULineTransform;

    // Line metadata (48 bytes, 16-byte aligned for std430)
    // Synced only when entity is dirty. Contains style properties.
    typedef struct {
        float lineWidth, blendId, _pad1, _pad2;  // lineWidth, blendId (vec4)
        float r, g, b, a;           // color (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
    } GPULineMetadata;

    // Circle instance data (64 bytes, 16-byte aligned) - OUTPUT from cull shader
    typedef struct {
        float x, y, radius, screenSpaceAndBlend;  // posRadius (vec4) - screenSpaceAndBlend: bits 0-2=screenSpace flags, bits 4-7=blendId
        float r, g, b, a;           // color (vec4)
        float layer, z, lineWidth, flags;  // layerZLineFlags (vec4) - lineWidth > 0 for outline, flags as float
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
    } GPUCircleInstance;

    // Ellipse instance data (80 bytes, 16-byte aligned)
    typedef struct {
        float x, y, radiusX, radiusY;  // posRadii (vec4)
        float r, g, b, a;              // color (vec4)
        float layer, z, lineWidth, flags;  // layerZLineFlags (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float pivotX, pivotY, rotation, _pad1;  // pivot (vec4) - pivotX, pivotY, rotation angle, pad
    } GPUEllipseInstance;

    // Arc instance data (96 bytes, 16-byte aligned)
    typedef struct {
        float x, y, radiusX, radiusY;  // posRadii (vec4)
        float r, g, b, a;              // color (vec4)
        float layer, z, lineWidth, flags;  // layerZLineFlags (vec4)
        float startAngle, endAngle, rotation, _pad0;  // angles (vec4) - radians
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float pivotX, pivotY, _pad1, _pad2;  // pivot (vec4) - for rotation/scale origin
    } GPUArcInstance;

    // Line instance data (80 bytes, 16-byte aligned)
    typedef struct {
        float x1, y1, x2, y2;          // points (vec4)
        float r, g, b, a;              // color (vec4)
        float layer, z, lineWidth, flags;  // layerZLineFlags (vec4)
        float centerX, centerY, rotation, _pad;  // centerRot (vec4) - rotation center and angle
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
    } GPULineInstance;

    // Rectangle transform (32 bytes, 16-byte aligned for std430)
    // Synced every frame. Includes pre-scaled dimensions so width/height animate without dirty tracking.
    typedef struct {
        float x, y, z;              // position (12 bytes)
        float layerFloat;           // render layer as float (4 bytes) - total 16 bytes
        float scaledWidth;          // width * scaleX (pre-computed CPU-side)
        float scaledHeight;         // height * scaleY (pre-computed CPU-side)
        float rotation;             // rotation in radians (4 bytes)
        float flags;                // RenderFlags bitmask (4 bytes) - total 32 bytes
    } GPURectTransform;

    // Rectangle metadata (64 bytes, 16-byte aligned for std430)
    // Synced only when entity is dirty. Contains style properties.
    // Note: rx, ry (corner radius) require dirty tracking when changed.
    typedef struct {
        float lineWidth, occluderHeight, _padLM, blendId;  // outline width + occluderHeight + pad + blendId (16 bytes)
        float r, g, b, a;           // color (16 bytes) - total 32 bytes
        float rx, ry, pivotX, pivotY;  // corner radius + pivot (16 bytes) - total 48 bytes
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clip bounds (16 bytes) - total 64 bytes
    } GPURectMetadata;

    // Rectangle instance data (96 bytes, 16-byte aligned) - OUTPUT from cull shader
    typedef struct {
        float x, y, w, h;           // posSize (vec4)
        float r, g, b, a;           // color (vec4)
        float layer, z, rotation, lineWidth;  // layerZRotLine (vec4)
        float rx, ry, scaleX, scaleY; // cornerRadius + scale (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        uint32_t flags, depthBits, pivotXBits, pivotYBits;  // flags (uvec4) - depth/pivot stored as float bits
    } GPURectInstance;

    // Light instance data (64 bytes, 16-byte aligned)
    // Supports both point lights (cosConeAngle = 1.0) and spotlights (cosConeAngle < 1.0)
    // Direction stored as precomputed (cos, sin) to avoid trig in fragment shader
    typedef struct {
        float x, y, z, radius;                                // posHeight (vec4): x, y, height, falloff radius
        float intensity, r, g, b;                              // intensityColor (vec4)
        float spotDirX, spotDirY, cosConeAngle, cosInnerConeAngle;  // spotParams (vec4): precomputed dir + cone cosines
        float penumbra, cookieSlice, cookieScaleRotX, cookieScaleRotY; // extraParams (vec4): penumbra, cookie params
    } GPULightInstance;

    // Material params (16 bytes per entity, vec4-aligned)
    // Per-entity variation parameters for the material system.
    typedef struct {
        float p0, p1, p2, p3;
    } GPUMaterialParams;

    // Indirect draw arguments (16 bytes)
    typedef struct {
        uint32_t vertexCount;
        uint32_t instanceCount;
        uint32_t firstVertex;
        uint32_t firstInstance;
    } GPUIndirectArgs;

    // TileChunk instance data (1088 bytes, 16-byte aligned)
    // Represents a 16x16 grid of static tiles as a single GPU draw instance.
    // Each chunk renders 256 tile quads via gl_InstanceID math.
    typedef struct {
        float x, y, tileWidth, tileHeight;  // posSize (vec4): chunk world pos, tile dimensions
        float layer, z, columns, textureIndex;  // layerInfo (vec4): render layer, z, tileset columns, texture array index
        float r, g, b, a;                   // color (vec4): tint color
        float occluderHeight, _padLM, hasOccluders, _pad;  // occluderInfo (vec4): shadow casting info
        uint32_t tiles[256];                // tile IDs (64 uvec4s), 0 = empty/skip
    } GPUTileChunkInstance;

    // Text glyph instance data (96 bytes, 16-byte aligned)
    // Each character in a text entity becomes one GPU instance.
    // Enables batched text rendering with per-character transforms.
    typedef struct {
        float x, y, z, layerFloat;           // posLayer (vec4): world position + layer
        float fontLayer, cosRot, sinRot, flags; // fontRotFlags (vec4): font texture layer + rotation + render flags
        float uvX, uvY, uvW, uvH;            // uvRect (vec4): glyph UV in atlas
        float glyphW, glyphH, r, g;          // sizeColor1 (vec4): glyph dimensions + color RG
        float b, a, clipMinX, clipMinY;      // color2Clip1 (vec4): color BA + clip min
        float clipMaxX, clipMaxY, pivotX, pivotY; // clip2Pivot (vec4): clip max + pivot
    } GPUTextGlyphInstance;

    // === Two-Tier Text Rendering Architecture ===
    // Reduces memory from 96 bytes/glyph to ~40 bytes/glyph average for 100K+ entities

    // Text header data (128 bytes per text entity, 16-byte aligned)
    // Contains shared data for all glyphs in a text entity.
    typedef struct {
        float x, y, z, layer;           // posLayer (vec4): entity position + render layer
        float rotation, scaleX, scaleY, flags;  // rotScaleFlags (vec4): rotation + scale + render flags
        float r, g, b, a;               // color (vec4): shared color for all glyphs
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        float fontLayer, glyphStartIdx, glyphCount, textWidth;  // fontMeta (vec4): font + glyph range + bbox
        float textHeight, pivotOffsetX, pivotOffsetY, blendId;  // extraMeta (vec4): height + precomputed pivot offsets + blend ID
        float effectOutlineColor, effectGlowColor, effectShadowColor, effectShadowOffset;  // effects1 (vec4): packed colors + shadow offset
        float effectOutlineWidth, effectGlowRadius, effectShadowBlur, effectSpare;  // effects2 (vec4): scalar effect params
    } GPUTextHeader;

    // Per-glyph data (32 bytes per glyph, 16-byte aligned)
    // Contains only position-relative and UV data (no duplicated color/clip/transform).
    typedef struct {
        float localX, localY, uvX, uvY;  // localPosUV (vec4): position relative to entity + UV origin
        float uvW, uvH, glyphW, glyphH;  // uvSizeWH (vec4): UV dimensions + glyph size
    } GPUGlyphData;

    // Visible glyph index pair (8 bytes per visible glyph)
    // Output by cull shader; render shader fetches from TextHeader and GlyphData.
    typedef struct {
        uint32_t headerIndex;  // Index into TextHeader buffer
        uint32_t glyphIndex;   // Index into GlyphData buffer
    } GPUVisibleGlyph;

    // Glyph slab entry (8 bytes per glyph, shared across entities)
    // Pre-computed glyph layout data, reference-counted and shared.
    typedef struct {
        uint16_t glyphID;      // Codepoint for atlas lookup
        int16_t xOffset;       // Local X offset (1/16 pixel fixed-point)
        int16_t yOffset;       // Local Y offset (1/16 pixel fixed-point)
        uint16_t _pad;         // Alignment padding
    } GPUGlyphSlabEntry;

    // Camera/cull parameters SSBO (272 bytes, matches CullParams GLSL layout)
    // Uploaded once per frame, shared across all cull shader dispatches.
    typedef struct {
        float viewMinX, viewMinY, viewMaxX, viewMaxY;  // _cullViewport (vec4)
        float camX, camY, cameraZoom, maxLayer;         // _cullCamZoom (vec4)
        float maxZ, maxY, virtualW, virtualH;           // _cullDepthVirtual (vec4)
        float screenW, screenH, _cameraLayerMask, _pad1;  // _cullScreenPad (vec4)
        uint32_t screenSpaceMask, ignoreZoomMask, virtualCoordsMask, unlitMask; // _cullMasks (uvec4)
        float parallaxX[16];                            // ParallaxX (mat4)
        float parallaxY[16];                            // ParallaxY (mat4)
        float sortModes[16];                            // SortModes (mat4)
    } GPUCullParams;

    // Render parameters SSBO (272 bytes, matches RenderParams GLSL layout)
    // Uploaded once per render phase, shared across all render shader dispatches.
    // Includes depth fields for text/tilechunk shaders that use depth_common.glsl.
    typedef struct {
        float camX, camY, cameraZoom, maxLayer;         // _renCamZoom (vec4)
        float screenHalfX, screenHalfY, subPixelX, subPixelY; // _renScreenSub (vec4)
        float virtualW, virtualH, screenW, screenH;     // _renVirtScreen (vec4)
        float renderW, renderH, maxZ, maxY;             // _renRenderDepth (vec4)
        uint32_t screenSpaceMask, ignoreZoomMask, virtualCoordsMask, unlitMask; // _renMasks (uvec4)
        float sortModes[16];                            // SortModes (mat4)
        float viewProj[16];                             // ViewProj (mat4, column-major)
        float invViewProj[16];                          // InvViewProj (mat4, column-major)
    } GPURenderParams;

    // Mesh instance data (96 bytes, 16-byte aligned) - OUTPUT from cull shader
    // Written by mesh cull shader for visible instances
    typedef struct {
        float x, y, z, layerFloat;  // posLayer (vec4)
        float r, g, b, a;           // color (vec4)
        float scaleX, scaleY, rotation, flags;  // scaleRotFlags (vec4)
        float pivotX, pivotY, _pad0, _pad1;     // pivot (vec4)
        float clipMinX, clipMinY, clipMaxX, clipMaxY;  // clipBounds (vec4)
        uint32_t flagBits, depthBits, _pad2, _pad3;    // flags (uvec4) - depth stored as float bits
    } GPUMeshInstance;
]]

local buffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local Camera <const> = require("tecs2d.gfx.Camera")
local gfxTypes <const> = require("tecs2d.gfx.types")

local sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")

local record types
    --- Data for a registered cookie texture.
    record CookieData
        name: string
        baseSlice: integer
        frameCount: integer
        tagName: string
        sheet: sheet.SpriteSheet
    end

    --- Configuration for the GPU renderer
    record Config
        --- Initial buffer capacity hints, keyed by shape/buffer name.
        --- Each shape plugin reads its own key with a fallback default.
        --- Built-in keys: "sprites", "circles", "ellipses", "arcs", "lines",
        --- "rects", "lights", "tilechunks", "textGlyphs", "textEntities".
        --- Custom shape plugins can use any string key.
        sizeHints: {string: integer}

        --- Maximum render layers for depth sorting (default: 16)
        maxLayers: integer

        --- Maximum z-index within a layer (default: 1000)
        maxZ: number

        --- World height range for bottomY sorting (default: 100000)
        maxY: number

        --- Virtual resolution for pixel-perfect mode {width, height}
        virtualRes: {integer, integer}

        --- Shadow mask resolution scale (0.25 = quarter res, 0.5 = half res, 1.0 = full res)
        --- Lower values reduce VRAM usage but may cause flickering when zoomed out.
        --- Default: 1.0
        shadowMaskScale: number

        --- Drop shadow AO canvas resolution scale (0.5 = half res, 1.0 = full res).
        --- Lower values reduce fill-rate cost; bilinear filtering smooths the result.
        --- Default: 0.5
        dropShadowScale: number

        --- Number of raymarch steps for shadow calculation.
        --- Higher values produce more accurate shadows at the cost of performance.
        --- Doubled automatically in pixel-perfect mode (low res = cheap pixels).
        --- Default: 10
        shadowSteps: integer

        --- Extra culling margin for off-screen lights (for shadow continuity).
        --- Lights within this distance of the viewport edge are kept to avoid shadow popping.
        --- Default: 200
        shadowMargin: number

    end

    --- A blend batch holds buffers for entities using a specific blend mode.
    --- Enables GPU batching per blend mode without hurting normal case performance.
    --- Created lazily only when entities with that blend mode exist.
    record BlendBatch
        blendMode: love.graphics.BlendMode
        blendAlphaMode: love.graphics.BlendAlphaMode
        inputBuffer: buffer.GPUBuffer
        outputBuffer: love.graphics.Buffer
        indirectBuffer: love.graphics.Buffer
        entitySlots: {integer: integer}  -- entityId -> slot
    end

    --- A texture batch for sprites using different sprite sheets.
    --- Groups sprites by texture for separate draw calls.
    --- Each batch has its own buffers (transform, metadata, output, indirect).
    record SpriteTextureBatch
        --- Sheet ID used as texture bucket key
        sheetId: integer
        --- Main albedo texture
        texture: love.graphics.Texture
        --- Normal map texture (may be nil)
        normalTexture: love.graphics.Texture
        --- Emission map texture (may be nil)
        emissionTexture: love.graphics.Texture
        --- ORM map texture (may be nil)
        ormTexture: love.graphics.Texture
        --- Transform buffer (synced every frame)
        transformBuffer: buffer.GPUBuffer
        --- Metadata buffer (synced on dirty)
        metadataBuffer: buffer.GPUBuffer
        --- Output buffer for cull shader results
        outputBuffer: love.graphics.Buffer
        --- Indirect draw arguments buffer
        indirectBuffer: love.graphics.Buffer
        --- Shadow output buffer (for occluder sprites)
        shadowOutputBuffer: love.graphics.Buffer
        --- Shadow indirect buffer (for occluder sprites)
        shadowIndirectBuffer: love.graphics.Buffer
        --- Number of sprites in this batch
        count: integer
    end

    --- A modular render plugin that registers with the renderer via hooks.
    --- Each rendering module (circles, sprites, text, etc.) creates a plugin implementing this interface.
    --- Nil methods are skipped in the corresponding phase.
    record RenderPlugin
        --- Plugin name (for debugging)
        name: string
        --- Upload dirty buffers to GPU
        upload: function(Renderer)
        --- Reset indirect draw buffers before culling
        resetIndirect: function(Renderer)
        --- Run culling compute shaders
        cull: function(Renderer, cullParamsBuffer: love.graphics.Buffer)
        --- Render to G-buffer (opaque/alpha-blend entities)
        renderGBuffer: function(Renderer, renderParamsBuffer: love.graphics.Buffer, globalTime: number)
        --- Render shapes with non-alpha blend modes (forward pass after lighting)
        renderForwardBlend: function(Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)
        --- Render shadow mask (occluder shapes)
        renderShadowMask: function(Renderer, shadowTransform: love.math.Transform)
        --- Render drop shadow AO pass (separate from G-buffer)
        renderDropShadowAO: function(Renderer, renderParamsBuffer: love.graphics.Buffer)
        --- Set layer range on this plugin's render shader(s)
        setLayerRange: function(Renderer, range: {number})
    end

    --- The GPU renderer instance.
    --- Shape-specific buffers are owned by each shape plugin (closure-captured locals).
    --- The Renderer holds only shared resources: G-buffer, lighting, camera params, config.
    record Renderer
        -- Shared shaders (not owned by any shape module)
        shadowBlurShader: love.graphics.Shader
        shadowMaskTemp: love.graphics.Canvas  -- Temp canvas for blur pass
        lightingShader: love.graphics.Shader
        -- Cross-cutting light buffers (set by Light plugin, read by renderLighting)
        lightOutputBuffer: love.graphics.Buffer
        lightVisibleCountBuffer: love.graphics.Buffer

        -- Light cookie texture array (lazily allocated on first registerCookie)
        cookieTextureArray: love.graphics.Canvas
        _cookieRegistry: {CookieData}
        _cookieNameToId: {string: integer}
        _cookieNextLayer: integer

        -- Tile-based light binning buffers (created in resize, dispatched by Light plugin)
        tileLightCountBuffer: love.graphics.Buffer
        tileLightIndexBuffer: love.graphics.Buffer
        tileCountResetData: love.data.ByteData
        tileGridWidth: integer
        tileGridHeight: integer

        -- Dummy material params buffer (1 element, all zeros) for shapes with no materials
        dummyMaterialParamsBuffer: love.graphics.Buffer

        -- Current layer range for variant shader dispatch
        _layerRange: {number}

        -- Hard-edge SDF rendering toggle (sent as RoughGeometry uniform).
        -- Independent of pixelMode; either off (smooth SDFs) or on (hard
        -- pixel cutoffs).
        _roughGeometry: boolean

        -- G-Buffer canvases
        gBufferAlbedo: love.graphics.Canvas
        gBufferNormal: love.graphics.Canvas
        gBufferORM: love.graphics.Canvas
        gBufferEmission: love.graphics.Canvas
        shadowMask: love.graphics.Canvas

        -- Drop shadow AO canvas (R8, screen res)
        dropShadowAO: love.graphics.Canvas

        -- Pixel-perfect canvases (low-res)
        pixelAlbedo: love.graphics.Canvas
        pixelNormal: love.graphics.Canvas
        pixelORM: love.graphics.Canvas
        pixelEmission: love.graphics.Canvas
        pixelShadowMask: love.graphics.Canvas
        pixelCanvas: love.graphics.Canvas

        -- Drop shadow AO canvas (R8, virtual res)
        pixelDropShadowAO: love.graphics.Canvas

        -- Lit result canvas (screen-resolution, lazy-allocated for queryLightAt)
        litCanvas: love.graphics.Canvas

        -- Bloom post-processing
        bloomDownsampleShader: love.graphics.Shader
        bloomUpsampleShader: love.graphics.Shader
        bloomMips: {love.graphics.Canvas}
        bloomMipWidths: {integer}
        bloomMipHeights: {integer}
        pixelBloomMips: {love.graphics.Canvas}
        pixelBloomMipWidths: {integer}
        pixelBloomMipHeights: {integer}
        bloom: gfxTypes.BloomConfig
        renderBloom: function(Renderer, useLowRes: boolean, outputCanvas?: love.graphics.Canvas)

        -- Always-to-canvas target for world lighting result
        worldLitCanvas: love.graphics.Canvas

        -- Screen-phase G-buffer canvases (nil; screen layers use main G-buffers)
        screenAlbedo: love.graphics.Canvas
        screenNormal: love.graphics.Canvas
        screenORM: love.graphics.Canvas
        screenEmission: love.graphics.Canvas
        screenShadowMask: love.graphics.Canvas
        screenDropShadowAO: love.graphics.Canvas

        -- Current render phase ("world" or "screen")
        _renderPhase: string


        -- Drop shadow AO flag (set during cull by sprite plugin)
        _hasDropShadows: boolean

        -- Cached cull-phase values (populated before plugin cull hooks)
        _cullViewport: {number}
        _tileViewport: {number}
        _effectiveTileGridW: integer
        _effectiveTileGridH: integer
        _cullCameraPos: {number}
        _cullParallaxMatX: {number}
        _cullParallaxMatY: {number}
        _cullGlobalTime: number
        _cullCameraLayerMask: integer

        -- Configuration
        config: Config
        screenWidth: integer
        screenHeight: integer

        -- Layer masks (cached during cull for render)
        screenSpaceMask: integer
        ignoreZoomMask: integer
        virtualCoordsMask: integer
        unlitMask: integer

        -- Sort modes packed as mat4 (cached during cull for render)
        sortModesMat: {number}

        -- Camera reference (set by pipeline before each render pass)
        camera: Camera

        _shadowTransform: love.math.Transform
        _lightTransform: love.math.Transform
        _lightShadowTransform: love.math.Transform
        _renderTransform: love.math.Transform

        -- Camera params SSBO buffers (uploaded once per frame/phase)
        cullParamsByteData: love.data.ByteData
        cullParamsBuffer: love.graphics.Buffer
        renderParamsByteData: love.data.ByteData
        renderParamsBuffer: love.graphics.Buffer

        -- Indirect buffer reset data (shared across all plugins)
        indirectResetData: love.data.ByteData

        -- Default texture for sprites (white 16x16 fallback)
        defaultTexture: love.graphics.Image

        -- Default fallback textures (1x1, created at init)
        flatNormalTexture: love.graphics.Image
        blackEmissionTexture: love.graphics.Image
        defaultORMTexture: love.graphics.Image

        --- Upload all dirty buffers to GPU
        upload: function(Renderer)

        --- Run culling compute shaders
        --- @param cameraX Camera X position
        --- @param cameraY Camera Y position
        --- @param cameraZoom Camera zoom level
        --- @param globalTime Global time for animations
        --- @param screenSpaceMask Bitmask of screen-space layers (bit N = layer N+1)
        --- @param ignoreZoomMask Bitmask of layers that ignore zoom (bit N = layer N+1)
        --- @param virtualCoordsMask Bitmask of layers that use virtual coordinates (bit N = layer N+1)
        --- @param unlitMask Bitmask of layers that are unlit (bit N = layer N+1)
        --- @param parallaxX Per-layer parallax X factors (1-16)
        --- @param parallaxY Per-layer parallax Y factors (1-16)
        --- @param sortModes Per-layer sort modes (0=topdown, 1=z-only, 2=isometric)
        --- @param rotation Camera rotation in radians (default 0)
        cull: function(Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, globalTime: number, screenSpaceMask: integer, ignoreZoomMask: integer, virtualCoordsMask: integer, unlitMask: integer, parallaxX: {number}, parallaxY: {number}, sortModes: {integer}, rotation: number, cameraLayerMask: integer)

        --- Render the G-Buffer pass.
        --- The optional gBufferDrawCallback is called after canvas setup to render
        --- content that should be depth-sorted with GPU shapes (e.g. tilemaps).
        renderGBuffer: function(Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, globalTime: number, gBufferDrawCallback?: function(number, number, number, number, number, number), rotation?: number, subPixelX?: number, subPixelY?: number)

        --- Render the shadow mask pass
        renderShadowMask: function(Renderer, cameraX: number, cameraY: number, cameraZoom: number, rotation: number)

        --- Render the lighting pass.
        --- @param outputCanvas Optional canvas to render to instead of the screen.
        ---   When nil, renders directly to screen (or pixelCanvas in retro mode).
        ---   When provided, renders the lit result to this canvas (no upscale).
        renderLighting: function(Renderer, useLowRes: boolean, shadowsEnabled: boolean, ambient: {number, number, number}, cameraX: number, cameraY: number, cameraZoom: number, outputCanvas?: love.graphics.Canvas, rotation?: number, subPixelX?: number, subPixelY?: number)

        --- Render all shapes with non-alpha blend modes (forward pass after lighting).
        --- Must be called after renderLighting to properly blend with the lit scene.
        renderForwardBlend: function(Renderer, cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)

        --- Register a forward blend render function (called by shape modules during setup).
        registerForwardBlend: function(Renderer, fn: function(Renderer, number, number, number, boolean, number, number))

        --- Handle window resize
        resize: function(Renderer, width: integer, height: integer)

        --- Registered render plugins (shape modules register during setup)
        plugins: {RenderPlugin}

        --- Register a render plugin (called by shape modules during setup)
        registerPlugin: function(Renderer, plugin: RenderPlugin)

        --- Registered forward blend render functions (shape modules push into this list)
        forwardBlendRenderers: {function(Renderer, number, number, number, integer, number, number)}

        --- Register a tileset texture and get its layer index in the texture array.
        --- If already registered, returns the existing index.
        --- Triggers texture array rebuild if needed.
        --- Optional normal, emission, and ORM maps are used for lighting.
        --- Optional occluderHeights maps local tile IDs to shadow-casting heights.
        registerTileset: function(
            Renderer,
            tileset: love.graphics.Texture,
            normalMap?: love.graphics.Texture,
            emissionMap?: love.graphics.Texture,
            ormMap?: love.graphics.Texture,
            occluderHeights?: {integer: number}
        ): integer

        --- Set the layer range for multi-pass rendering with effects.
        --- Entities outside this range are discarded in the vertex shader.
        setLayerRange: function(Renderer, minLayer: number, maxLayer: number)

        --- Reset layer range to render all layers (0 to 65535).
        resetLayerRange: function(Renderer)
    end

    --- Buffer format for transforms (matches GPUTransformInstance)
    TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for sprite metadata (matches GPUSpriteMetadata)
    SPRITE_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for sprite cull output (matches GPUSpriteInstance)
    SPRITE_FORMAT: love.graphics.BufferFormat

    --- Buffer format for circles (matches GPUCircleInstance)
    CIRCLE_FORMAT: love.graphics.BufferFormat

    --- Buffer format for circle transforms (matches GPUCircleTransform)
    CIRCLE_TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for circle metadata (matches GPUCircleMetadata)
    CIRCLE_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for ellipses (matches GPUEllipseInstance)
    ELLIPSE_FORMAT: love.graphics.BufferFormat

    --- Buffer format for ellipse transforms (matches GPUEllipseTransform)
    ELLIPSE_TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for ellipse metadata (matches GPUEllipseMetadata)
    ELLIPSE_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for arcs (matches GPUArcInstance)
    ARC_FORMAT: love.graphics.BufferFormat

    --- Buffer format for arc transforms (matches GPUArcTransform)
    ARC_TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for arc metadata (matches GPUArcMetadata)
    ARC_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for lines (matches GPULineInstance)
    LINE_FORMAT: love.graphics.BufferFormat

    --- Buffer format for line transforms (matches GPULineTransform)
    LINE_TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for line metadata (matches GPULineMetadata)
    LINE_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for rectangles (matches GPURectInstance)
    RECT_FORMAT: love.graphics.BufferFormat

    --- Buffer format for rectangle transforms (matches GPURectTransform)
    RECT_TRANSFORM_FORMAT: love.graphics.BufferFormat

    --- Buffer format for rectangle metadata (matches GPURectMetadata)
    RECT_METADATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for lights (matches GPULightInstance)
    LIGHT_FORMAT: love.graphics.BufferFormat

    --- Buffer format for material params (matches GPUMaterialParams)
    MATERIAL_PARAMS_FORMAT: love.graphics.BufferFormat

    --- Buffer format for indirect draw args
    INDIRECT_FORMAT: love.graphics.BufferFormat

    --- Buffer format for tile chunks (matches GPUTileChunkInstance)
    TILECHUNK_FORMAT: love.graphics.BufferFormat
    TILECHUNK_VIS_FORMAT: love.graphics.BufferFormat

    --- Buffer format for text glyphs (matches GPUTextGlyphInstance)
    TEXT_GLYPH_FORMAT: love.graphics.BufferFormat

    --- Buffer format for text headers (matches GPUTextHeader) - two-tier architecture
    TEXT_HEADER_FORMAT: love.graphics.BufferFormat

    --- Buffer format for glyph data (matches GPUGlyphData) - two-tier architecture
    GLYPH_DATA_FORMAT: love.graphics.BufferFormat

    --- Buffer format for visible glyph indices (matches GPUVisibleGlyph) - two-tier architecture
    VISIBLE_GLYPH_FORMAT: love.graphics.BufferFormat

    --- Buffer format for glyph slab entries (matches GPUGlyphSlabEntry) - slab architecture
    GLYPH_SLAB_FORMAT: love.graphics.BufferFormat

    --- Buffer format for mesh cull output (matches GPUMeshInstance)
    MESH_FORMAT: love.graphics.BufferFormat

    --- Instance flag bits
    FLAG_UNLIT: integer
    FLAG_REPEAT_X: integer
    FLAG_REPEAT_Y: integer
    FLAG_FILLED: integer
    FLAG_OUTLINED: integer
    FLAG_MSDF: integer
    FLAG_OCCLUDER: integer
    FLAG_DROP_SHADOW: integer

    --- FFI type names
    TRANSFORM_CTYPE: string
    SPRITE_METADATA_CTYPE: string
    CIRCLE_CTYPE: string
    CIRCLE_TRANSFORM_CTYPE: string
    CIRCLE_METADATA_CTYPE: string
    ELLIPSE_CTYPE: string
    ELLIPSE_TRANSFORM_CTYPE: string
    ELLIPSE_METADATA_CTYPE: string
    ARC_CTYPE: string
    ARC_TRANSFORM_CTYPE: string
    ARC_METADATA_CTYPE: string
    LINE_CTYPE: string
    LINE_TRANSFORM_CTYPE: string
    LINE_METADATA_CTYPE: string
    RECT_CTYPE: string
    RECT_TRANSFORM_CTYPE: string
    RECT_METADATA_CTYPE: string
    LIGHT_CTYPE: string
    MATERIAL_PARAMS_CTYPE: string
    INDIRECT_CTYPE: string
    TILECHUNK_CTYPE: string
    TEXT_GLYPH_CTYPE: string
    TEXT_HEADER_CTYPE: string
    GLYPH_DATA_CTYPE: string
    VISIBLE_GLYPH_CTYPE: string
    GLYPH_SLAB_CTYPE: string
    MESH_CTYPE: string

    --- Buffer format for cull params SSBO (matches GPUCullParams)
    CULL_PARAMS_FORMAT: love.graphics.BufferFormat

    --- Buffer format for render params SSBO (matches GPURenderParams)
    RENDER_PARAMS_FORMAT: love.graphics.BufferFormat

    --- FFI type names for param SSBOs
    CULL_PARAMS_CTYPE: string
    RENDER_PARAMS_CTYPE: string

    --- Teal record mirroring GPUCullParams FFI struct (for typed pointer access)
    record CullParamsRecord
        viewMinX: number
        viewMinY: number
        viewMaxX: number
        viewMaxY: number
        camX: number
        camY: number
        cameraZoom: number
        maxLayer: number
        maxZ: number
        maxY: number
        virtualW: number
        virtualH: number
        screenW: number
        screenH: number
        _cameraLayerMask: number
        _pad1: number
        screenSpaceMask: integer
        ignoreZoomMask: integer
        virtualCoordsMask: integer
        unlitMask: integer
        parallaxX: {integer: number}
        parallaxY: {integer: number}
        sortModes: {integer: number}
    end

    --- Teal record mirroring GPURenderParams FFI struct (for typed pointer access)
    record RenderParamsRecord
        camX: number
        camY: number
        cameraZoom: number
        maxLayer: number
        screenHalfX: number
        screenHalfY: number
        subPixelX: number
        subPixelY: number
        virtualW: number
        virtualH: number
        screenW: number
        screenH: number
        renderW: number
        renderH: number
        maxZ: number
        maxY: number
        screenSpaceMask: integer
        ignoreZoomMask: integer
        virtualCoordsMask: integer
        unlitMask: integer
        sortModes: {integer: number}
        viewProj: {integer: number}
        invViewProj: {integer: number}
    end
end

-- Buffer formats matching the FFI structs
-- Transform buffer: 32 bytes per entity (vec4-aligned for Metal compatibility)
-- Cannot bulk-copy from ECS Transform (28 bytes) - must copy field-by-field.
types.TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- x, y, z, layerFloat (16 bytes)
    {format = "floatvec4"},  -- rotation, scaleX, scaleY, _pad (16 bytes) - total 32 bytes
}

-- Sprite metadata buffer: 128 bytes per entity (synced on add/move only)
types.SPRITE_METADATA_FORMAT = {
    {format = "floatvec4"},  -- pivotX, pivotY, width, height
    {format = "floatvec4"},  -- uvX, uvY, uvW, uvH
    {format = "floatvec4"},  -- r, g, b, a
    {format = "floatvec4"},  -- clipMinX, clipMinY, clipMaxX, clipMaxY
    {format = "floatvec4"},  -- animStartTime, animTotalDuration, animFrameCount, animFrameWidth
    {format = "floatvec4"},  -- animColumnCount, animFrameHeight, animTimingOffset, animPausedFrame
    {format = "floatvec4"},  -- occluderHeight, _pad, textureSlice, blendId
    {format = "floatvec4"},  -- dropShadowOffsetX, dropShadowOffsetY, dropShadowScaleY, dropShadowOpacity
}

-- Sprite output format for cull shader results (GPU-side sprite instances after culling)
types.SPRITE_FORMAT = {
    {format = "floatvec4"},  -- posSize
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZ / depthLayerGrid (depth, layer, animColumnCount, animFrameHeight)
    {format = "floatvec4"},  -- clipBounds
    {format = "floatvec4"},  -- uvRect (base UV for animation)
    {format = "floatvec4"},  -- animData (frameIndex, firstFrame, frameCount, frameWidth)
    {format = "floatvec4"},  -- rotScale (rotation, scaleX, scaleY, textureSlice)
    {format = "floatvec4"},  -- pivot (pivotX, pivotY, flags, screenSpaceFlags)
}

types.CIRCLE_FORMAT = {
    {format = "floatvec4"},  -- posRadius
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZ
    {format = "floatvec4"},  -- clipBounds
}

-- Circle transform buffer: 32 bytes per entity (synced every frame, includes radius)
types.CIRCLE_TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- x, y, z, layerFloat
    {format = "floatvec4"},  -- radius, scaleX, scaleY, flags
}

-- Circle metadata buffer: 48 bytes per entity (synced only on dirty)
types.CIRCLE_METADATA_FORMAT = {
    {format = "floatvec4"},  -- lineWidth, _pad0, _pad1, _pad2
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
}

types.ELLIPSE_FORMAT = {
    {format = "floatvec4"},  -- posRadii (x, y, radiusX, radiusY)
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZLineFlags
    {format = "floatvec4"},  -- clipBounds
    {format = "floatvec4"},  -- pivot (pivotX, pivotY, rotation, pad)
}

-- Ellipse transform buffer: 32 bytes per entity (synced every frame, includes scaled radii)
types.ELLIPSE_TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- x, y, z, layerFloat
    {format = "floatvec4"},  -- scaledRadiusX, scaledRadiusY, rotation, flags
}

-- Ellipse metadata buffer: 64 bytes per entity (synced only on dirty)
types.ELLIPSE_METADATA_FORMAT = {
    {format = "floatvec4"},  -- lineWidthPad: lineWidth, _pad, _pad, _pad
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
    {format = "floatvec4"},  -- pivot: pivotX, pivotY, _pad, _pad
}

types.ARC_FORMAT = {
    {format = "floatvec4"},  -- posRadii (x, y, radiusX, radiusY)
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZLineFlags
    {format = "floatvec4"},  -- angles (startAngle, endAngle, rotation, pad)
    {format = "floatvec4"},  -- clipBounds
    {format = "floatvec4"},  -- pivot (pivotX, pivotY, pad, pad)
}

-- Arc transform buffer: 48 bytes per entity (synced every frame, includes radii and angles)
types.ARC_TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- x, y, z, layerFloat
    {format = "floatvec4"},  -- scaledRadiusX, scaledRadiusY, startAngle, endAngle
    {format = "floatvec4"},  -- rotation, flags, _pad, _pad
}

-- Arc metadata buffer: 48 bytes per entity (synced only on dirty)
types.ARC_METADATA_FORMAT = {
    {format = "floatvec4"},  -- lineWidthPad: lineWidth, _pad, _pad, _pad
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
    {format = "floatvec4"},  -- pivot: pivotX, pivotY, _pad, _pad
}

types.LINE_FORMAT = {
    {format = "floatvec4"},  -- points (x1, y1, x2, y2)
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZLineFlags
    {format = "floatvec4"},  -- centerRot (centerX, centerY, rotation, pad)
    {format = "floatvec4"},  -- clipBounds
}

-- Line transform buffer: 32 bytes per entity (synced every frame, includes world endpoints)
types.LINE_TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- worldX1, worldY1, worldX2, worldY2
    {format = "floatvec4"},  -- z, layerFloat, rotation, flags
}

-- Line metadata buffer: 48 bytes per entity (synced only on dirty)
types.LINE_METADATA_FORMAT = {
    {format = "floatvec4"},  -- lineWidthPad: lineWidth, _pad, _pad, _pad
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
}

types.RECT_FORMAT = {
    {format = "floatvec4"},  -- posSize
    {format = "floatvec4"},  -- color
    {format = "floatvec4"},  -- layerZRotLine
    {format = "floatvec4"},  -- cornerRadius (rx, ry, pad, pad)
    {format = "floatvec4"},  -- clipBounds
    {format = "uint32vec4"}, -- flags
}

-- Rectangle transform buffer: 32 bytes per entity (synced every frame, includes scaled dimensions)
types.RECT_TRANSFORM_FORMAT = {
    {format = "floatvec4"},  -- x, y, z, layerFloat
    {format = "floatvec4"},  -- scaledWidth, scaledHeight, rotation, flags
}

-- Rectangle metadata buffer: 64 bytes per entity (synced only on dirty)
-- Note: width/height are now pre-computed in transform buffer as scaledWidth/scaledHeight
types.RECT_METADATA_FORMAT = {
    {format = "floatvec4"},  -- lineWidthPad: lineWidth, _pad, _pad, _pad
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- cornerPivot: rx, ry, pivotX, pivotY
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
}

types.LIGHT_FORMAT = {
    {format = "floatvec4"},  -- posHeight
    {format = "floatvec4"},  -- intensityColor
    {format = "floatvec4"},  -- spotParams: spotDirX, spotDirY, cosConeAngle, cosInnerConeAngle
    {format = "floatvec4"},  -- extraParams: penumbra, cookieSlice, cookieScaleRotX, cookieScaleRotY
}

types.MATERIAL_PARAMS_FORMAT = {
    {format = "floatvec4"},  -- p0, p1, p2, p3
}

types.INDIRECT_FORMAT = {
    {format = "uint32"},
}

-- Compact visible-chunk record written by the tilechunk cull pass.
-- Must match TileChunkVis in tile_common.glsl / tilechunk_cull.glsl.
types.TILECHUNK_VIS_FORMAT = {
    {format = "floatvec4"},   -- posSize (parallax-adjusted x, y, tileWidth, tileHeight)
    {format = "uint32vec4"},  -- srcIndex (x = row in TileChunkInput; yzw unused)
}

-- TileChunk buffer format: 4 vec4s for header + 64 uvec4s for 256 tile IDs
types.TILECHUNK_FORMAT = {
    {format = "floatvec4"},  -- posSize (x, y, tileWidth, tileHeight)
    {format = "floatvec4"},  -- layerInfo (layer, z, columns, textureIndex)
    {format = "floatvec4"},  -- color (r, g, b, a)
    {format = "floatvec4"},  -- occluderInfo (occluderHeight, _pad, hasOccluders, _pad)
    -- 256 tile IDs as 64 uvec4s (4 uints per uvec4)
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
    {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"}, {format = "uint32vec4"},
}

-- Text glyph buffer format: 96 bytes per glyph (6 vec4s)
types.TEXT_GLYPH_FORMAT = {
    {format = "floatvec4"},  -- posLayer: x, y, z, layer
    {format = "floatvec4"},  -- fontRotFlags: fontLayer, cosRot, sinRot, flags
    {format = "floatvec4"},  -- uvRect: uvX, uvY, uvW, uvH
    {format = "floatvec4"},  -- sizeColor1: glyphW, glyphH, r, g
    {format = "floatvec4"},  -- color2Clip1: b, a, clipMinX, clipMinY
    {format = "floatvec4"},  -- clip2Pivot: clipMaxX, clipMaxY, pivotX, pivotY
}

-- Instance flags
types.FLAG_UNLIT = 0x1
types.FLAG_REPEAT_X = 0x2  -- Sprite: tile horizontally
types.FLAG_REPEAT_Y = 0x4  -- Sprite: tile vertically
types.FLAG_FILLED = 0x2    -- Shape: filled (note: same bit as REPEAT_X, different context)
types.FLAG_OUTLINED = 0x4  -- Shape: outlined (note: same bit as REPEAT_Y, different context)
types.FLAG_MSDF = 0x10     -- Text: MSDF font rendering (bit 4, text context only)
types.FLAG_OCCLUDER = 0x100  -- Entity casts shadows (has Occluder component)
types.FLAG_DROP_SHADOW = 0x200  -- Entity has a drop shadow (has DropShadow component)

-- FFI type names
types.TRANSFORM_CTYPE = "GPUTransformInstance"
types.SPRITE_METADATA_CTYPE = "GPUSpriteMetadata"
types.CIRCLE_CTYPE = "GPUCircleInstance"
types.CIRCLE_TRANSFORM_CTYPE = "GPUCircleTransform"
types.CIRCLE_METADATA_CTYPE = "GPUCircleMetadata"
types.ELLIPSE_CTYPE = "GPUEllipseInstance"
types.ELLIPSE_TRANSFORM_CTYPE = "GPUEllipseTransform"
types.ELLIPSE_METADATA_CTYPE = "GPUEllipseMetadata"
types.ARC_CTYPE = "GPUArcInstance"
types.ARC_TRANSFORM_CTYPE = "GPUArcTransform"
types.ARC_METADATA_CTYPE = "GPUArcMetadata"
types.LINE_CTYPE = "GPULineInstance"
types.LINE_TRANSFORM_CTYPE = "GPULineTransform"
types.LINE_METADATA_CTYPE = "GPULineMetadata"
types.RECT_CTYPE = "GPURectInstance"
types.RECT_TRANSFORM_CTYPE = "GPURectTransform"
types.RECT_METADATA_CTYPE = "GPURectMetadata"
types.LIGHT_CTYPE = "GPULightInstance"
types.MATERIAL_PARAMS_CTYPE = "GPUMaterialParams"
types.INDIRECT_CTYPE = "GPUIndirectArgs"
types.TILECHUNK_CTYPE = "GPUTileChunkInstance"
types.TEXT_GLYPH_CTYPE = "GPUTextGlyphInstance"
types.TEXT_HEADER_CTYPE = "GPUTextHeader"
types.GLYPH_DATA_CTYPE = "GPUGlyphData"
types.VISIBLE_GLYPH_CTYPE = "GPUVisibleGlyph"

-- Two-tier text buffer formats (8 vec4s = 128 bytes for header, 2 vec4s = 32 bytes for glyph)
types.TEXT_HEADER_FORMAT = {
    {format = "floatvec4"},  -- posLayer: x, y, z, layer
    {format = "floatvec4"},  -- rotScaleFlags: rotation, scaleX, scaleY, flags
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
    {format = "floatvec4"},  -- fontMeta: fontLayer, glyphStartIdx, glyphCount, textWidth
    {format = "floatvec4"},  -- extraMeta: textHeight, pivotOffsetX, pivotOffsetY, blendId
    {format = "floatvec4"},  -- effects1: outlineColor, glowColor, shadowColor, shadowOffset (packed)
    {format = "floatvec4"},  -- effects2: outlineWidth, glowRadius, shadowBlur, spare
}

types.GLYPH_DATA_FORMAT = {
    {format = "floatvec4"},  -- localPosUV: localX, localY, uvX, uvY
    {format = "floatvec4"},  -- uvSizeWH: uvW, uvH, glyphW, glyphH
}

types.VISIBLE_GLYPH_FORMAT = {
    {format = "uint32"},  -- headerIndex
    {format = "uint32"},  -- glyphIndex
}

-- Glyph slab buffer format (8 bytes per glyph, 2 uint16s + 2 int16s packed as uint32s)
types.GLYPH_SLAB_FORMAT = {
    {format = "uint32"},  -- glyphID (u16) + xOffset (i16) packed
    {format = "uint32"},  -- yOffset (i16) + _pad (u16) packed
}

types.GLYPH_SLAB_CTYPE = "GPUGlyphSlabEntry"

-- Mesh output format for cull shader results (GPU-side mesh instances
-- after culling). Source columns flow through the renderer-owned
-- shadow-column path; per-row Transform / Color / ClipBounds / Pivot
-- / Material live on `shadow_state` instances, not on a dual-tier
-- transform/metadata pair.
types.MESH_FORMAT = {
    {format = "floatvec4"},  -- posLayer: x, y, z, layerFloat
    {format = "floatvec4"},  -- color: r, g, b, a
    {format = "floatvec4"},  -- scaleRotFlags: scaleX, scaleY, rotation, flags
    {format = "floatvec4"},  -- pivot: pivotX, pivotY, _pad, _pad
    {format = "floatvec4"},  -- clipBounds: minX, minY, maxX, maxY
    {format = "uint32vec4"}, -- flags: flagBits, depthBits, _pad, _pad
}

types.MESH_CTYPE = "GPUMeshInstance"

-- CullParams SSBO format: 5 vec4s + 3 mat4s (12 vec4s) = 17 vec4s = 272 bytes
types.CULL_PARAMS_FORMAT = {
    {format = "floatvec4"},   -- _cullViewport
    {format = "floatvec4"},   -- _cullCamZoom
    {format = "floatvec4"},   -- _cullDepthVirtual
    {format = "floatvec4"},   -- _cullScreenPad
    {format = "uint32vec4"},  -- _cullMasks
    -- ParallaxX (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
    -- ParallaxY (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
    -- SortModes (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
}

-- RenderParams SSBO format: 5 vec4s + 3 mat4s (12 vec4s) = 17 vec4s = 272 bytes
types.RENDER_PARAMS_FORMAT = {
    {format = "floatvec4"},   -- _renCamZoom
    {format = "floatvec4"},   -- _renScreenSub
    {format = "floatvec4"},   -- _renVirtScreen
    {format = "floatvec4"},   -- _renRenderDepth
    {format = "uint32vec4"},  -- _renMasks
    -- SortModes (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
    -- ViewProj (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
    -- InvViewProj (mat4 = 4 vec4s)
    {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"}, {format = "floatvec4"},
}

types.CULL_PARAMS_CTYPE = "GPUCullParams"
types.RENDER_PARAMS_CTYPE = "GPURenderParams"

return types

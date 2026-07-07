// Sprite culling compute shader (renderer-owned shadow-column path).
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
//
// One dispatch per (sprite archetype × bucket). The dispatch closure
// in `sprite/shadow_dispatch.tl` binds the archetype's shadow source
// columns plus the bucket's per-output buffers, then atomically appends
// per visible entity.
//
// Inputs are addressed by archetype row (`gl_GlobalInvocationID.x`),
// not by stable slot. Transform / Sprite / SpriteData / optional
// component columns are shadowed straight to GPU.
//
// Outputs (per-bucket, shared across all archetypes routed to this
// bucket via atomicAdd):
//   - SpriteOutput: visible sprite instances
//   - SpriteShadowOutput: occluder dual-write for shadow pass
//   - DropShadowOutput: per-light fan-out for drop-shadow AO pass
//   - MaterialParamsOutput: per-instance material params (output-order)

// ---------- Shape-specific source SSBOs ----------

struct Std430Sprite {
    int   spriteId;
    int   entityId;
    float animStartTime;
    int   pausedFrame;
    int   pauseAtFrame;
    int   pauseDepth;
};
layout(std430) readonly buffer SpriteInput {
    Std430Sprite sprites[];
};

// SpriteData: renderer-internal derived metadata (UV / pivot / anim /
// textureSlice). Sync writes this on dirty; cull reads it per-row.
struct Std430SpriteData {
    float pivotX;
    float pivotY;
    float width;
    float height;
    float uvX;
    float uvY;
    float uvW;
    float uvH;
    float animTotalDuration;
    float animFrameCount;
    float animFrameWidth;
    float animColumnCount;
    float animFrameHeight;
    float animTimingOffset;
    float textureSlice;        // packed: layerIndex | (generation << packBits)
};
layout(std430) readonly buffer SpriteDataInput {
    Std430SpriteData spriteData[];
};

// (BucketMarker stays CPU-only for archetype routing; the cull shader
// doesn't read it directly because SpriteData.textureSlice already
// carries the packed layer index + generation.)

struct Std430Pivot { vec4 xyPad; };  // (x, y, _pad, _pad)
layout(std430) readonly buffer PivotInput { Std430Pivot pivots[]; };

struct Std430Occluder { vec2 heightAlpha; };
layout(std430) readonly buffer OccluderInput { Std430Occluder occluders[]; };

struct Std430DropShadow {
    float height;
    float opacity;
};
layout(std430) readonly buffer DropShadowInput { Std430DropShadow dropShadows[]; };

struct Std430RepeatedSprite {
    uint repeatX;
    uint repeatY;
    float width;
    float height;
};
layout(std430) readonly buffer RepeatedSpriteInput { Std430RepeatedSprite repeats[]; };

// ---------- Output buffers (per-bucket; shared across archetypes
// routed to this bucket via atomicAdd) ----------

struct SpriteOut {
    vec4 posSize;
    vec4 color;
    vec4 depthLayerGrid;  // depth, layer, animColumnCount, animFrameHeight
    vec4 clipBounds;
    vec4 uvRect;
    vec4 animData;        // frameIndex, totalDuration, frameCount, frameWidth
    vec4 rotScale;        // rotation, scaleX, scaleY, textureSlice
    vec4 pivot;           // pivotX, pivotY, slice-or-spare, packed flags (uint bits)
};
layout(std430) writeonly buffer SpriteOutput {
    SpriteOut spritesOut[];
};
layout(std430) writeonly buffer SpriteShadowOutput {
    SpriteOut spritesShadowOut[];
};
layout(std430) writeonly buffer DropShadowOutput {
    SpriteOut spritesDropShadowOut[];
};
layout(std430) buffer ShadowIndirectArgs { uint shadowArgs[]; };
layout(std430) buffer DropShadowIndirectArgs { uint dropShadowArgs[]; };

// ---------- Frame-timing + lighting (shared globals) ----------

layout(std430) readonly buffer FrameTimings {
    float cumulativeTimes[];
};

#define MAX_LIGHTS_PER_TILE 128u

struct LightData {
    vec4 posHeight;
    vec4 intensityColor;
    vec4 spotParams;
    vec4 extraParams;
};
layout(std430) readonly buffer LightBuffer { LightData lights[]; };
layout(std430) readonly buffer TileLightCounts { uint tileCounts[]; };
layout(std430) readonly buffer TileLightIndices { uint tileIndices[]; };

uniform vec4 TileViewport;
uniform ivec2 TileGridDims;

layout(std430) readonly buffer SliceGenerations {
    float sliceGens[];
};

// ---------- Shape uniforms ----------

uniform float GlobalTime;
uniform int   SlicePackingBits;
uniform float ShadowMargin;
uniform uint  MaxDropShadows;

// ---------- Shape flag constants ----------

const uint FLAG_DROP_SHADOW    = 0x200u;
// REPEAT_X / REPEAT_Y live in the low flag bits the render shader
// unpacks. sprite.glsl uses 0x2 / 0x4; keep these in sync.
const uint FLAG_REPEAT_X       = 0x2u;
const uint FLAG_REPEAT_Y       = 0x4u;

// ---------- Shape-specific component readers ----------

vec2 readPivot(uint row, vec2 fallback) {
    if ((ComponentMask & COMP_PIVOT) != 0u) {
        return pivots[row].xyPad.xy;
    }
    return fallback;
}

float readOccluderHeight(uint row) {
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        return occluders[row].heightAlpha.x;
    }
    return 0.0;
}

vec2 readDropShadowParams(uint row) {
    if ((ComponentMask & COMP_DROPSHADOW) != 0u) {
        Std430DropShadow d = dropShadows[row];
        return vec2(d.height, d.opacity);
    }
    return vec2(0.0, 0.0);
}

// Returns (repeatXBits | repeatYBits, scaledUvW, scaledUvH). The cull
// shader stretches the UV rect so the render shader's `fract` wrap
// produces N tiles inside the larger sprite quad.
vec3 readRepeatedSprite(uint row, float spriteW, float spriteH, float baseUvW, float baseUvH) {
    if ((ComponentMask & COMP_REPEATEDSPRITE) == 0u) {
        return vec3(0.0, baseUvW, baseUvH);
    }
    Std430RepeatedSprite r = repeats[row];
    float flagBits = 0.0;
    float outUvW = baseUvW;
    float outUvH = baseUvH;
    if (r.repeatX != 0u && spriteW > 0.0 && r.width > 0.0) {
        flagBits += float(FLAG_REPEAT_X);
        outUvW = baseUvW * (r.width / spriteW);
    }
    if (r.repeatY != 0u && spriteH > 0.0 && r.height > 0.0) {
        flagBits += float(FLAG_REPEAT_Y);
        outUvH = baseUvH * (r.height / spriteH);
    }
    return vec3(flagBits, outUvW, outUvH);
}

// ---------- Frame-index lookup (variable per-frame timing) ----------

float computeFrameIndex(float startTime, float totalDuration, int frameCount, int timingOffset) {
    if (frameCount <= 1) return 0.0;
    float localTime = GlobalTime - startTime;
    float loopedTime = mod(localTime, totalDuration);
    for (int i = 0; i < frameCount; i++) {
        float cumulativeTime = cumulativeTimes[timingOffset + i];
        if (loopedTime < cumulativeTime) return float(i);
    }
    return float(frameCount - 1);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    // Layer check first: it needs only the Transform, so rows on
    // invisible layers (e.g. all world sprites during the screen-phase
    // cull) exit before touching the Sprite/SpriteData columns.
    Std430Transform t = transforms[row];
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    Std430SpriteData sd = spriteData[row];

    // Generation check: if the texture slice was evicted since this
    // sprite was allocated, skip rendering (matches legacy behavior).
    int packBits = SlicePackingBits > 0 ? SlicePackingBits : 8;
    int sliceMask = (1 << packBits) - 1;
    int packedInt = int(sd.textureSlice);
    int sliceIndex = packedInt & sliceMask;
    int entityGen = (packedInt >> packBits) & sliceMask;
    int currentGen = int(sliceGens[sliceIndex]);
    if (entityGen != currentGen) return;

    float w = sd.width;
    float h = sd.height;
    float scaleX = t.scaleX;
    float scaleY = t.scaleY;
    float x = t.x;
    float y = t.y;
    float z = t.z;

    bool isScreenSpace     = isScreenSpaceLayer(layer);
    bool ignoresZoom       = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    vec2 pivot = readPivot(row, vec2(sd.pivotX, sd.pivotY));
    float pivotX = pivot.x;
    float pivotY = pivot.y;

    float bottomY = y + h * scaleY * (1.0 - pivotY);

    // Flags: combine per-archetype tag bits with renderer-internal
    // markers (occluder / drop-shadow presence).
    uint flags = StaticFlags;
    if ((ComponentMask & COMP_OCCLUDER) != 0u) {
        flags = flags | FLAG_OCCLUDER;
    }
    if ((ComponentMask & COMP_DROPSHADOW) != 0u) {
        flags = flags | FLAG_DROP_SHADOW;
    }

    // Bounding box for cull (conservative, accounts for rotation).
    float scaledW = w * scaleX;
    float scaledH = h * scaleY;
    float centerX = x + scaledW * (0.5 - pivotX);
    float centerY = y + scaledH * (0.5 - pivotY);
    float halfDiag = sqrt(scaledW * scaledW + scaledH * scaledH) * 0.5;

    if ((flags & FLAG_DROP_SHADOW) != 0u) {
        halfDiag += h * abs(scaleY) * 3.0;
    }
    if ((flags & FLAG_OCCLUDER) != 0u) {
        halfDiag += ShadowMargin;
    }

    vec4 bounds = vec4(centerX - halfDiag, centerY - halfDiag,
                       centerX + halfDiag, centerY + halfDiag);

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = (w > 0.0) && (h > 0.0);
    if (!isScreenSpace) {
        sizeOK = sizeOK && (scaledW * CameraZoom >= 1.0 || scaledH * CameraZoom >= 1.0);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    uint outIdx = atomicAdd(args[1], 1u);

    // Anim state is only needed for visible rows; load it after the
    // visibility test.
    Std430Sprite sp = sprites[row];

    // Compute current animation frame. pauseAtFrame >= 0 is a pending
    // play-once clamp (Sprite:pauseAtEnd / playOnce): play the current
    // cycle to that frame, then hold it instead of wrapping. Mirrors the
    // CPU reference in Sprite:getFrame.
    int   animFrameCount   = int(sd.animFrameCount);
    int   animTimingOffset = int(sd.animTimingOffset);
    float animPausedFrame  = float(sp.pausedFrame);
    float frameIndex;
    if (animPausedFrame >= 0.0) {
        frameIndex = animPausedFrame;
    } else if (sp.pauseAtFrame >= 0) {
        float targetFrame = float(sp.pauseAtFrame);
        float elapsed = GlobalTime - sp.animStartTime;
        if (elapsed >= sd.animTotalDuration || elapsed < 0.0) {
            frameIndex = targetFrame;
        } else {
            frameIndex = computeFrameIndex(sp.animStartTime, sd.animTotalDuration, animFrameCount, animTimingOffset);
            if (frameIndex > targetFrame) frameIndex = targetFrame;
        }
    } else {
        frameIndex = computeFrameIndex(sp.animStartTime, sd.animTotalDuration, animFrameCount, animTimingOffset);
    }

    float depthWithTie = computeDepth(layer, z, x, bottomY, row);

    // Apply repeat-mode UV scaling (no-op for non-repeated sprites).
    vec3 repeatPack = readRepeatedSprite(row, w, h, sd.uvW, sd.uvH);
    flags = flags | uint(repeatPack.x);
    float outUvW = repeatPack.y;
    float outUvH = repeatPack.z;

    if (isUnlitLayer(layer)) {
        flags = flags | FLAG_UNLIT;
    }

    uint materialId = readMaterialId(row);
    uint packed = packRenderFlags(flags, isScreenSpace, ignoresZoom, usesVirtualCoords, BlendId, materialId);
    float packedBits = uintBitsToFloat(packed);

    float outX = x + pOff.x;
    float outY = y + pOff.y;

    vec4 outColor = readColor(row);
    vec4 outClipBounds = readClipBounds(row);
    vec4 outPosSize = vec4(outX, outY, w, h);
    vec4 outDepthLayerGrid = vec4(depthWithTie, layer, sd.animColumnCount, sd.animFrameHeight);
    vec4 outUvRect = vec4(sd.uvX, sd.uvY, outUvW, outUvH);
    vec4 outAnimData = vec4(frameIndex, sd.animTotalDuration, float(animFrameCount), sd.animFrameWidth);
    vec4 outRotScale = vec4(t.rotation, scaleX, scaleY, float(sliceIndex));

    spritesOut[outIdx].posSize = outPosSize;
    spritesOut[outIdx].color = outColor;
    spritesOut[outIdx].depthLayerGrid = outDepthLayerGrid;
    spritesOut[outIdx].clipBounds = outClipBounds;
    spritesOut[outIdx].uvRect = outUvRect;
    spritesOut[outIdx].animData = outAnimData;
    spritesOut[outIdx].rotScale = outRotScale;
    spritesOut[outIdx].pivot = vec4(pivotX, pivotY, 0.0, packedBits);

    materialParamsOut[outIdx] = readMaterialParams(row);

    // Occluder dual-write (shadow-mask shader reads occluderHeight in
    // .color.a and textureSlice in .pivot.z).
    if ((flags & FLAG_OCCLUDER) != 0u) {
        uint shadowIdx = atomicAdd(shadowArgs[1], 1u);
        spritesShadowOut[shadowIdx].posSize = outPosSize;
        spritesShadowOut[shadowIdx].color = vec4(outColor.rgb, readOccluderHeight(row));
        spritesShadowOut[shadowIdx].depthLayerGrid = outDepthLayerGrid;
        spritesShadowOut[shadowIdx].clipBounds = outClipBounds;
        spritesShadowOut[shadowIdx].uvRect = outUvRect;
        spritesShadowOut[shadowIdx].animData = outAnimData;
        spritesShadowOut[shadowIdx].rotScale = vec4(outRotScale.xyz, 0.0);
        spritesShadowOut[shadowIdx].pivot = vec4(pivotX, pivotY, float(sliceIndex), packedBits);
    }

    // Drop-shadow per-light fan-out.
    if ((flags & FLAG_DROP_SHADOW) != 0u) {
        vec2 dsParams = readDropShadowParams(row);
        float entityHeight = dsParams.x;
        float baseOpacity  = dsParams.y;

        float footX = outX + w * scaleX * (0.5 - pivotX);
        float footY = outY + h * scaleY * (1.0 - pivotY);
        vec2 footPos = vec2(footX, footY);

        float spriteH = h * abs(scaleY);
        float dsDepth = min(computeDepth(layer, z, footX, footY, row) + 0.03, 0.999);
        vec4 dsUvRect = vec4(sd.uvX, sd.uvY + sd.uvH, sd.uvW, -sd.uvH);

        vec2 vpMin = TileViewport.xy;
        vec2 vpSize = TileViewport.zw - TileViewport.xy;
        vec2 tileNorm = (footPos - vpMin) / vpSize;
        ivec2 tileCoord = clamp(ivec2(tileNorm * vec2(TileGridDims)), ivec2(0), TileGridDims - 1);
        uint tileIdx = uint(tileCoord.y * TileGridDims.x + tileCoord.x);
        uint numTileLights = min(tileCounts[tileIdx], MAX_LIGHTS_PER_TILE);

        for (uint ti = 0u; ti < numTileLights; ti++) {
            uint lightIdx = tileIndices[tileIdx * MAX_LIGHTS_PER_TILE + ti];
            LightData light = lights[lightIdx];
            vec2 lpos = light.posHeight.xy;
            float lheight = light.posHeight.z;
            float lradius = light.posHeight.w;
            float lintensity = light.intensityColor.x;

            float ldist = distance(footPos, lpos);
            if (ldist > lradius) continue;

            float tFactor = ldist / lradius;
            float atten = 1.0 - tFactor * tFactor;
            float weight = lintensity * atten;
            if (weight < 0.05) continue;

            uint dsIdx = atomicAdd(dropShadowArgs[1], 1u);
            if (dsIdx >= MaxDropShadows) break;

            vec2 dir = footPos - lpos;
            float dist = length(dir);
            dir = dist > 0.001 ? dir / dist : vec2(0.0, 1.0);

            float distRatio = ldist / max(lradius * lheight, 1.0);
            float heightFactor = (1.0 - lheight) / max(lheight, 0.15);
            float shadowLen = spriteH * entityHeight * (0.3 + distRatio * 1.5) * min(heightFactor, 2.0);
            shadowLen = clamp(shadowLen, spriteH * 0.2, spriteH * 3.0);
            float dsStretch = shadowLen / max(spriteH, 0.001);

            float dsRotation = atan(-dir.x, dir.y);
            float dsScaleY = abs(scaleY) * dsStretch;
            float dsOpacity = baseOpacity * clamp(weight, 0.0, 1.0);

            vec4 dsPos = vec4(footX, footY, w, h);

            spritesDropShadowOut[dsIdx].posSize = dsPos;
            spritesDropShadowOut[dsIdx].color = vec4(0.0, 0.0, 0.0, dsOpacity);
            spritesDropShadowOut[dsIdx].depthLayerGrid = vec4(dsDepth, layer, sd.animColumnCount, sd.animFrameHeight);
            spritesDropShadowOut[dsIdx].clipBounds = outClipBounds;
            spritesDropShadowOut[dsIdx].uvRect = dsUvRect;
            spritesDropShadowOut[dsIdx].animData = outAnimData;
            spritesDropShadowOut[dsIdx].rotScale = vec4(dsRotation, abs(scaleX), dsScaleY, float(sliceIndex));
            spritesDropShadowOut[dsIdx].pivot = vec4(0.5, 0.0, 0.0, packedBits);
        }
    }
}

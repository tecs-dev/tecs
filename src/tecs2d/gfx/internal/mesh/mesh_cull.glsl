// Mesh culling compute shader — renderer-owned shadow-column path.
// Common code is prepended from cull_common.glsl.
//
// One dispatch per (definition, archetype). Each dispatch binds the
// archetype's source-component shadow SSBOs and reads them by archetype-
// row index. The host sets `TargetDefinitionId` per dispatch; rows with
// `mesh._definitionId != TargetDefinitionId` are skipped (single uint
// compare per row, dispatch-uniform branch).
//
// Mesh bounds are definition-constant, so they come in as a `MeshBounds`
// uniform (vec4: centerX, centerY, halfW, halfH) instead of a per-row
// shadow column. Saves 16 bytes per row of shadow upload.
//
// Output buffers (MeshOutput, IndirectArgs, MaterialParamsOutput) are
// per-definition — each MeshDefinition has its own output buffer because
// each definition draws with its own `love.graphics.Mesh` geometry. The
// atomicAdd on the indirect counter gives a globally-unique output index
// for visible entities of this definition across all archetypes that
// host them.

// ---------- Source-component SSBOs ----------

struct Std430Transform {
    vec4 xyzLayer;       // x, y, z, layerFloat
    vec4 rotScalePad;    // rotation, scaleX, scaleY, _pad0
};
layout(std430) readonly buffer TransformInput {
    Std430Transform transforms[];
};

struct Std430Mesh {
    uint definitionId;
};
layout(std430) readonly buffer MeshInput {
    Std430Mesh meshes[];
};

struct Std430Color {
    vec4 rgba;
};
layout(std430) readonly buffer ColorInput {
    Std430Color colors[];
};

struct Std430ClipBounds {
    vec4 minMaxXY;       // minX, minY, maxX, maxY
};
layout(std430) readonly buffer ClipBoundsInput {
    Std430ClipBounds clipBounds[];
};

struct Std430Pivot {
    vec4 xyPad;          // x, y, _pad, _pad
};
layout(std430) readonly buffer PivotInput {
    Std430Pivot pivots[];
};

struct Std430Material {
    vec4 idP012;         // materialId(bits as float), p0, p1, p2
    vec4 p3Pad;          // p3, _pad, _pad, _pad
};
layout(std430) readonly buffer MaterialInput {
    Std430Material materials[];
};

// ---------- Output buffers (per-definition; shared across archetypes
// routed to this definition) ----------

struct MeshOut {
    vec4 posLayer;         // x, y, z, layerFloat
    vec4 color;            // r, g, b, a
    vec4 scaleRotFlags;    // scaleX, scaleY, rotation, flags-as-float
    vec4 pivot;            // pivotX, pivotY, _pad, _pad
    vec4 clipBounds;       // minX, minY, maxX, maxY
    uvec4 flags;           // flagBits, depthBits, _pad, _pad
};
// IndirectArgs (uint args[]) is declared in cull_common.glsl which is
// prepended by shaders.loadCullShader; we use `args[]` directly.
layout(std430) writeonly buffer MeshOutput {
    MeshOut meshesOut[];
};
layout(std430) writeonly buffer MaterialParamsOutput {
    vec4 materialParamsOut[];
};

// ---------- Component-presence mask ----------

const uint COMP_COLOR        = 0x1u;
const uint COMP_CLIPBOUNDS   = 0x2u;
const uint COMP_PIVOT        = 0x4u;
const uint COMP_MATERIAL     = 0x8u;

uniform uint ComponentMask;
uniform uint ArchetypeRowCount;
// TargetDefinitionId: dispatch-uniform. Rows whose `_definitionId`
// doesn't match are skipped.
uniform uint TargetDefinitionId;
// MeshBounds: definition-constant bounds (centerX, centerY, halfW,
// halfH). Set once per dispatch.
uniform vec4 MeshBounds;
// StaticFlags: per-archetype OR of bits whose tag components are
// present (e.g. FLAG_UNLIT for the Unlit tag).
uniform uint StaticFlags;
// BlendId is dispatch-uniform: every entity in this archetype shares
// the same blend mode (archetype identity = blend identity).
uniform uint BlendId;

// ---------- Helpers for optional components ----------

vec4 readColor(uint row) {
    if ((ComponentMask & COMP_COLOR) != 0u) {
        return colors[row].rgba;
    }
    return vec4(1.0, 1.0, 1.0, 1.0);
}

vec4 readClipBounds(uint row) {
    if ((ComponentMask & COMP_CLIPBOUNDS) != 0u) {
        return clipBounds[row].minMaxXY;
    }
    return vec4(-3.4e38, -3.4e38, 3.4e38, 3.4e38);  // unbounded
}

vec2 readPivot(uint row) {
    if ((ComponentMask & COMP_PIVOT) != 0u) {
        return pivots[row].xyPad.xy;
    }
    return vec2(0.0, 0.0);
}

uint readMaterialId(uint row) {
    if ((ComponentMask & COMP_MATERIAL) != 0u) {
        return floatBitsToUint(materials[row].idP012.x);
    }
    return 0u;
}

vec4 readMaterialParams(uint row) {
    if ((ComponentMask & COMP_MATERIAL) != 0u) {
        Std430Material m = materials[row];
        return vec4(m.idP012.y, m.idP012.z, m.idP012.w, m.p3Pad.x);
    }
    return vec4(0.0);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    // Definition filter: skip rows whose mesh definition doesn't
    // match this dispatch's target. id=0 means "unresolved" and is
    // also skipped (the host could log this; for now treat as not-
    // visible).
    Std430Mesh m = meshes[row];
    if (m.definitionId != TargetDefinitionId) return;
    if (m.definitionId == 0u) return;

    Std430Transform t = transforms[row];

    float x = t.xyzLayer.x;
    float y = t.xyzLayer.y;
    float z = t.xyzLayer.z;
    float layer = t.xyzLayer.w;
    if (!isCameraLayerVisible(layer)) return;

    float rotation = t.rotScalePad.x;
    float scaleX = t.rotScalePad.y;
    float scaleY = t.rotScalePad.z;

    bool isScreenSpace = isScreenSpaceLayer(layer);
    bool ignoresZoom = isIgnoreZoomLayer(layer);
    bool usesVirtualCoords = isVirtualCoordsLayer(layer);

    // Definition-constant bounds, scaled by the entity's transform.
    float boundsCenterX = MeshBounds.x;
    float boundsCenterY = MeshBounds.y;
    float boundsHalfW = MeshBounds.z;
    float boundsHalfH = MeshBounds.w;

    float scaledHalfW = boundsHalfW * abs(scaleX);
    float scaledHalfH = boundsHalfH * abs(scaleY);

    float centerX = x + boundsCenterX * scaleX;
    float centerY = y + boundsCenterY * scaleY;

    // Conservative bounding circle for rotated bounds.
    float halfDiag = sqrt(scaledHalfW * scaledHalfW + scaledHalfH * scaledHalfH);

    float left = centerX - halfDiag;
    float top = centerY - halfDiag;
    float right = centerX + halfDiag;
    float bottom = centerY + halfDiag;

    bool visible;
    if (isScreenSpace) {
        vec2 cullSize = getScreenSpaceCullSize(usesVirtualCoords);
        visible = (scaledHalfW > 0.0 || scaledHalfH > 0.0) &&
                  (right > 0.0) && (left < cullSize.x) &&
                  (bottom > 0.0) && (top < cullSize.y);
    } else {
        vec2 parallax = getParallaxFactor(layer);
        float parallaxOffsetX = CameraPos.x * (1.0 - parallax.x);
        float parallaxOffsetY = CameraPos.y * (1.0 - parallax.y);
        float adjLeft = left + parallaxOffsetX;
        float adjRight = right + parallaxOffsetX;
        float adjTop = top + parallaxOffsetY;
        float adjBottom = bottom + parallaxOffsetY;

        float screenW = scaledHalfW * 2.0 * CameraZoom;
        float screenH = scaledHalfH * 2.0 * CameraZoom;
        visible = (scaledHalfW > 0.0 || scaledHalfH > 0.0) &&
                  (screenW >= 1.0 || screenH >= 1.0) &&
                  (adjRight > CameraViewport.x) && (adjLeft < CameraViewport.z) &&
                  (adjBottom > CameraViewport.y) && (adjTop < CameraViewport.w);
    }

    if (!visible) return;

    uint outIdx = atomicAdd(args[1], 1u);

    // Apply parallax offset to output position (for rendering).
    float outX = x;
    float outY = y;
    if (!isScreenSpace) {
        vec2 parallax = getParallaxFactor(layer);
        outX += CameraPos.x * (1.0 - parallax.x);
        outY += CameraPos.y * (1.0 - parallax.y);
    }

    // Stable depth tie-breaker: archetype row index (matches the
    // simple-shape convention).
    float actualBottom = y + (boundsCenterY + boundsHalfH) * scaleY;
    float depth = computeDepth(layer, z, x, actualBottom, row);

    uint flags = StaticFlags;
    if (isUnlitLayer(layer)) {
        flags = flags | 1u;  // FLAG_UNLIT = 0x1
    }

    uint screenSpaceFlags = encodeScreenSpaceFlagsUint(isScreenSpace, ignoresZoom, usesVirtualCoords);
    uint materialId = readMaterialId(row);
    uint packedFlags = flags | screenSpaceFlags | (BlendId << 20u) | (materialId << 24u);

    vec2 pivot = readPivot(row);
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);

    MeshOut mo;
    mo.posLayer = vec4(outX, outY, z, layer);
    mo.color = color;
    mo.scaleRotFlags = vec4(scaleX, scaleY, rotation, uintBitsToFloat(packedFlags));
    mo.pivot = vec4(pivot.x, pivot.y, 0.0, 0.0);
    mo.clipBounds = clip;
    mo.flags = uvec4(packedFlags, floatBitsToUint(depth), 0u, 0u);

    meshesOut[outIdx] = mo;

    // Per-output material params (output-order; render shader reads
    // by gl_InstanceID).
    materialParamsOut[outIdx] = readMaterialParams(row);
}

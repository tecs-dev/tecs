// Mesh culling compute shader -- renderer-owned shadow-column path.
// Shared structs, component readers, uniforms, and cull helpers are
// prepended from cull_common.glsl.
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
// per-definition -- each MeshDefinition has its own output buffer because
// each definition draws with its own `love.graphics.Mesh` geometry. The
// atomicAdd on the indirect counter gives a globally-unique output index
// for visible entities of this definition across all archetypes that
// host them.

// ---------- Shape-specific source SSBOs ----------

struct Std430Mesh {
    uint definitionId;
};
layout(std430) readonly buffer MeshInput {
    Std430Mesh meshes[];
};

struct Std430Pivot {
    vec4 xyPad;          // x, y, _pad, _pad
};
layout(std430) readonly buffer PivotInput {
    Std430Pivot pivots[];
};

// ---------- Output buffers (per-definition; shared across archetypes
// routed to this definition) ----------

struct MeshOut {
    vec4 posLayer;         // x, y, z, layerFloat
    vec4 color;            // r, g, b, a
    vec4 scaleRotFlags;    // scaleX, scaleY, rotation, spare
    vec4 pivot;            // pivotX, pivotY, _pad, _pad
    vec4 clipBounds;       // minX, minY, maxX, maxY
    uvec4 flags;           // packed flags, depthBits, _pad, _pad
};
// IndirectArgs (uint args[]) is declared in cull_common.glsl which is
// prepended by shaders.loadCullShader; we use `args[]` directly.
layout(std430) writeonly buffer MeshOutput {
    MeshOut meshesOut[];
};

// TargetDefinitionId: dispatch-uniform. Rows whose `_definitionId`
// doesn't match are skipped.
uniform uint TargetDefinitionId;
// MeshBounds: definition-constant bounds (centerX, centerY, halfW,
// halfH). Set once per dispatch.
uniform vec4 MeshBounds;

// ---------- Shape-specific component readers ----------

vec2 readPivot(uint row) {
    if ((ComponentMask & COMP_PIVOT) != 0u) {
        return pivots[row].xyPad.xy;
    }
    return vec2(0.0, 0.0);
}

// ---------- Cull main ----------

void computemain() {
    uint row = gl_GlobalInvocationID.x;
    if (row >= ArchetypeRowCount) return;

    // Definition filter: skip rows whose mesh definition doesn't match
    // this dispatch's target. id=0 means "unresolved" and never matches
    // a real target (definition ids start at 1).
    Std430Mesh m = meshes[row];
    if (m.definitionId != TargetDefinitionId) return;

    Std430Transform t = transforms[row];

    float x = t.x;
    float y = t.y;
    float z = t.z;
    float layer = float(t.layerInt);
    if (!isCameraLayerVisible(layer)) return;

    float rotation = t.rotation;
    float scaleX = t.scaleX;
    float scaleY = t.scaleY;

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

    vec4 bounds = vec4(centerX - halfDiag, centerY - halfDiag,
                       centerX + halfDiag, centerY + halfDiag);

    vec2 pOff = isScreenSpace ? vec2(0.0) : getParallaxOffset(layer);
    bool sizeOK = (scaledHalfW > 0.0 || scaledHalfH > 0.0);
    if (!isScreenSpace) {
        sizeOK = sizeOK && (scaledHalfW * 2.0 * CameraZoom >= 1.0 || scaledHalfH * 2.0 * CameraZoom >= 1.0);
    }
    if (!sizeOK || !cullBoundsVisible(bounds, isScreenSpace, usesVirtualCoords, pOff)) return;

    uint outIdx = atomicAdd(args[1], 1u);

    // Apply parallax offset to output position (for rendering).
    float outX = x + pOff.x;
    float outY = y + pOff.y;

    // Stable depth tie-breaker: archetype row index (matches the
    // simple-shape convention).
    float actualBottom = y + (boundsCenterY + boundsHalfH) * scaleY;
    float depth = computeDepth(layer, z, x, actualBottom, row);

    uint flags = StaticFlags;
    if (isUnlitLayer(layer)) {
        flags = flags | FLAG_UNLIT;
    }

    uint materialId = readMaterialId(row);
    uint packed = packRenderFlags(flags, isScreenSpace, ignoresZoom, usesVirtualCoords, BlendId, materialId);

    vec2 pivot = readPivot(row);
    vec4 color = readColor(row);
    vec4 clip = readClipBounds(row);

    MeshOut mo;
    mo.posLayer = vec4(outX, outY, z, layer);
    mo.color = color;
    mo.scaleRotFlags = vec4(scaleX, scaleY, rotation, 0.0);
    mo.pivot = vec4(pivot.x, pivot.y, 0.0, 0.0);
    mo.clipBounds = clip;
    mo.flags = uvec4(packed, floatBitsToUint(depth), 0u, 0u);

    meshesOut[outIdx] = mo;

    // Per-output material params (output-order; render shader reads
    // by gl_InstanceID).
    materialParamsOut[outIdx] = readMaterialParams(row);
}

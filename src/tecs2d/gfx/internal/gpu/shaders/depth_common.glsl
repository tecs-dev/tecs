// Shared depth computation, sort mode, and layer check functions
// Used by cull shaders (via cull_common.glsl) and render shaders (text, tilechunk)
//
// All uniforms (MaxLayer, MaxZ, MaxY, masks, SortModes) are provided by the
// including SSBO block: CullParams (cull shaders) or RenderParams (render shaders).
// The #define macros in those blocks map the original uniform names to SSBO fields.

// Check if a layer is screen-space (bit N = layer N+1)
bool isScreenSpaceLayer(float layer) {
    uint layerIdx = uint(layer) - 1u;
    return ((ScreenSpaceMask >> layerIdx) & 1u) == 1u;
}

// Check if a layer ignores zoom (bit N = layer N+1)
bool isIgnoreZoomLayer(float layer) {
    uint layerIdx = uint(layer) - 1u;
    return ((IgnoreZoomMask >> layerIdx) & 1u) == 1u;
}

// Check if a layer uses virtual coordinates (bit N = layer N+1)
bool isVirtualCoordsLayer(float layer) {
    uint layerIdx = uint(layer) - 1u;
    return ((VirtualCoordsMask >> layerIdx) & 1u) == 1u;
}

// Check if a layer is unlit (bit N = layer N+1)
bool isUnlitLayer(float layer) {
    uint layerIdx = uint(layer) - 1u;
    return ((UnlitMask >> layerIdx) & 1u) == 1u;
}

// Sort mode constants
const int SORT_MODE_TOPDOWN = 0;
const int SORT_MODE_Z = 1;
const int SORT_MODE_ISOMETRIC = 2;

// Get sort mode for a layer (0=topdown, 1=z-only, 2=isometric)
int getSortMode(float layer) {
    int idx = int(layer) - 1;
    int col = idx / 4;
    int row = idx % 4;
    return int(SortModes[col][row]);
}

// Compute depth value for z-ordering
// Uses layer bands, sort mode, and slot-based tie-breaking
// Sort modes: 0=topdown (Y-sort), 1=z-only, 2=isometric (X+Y+Z)
float computeDepth(float layer, float zIndex, float x, float bottomY, uint slotIdx) {
    float layerBandSize = 1.0 / MaxLayer;
    float layerBase = (MaxLayer - layer) * layerBandSize;

    int sortMode = getSortMode(layer);
    float withinBand;

    if (sortMode == SORT_MODE_Z) {
        // Z-only: sort purely by z-index with slot tie-breaker
        withinBand = (1.0 - zIndex / MaxZ) * layerBandSize * 0.99;
    } else if (sortMode == SORT_MODE_ISOMETRIC) {
        // Isometric: sort by X + Y + Z
        // Normalize to [0,1] range assuming world coords in [-MaxY, +MaxY] for both X and Y
        float normalizedX = (x + MaxY) / (2.0 * MaxY);
        float normalizedY = (bottomY + MaxY) / (2.0 * MaxY);
        float isoValue = normalizedX + normalizedY + zIndex / MaxZ;
        // Clamp to prevent overflow (max iso = 3.0)
        withinBand = (1.0 - clamp(isoValue / 3.0, 0.0, 1.0)) * layerBandSize * 0.99;
    } else {
        // TopDown (default): Y-sort with Z for explicit ordering
        float normalizedY = (bottomY + MaxY) / (2.0 * MaxY);
        withinBand = (1.0 - (zIndex / MaxZ * 0.7 + normalizedY * 0.3)) * layerBandSize * 0.99;
    }

    // Slot-based tie-breaker for exact depth ties. Keep the entire range
    // below one tenth of a single z unit so entity identity can never
    // override an explicit z ordering (notably for layered UI).
    const float TIE_SLOTS = 1024.0;
    float tieStep = layerBandSize * 0.099 / (MaxZ * TIE_SLOTS);
    float tieBreaker = float(slotIdx % 1024u) * tieStep;
    return clamp(layerBase + withinBand + tieBreaker, 0.001, 0.999);
}

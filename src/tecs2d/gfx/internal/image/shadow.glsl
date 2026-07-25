#pragma language glsl4

// Alpha-silhouette shadow mask for directly rendered Images.

uniform vec2 ImagePosition;
uniform vec2 ImageSize;
uniform vec2 ImageScale;
uniform vec2 ImagePivot;
uniform float ImageRotation;
uniform float OccluderHeight;
uniform float AlphaThreshold;
uniform vec4 ClipBounds;
uniform bool HasClipBounds;

varying vec2 WorldPosition;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertexPosition) {
    vec2 local = vertexPosition.xy - ImageSize * ImagePivot;
    vec2 scaled = local * ImageScale;
    float c = cos(ImageRotation);
    float s = sin(ImageRotation);
    vec2 rotated = vec2(
        scaled.x * c - scaled.y * s,
        scaled.x * s + scaled.y * c
    );
    WorldPosition = ImagePosition + rotated;
    return transform_projection * vec4(
        shadowMaskToScreen(WorldPosition),
        0.0,
        1.0
    );
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screenCoord) {
    if (HasClipBounds && (
        WorldPosition.x < ClipBounds.x
        || WorldPosition.y < ClipBounds.y
        || WorldPosition.x > ClipBounds.z
        || WorldPosition.y > ClipBounds.w
    )) {
        discard;
    }
    if (Texel(texture, uv).a < AlphaThreshold) {
        discard;
    }
    return encodeOccluder(OccluderHeight);
}
#endif

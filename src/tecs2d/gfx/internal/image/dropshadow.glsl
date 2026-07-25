#pragma language glsl4

// Direct Image drop-shadow AO. The same shader projects shadows and stamps
// source silhouettes back to AO=1 to avoid self-shadowing.

uniform vec2 ImagePosition;
uniform vec2 ImageSize;
uniform vec2 ImageScale;
uniform vec2 ImagePivot;
uniform float ImageRotation;
uniform float ImageLayer;
uniform float ShadowOpacity;
uniform bool FlipTextureY;
uniform bool StampSource;
uniform vec4 ClipBounds;
uniform bool HasClipBounds;
uniform Image MainTex;

varying vec2 WorldPosition;
varying vec2 TextureCoordinate;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertexPosition) {
    if (ImageLayer < LayerRange.x || ImageLayer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    vec2 local = vertexPosition.xy - ImageSize * ImagePivot;
    vec2 scaled = local * ImageScale;
    float c = cos(ImageRotation);
    float s = sin(ImageRotation);
    vec2 rotated = vec2(
        scaled.x * c - scaled.y * s,
        scaled.x * s + scaled.y * c
    );
    WorldPosition = ImagePosition + rotated;
    TextureCoordinate = VaryingTexCoord.xy;
    if (FlipTextureY) {
        TextureCoordinate.y = 1.0 - TextureCoordinate.y;
    }

    vec2 screenPosition = worldToScreen(
        WorldPosition,
        false,
        false,
        false
    );
    return transform_projection * vec4(screenPosition, 0.0, 1.0);
}
#endif

#ifdef PIXEL
void effect() {
    if (HasClipBounds && outsideClipBounds(WorldPosition, ClipBounds)) {
        discard;
    }
    if (Texel(MainTex, TextureCoordinate).a < 0.01) {
        discard;
    }
    float ao = StampSource ? 1.0 : 1.0 - ShadowOpacity;
    love_Canvases[0] = vec4(ao, 0.0, 0.0, 1.0);
}
#endif

#pragma language glsl4

#define MAX_LIGHTS_PER_TILE 128u

struct LightData {
    vec4 posHeight;       // x, y, z (height), radius
    vec4 intensityColor;  // intensity, r, g, b
    vec4 spotParams;      // spotDirX, spotDirY, cosConeAngle, cosInnerConeAngle
    vec4 extraParams;     // penumbra, cookieSlice, cookieScaleRotX, cookieScaleRotY
};

layout(std430) readonly buffer LightBuffer {
    LightData lights[];
};

layout(std430) readonly buffer TileLightCounts {
    uint tileCounts[];
};

layout(std430) readonly buffer TileLightIndices {
    uint tileIndices[];
};

uniform Image gAlbedo;
uniform Image gNormal;
uniform Image gORM;
uniform Image gEmission;
uniform Image shadowMask;
uniform bool shadowsActive;
uniform vec3 ambient;
uniform Image gDropShadowAO;
uniform bool dropShadowsActive;
uniform mat4 InvViewProj;
uniform mat4 ShadowViewProj;
uniform ivec2 TileGridDims;
uniform float TileSize;
uniform int MaxShadowSteps;
uniform ArrayImage CookieTex;
uniform bool cookiesActive;

// Interleaved gradient noise (Jimenez, "Next Generation Post Processing in Call of Duty:
// Advanced Warfare", SIGGRAPH 2014, slide 91).
// https://advances.realtimerendering.com/s2014/index.html
// Blue-noise-like spatial distribution; breaks uniform step banding into per-pixel grain.
float interleavedGradientNoise(vec2 screenCoord) {
    return fract(52.9829189 * fract(0.06711056 * screenCoord.x + 0.00583715 * screenCoord.y));
}

// Orthographic shadow VP decomposed into mat2 + offset for fast per-sample UV lookup.
vec2 shadowToUV(mat2 shadowXform, vec2 shadowOffset, vec2 worldPos) {
    return shadowXform * worldPos + shadowOffset;
}

// Raymarch from origin toward light through the shadow mask.
// Shadow mask: R = blurred occluder height, G = occluder flag (1 = real occluder pixel).
// For occluder origins, self-shadow is prevented by skipping hits until the ray exits
// the origin occluder (passes through empty space). Cross-occluder shadows still work.
float raymarchShadow(
    mat2 shadowXform, vec2 shadowOffset,
    vec2 origin, vec2 lightPos, float lightHeight,
    float jitter, float softness, float attenuation
) {
    int maxSteps = clamp(int(float(MaxShadowSteps) * attenuation + 0.5), 4, MaxShadowSteps);

    vec2 originUV = shadowToUV(shadowXform, shadowOffset, origin);
    vec4 originSample = Texel(shadowMask, originUV);
    bool originIsOccluder = (originSample.r > 0.02 && originSample.g > 0.5);

    bool passedEmpty = !originIsOccluder;

    float stepSize = 1.0 / float(maxSteps);
    float shadow = 1.0;

    for (int i = 0; i < maxSteps; i++) {
        float t = (float(i) + jitter) * stepSize;
        vec2 samplePos = mix(origin, lightPos, t);
        vec2 uv = shadowToUV(shadowXform, shadowOffset, samplePos);

        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) continue;

        vec4 maskSample = Texel(shadowMask, uv);
        float occH = maskSample.r;
        bool isOccluder = (occH > 0.01 && maskSample.g > 0.5);

        if (isOccluder) {
            if (!passedEmpty) continue;

            float shadowReach = (lightHeight > 0.001) ? occH / lightHeight : 1.0;

            float edgeFalloff = t / max(shadowReach, 0.001);
            float penumbra = clamp(edgeFalloff * softness, 0.0, 1.0);
            float tipFade = smoothstep(shadowReach * 0.5, shadowReach * 1.2, t);
            float value = mix(penumbra, 1.0, tipFade);
            shadow = min(shadow, value);

            if (shadow <= 0.01) return 0.0;
        } else {
            passedEmpty = true;
        }
    }
    return shadow;
}

const float PI = 3.14159265359;

// GGX/Trowbridge-Reitz normal distribution
float D_GGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

// Schlick-GGX geometry (single direction)
float G_SchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Smith geometry (both directions)
float G_Smith(float NdotV, float NdotL, float roughness) {
    return G_SchlickGGX(NdotV, roughness) * G_SchlickGGX(NdotL, roughness);
}

// Schlick Fresnel approximation
vec3 F_Schlick(float cosTheta, vec3 F0) {
    float t = 1.0 - cosTheta;
    float t2 = t * t;
    return F0 + (1.0 - F0) * (t2 * t2 * t);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screenCoord) {
    vec4 albedo = Texel(gAlbedo, uv);
    if (albedo.a < 0.01) discard;

    vec4 normalSample = Texel(gNormal, uv);

    // Unlit pixels: pass through albedo + emission
    if (normalSample.a < 0.5) {
        vec4 emissionSample = Texel(gEmission, uv);
        vec3 unlitColor = albedo.rgb + emissionSample.rgb * emissionSample.a;
        // G-buffer rendering uses replace blending, so albedo.a still
        // contains the shape's straight-alpha edge coverage.
        return vec4(unlitColor, albedo.a);
    }

    vec3 normal = normalSample.rgb * 2.0 - 1.0;

    // ORM: R = ambient occlusion, G = roughness, B = metallic
    vec4 ormSample = Texel(gORM, uv);
    float ao = ormSample.r;
    float roughness = ormSample.g;
    float metallic = ormSample.b;

    // Fixed orthographic view direction
    vec3 viewDir = vec3(0.0, 0.0, 1.0);
    float NdotV = max(normal.z, 0.001);

    // Fresnel reflectance at normal incidence: dielectric = 0.04, metallic = albedo color
    vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);

    vec2 worldPos = (InvViewProj * vec4(screenCoord, 0.0, 1.0)).xy;

    // Decompose orthographic ShadowViewProj into mat2 + offset
    vec2 smSizeInv = 1.0 / vec2(textureSize(shadowMask, 0));
    mat2 shadowXform = mat2(
        ShadowViewProj[0].xy * smSizeInv,
        ShadowViewProj[1].xy * smSizeInv
    );
    vec2 shadowOffset = ShadowViewProj[3].xy * smSizeInv;

    // AO modulates ambient only
    vec3 litColor = albedo.rgb * ambient * ao;

    // Per-pixel jitter for shadow ray steps (breaks banding into grain)
    float jitter = interleavedGradientNoise(screenCoord);

    // Tile-based light iteration
    ivec2 tileCoord = clamp(ivec2(screenCoord / TileSize), ivec2(0), TileGridDims - 1);
    uint tileIdx = uint(tileCoord.y * TileGridDims.x + tileCoord.x);
    uint numTileLights = min(tileCounts[tileIdx], MAX_LIGHTS_PER_TILE);

    for (uint i = 0u; i < numTileLights; i++) {
        uint lightIdx = tileIndices[tileIdx * MAX_LIGHTS_PER_TILE + i];
        LightData light = lights[lightIdx];
        vec2 lightPos2D = light.posHeight.xy;
        float lightHeight = light.posHeight.z;
        float lightRadius = light.posHeight.w;

        vec2 toLight2D = lightPos2D - worldPos;
        float dist2D = length(toLight2D);

        if (dist2D <= lightRadius) {
            float attenuation = 1.0 - (dist2D / lightRadius);
            attenuation = attenuation * attenuation;

            // Spotlight cone attenuation
            vec2 spotDir = light.spotParams.xy;
            float cosConeAngle = light.spotParams.z;
            float cosInnerConeAngle = light.spotParams.w;

            float spotAttenuation = 1.0;
            if (cosConeAngle < 1.0) {
                vec2 lightToPixel = normalize(-toLight2D);
                float cosAngle = dot(lightToPixel, spotDir);

                if (cosAngle < cosConeAngle) {
                    spotAttenuation = 0.0;
                } else if (cosAngle < cosInnerConeAngle) {
                    spotAttenuation = (cosAngle - cosConeAngle) / (cosInnerConeAngle - cosConeAngle);
                    spotAttenuation = spotAttenuation * spotAttenuation;
                }
            }

            // Shadow raymarch (skip at light fringes where attenuation is imperceptible)
            float shadow = 1.0;
            if (shadowsActive && spotAttenuation > 0.0 && attenuation > 0.05) {
                // Remap penumbra from user-facing [0,1] to internal softness [0,3]
                float softness = light.extraParams.x * 3.0;
                shadow = raymarchShadow(shadowXform, shadowOffset, worldPos, lightPos2D, lightHeight, jitter, softness, attenuation);
            }

            // 2.5D normal-based shading: low height = dramatic side-lighting, high = uniform
            float scaledHeight = lightHeight * 300.0;
            vec3 toLight3D = vec3(toLight2D, scaledHeight);
            vec3 lightDir = normalize(toLight3D);
            float rawNdotL = max(dot(normal, lightDir), 0.0);
            float heightBlend = clamp(lightHeight, 0.0, 0.85);
            float NdotL = mix(rawNdotL, 1.0, heightBlend);

            vec3 lightColor = light.intensityColor.yzw;
            float lightIntensity = light.intensityColor.x;
            float combinedAttenuation = attenuation * spotAttenuation * shadow;

            // Light cookie (gobo) projection
            float cookieSlice = light.extraParams.y;
            if (cookiesActive && cookieSlice >= 0.0) {
                vec2 toFrag = (worldPos - lightPos2D) / lightRadius;
                float csX = light.extraParams.z;
                float csY = light.extraParams.w;
                vec2 cookieUV = vec2(
                    toFrag.x * csX - toFrag.y * csY,
                    toFrag.x * csY + toFrag.y * csX
                );
                cookieUV = cookieUV * 0.5 + 0.5;
                vec4 cookie = Texel(CookieTex, vec3(cookieUV, cookieSlice));
                combinedAttenuation *= cookie.a;
                lightColor *= mix(vec3(1.0), cookie.rgb, cookie.a);
            }

            if (combinedAttenuation < 0.01) {
                continue;
            }

            // Cook-Torrance PBR BRDF
            vec3 H = normalize(lightDir + viewDir);
            float NdotH = max(dot(normal, H), 0.0);

            float D = D_GGX(NdotH, roughness);
            float G = G_Smith(NdotV, NdotL, roughness);
            vec3 F = F_Schlick(max(dot(H, viewDir), 0.0), F0);

            vec3 specBRDF = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);
            vec3 kD = (1.0 - F) * (1.0 - metallic);

            litColor += (kD * albedo.rgb / PI + specBRDF) * lightColor * lightIntensity * combinedAttenuation * NdotL;
        }
    }

    // Drop shadow AO: attenuates all lighting (ambient + dynamic), not emission
    if (dropShadowsActive) {
        float dsAO = Texel(gDropShadowAO, uv).r;
        litColor *= dsAO;
    }

    // Emission (visible even in darkness)
    vec4 emissionSample = Texel(gEmission, uv);
    litColor += emissionSample.rgb * emissionSample.a;

    return vec4(litColor, albedo.a);
}

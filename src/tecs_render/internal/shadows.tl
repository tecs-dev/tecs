--- Shader that applies a light map to a sprite.
local record shadows
    --- Creates a new shader used for shadows from a lightmap canvas.
    ---
    --- @return a new love.graphics.Shader
    newShadowShader: function(): love.graphics.Shader
end

function shadows.newShadowShader(): love.graphics.Shader
    return love.graphics.newShader([[
        #pragma language glsl3
        #ifdef GL_ES
        precision mediump float;
        #endif
        extern Image lightMap;
        extern vec2 lightMapInvSize;

        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
            vec4 outc = Texel(tex, uv) * color;
            vec3 L = Texel(lightMap, sc * lightMapInvSize).rgb;
            outc.rgb *= L;
            return outc;
        }
    ]])
end

return shadows
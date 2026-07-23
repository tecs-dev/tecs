--- Storage for process-owned GPU resources.
---
--- Kept separate from device initialization so low-level bookkeeping modules
--- can share ownership without forcing shader creation or forming import
--- cycles through drawable modules.

local record devicestate
    record Resources
        shadowBlurShader: love.graphics.Shader
        screenUnlitShader: love.graphics.Shader
        lightingShader: love.graphics.Shader
        bloomDownsampleShader: love.graphics.Shader
        bloomUpsampleShader: love.graphics.Shader
        cpuWorldShader: love.graphics.Shader
        layerCompositeShader: love.graphics.Shader
        dummyMaterialParamsBuffer: love.graphics.Buffer
        defaultTexture: love.graphics.Image
        flatNormalTexture: love.graphics.Image
        blackEmissionTexture: love.graphics.Image
        defaultORMTexture: love.graphics.Image
        scratchByKey: {string: {string: any}}
        spriteBucketManager: any
        timingBuffer: any
        dummySSBOs: {string: love.graphics.Buffer}
        retiredObjects: {any}
        materialRegistry: any
    end

    get: function(): Resources
end

local resources: devicestate.Resources = {
    scratchByKey = {},
    dummySSBOs = {},
    retiredObjects = {},
} as devicestate.Resources

function devicestate.get(): devicestate.Resources
    return resources
end

return devicestate

--- Shared render-parameter setup for the forward blend pass.
--- populateRenderParams fills and uploads the RenderParams SSBO used by both
--- renderGBuffer and the shape plugins' forward blend renderers, which draw
--- non-alpha blend modes over the lit image after lighting.

local types <const> = require("tecs2d.gfx.internal.gpu.types")
local C <const> = require("ffi")

local function setOrthographic(t: love.math.Transform, camX: number, camY: number,
        zoom: number, rotation: number, w: number, h: number, spX: number, spY: number)
    t:reset()
    t:translate(w / 2 + spX, h / 2 + spY)
    t:rotate(rotation)
    t:scale(zoom, zoom)
    t:translate(-camX, -camY)
end

local function writeTransformToFFI(t: love.math.Transform, dst: {integer: number})
    local r1,r2,r3,r4, r5,r6,r7,r8, r9,r10,r11,r12, r13,r14,r15,r16 = t:getMatrix()
    dst[0]=r1;  dst[1]=r5;  dst[2]=r9;   dst[3]=r13
    dst[4]=r2;  dst[5]=r6;  dst[6]=r10;  dst[7]=r14
    dst[8]=r3;  dst[9]=r7;  dst[10]=r11; dst[11]=r15
    dst[12]=r4; dst[13]=r8; dst[14]=r12; dst[15]=r16
end

local record forward_blend
    populateRenderParams: function(
        renderer: types.Renderer,
        effectiveCamX: number, effectiveCamY: number,
        cameraZoom: number,
        subPixelX: number, subPixelY: number,
        rw: number, rh: number,
        rotation: number
    )
end

--- Populate and upload RenderParams SSBO. Used by renderGBuffer and forward blend.
function forward_blend.populateRenderParams(
    renderer: types.Renderer,
    effectiveCamX: number, effectiveCamY: number,
    cameraZoom: number,
    subPixelX: number, subPixelY: number,
    rw: number, rh: number,
    rotation: number
)
    rotation = rotation or 0.0
    local vw, vh = renderer.config.virtualRes[1], renderer.config.virtualRes[2]
    local sw, sh = renderer.screenWidth, renderer.screenHeight

    -- Effective render dimensions: normally the G-buffer canvas size (rw × rh),
    -- but for secondary cameras the renderer's screen dims are overridden to the
    -- camera's canvas size, which may be smaller than the shared G-buffer.
    local erw = math.min(rw, sw)
    local erh = math.min(rh, sh)

    local renderPtr = C.cast("GPURenderParams*", renderer.renderParamsByteData:getFFIPointer()) as {integer: types.RenderParamsRecord}
    renderPtr[0].camX = effectiveCamX
    renderPtr[0].camY = effectiveCamY
    renderPtr[0].cameraZoom = cameraZoom
    renderPtr[0].maxLayer = renderer.config.maxLayers
    renderPtr[0].screenHalfX = erw / 2
    renderPtr[0].screenHalfY = erh / 2
    renderPtr[0].subPixelX = subPixelX
    renderPtr[0].subPixelY = subPixelY
    renderPtr[0].virtualW = vw
    renderPtr[0].virtualH = vh
    renderPtr[0].screenW = sw
    renderPtr[0].screenH = sh
    renderPtr[0].renderW = erw
    renderPtr[0].renderH = erh
    renderPtr[0].maxZ = renderer.config.maxZ
    renderPtr[0].maxY = renderer.config.maxY
    renderPtr[0].screenSpaceMask = renderer.screenSpaceMask or 0
    renderPtr[0].ignoreZoomMask = renderer.ignoreZoomMask or 0
    renderPtr[0].virtualCoordsMask = renderer.virtualCoordsMask or 0
    renderPtr[0].unlitMask = renderer.unlitMask or 0
    local sortModesMat = renderer.sortModesMat or {0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0}
    for i = 0, 15 do
        renderPtr[0].sortModes[i] = sortModesMat[i + 1] as number
    end

    -- Use the camera's stored VP transform when it matches the render state
    -- (no sub-pixel offset, dimensions match). Build a fresh transform for
    -- retro mode (camera has screen dims, we render at virtual res), sub-pixel
    -- snap, or secondary cameras (G-buffer is oversized).
    local vt: love.math.Transform
    local cam = renderer.camera
    if cam and subPixelX == 0 and subPixelY == 0
            and cam._screenWidth == erw and cam._screenHeight == erh then
        vt = cam:getTransform()
    else
        local rvt = renderer._renderTransform
        setOrthographic(rvt,
            effectiveCamX, effectiveCamY, cameraZoom, rotation,
            erw, erh, subPixelX, subPixelY
        )
        vt = rvt
    end

    writeTransformToFFI(vt, renderPtr[0].viewProj)
    writeTransformToFFI(vt:inverse(), renderPtr[0].invViewProj)

    renderer.renderParamsBuffer:setArrayData(renderer.renderParamsByteData)
end

return forward_blend

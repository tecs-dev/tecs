local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")

local exp <const> = math.exp
local Transform <const> = tecs.builtins.Transform

local TELEPORT_THRESHOLD_SQ <const> = 500 * 500

local record CameraTargetConfig
    offsetX: number
    offsetY: number
    active: boolean
    deadZoneW: number
    deadZoneH: number
    lookAheadX: number
    lookAheadY: number
end

--- Camera target component and plugin for smooth camera following.
local record CameraTarget is tecs.Component
    --- Horizontal offset from entity center. Defaults to 0.
    offsetX: number
    --- Vertical offset from entity center. Defaults to 0.
    offsetY: number
    --- Whether the camera should follow this target. Defaults to true.
    active: boolean
    --- Half-width of dead zone in world units (0 = disabled).
    deadZoneW: number
    --- Half-height of dead zone in world units (0 = disabled).
    deadZoneH: number
    --- Look-ahead multiplier for horizontal movement (0 = disabled).
    lookAheadX: number
    --- Look-ahead multiplier for vertical movement (0 = disabled).
    lookAheadY: number
    --- Previous target x (for velocity estimation).
    _prevX: number
    --- Previous target y (for velocity estimation).
    _prevY: number
    --- Current look-ahead offset x (smoothed).
    _lookX: number
    --- Current look-ahead offset y (smoothed).
    _lookY: number
    --- Whether _prevX/Y have been set (skip first frame).
    _initialized: boolean

    new: function(config: CameraTargetConfig): CameraTarget
end

tecs.newComponent({
    name = "CameraTarget",
    container = CameraTarget,
    new = function(data: {string: any}): CameraTarget
        local config = (data or {}) as CameraTargetConfig
        return {
            offsetX = config.offsetX or 0,
            offsetY = config.offsetY or 0,
            active = config.active ~= false,  -- defaults to true
            deadZoneW = config.deadZoneW or 0,
            deadZoneH = config.deadZoneH or 0,
            lookAheadX = config.lookAheadX or 0,
            lookAheadY = config.lookAheadY or 0,
            _prevX = 0,
            _prevY = 0,
            _lookX = 0,
            _lookY = 0,
            _initialized = false,
        }
    end,
})

local record cameratarget
    CameraTarget: CameraTarget
    plugin: function(pipeline: types.Pipeline): tecs.Plugin
end

cameratarget.CameraTarget = CameraTarget

function cameratarget.plugin(pipelineInstance: types.Pipeline): tecs.Plugin
    return function(world: tecs.World)
        local query <const> = world:query({
            name = "camera-target",
            include = { Transform, CameraTarget },
            type = "logic"
        })

        world:addSystem({
            name = "render.cameraTarget",
            phase = tecs.phases.PreRender,
            after = {"physics.applyTransform"},
            run = function(dt: number)
                local cam = pipelineInstance:getCamera()
                local invDt = dt > 0 and (1.0 / dt) or 0
                local processed = false

                for archetype, len in query:iter() do
                    local transforms = archetype:get(Transform)
                    local targets = archetype:getMut(CameraTarget)
                    for i = 1, len do
                        local ct = targets[i]
                        if not ct.active then
                            -- Reset initialization so reactivation doesn't
                            -- produce a bogus velocity from stale _prevX/Y.
                            ct._initialized = false
                        elseif not processed then
                            -- First active target wins; subsequent active
                            -- targets are ignored to avoid camera fighting.
                            processed = true

                            local t = transforms[i]
                            local targetX = t.x + ct.offsetX
                            local targetY = t.y + ct.offsetY

                            -- Look-ahead: estimate velocity (per-second) from
                            -- position delta. Using dt makes look-ahead
                            -- framerate-independent.
                            if ct.lookAheadX ~= 0 or ct.lookAheadY ~= 0 then
                                if ct._initialized and invDt > 0 then
                                    local vx = (targetX - ct._prevX) * invDt
                                    local vy = (targetY - ct._prevY) * invDt
                                    local goalX = vx * ct.lookAheadX
                                    local goalY = vy * ct.lookAheadY
                                    local factor = 1 - exp(-5 * dt)
                                    ct._lookX = ct._lookX + (goalX - ct._lookX) * factor
                                    ct._lookY = ct._lookY + (goalY - ct._lookY) * factor
                                end
                                ct._prevX = targetX
                                ct._prevY = targetY
                                ct._initialized = true
                            end

                            -- Teleport detection: if target jumped far, snap camera
                            local camX, camY = cam:getPosition()
                            local ddx = targetX - camX
                            local ddy = targetY - camY
                            local distSq = ddx * ddx + ddy * ddy

                            if distSq > TELEPORT_THRESHOLD_SQ then
                                -- Zero look-ahead BEFORE applying the snap so
                                -- the teleport target isn't offset by stale
                                -- look-ahead from the pre-teleport frame.
                                ct._lookX = 0
                                ct._lookY = 0
                                cam:setPosition(targetX, targetY)
                            else
                                -- Dead zone: clamp per-axis independently so
                                -- X-only or Y-only dead zones work.
                                local moveX = camX
                                local moveY = camY
                                if ct.deadZoneW > 0 then
                                    local dx = targetX - camX
                                    if dx > ct.deadZoneW then moveX = targetX - ct.deadZoneW
                                    elseif dx < -ct.deadZoneW then moveX = targetX + ct.deadZoneW end
                                else
                                    moveX = targetX
                                end
                                if ct.deadZoneH > 0 then
                                    local dy = targetY - camY
                                    if dy > ct.deadZoneH then moveY = targetY - ct.deadZoneH
                                    elseif dy < -ct.deadZoneH then moveY = targetY + ct.deadZoneH end
                                else
                                    moveY = targetY
                                end
                                cam:move(moveX + ct._lookX, moveY + ct._lookY)
                            end
                        end
                    end
                end
            end
        })
    end
end

return cameratarget

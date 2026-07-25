-- Cross-engine 2D sprite throughput benchmark, Tecs implementation.
-- See benches/cross-engine/SPEC.md for the scene contract.
--
-- Split scene: half the sprites sit in a viewport-filling grid (drawn), half
-- sit far off-screen (frustum-culled), so one run covers both paths.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local SpriteSheet <const> = gfx.SpriteSheet

local sin <const> = math.sin
local cos <const> = math.cos
local floor <const> = math.floor
local sqrt <const> = math.sqrt
local ceil <const> = math.ceil

-- ---------- Scene constants (must match SPEC.md) ----------
-- SCREEN_H is the render (virtual) height; overridable for config sweeps.
local SCREEN_H <const> = tonumber(os.getenv("BENCH_VH")) or 720
local LIGHTING <const> = os.getenv("BENCH_LIGHTING") or "none"
local SPACING <const> = 40
local AMP <const> = 16.0
local OMEGA <const> = 2.0
local FIT <const> = 0.9          -- fraction of window height the visible grid fills
local CULL_OFFSET <const> = 1.0e7 -- world X offset that parks the culled half off-screen

local function envNum(name: string, default: number): number
    local v = os.getenv(name)
    if v then
        local n = tonumber(v)
        if n then return n end
    end
    return default
end

local function getSpawnCount(): integer
    local args = love.arg.parseGameArguments(arg)
    if args[1] then
        local count = tonumber(args[1])
        if count and count > 0 then
            return count as integer
        end
    end
    return 100 * 1000
end

local SPAWN_COUNT <const> = getSpawnCount()
local WARMUP <const> = envNum("BENCH_WARMUP", 2.0)
local MEASURE <const> = envNum("BENCH_MEASURE", 5.0)
local MOVE <const> = envNum("BENCH_MOVE", 1) ~= 0

-- Split: first VIS sprites are visible, the rest are parked off-screen.
-- BENCH_SPLIT=0 puts all sprites in the visible grid (no culled half).
local SPLIT <const> = envNum("BENCH_SPLIT", 1) ~= 0
local VIS <const> = SPLIT and floor(SPAWN_COUNT / 2) or SPAWN_COUNT
local CUL <const> = SPAWN_COUNT - VIS
local GRID_V <const> = ceil(sqrt(VIS > 0 and VIS or 1))
local GRID_C <const> = ceil(sqrt(CUL > 0 and CUL or 1))
local GW_V <const> = (GRID_V - 1) * SPACING
local GW_C <const> = (GRID_C - 1) * SPACING

-- Base position for sprite idx (0-based): visible grid centered on the
-- origin, culled grid centered far off-screen at +CULL_OFFSET.
local function baseFor(idx: integer): number, number
    if idx < VIS then
        local row = floor(idx / GRID_V)
        local col = idx % GRID_V
        return -(GW_V / 2) + col * SPACING, -(GW_V / 2) + row * SPACING
    end
    local j = idx - VIS
    local row = floor(j / GRID_C)
    local col = j % GRID_C
    return CULL_OFFSET - (GW_C / 2) + col * SPACING, -(GW_C / 2) + row * SPACING
end

local function benchPlugin(world: tecs.World)
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    local sheet = SpriteSheet.fromFile("assets/running.png")

    local startTime = pipeline:getTime()
    local probe = gfx.Sprite.fromSheet(sheet, "run", {centered = true, startTime = startTime})

    local Transform <const> = tecs.builtins.Transform
    local SpriteComponent <const> = gfx.Sprite

    -- Per-sprite base position, precomputed once (1-indexed, by column row).
    -- ofsX/ofsY hold the orbit offset vector (used by the incremental-rotation
    -- movement path; see BENCH_INCREMENTAL).
    local baseX: {number} = {}
    local baseY: {number} = {}
    local ofsX: {number} = {}
    local ofsY: {number} = {}

    world:batchSpawn(SPAWN_COUNT,
        {Transform as tecs.Component, SpriteComponent as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _n: integer)
            local transforms = arch:getMut(Transform)
            for i = startRow, lastRow do
                local idx = i - 1
                local bx, by = baseFor(idx)
                baseX[i] = bx
                baseY[i] = by
                local ph = idx * 0.001
                ofsX[i] = sin(ph) * AMP
                ofsY[i] = cos(ph) * AMP
                local t = transforms[i]
                t.x = bx
                t.y = by
                t.z = idx * 0.000001
                t.layer = 2
                t.rotation = 0
                t.scaleX = 1
                t.scaleY = 1

                probe.animStartTime = startTime - (idx * 0.0137)
                arch:set(i, probe)
            end
        end)

    -- Camera: centered on the visible grid, zoomed so it fills 90% of the
    -- window height. The culled grid sits at +CULL_OFFSET, well outside the
    -- frustum. BENCH_ZOOM overrides the fit zoom for diagnostics.
    local cam = pipeline:getCamera()
    cam:setLerpingEnabled(false)
    cam:setPosition(0, 0)
    local zoom = GW_V > 0 and (SCREEN_H * FIT) / GW_V or 1.0
    local zoomEnv = os.getenv("BENCH_ZOOM")
    if zoomEnv and tonumber(zoomEnv) then
        zoom = tonumber(zoomEnv)
    end
    cam:setZoom(zoom)

    -- Movement: every sprite's transform changes every frame, which defeats
    -- the static-scene dirty-skip. Animation is automatic (GPU, time-driven).
    if MOVE then
        local benchQuery = world:query({include = {SpriteComponent}})
        world:addSystem({
            name = "bench.Move",
            phase = tecs.phases.Update,
            run = function(dt: number)
                -- Every sprite orbits at the same angular rate, so the
                -- per-frame rotation is shared: compute it once, then rotate
                -- each sprite's stored offset (no per-sprite trig).
                local a = OMEGA * dt
                local c, s = cos(a), sin(a)
                for archetype, len in benchQuery:iter() do
                    local transforms = archetype:getMut(Transform)
                    for i = 1, len do
                        local ox, oy = ofsX[i], ofsY[i]
                        local nx = ox * c + oy * s
                        local ny = oy * c - ox * s
                        ofsX[i] = nx
                        ofsY[i] = ny
                        local tr = transforms[i]
                        tr.x = baseX[i] + nx
                        tr.y = baseY[i] + ny
                    end
                end
            end
        })
    end

    -- Timing: warm up, measure a fixed window, print one RESULT line, exit.
    -- Frame time is the dt the run loop passes (love_timer_step), summed into
    -- the warmup and measure windows.
    local samples: {number} = {}
    local sumDt = 0.0
    local frames = 0
    local elapsed = 0.0
    local measured = 0.0

    world:addSystem({
        name = "bench.Timing",
        phase = tecs.phases.Last,
        run = function(dt: number)
            elapsed = elapsed + dt
            if elapsed < WARMUP then
                return
            end
            samples[#samples + 1] = dt
            sumDt = sumDt + dt
            frames = frames + 1
            measured = measured + dt
            if measured >= MEASURE then
                local meanMs = (sumDt / frames) * 1000.0
                table.sort(samples)
                local p99Idx = ceil(0.99 * #samples)
                if p99Idx < 1 then p99Idx = 1 end
                local p99Ms = samples[p99Idx] * 1000.0
                local fps = meanMs > 0 and 1000.0 / meanMs or 0
                local low1 = p99Ms > 0 and 1000.0 / p99Ms or 0
                io.write(string.format(
                    "RESULT,tecs,%d,%d,%.4f,%.2f,%.2f\n",
                    SPAWN_COUNT, frames, meanMs, fps, low1))
                io.flush()
                tecs2d.quit(0)
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    maxEntities = SPAWN_COUNT + 1024,
    game = function(world: tecs.World)
        if os.getenv("BENCH_MCP") then
            world:addPlugin((require("tecs2d.mcp")).new())
        end
        world:addPlugin(benchPlugin)
    end,
    render = {
        virtualHeight = math.floor(SCREEN_H),
        lightingMode = LIGHTING,
        layers = {
            [1] = { name = "background" },
            [2] = { name = "sprites" },
            [3] = { name = "hud", space = "screen" },
        },
        sizeHints = { sprites = SPAWN_COUNT + 1000 },
    },
})

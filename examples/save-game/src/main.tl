--- Tiny paint app with save / load / undo.
---
--- A 32x32 grid of cells. Each painted cell is a real entity with a colour
--- and (col, row). Saves go through `world:saveSnapshot({format="table"})`
--- -> JSON, and loads through `world:loadSnapshot`, so the painting
--- round-trips as plain ECS state.
---
--- Controls:
---   Left click         paint current cell with current colour
---   Right click        erase cell
---   Click a palette swatch to pick a colour
---   S                  save
---   L                  load
---   U                  undo
---   C                  clear the canvas
---   Esc                quit

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local input <const> = require("tecs2d.input")
local json <const> = require("tecs.utils.json")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("save-game")

local Transform <const> = tecs.builtins.Transform

local WINDOW_WIDTH <const> = 800
local WINDOW_HEIGHT <const> = 600

local GRID_SIZE <const> = 16                    -- sprite canvas dimensions
local CELL_PX <const> = 28                      -- display size of one cell
local CANVAS_PX <const> = GRID_SIZE * CELL_PX   -- 448
local CANVAS_X <const> = (WINDOW_WIDTH - CANVAS_PX) / 2   -- 176
local CANVAS_Y <const> = 56                     -- leaves room for title + status above

local CANVAS_LAYER <const> = 1                  -- painted cells
local GRID_LAYER <const> = 2                    -- white grid lines
local HUD_LAYER <const> = 16                    -- text + palette swatches

local SAVE_PATH <const> = "paint.json"
local FONT <const> = "assets/press-start-2p.fnt"

local PALETTE <const>: {{number, number, number}} = {
    {0.10, 0.10, 0.12},   -- 1  near-black
    {0.95, 0.95, 0.95},   -- 2  white
    {0.92, 0.20, 0.25},   -- 3  red
    {0.55, 0.10, 0.12},   -- 4  dark red
    {1.00, 0.55, 0.20},   -- 5  orange
    {1.00, 0.85, 0.25},   -- 6  yellow
    {0.30, 0.85, 0.35},   -- 7  green
    {0.10, 0.50, 0.20},   -- 8  dark green
    {0.25, 0.80, 0.85},   -- 9  cyan
    {0.15, 0.45, 0.90},   -- 10 blue
    {0.10, 0.20, 0.55},   -- 11 navy
    {0.60, 0.30, 0.85},   -- 12 purple
    {0.95, 0.45, 0.85},   -- 13 pink
    {0.55, 0.35, 0.20},   -- 14 brown
    {0.55, 0.55, 0.55},   -- 15 gray
    {0.85, 0.85, 0.85},   -- 16 silver
}
local PALETTE_COUNT <const> = #PALETTE

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local record Cell is tecs.Component
    col: integer
    row: integer
    colorIdx: integer
    metamethod __call: function(self, col: integer, row: integer, colorIdx: integer): Cell
end
tecs.newComponent({
    name = "Cell",
    container = Cell,
    fields = {"col", "row", "colorIdx"},
})

-- HUD slots: their Text is setText'd each frame based on role.
local record HudSlot is tecs.Component
    role: string
    metamethod __call: function(self, role: string): HudSlot
end
tecs.newComponent({
    name = "HudSlot",
    container = HudSlot,
    fields = {"role"},
})

-- Palette swatch: carries its colour index, so the highlight system can find
-- "the currently-selected swatch" by matching `idx == currentColorIdx`.
local record Swatch is tecs.Component
    idx: integer
    metamethod __call: function(self, idx: integer): Swatch
end
tecs.newComponent({
    name = "Swatch",
    container = Swatch,
    fields = {"idx"},
})

-- Marker for the single outline entity that tracks the selected swatch.
local record SwatchCursor is tecs.Component
    metamethod __call: function(self): SwatchCursor
end
tecs.newTagComponent({
    name = "SwatchCursor",
    container = SwatchCursor,
})

-------------------------------------------------------------------------------
-- Undo stack
-------------------------------------------------------------------------------

local record UndoOp
    kind: string         -- "add", "remove", or "replace"
    col: integer
    row: integer
    colorIdx: integer    -- for "add" / "replace": the new colour; for "remove": what was erased
    previousColorIdx: integer  -- "replace" only: the colour that was overwritten
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local function cellKey(col: integer, row: integer): integer
    return row * GRID_SIZE + col
end

local function mouseToCell(): integer, integer
    local col = math.floor((input.mouseX - CANVAS_X) / CELL_PX)
    local row = math.floor((input.mouseY - CANVAS_Y) / CELL_PX)
    return col, row
end

local function inGrid(col: integer, row: integer): boolean
    return col >= 0 and col < GRID_SIZE and row >= 0 and row < GRID_SIZE
end

local function plugin(world: tecs.World)
    love.graphics.setBackgroundColor(0.06, 0.07, 0.10)
    world:addPlugin(mcp.new())

    local currentColorIdx = 3          -- start on red, feels friendlier than black
    local cellByPos: {integer: integer} = {}
    local undoStack: {UndoOp} = {}
    local status = "Click to paint. Click a swatch to pick a colour."
    -- Tracks the last cell touched during the current drag, so holding the
    -- mouse and sweeping across the canvas doesn't stamp the same cell over
    -- and over. Reset whenever a mouse button transitions up -> down.
    local lastPaintedKey = -1

    local cellQuery = world:query({
        name = "Cells",
        include = {Cell},
    })
    local hudQuery = world:query({
        name = "HudSlots",
        include = {HudSlot, gfx.Text},
    })
    local swatchQuery = world:query({
        name = "Swatches",
        include = {Swatch, Transform},
    })
    local cursorQuery = world:query({
        name = "SwatchCursors",
        include = {SwatchCursor, Transform},
    })

    ---------------------------------------------------------------------------
    -- Spawners
    ---------------------------------------------------------------------------

    local function spawnCell(col: integer, row: integer, colorIdx: integer): integer
        local c = PALETTE[colorIdx]
        local id = world:spawn(
            Transform.new({
                x = CANVAS_X + col * CELL_PX,
                y = CANVAS_Y + row * CELL_PX,
                layer = CANVAS_LAYER,
            }),
            gfx.Rectangle(CELL_PX, CELL_PX),
            gfx.Color(c[1], c[2], c[3], 1),
            gfx.Pivot(0, 0),
            Cell(col, row, colorIdx)
        )
        cellByPos[cellKey(col, row)] = id
        return id
    end

    local function spawnGridLines()
        -- One Line entity per grid line. 33 horizontal + 33 vertical = 66 entities.
        -- Semi-transparent white so painted cells show through.
        for i = 0, GRID_SIZE do
            local off = i * CELL_PX
            -- Vertical line
            world:spawn(
                Transform.new({x = CANVAS_X + off, y = CANVAS_Y, layer = GRID_LAYER}),
                gfx.Line(0, 0, 0, CANVAS_PX, 1.5),
                gfx.Color(1, 1, 1, 0.55)
            )
            -- Horizontal line
            world:spawn(
                Transform.new({x = CANVAS_X, y = CANVAS_Y + off, layer = GRID_LAYER}),
                gfx.Line(0, 0, CANVAS_PX, 0, 1.5),
                gfx.Color(1, 1, 1, 0.55)
            )
        end
    end

    local SWATCH_PX <const> = 22
    local SWATCH_GAP <const> = 4
    local SWATCH_Y <const> = CANVAS_Y + CANVAS_PX + 14

    local function spawnPalette()
        local totalWidth = PALETTE_COUNT * SWATCH_PX + (PALETTE_COUNT - 1) * SWATCH_GAP
        local startX = (WINDOW_WIDTH - totalWidth) / 2
        for i = 1, PALETTE_COUNT do
            local c = PALETTE[i]
            local x = startX + (i - 1) * (SWATCH_PX + SWATCH_GAP)
            -- Filled swatch
            world:spawn(
                Transform.new({x = x, y = SWATCH_Y, layer = HUD_LAYER}),
                gfx.Rectangle(SWATCH_PX, SWATCH_PX),
                gfx.Color(c[1], c[2], c[3], 1),
                gfx.Pivot(0, 0),
                Swatch(i)
            )
        end

        -- Single outlined rectangle that we reposition onto the selected
        -- swatch each frame. Rectangle's `lineWidth > 0` makes it outline-only,
        -- so the swatch fill beneath stays visible.
        local padding = 3
        world:spawn(
            Transform.new({x = startX - padding, y = SWATCH_Y - padding, layer = HUD_LAYER}),
            gfx.Rectangle(SWATCH_PX + padding * 2, SWATCH_PX + padding * 2, 3),
            gfx.Color(1, 1, 1, 1),
            gfx.Pivot(0, 0),
            SwatchCursor()
        )
    end

    local function spawnHud()
        world:spawn(
            Transform.new({x = 20, y = 8, layer = HUD_LAYER}),
            gfx.Text(FONT, "Tecs Paint", 1.2),
            gfx.Color(1, 1, 1, 1),
            gfx.Pivot(0, 0)
        )
        world:spawn(
            Transform.new({x = 20, y = 34, layer = HUD_LAYER}),
            gfx.Text(FONT, status, 0.9),
            gfx.Color(1, 1, 1, 0.9),
            gfx.Pivot(0, 0),
            HudSlot("status")
        )
        world:spawn(
            Transform.new({x = 20, y = SWATCH_Y + SWATCH_PX + 12, layer = HUD_LAYER}),
            gfx.Text(FONT, "LMB paint  RMB erase  S save  L load  U undo  C clear  Esc", 0.8),
            gfx.Color(0.75, 0.78, 0.85, 1),
            gfx.Pivot(0, 0)
        )
    end

    ---------------------------------------------------------------------------
    -- Paint actions
    ---------------------------------------------------------------------------

    local function paintAt(col: integer, row: integer)
        if not inGrid(col, row) then return end
        local key = cellKey(col, row)
        if key == lastPaintedKey then return end      -- dragging over the same cell
        lastPaintedKey = key

        local existing = cellByPos[key]
        if existing then
            local cell = world:get(existing, Cell)
            local prevIdx = cell and cell.colorIdx or 1
            if prevIdx == currentColorIdx then return end
            world:despawn(existing)
            cellByPos[key] = nil
            spawnCell(col, row, currentColorIdx)
            undoStack[#undoStack + 1] = {
                kind = "replace",
                col = col, row = row,
                colorIdx = currentColorIdx,
                previousColorIdx = prevIdx,
            }
        else
            spawnCell(col, row, currentColorIdx)
            undoStack[#undoStack + 1] = {
                kind = "add",
                col = col, row = row,
                colorIdx = currentColorIdx,
            }
        end
    end

    local function eraseAt(col: integer, row: integer)
        if not inGrid(col, row) then return end
        local key = cellKey(col, row)
        if key == lastPaintedKey then return end      -- dragging over the same cell
        lastPaintedKey = key
        local id = cellByPos[key]
        if not id then return end
        local cell = world:get(id, Cell)
        local colorIdx = cell and cell.colorIdx or 1
        world:despawn(id)
        cellByPos[key] = nil
        undoStack[#undoStack + 1] = {
            kind = "remove",
            col = col, row = row,
            colorIdx = colorIdx,
        }
    end

    local function undo()
        local op = undoStack[#undoStack]
        if not op then
            status = "Nothing to undo."
            return
        end
        undoStack[#undoStack] = nil
        if op.kind == "add" then
            local id = cellByPos[cellKey(op.col, op.row)]
            if id then
                world:despawn(id)
                cellByPos[cellKey(op.col, op.row)] = nil
            end
            status = string.format("Undo: removed (%d, %d).", op.col, op.row)
        elseif op.kind == "replace" then
            -- Revert to the previous colour.
            local id = cellByPos[cellKey(op.col, op.row)]
            if id then
                world:despawn(id)
                cellByPos[cellKey(op.col, op.row)] = nil
            end
            spawnCell(op.col, op.row, op.previousColorIdx)
            status = string.format("Undo: reverted (%d, %d).", op.col, op.row)
        else
            spawnCell(op.col, op.row, op.colorIdx)
            status = string.format("Undo: restored (%d, %d).", op.col, op.row)
        end
    end

    local function rebuildIndex()
        cellByPos = {}
        for archetype, len in cellQuery:iter() do
            local entities = archetype.entities as {integer}
            local cells = archetype:get(Cell) as {Cell}
            for i = 1, len do
                cellByPos[cellKey(cells[i].col, cells[i].row)] = entities[i]
            end
        end
    end

    local function countCells(): integer
        local n = 0
        for _, len in cellQuery:iter() do n = n + len end
        return n
    end

    ---------------------------------------------------------------------------
    -- Save / load
    ---------------------------------------------------------------------------

    local function eraseAll()
        local ids: {integer} = {}
        for archetype, len in cellQuery:iter() do
            local entities = archetype.entities as {integer}
            for i = 1, len do
                ids[#ids + 1] = entities[i]
            end
        end
        for i = 1, #ids do world:despawn(ids[i]) end
        cellByPos = {}
        undoStack = {}
        lastPaintedKey = -1
        status = string.format("Erased %d cells.", #ids)
        LOGGER:info("erased %d cells", #ids)
    end

    local function saveCanvas()
        local snap = world:saveSnapshot({
            format = "table",
            filterQuery = {include = {Cell}},
        }).snapshot as tecs.Snapshot
        local payload = json.serializePretty(snap as {string: any}, true)
        local ok, err = love.filesystem.write(SAVE_PATH, payload)
        local cellCount = 0
        for i = 1, #snap.archetypes do
            cellCount = cellCount + #(snap.archetypes[i].entities as {any})
        end
        if ok then
            status = string.format("Saved %d cells.", cellCount)
            LOGGER:info("saved %d cells (%d bytes) to %s/%s",
                cellCount, #payload,
                love.filesystem.getSaveDirectory(), SAVE_PATH)
        else
            status = "Save failed: " .. tostring(err)
            LOGGER:error("save failed: %s", err)
        end
    end

    local function loadCanvas()
        if not love.filesystem.getInfo(SAVE_PATH) then
            status = "No save file (" .. SAVE_PATH .. "). Paint something and press S."
            LOGGER:warn("load: file not found at %s/%s",
                love.filesystem.getSaveDirectory(), SAVE_PATH)
            return
        end
        local payload = love.filesystem.read(SAVE_PATH)
        if not payload then
            status = "Could not read " .. SAVE_PATH
            return
        end
        local snap = json.parse(payload) as tecs.Snapshot
        LOGGER:info("loading %d cells (%d bytes, version=%s, nextId=%s)",
            ((function(): integer
                local n = 0
                for i = 1, #snap.archetypes do
                    n = n + #(snap.archetypes[i].entities as {any})
                end
                return n
            end)()), #payload,
            tostring(snap.version), tostring(snap.nextEntityId))

        world:loadSnapshot(snap)
        -- loadSnapshot wiped everything (HUD / grid / palette too). Rebuild them.
        spawnGridLines()
        spawnPalette()
        spawnHud()
        undoStack = {}
        lastPaintedKey = -1
        rebuildIndex()
        status = string.format("Loaded %d cells.", countCells())
        LOGGER:info("loaded %d cells", countCells())
    end

    ---------------------------------------------------------------------------
    -- Scene setup
    ---------------------------------------------------------------------------

    spawnGridLines()
    spawnPalette()
    spawnHud()

    ---------------------------------------------------------------------------
    -- Systems
    ---------------------------------------------------------------------------

    -- Return the swatch index at (mx, my), or nil if the mouse isn't over one.
    local function swatchAt(mx: number, my: number): integer
        local picked: integer
        for archetype, len in swatchQuery:iter() do
            local swatches = archetype:get(Swatch) as {Swatch}
            local transforms = archetype:get(Transform) as {Transform}
            for i = 1, len do
                local t = transforms[i]
                if not picked
                        and mx >= t.x and mx < t.x + SWATCH_PX
                        and my >= t.y and my < t.y + SWATCH_PX then
                    picked = swatches[i].idx
                end
            end
        end
        return picked
    end

    -- Mouse painting: press + drag both work. `paintAt` / `eraseAt` skip the
    -- cell that was just painted, so drag never stamps the same cell twice.
    -- Clicking a palette swatch selects that colour.
    world:addSystem({
        name = "PaintInput",
        phase = tecs.phases.Update,
        run = function()
            -- A fresh button press starts a new drag session.
            if input.isMousePressed(1) or input.isMousePressed(2) then
                lastPaintedKey = -1
            end
            if input.isMousePressed(1) then
                local picked = swatchAt(input.mouseX, input.mouseY)
                if picked then
                    currentColorIdx = picked
                    return
                end
            end
            if input.isMouseDown(1) then
                local col, row = mouseToCell()
                paintAt(col, row)
            end
            if input.isMouseDown(2) then
                local col, row = mouseToCell()
                eraseAt(col, row)
            end
        end,
    })

    world:addSystem({
        name = "KeyboardInput",
        phase = tecs.phases.First,
        run = function()
            if input.isKeyPressed("u") then
                undo()
            elseif input.isKeyPressed("c") then
                eraseAll()
            elseif input.isKeyPressed("s") then
                saveCanvas()
            elseif input.isKeyPressed("l") then
                loadCanvas()
            end
        end,
    })

    -- Move the selection cursor onto the currently-selected swatch.
    world:addSystem({
        name = "SwatchHighlight",
        phase = tecs.phases.PostUpdate,
        run = function()
            -- Find the Transform of the selected swatch.
            local targetX, targetY: number, number
            for archetype, len in swatchQuery:iter() do
                local swatches = archetype:get(Swatch) as {Swatch}
                local transforms = archetype:get(Transform) as {Transform}
                for i = 1, len do
                    if not targetX and swatches[i].idx == currentColorIdx then
                        targetX, targetY = transforms[i].x, transforms[i].y
                    end
                end
            end
            if not targetX then return end

            local padding = 3
            for archetype, len in cursorQuery:iter() do
                local transforms = archetype:getMut(Transform) as {Transform}
                for i = 1, len do
                    transforms[i].x = targetX - padding
                    transforms[i].y = targetY - padding
                end
            end
        end,
    })

    -- Keep the status text current.
    world:addSystem({
        name = "HudSync",
        phase = tecs.phases.PostUpdate,
        run = function()
            for archetype, len in hudQuery:iter() do
                local slots = archetype:get(HudSlot) as {HudSlot}
                local texts = archetype:getMut(gfx.Text) as {gfx.Text}
                for i = 1, len do
                    if slots[i].role == "status" then
                        texts[i]:setText(status)
                    end
                end
            end
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = plugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2},
        layers = {
            [CANVAS_LAYER] = {name = "canvas",  space = "virtual"},
            [GRID_LAYER]   = {name = "grid",    space = "virtual"},
            [HUD_LAYER]    = {name = "hud",     space = "virtual"},
        },
    },
})

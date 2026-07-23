--- Reusable popup state for debugger UI surfaces.
---
--- Popup presentation is configured per show() call: title, modality,
--- optional close control, typed or legacy content, syntax mode, semantic
--- column blocks, and column cap. The overlay owns placement/rendering, while
--- this component owns the document lifecycle, scrolling bounds, hit geometry,
--- and image lifetime.

local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local markup <const> = require("tecs2d.debug.internal.markup")

local record PopupBlock
    lines: {string}
    documentLines: {markup.Line}
    rows: {{string}}
    colX: {number}
    width: number
end

local record Popup
    type Block = PopupBlock
    record Options
        lines: {string}
        title: string
        modal: boolean
        closable: boolean
        language: string
        blocks: {{string}}
        imagePath: string
        maxColumns: integer
        scrollToEnd: boolean
        document: markup.Document
    end

    lines: {string}
    title: string
    language: string
    semanticBlocks: {{string}}
    document: markup.Document
    shown: boolean
    modal: boolean
    closable: boolean
    maxColumns: integer
    scroll: number
    scrollMax: number
    scrollToEndPending: boolean
    image: love.graphics.Image
    measuredLines: {string}
    measuredBlocks: {{string}}
    measuredDocument: markup.Document
    measuredSw: number
    block: PopupBlock
    columns: {PopupBlock}
    columnWidth: number
    columnGap: number
    panelX: number
    panelY: number
    panelW: number
    panelH: number
    visibleRows: integer
    closeX: number
    closeY: number
    closeRadius: number

    --- Overlay-owned caches live with the surface rather than in the shared
    --- DebugContext. They do not affect popup behavior.
    lastCommandLine: string
    previewCmd: cmdtypes.Command
    previewFor: cmdtypes.Command
    previewDocument: markup.Document
    cmdRowsText: string
    cmdRowsSw: number
    cmdRows: {string}
    barCompletions: {string}
    barLabels: {string}
    barWidths: {number}
    barScroll: number
    barScrollForIndex: integer
    barTop: number
    barBottom: number
    barHitValue: {integer}
    barHitX: {number}
    barHitY: {number}
    barHitW: {number}
    barHitH: {number}
    barHitCount: integer

    new: function(): Popup
    show: function(self, options: Options)
    dismiss: function(self)
    contains: function(self, x: number, y: number): boolean
    pressClose: function(self, x: number, y: number): boolean
end

local MT <const>: metatable<Popup> = {__index = Popup}

function Popup.new(): Popup
    return setmetatable({
        lines = {},
        shown = false,
        modal = false,
        closable = false,
        maxColumns = 0,
        scroll = 0,
        scrollMax = 0,
        scrollToEndPending = false,
        panelX = 0,
        panelY = 0,
        panelW = 0,
        panelH = 0,
        visibleRows = 1,
        closeX = 0,
        closeY = 0,
        closeRadius = 0,
        barTop = 0,
        barBottom = 0,
    } as Popup, MT)
end

local function releaseImage(self: Popup)
    if not self.image then return end
    (self.image as love.Object):release()
    self.image = nil
end

function Popup:show(options: Popup.Options)
    releaseImage(self)
    self.lines = options.lines or {}
    self.title = options.title
    self.language = options.language
    self.semanticBlocks = options.blocks
    self.document = options.document
    self.shown = true
    self.modal = options.modal or false
    self.closable = options.closable or false
    self.maxColumns = options.maxColumns or 0
    self.scroll = 0
    self.scrollMax = 0
    self.scrollToEndPending = options.scrollToEnd or false
    self.measuredLines = nil
    self.measuredBlocks = nil
    self.measuredDocument = nil
    self.closeRadius = 0
    if options.imagePath then
        local ok, image = pcall(love.graphics.newImage, options.imagePath)
        if ok then self.image = image as love.graphics.Image end
    end
end

function Popup:dismiss()
    self.shown = false
    self.modal = false
    self.closable = false
    self.measuredLines = nil
    self.measuredDocument = nil
    self.closeRadius = 0
    releaseImage(self)
end

function Popup:contains(x: number, y: number): boolean
    return self.shown and x >= self.panelX and x <= self.panelX + self.panelW
        and y >= self.panelY and y <= self.panelY + self.panelH
end

function Popup:pressClose(x: number, y: number): boolean
    if not self.shown or not self.closable or self.closeRadius <= 0 then
        return false
    end
    local dx, dy = x - self.closeX, y - self.closeY
    if dx * dx + dy * dy > self.closeRadius * self.closeRadius then
        return false
    end
    self:dismiss()
    return true
end

return Popup

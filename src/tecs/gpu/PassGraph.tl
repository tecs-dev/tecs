--- A declarative graph of render passes over shared targets.
---
--- Passes name the targets they read and write; the graph owns those targets,
--- resizes them with the frame, begins and ends each pass, and binds each
--- pass's inputs as fragment samplers. What a pass body does is draw.
---
--- Execution follows declaration order rather than a topological sort. The
--- order of a deferred pipeline is a design decision, not something worth
--- rediscovering every frame, and a graph that silently reorders passes is
--- harder to reason about than one that refuses to run. Declared inputs are
--- validated against what earlier passes produce, so a missing dependency is
--- an error at build time instead of a black screen.
---
--- One depth attachment is shared by whichever passes ask for it, sized and
--- resized with the frame like every other target. Depth is per pass rather
--- than per graph because a pass that must not have one is as ordinary as a
--- pass that must, and a pipeline bound in either has to agree with it.
---
--- The graph knows nothing about entities, archetypes, or dirtiness. A pass
--- that should be skipped says so through `enabled`, which is where an
--- ECS-side dirty gate plugs in without the graph learning what dirty means.

local loader <const> = require("tecs.ffi.loader")
local Texture <const> = require("tecs.gpu.Texture")
local Sampler <const> = require("tecs.gpu.Sampler")
local RenderPass <const> = require("tecs.gpu.RenderPass")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")

--- Default colour format for intermediate targets. Eight bits per channel is
--- enough for albedo and composited output; targets holding normals or
--- lighting values ask for a wider format explicitly.
local DEFAULT_FORMAT <const> = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM

local record TargetSpec
    name: string
    --- Defaults to R8G8B8A8_UNORM.
    format: integer
    --- Size relative to the frame. 0.5 halves each axis, as a bloom or
    --- occlusion target would.
    scale: number
    --- Clear colour applied when a pass writes this target. Omitted targets
    --- load their previous contents.
    clear: RenderPass.ClearColor
end

local record PassContext
    --- The begun render pass, with outputs attached and inputs bound.
    pass: RenderPass
    frame: Frame
    commandBuffer: loader.CValue
    --- Size of this pass's targets in pixels.
    width: integer
    height: integer
end

--- How one pass uses the graph's depth attachment.
---
--- Declared per pass rather than per graph, because whether depth is attached
--- at all differs between passes: geometry needs it and a fullscreen resolve
--- covering every pixel once has nothing to be occluded by.
local record DepthState
    --- Tests each fragment against the attachment. Defaults to true; false
    --- attaches depth without letting it reject anything.
    test: boolean
    --- Writes surviving fragments' depth back. Defaults to true, and has no
    --- effect while `test` is false.
    write: boolean
    --- "never", "less", "equal", "lessOrEqual", "greater", "notEqual",
    --- "greaterOrEqual", or "always". Defaults to "lessOrEqual", which keeps
    --- draw order deciding ties: equal depths let the later fragment through,
    --- so what a pass draws last is still what is seen.
    compare: string
    --- Value the attachment is cleared to when the pass begins. Omit to load
    --- what is already there. One is the far plane.
    clear: number
end

local record PassSpec
    name: string
    --- Targets sampled by this pass, bound to fragment slots in this order.
    inputs: {string}
    --- Targets written by this pass. Empty or omitted renders to the
    --- swapchain, which is how the final composite reaches the screen.
    outputs: {string}
    --- How this pass uses depth. Omit for a pass with no depth attachment.
    depth: DepthState
    --- Consulted each frame. Returning false skips the pass entirely,
    --- including beginning it. This is the dirty gate.
    enabled: function(): boolean
    execute: function(context: PassContext)
end

local record PassGraph
    TargetSpec: TargetSpec
    PassSpec: PassSpec
    PassContext: PassContext
    DepthState: DepthState

    device: loader.CPtr
    --- Format the swapchain expects, for passes that render to it.
    swapchainFormat: integer
    --- Depth format this device supports, discovered at creation. The graph
    --- owns one depth attachment in this format, shared by every pass that
    --- declares depth.
    depthFormat: integer
    _targets: {string: TargetSpec}
    _textures: {string: Texture}
    _order: {string}
    _passes: {PassSpec}
    _sampler: Sampler
    _depth: Texture
    _depthAttachment: RenderPass.DepthAttachment
    _needsDepth: boolean
    _width: integer
    _height: integer
    _built: boolean
    _destroyed: boolean
end

local PassGraphMT <const>: metatable<PassGraph> = { __index = PassGraph }

--- Creates an empty graph.
function PassGraph.create(device: loader.CPtr, swapchainFormat: integer): PassGraph
    local self = setmetatable({} as PassGraph, PassGraphMT)
    self.device = device
    self.swapchainFormat = swapchainFormat
    self._targets = {}
    self._textures = {}
    self._order = {}
    self._passes = {}
    self._sampler = Sampler.create(device, { filter = "nearest", address = "clamp" })
    self.depthFormat = Texture.depthFormat(device)
    self._needsDepth = false
    -- Reused rather than rebuilt per pass per frame; only its texture and clear
    -- value ever differ, and both are known when the pass runs.
    self._depthAttachment = { texture = nil, clear = nil }
    self._width = 0
    self._height = 0
    self._built = false
    self._destroyed = false
    return self
end

--- Declares a target the graph owns.
function PassGraph:target(spec: TargetSpec): PassGraph
    if self._targets[spec.name] ~= nil then
        error(("tecs: target '%s' is already declared"):format(spec.name), 2)
    end
    spec.format = spec.format or DEFAULT_FORMAT
    spec.scale = spec.scale or 1.0
    self._targets[spec.name] = spec
    self._order[#self._order + 1] = spec.name
    return self
end

--- Declares a pass. Passes run in the order they are declared.
function PassGraph:pass(spec: PassSpec): PassGraph
    -- Validate against what earlier passes have produced, so an ordering
    -- mistake surfaces here rather than as an empty or stale attachment.
    local produced: {string: boolean} = {}
    for _, earlier in ipairs(self._passes) do
        for _, output in ipairs(earlier.outputs or {}) do
            produced[output] = true
        end
    end

    for _, input in ipairs(spec.inputs or {}) do
        if self._targets[input] == nil then
            error(("tecs: pass '%s' reads undeclared target '%s'")
                :format(spec.name, input), 2)
        end
        if not produced[input] then
            error(("tecs: pass '%s' reads '%s' before any pass writes it")
                :format(spec.name, input), 2)
        end
    end

    for _, output in ipairs(spec.outputs or {}) do
        if self._targets[output] == nil then
            error(("tecs: pass '%s' writes undeclared target '%s'")
                :format(spec.name, output), 2)
        end
    end

    if spec.depth ~= nil then
        -- One depth attachment at frame size serves every depth pass, so a
        -- pass drawing into a scaled target cannot share it. SDL would reject
        -- the mismatch when the pass began; saying so here names the pass.
        for _, output in ipairs(spec.outputs or {}) do
            local scale = self._targets[output].scale
            if scale ~= 1.0 then
                error(("tecs: pass '%s' uses depth but writes '%s' at scale " ..
                    "%s, and the depth attachment is frame sized")
                    :format(spec.name, output, tostring(scale)), 2)
            end
        end
        self._needsDepth = true
    end

    self._passes[#self._passes + 1] = spec
    return self
end

--- Returns the texture backing a target, or nil before the first execute.
function PassGraph:texture(name: string): Texture
    return self._textures[name]
end

--- Returns the format a pipeline writing `name` must be created against.
---
--- Pipelines bake their target formats, so this is how a pass's pipeline stays
--- in step with the target the graph allocated for it.
function PassGraph:formatOf(name: string): integer
    local spec = self._targets[name]
    if spec == nil then
        error(("tecs: no target named '%s'"):format(tostring(name)), 2)
    end
    return spec.format
end

--- Depth state a pipeline drawing in `passName` must bake, or nil when that
--- pass has no depth attachment.
---
--- The depth counterpart to `formatOf`, and it answers both cases rather than
--- assuming one. A pipeline's target info has to match the pass it is bound in
--- exactly, so "no depth target" is as much a thing to get right as a format
--- is, and both come from the pass's own declaration instead of being restated
--- where the pipeline is built.
---
--- The defaults are the pipeline's: an omitted `test`, `write`, or `compare`
--- means the same here as it does there.
function PassGraph:depthOf(passName: string): GraphicsPipeline.DepthConfig
    for _, spec in ipairs(self._passes) do
        if spec.name == passName then
            local state = spec.depth
            if state == nil then return nil end
            return {
                format = self.depthFormat,
                test = state.test,
                write = state.write,
                compare = state.compare,
            }
        end
    end
    error(("tecs: no pass named '%s'"):format(tostring(passName)), 2)
end

--- Allocates or reallocates targets for a frame size.
local function resize(self: PassGraph, width: integer, height: integer)
    if self._width ~= width or self._height ~= height then
        for _, name in ipairs(self._order) do
            -- Dropped before the replacement is built rather than after, so a
            -- creation that fails leaves the name empty instead of leaving it
            -- pointing at a texture that has already been released.
            local existing = self._textures[name]
            if existing ~= nil then
                self._textures[name] = nil
                existing:destroy()
            end

            local spec = self._targets[name]
            local scaledWidth = math.max(1, math.floor(width * spec.scale))
            local scaledHeight = math.max(1, math.floor(height * spec.scale))
            self._textures[name] = Texture.create(self.device, {
                width = scaledWidth,
                height = scaledHeight,
                format = spec.format,
                usage = { "colorTarget", "sampled" },
                name = name,
            })
        end

        if self._depth ~= nil then
            self._depth:destroy()
            self._depth = nil
        end

        self._width = width
        self._height = height
    end

    -- Frame sized, so it matches the unscaled targets a depth pass writes, and
    -- allocated only once a pass has declared depth: a graph that never tests
    -- it should not pay four bytes a pixel for an attachment nothing reads.
    -- Gated on the attachment rather than on the frame size, because a pass may
    -- be declared after the graph has already run a frame.
    if self._needsDepth and self._depth == nil then
        self._depth = Texture.create(self.device, {
            width = width,
            height = height,
            format = self.depthFormat,
            usage = { "depthTarget" },
            name = "depth",
        })
    end
end

--- Runs every enabled pass against `frame`.
---
--- A pass body that throws takes the whole frame with it, and the pass it was
--- inside is left open. Nothing here catches that: the pass is on the frame's
--- open list from the moment it began, and `Frame:abandon` is what ends it, so
--- recovery happens once where the frame is resolved rather than once per pass.
function PassGraph:execute(frame: Frame)
    local frameWidth = frame.width
    local frameHeight = frame.height
    resize(self, frameWidth, frameHeight)

    for _, spec in ipairs(self._passes) do
        local enabled = spec.enabled == nil or spec.enabled()
        if enabled then
            local outputs = spec.outputs or {}
            local attachments: {RenderPass.Attachment} = {}
            local width, height = frameWidth, frameHeight

            if #outputs == 0 then
                attachments[1] = {
                    texture = frame.swapchainTexture,
                    clear = nil,
                }
            else
                for index, name in ipairs(outputs) do
                    local texture = self._textures[name]
                    attachments[index] = {
                        texture = texture.handle,
                        clear = self._targets[name].clear,
                    }
                    width, height = texture.width, texture.height
                end
            end

            local depth: RenderPass.DepthAttachment = nil
            if spec.depth ~= nil then
                depth = self._depthAttachment
                depth.texture = self._depth.handle
                depth.clear = spec.depth.clear
            end

            local pass = RenderPass.begin(frame.commandBuffer, attachments,
                depth)

            local inputs = spec.inputs or {}
            if #inputs > 0 then
                local textures: {loader.CValue} = {}
                for index, name in ipairs(inputs) do
                    textures[index] = self._textures[name].handle
                end
                pass:bindTextures(0, textures, self._sampler.handle)
            end

            spec.execute({
                pass = pass,
                frame = frame,
                commandBuffer = frame.commandBuffer,
                width = width,
                height = height,
            })

            pass:finish()
        end
    end
end

--- Releases every target the graph owns. Safe to call more than once.
function PassGraph:destroy()
    if self._destroyed then return end
    self._destroyed = true
    for _, texture in pairs(self._textures) do
        texture:destroy()
    end
    self._textures = {}
    if self._depth ~= nil then
        self._depth:destroy()
        self._depth = nil
    end
    self._sampler:destroy()
end

return PassGraph

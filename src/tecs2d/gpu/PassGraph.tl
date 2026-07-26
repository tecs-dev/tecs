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
--- The graph knows nothing about entities, archetypes, or dirtiness. A pass
--- that should be skipped says so through `enabled`, which is where an
--- ECS-side dirty gate plugs in without the graph learning what dirty means.

local loader <const> = require("tecs2d.ffi.loader")
local Texture <const> = require("tecs2d.gpu.Texture")
local Sampler <const> = require("tecs2d.gpu.Sampler")
local RenderPass <const> = require("tecs2d.gpu.RenderPass")
local Frame <const> = require("tecs2d.gpu.Frame")

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

local record PassSpec
    name: string
    --- Targets sampled by this pass, bound to fragment slots in this order.
    inputs: {string}
    --- Targets written by this pass. Empty or omitted renders to the
    --- swapchain, which is how the final composite reaches the screen.
    outputs: {string}
    --- Consulted each frame. Returning false skips the pass entirely,
    --- including beginning it. This is the dirty gate.
    enabled: function(): boolean
    execute: function(context: PassContext)
end

local record PassGraph
    TargetSpec: TargetSpec
    PassSpec: PassSpec
    PassContext: PassContext

    device: loader.CPtr
    --- Format the swapchain expects, for passes that render to it.
    swapchainFormat: integer
    _targets: {string: TargetSpec}
    _textures: {string: Texture}
    _order: {string}
    _passes: {PassSpec}
    _sampler: Sampler
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
    self._width = 0
    self._height = 0
    self._built = false
    self._destroyed = false
    return self
end

--- Declares a target the graph owns.
function PassGraph:target(spec: TargetSpec): PassGraph
    if self._targets[spec.name] ~= nil then
        error(("tecs2d: target '%s' is already declared"):format(spec.name), 2)
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
            error(("tecs2d: pass '%s' reads undeclared target '%s'")
                :format(spec.name, input), 2)
        end
        if not produced[input] then
            error(("tecs2d: pass '%s' reads '%s' before any pass writes it")
                :format(spec.name, input), 2)
        end
    end

    for _, output in ipairs(spec.outputs or {}) do
        if self._targets[output] == nil then
            error(("tecs2d: pass '%s' writes undeclared target '%s'")
                :format(spec.name, output), 2)
        end
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
        error(("tecs2d: no target named '%s'"):format(tostring(name)), 2)
    end
    return spec.format
end

--- Allocates or reallocates targets for a frame size.
local function resize(self: PassGraph, width: integer, height: integer)
    if self._width == width and self._height == height then return end

    for _, name in ipairs(self._order) do
        local existing = self._textures[name]
        if existing ~= nil then existing:destroy() end

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

    self._width = width
    self._height = height
end

--- Runs every enabled pass against `frame`.
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

            local pass = RenderPass.begin(frame.commandBuffer, attachments)

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
    self._sampler:destroy()
end

return PassGraph

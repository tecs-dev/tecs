--[=[
A declarative graph of render passes over shared targets.

Passes name the targets they read and write; the graph owns those targets,
resizes them with the frame, begins and ends each pass, and binds each
pass's inputs as fragment samplers. What a pass body does is draw.

Execution follows declaration order rather than a topological sort. The
order of a deferred pipeline is a design decision, not something worth
rediscovering every frame, and a graph that silently reorders passes is
harder to reason about than one that refuses to run. Declared inputs are
validated against what earlier passes produce, so a missing dependency is
an error at build time instead of a black screen.

One depth attachment is shared by whichever passes ask for it, sized and
resized with the frame like every other target. A later pass may name the
reserved `depth` input to sample what an earlier depth-writing pass produced.
Depth is per pass rather than per graph because a pass that must not have one
is as ordinary as a pass that must, and a pipeline bound in either has to agree
with it.

A color clear comes from the target, which is right while one pass writes
a target and wrong as soon as two do: the second would clear the first
one's result away. A pass may therefore override it, with `PassGraph.LOAD`
as the way to say "load, whatever the target asks for". That is what any
pass accumulating into a target an earlier pass filled needs, and what a
second view's composite needs to leave the first view's pixels alone.

The graph knows nothing about entities, archetypes, or dirtiness. A pass
that should be skipped says so through `enabled`, which is where an
ECS-side dirty gate plugs in without the graph learning what dirty means.
]=]

local loader <const> = require("tecs.ffi.loader")
local Texture <const> = require("tecs.gpu.Texture")
local Sampler <const> = require("tecs.gpu.Sampler")
local RenderPass <const> = require("tecs.gpu.RenderPass")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")

--- Default color format for intermediate targets. Eight bits per channel is
--- enough for albedo and composited output; targets holding normals or
--- lighting values ask for a wider format explicitly.
local DEFAULT_FORMAT <const> = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM

--- The clear a pass asks for when what it wants is not to clear at all.
---
--- A sentinel rather than a color, matched by identity, because the field it
--- goes in already uses nil for "the target decides" and a pass overriding a
--- target that clears needs a third answer. Its contents are never read.
local LOAD <const>: RenderPass.ClearColor = {r = 0, g = 0, b = 0, a = 0}

--- A target the graph allocates, sizes with the frame, and owns.
---
--- The spec is kept rather than copied, and `target` fills its defaults in
--- place, so a caller must not reuse one table for two targets.
local record TargetSpec
    --- Names the target for `inputs`, `outputs`, `texture` and `formatOf`.
    --- Unique within a graph; a second declaration under the same name raises.
    name: string
    --- Defaults to R8G8B8A8_UNORM.
    format: integer
    --- Size relative to the frame. 0.5 halves each axis, as a bloom or
    --- occlusion target would.
    scale: number
    --- Clear color applied when a pass writes this target. Omitted targets
    --- load their previous contents.
    clear: RenderPass.ClearColor
end

--- What a pass body is handed when the graph runs it.
---
--- The graph's own object, rewritten before every pass and valid only for the
--- duration of the `execute` call it arrived in. Nothing may keep one.
local record PassContext
    --- The begun render pass, with outputs attached and inputs bound.
    pass: RenderPass
    --- The frame being recorded, for a body that needs the swapchain texture
    --- or the frame's own size rather than this pass's.
    frame: Frame
    --- The frame's command buffer, which is where uniform pushes go.
    commandBuffer: loader.CValue
    --- Size of this pass's targets in pixels.
    width: integer
    --- Height of this pass's targets in pixels. A scaled target makes these
    --- smaller than the frame's, so a fullscreen draw uses these and not the
    --- frame's.
    height: integer
end

--- What a declared pass needs per frame, allocated once when it is declared.
---
--- Every field is rewritten before the pass runs and read only while it does,
--- so the graph builds none of it per frame. The consequence is that a pass
--- body may not hold on to what it was handed: the context it received, and
--- the pass inside it, describe the next frame's pass by the time that frame
--- runs.
local record Prepared
    --- Color attachments, one record per output, or one for the swapchain.
    attachments: {RenderPass.Attachment}
    --- Fragment sampler bindings, or nil for a pass that reads nothing.
    textures: {loader.CValue}
    --- Handed to `execute`.
    context: PassContext
    --- The pass object, begun again each frame. Nil until the first one.
    pass: RenderPass
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
    --- One of `GraphicsPipeline.COMPARE_*`. Defaults to
    --- `GraphicsPipeline.COMPARE_LESS_OR_EQUAL`, which keeps
    --- draw order deciding ties: equal depths let the later fragment through,
    --- so what a pass draws last is still what is seen.
    compare: integer
    --- Value the attachment is cleared to when the pass begins. Omit to load
    --- what is already there. One is the far plane.
    clear: number
end

--- One render pass, as it is declared on the graph.
---
--- Held rather than copied, so the spec a caller passed in is what the graph
--- reads every frame; assigning to `enabled` after declaring the pass takes
--- effect on the next frame.
local record PassSpec
    --- Names the pass for `depthOf` and for the errors validation raises.
    name: string
    --- Targets sampled by this pass, bound to fragment slots in this order.
    inputs: {string}
    --- Targets written by this pass. Empty or omitted renders to the
    --- swapchain, which is how the final composite reaches the screen.
    outputs: {string}
    --- How this pass uses depth. Omit for a pass with no depth attachment.
    depth: DepthState
    --- Color clear for every output this pass writes, winning over what the
    --- targets themselves declare. `PassGraph.LOAD` loads instead of clearing,
    --- which is what a pass writing a target a previous pass already filled
    --- asks for. Omit to take each target's own clear.
    clear: RenderPass.ClearColor
    --- Consulted each frame. Returning false skips the pass entirely,
    --- including beginning it. This is the dirty gate.
    enabled: function(): boolean
    --- Draws the pass. Called with the pass already begun and finished for it,
    --- so a body only records draws. Throwing takes the frame with it and
    --- leaves the pass open for `Frame:abandon` to close.
    execute: function(context: PassContext)
end

--- A graph of render passes and the targets they share.
---
--- Built by declaring targets with `target` and passes with `pass`, both of
--- which validate as they go, then run once per frame with `execute`. The
--- graph owns every target it declared and releases them in `destroy`; the
--- swapchain texture is the frame's and is only ever written, never sampled.
local record PassGraph
    --- What `target` takes.
    TargetSpec: TargetSpec
    --- What `pass` takes.
    PassSpec: PassSpec
    --- What a pass's `execute` receives.
    PassContext: PassContext
    --- How one pass uses the shared depth attachment.
    DepthState: DepthState

    --- `PassSpec.clear` value meaning "load this target rather than clear it",
    --- whatever the target's own spec says.
    LOAD: RenderPass.ClearColor

    --- The `SDL_GPUDevice` every target and the shared sampler were created
    --- against, as `create` was given it.
    device: loader.CPtr
    --- Format the swapchain expects, for passes that render to it.
    swapchainFormat: integer
    --- Depth format this device supports, discovered at creation. The graph
    --- owns one depth attachment in this format, shared by every pass that
    --- declares depth.
    depthFormat: integer
    --- Declared targets by name, holding the caller's spec with its defaults
    --- filled in.
    _targets: {string: TargetSpec}
    --- The texture allocated for each target, empty until the first `execute`
    --- sizes the graph and replaced whenever the frame size changes.
    _textures: {string: Texture}
    --- Target names in declaration order, which is the order `resize` walks so
    --- that reallocation is deterministic.
    _order: {string}
    --- Declared passes in execution order.
    _passes: {PassSpec}
    --- Per-frame storage for the pass at the same index in `_passes`.
    _prepared: {Prepared}
    --- The one sampler every pass's inputs are bound through: nearest, clamped,
    --- since a graph target is read at the resolution it was written.
    _sampler: Sampler
    --- The shared depth attachment at frame size, or nil while no declared pass
    --- asks for depth.
    _depth: Texture
    --- The attachment record handed to `RenderPass.begin`, rewritten per pass
    --- rather than rebuilt.
    _depthAttachment: RenderPass.DepthAttachment
    --- True once any declared pass asks for depth, which is what makes `resize`
    --- allocate the attachment.
    _needsDepth: boolean
    --- Frame width the targets were last allocated for; zero before the first
    --- `execute`.
    _width: integer
    --- Frame height the targets were last allocated for. A change in either
    --- reallocates every target.
    _height: integer
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local PassGraphMT <const>: metatable<PassGraph> = {__index = PassGraph}

PassGraph.LOAD = LOAD

--- Creates an empty graph.
---
--- Allocates the shared sampler and asks the device which depth format it
--- supports. No target exists yet: the first `execute` is what sizes them, so
--- the frame's dimensions never have to be guessed here.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param swapchainFormat Format a pass with no outputs renders into, from
---     `Device:getSwapchainFormat`.
function PassGraph.create(device: loader.CPtr, swapchainFormat: integer): PassGraph
    local self = setmetatable({} as PassGraph, PassGraphMT)
    self.device = device
    self.swapchainFormat = swapchainFormat
    self._targets = {}
    self._textures = {}
    self._order = {}
    self._passes = {}
    self._prepared = {}
    self._sampler = Sampler.create(device, {})
    self.depthFormat = Texture.depthFormat(device)
    self._needsDepth = false
    -- Reused rather than rebuilt per pass per frame; only its texture and clear
    -- value ever differ, and both are known when the pass runs.
    self._depthAttachment = {texture = nil, clear = nil}
    self._width = 0
    self._height = 0
    self._destroyed = false
    return self
end

--- Declares a target the graph owns.
---
--- Raises on a name already declared. Nothing is allocated here; the texture
--- appears on the first `execute`.
--- @param spec Retained and filled in with its defaults, so it must not be
---     reused for a second target.
--- @return The graph, so declarations chain.
function PassGraph:target(spec: TargetSpec): PassGraph
    if spec.name == "depth" then
        error("tecs: target name 'depth' is reserved for the shared depth attachment", 2)
    end
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
---
--- Raises when an input is undeclared or is not written by an earlier pass,
--- when an output is undeclared, or when a pass asking for depth writes a
--- target at any scale other than one. A pass may be declared after the graph
--- has already run frames; the depth attachment is allocated when it is next
--- needed.
--- @param spec Retained, so later assignment to `enabled` is picked up.
--- @return The graph, so declarations chain.
function PassGraph:pass(spec: PassSpec): PassGraph
    -- Validate against what earlier passes have produced, so an ordering
    -- mistake surfaces here rather than as an empty or stale attachment.
    local produced: {string: boolean} = {}
    local producedDepth = false
    for _, earlier in ipairs(self._passes) do
        for _, output in ipairs(earlier.outputs or {}) do
            produced[output] = true
        end
        if earlier.depth ~= nil and earlier.depth.write ~= false then
            producedDepth = true
        end
    end

    for _, input in ipairs(spec.inputs or {}) do
        if input == "depth" then
            if not producedDepth then
                error(("tecs: pass '%s' reads depth before any pass writes it"):format(spec.name), 2)
            end
        elseif self._targets[input] == nil then
            error(("tecs: pass '%s' reads undeclared target '%s'"):format(spec.name, input), 2)
        elseif not produced[input] then
            error(("tecs: pass '%s' reads '%s' before any pass writes it"):format(spec.name, input), 2)
        end
    end

    for _, output in ipairs(spec.outputs or {}) do
        if self._targets[output] == nil then
            error(("tecs: pass '%s' writes undeclared target '%s'"):format(spec.name, output), 2)
        end
    end

    if spec.depth ~= nil then
        -- One depth attachment at frame size serves every depth pass, so a
        -- pass drawing into a scaled target cannot share it. SDL would reject
        -- the mismatch when the pass began; saying so here names the pass.
        for _, output in ipairs(spec.outputs or {}) do
            local scale = self._targets[output].scale
            if scale ~= 1.0 then
                error(
                    (
                        "tecs: pass '%s' uses depth but writes '%s' at scale "
                        .. "%s, and the depth attachment is frame sized"
                    ):format(spec.name, output, tostring(scale)),
                    2
                )
            end
        end
        self._needsDepth = true
    end

    -- One color attachment per output, or the single swapchain one a pass
    -- with no outputs renders into. Built here so `execute` only ever writes
    -- fields; a pass is run far too often to build its arguments per frame.
    local outputs <const> = spec.outputs or {}
    local attachments: {RenderPass.Attachment} = {}
    for index = 1, math.max(#outputs, 1) do
        attachments[index] = {texture = nil, clear = nil}
    end

    -- Filled on the first execute, since a texture handle only exists once the
    -- graph has been sized, and reused unchanged after that.
    local textures: {loader.CValue} = nil
    if #(spec.inputs or {}) > 0 then
        textures = {}
    end

    self._passes[#self._passes + 1] = spec
    self._prepared[#self._passes] = {
        attachments = attachments,
        textures = textures,
        context = {
            pass = nil,
            frame = nil,
            commandBuffer = nil,
            width = 0,
            height = 0,
        },
        pass = nil,
    }
    return self
end

--- Returns the texture backing a target, or nil before the first execute.
--- @param name A declared target's name. An undeclared one answers nil rather
---     than raising, which `formatOf` does not.
--- @return The graph's texture, replaced whenever the frame size changes, so
---     nothing may hold it across frames. Nil before the graph has been sized.
function PassGraph:texture(name: string): Texture
    if name == "depth" then
        return self._depth
    end
    return self._textures[name]
end

--- Returns the format a pipeline writing `name` must be created against.
---
--- Pipelines bake their target formats, so this is how a pass's pipeline stays
--- in step with the target the graph allocated for it.
--- @param name A declared target's name. An undeclared one raises.
--- @return The SDL texture format the target was declared with, defaulted if
---     the spec left it out.
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
--- @param passName A declared pass's name. An undeclared one raises; a
---     declared one with no depth answers nil.
--- @return A fresh config a pipeline may keep, or nil when the pass attaches
---     no depth.
function PassGraph:depthOf(passName: string): GraphicsPipeline.DepthConfig
    for _, spec in ipairs(self._passes) do
        if spec.name == passName then
            local state = spec.depth
            if state == nil then
                return nil
            end
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
            self._textures[name] = Texture.create(
                self.device,
                {
                    width = scaledWidth,
                    height = scaledHeight,
                    format = spec.format,
                    usage = {"colorTarget", "sampled"},
                    name = name,
                }
            )
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
        self._depth = Texture.create(
            self.device,
            {
                width = width,
                height = height,
                format = self.depthFormat,
                usage = {"depthTarget", "sampled"},
                name = "depth",
            }
        )
    end
end

--- Runs every enabled pass against `frame`.
---
--- Everything a pass is run out of was allocated when it was declared and is
--- rewritten here, so a frame's worth of passes allocates nothing. See
--- `Prepared` for what that costs a pass body: what it is handed is the
--- graph's, and describes this frame only.
---
--- A pass body that throws takes the whole frame with it, and the pass it was
--- inside is left open. Nothing here catches that: the pass is on the frame's
--- open list from the moment it began, and `Frame:abandon` is what ends it, so
--- recovery happens once where the frame is resolved rather than once per pass.
--- @param frame The frame to record into. Its width and height are what every
---     target is sized to, so a change in either reallocates all of them here.
function PassGraph:execute(frame: Frame)
    local frameWidth = frame.width
    local frameHeight = frame.height
    resize(self, frameWidth, frameHeight)

    local passes <const> = self._passes
    for index = 1, #passes do
        local spec <const> = passes[index]
        local enabled = spec.enabled == nil or spec.enabled()
        if enabled then
            local prepared <const> = self._prepared[index]
            local attachments <const> = prepared.attachments
            local outputs <const> = spec.outputs
            local width, height = frameWidth, frameHeight

            -- Resolved once for the pass rather than once per output: the
            -- override applies to every attachment, and LOAD is the one value
            -- that has to become an absent clear rather than be passed on.
            local override <const> = spec.clear
            local overridden <const> = override ~= nil
            local overrideClear <const> = override ~= LOAD and override or nil

            if outputs == nil or #outputs == 0 then
                local attachment <const> = attachments[1]
                attachment.texture = frame.swapchainTexture
                -- Nil unless the pass asked for a clear, which is the same
                -- answer the target-driven branch gives a target with none.
                attachment.clear = overrideClear
            else
                for slot = 1, #outputs do
                    local name <const> = outputs[slot]
                    local texture <const> = self._textures[name]
                    local attachment <const> = attachments[slot]
                    attachment.texture = texture.handle
                    if overridden then
                        attachment.clear = overrideClear
                    else
                        attachment.clear = self._targets[name].clear
                    end
                    width, height = texture.width, texture.height
                end
            end

            local depth: RenderPass.DepthAttachment = nil
            if spec.depth ~= nil then
                depth = self._depthAttachment
                depth.texture = self._depth.handle
                depth.clear = spec.depth.clear
            end

            local pass = RenderPass.begin(frame.commandBuffer, attachments, depth, prepared.pass)
            prepared.pass = pass

            local textures <const> = prepared.textures
            if textures ~= nil then
                local inputs <const> = spec.inputs
                for slot = 1, #inputs do
                    local input <const> = inputs[slot]
                    textures[slot] = input == "depth" and self._depth.handle or self._textures[input].handle
                end
                pass:bindTextures(0, textures, self._sampler.handle)
            end

            local context <const> = prepared.context
            context.pass = pass
            context.frame = frame
            context.commandBuffer = frame.commandBuffer
            context.width = width
            context.height = height
            spec.execute(context)

            pass:finish()
        end
    end
end

--- Releases every target the graph owns. Safe to call more than once.
function PassGraph:destroy()
    if self._destroyed then
        return
    end
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

local tecs <const> = require("tecs")
local pipeline <const> = require("tecs2d.gfx.internal.pipeline")
local types <const> = require("tecs2d.gfx.types")
local pipeline_key <const> = require("tecs2d.gfx.internal.pipeline_key")
local sprite <const> = require("tecs2d.gfx.internal.sprite")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local circle <const> = require("tecs2d.gfx.internal.circle")
local ellipse <const> = require("tecs2d.gfx.internal.ellipse")
local arc <const> = require("tecs2d.gfx.internal.arc")
local line <const> = require("tecs2d.gfx.internal.line")
local rectangle <const> = require("tecs2d.gfx.internal.rectangle")
local RoundedCorners <const> = require("tecs2d.gfx.internal.rectangle.RoundedCorners")
local meshMod <const> = require("tecs2d.gfx.internal.mesh")
local text <const> = require("tecs2d.gfx.internal.text")
local TextEffects <const> = require("tecs2d.gfx.internal.text.effects")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local particles <const> = require("tecs2d.gfx.internal.particles")
local Color <const> = require("tecs2d.gfx.internal.Color")
local BlendMode <const> = require("tecs2d.gfx.internal.BlendMode")
local blend <const> = require("tecs2d.gfx.internal.blend")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Occluder <const> = require("tecs2d.gfx.internal.Occluder")
local DropShadow <const> = require("tecs2d.gfx.internal.DropShadow")
local lightMod <const> = require("tecs2d.gfx.internal.Light")
local cameratarget <const> = require("tecs2d.gfx.internal.CameraTarget")
local physicsDebug <const> = require("tecs2d.gfx.internal.physicsDebug")
local tileChunkMod <const> = require("tecs2d.gfx.internal.tilechunk")
local text_sync <const> = require("tecs2d.gfx.internal.text.sync")
local gpu_types <const> = require("tecs2d.gfx.internal.gpu.types")
local Material <const> = require("tecs2d.gfx.internal.Material")
local material_registry <const> = require("tecs2d.gfx.internal.material_registry")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local gpuBuffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local shape_utils <const> = require("tecs2d.gfx.internal.gpu.shape_utils")
local shape_sync_base <const> = require("tecs2d.gfx.internal.shape_sync_base")

local CameraClass <const> = require("tecs2d.gfx.Camera")

local record gfx is tecs.Key<pipeline.Pipeline>

    --- Create a new render pipeline, automatically register it with the world, and return it.
    --- The pipeline includes a default camera. Access it via pipeline:getCamera().
    --- @param config Pipeline configuration including world.
    --- @return The created pipeline instance.
    newPipeline: function(config: pipeline.RenderConfig): types.Pipeline

    -- Type re-exports from internal modules
    type Rect = types.Rect
    type Pipeline = types.Pipeline
    type RenderPlugin = types.RenderPlugin
    type Layer = types.Layer
    type RenderConfig = pipeline.RenderConfig
    type Camera = CameraClass

    --- Camera configuration type re-export.
    type CameraConfig = CameraClass.CameraConfig

    --- Create a standalone Camera from a configuration table.
    --- @param config Camera configuration.
    --- @return A new Camera instance.
    newCamera: function(config: CameraClass.CameraConfig): CameraClass

    --- Resource key for accessing the render pipeline from world.resources.
    PIPELINE: tecs.Key<types.Pipeline>

    --- A Sprite component used to draw Love2D sprites.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Sprite: sprite.Sprite

    --- SpriteSheet record for sprite frame data, textures, and animations.
    --- Factory methods: fromFile, fromImage, fromTexture, fromTextureFile
    SpriteSheet: sprite_sheet.SpriteSheet

    --- SpriteCollision component for slice-based physics.
    --- Add alongside a Sprite to enable collision from Aseprite slices.
    SpriteCollision: sprite.SpriteCollision

    --- RepeatedSprite component for tiling sprites across an area.
    --- Add alongside a Sprite to enable tiling/repeating.
    RepeatedSprite: sprite.RepeatedSprite

    --- Event emitted when sprite animation tag changes.
    ChangeTag: tecs.Event

    --- A Circle component used to draw filled circles.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Circle: circle.Circle

    --- An Ellipse component used to draw filled ellipses.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Ellipse: ellipse.Ellipse

    --- An Arc component used to draw arcs (partial ellipses/circles).
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Arc: arc.Arc

    --- A Line component used to draw line segments.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Line: line.Line

    --- A Rectangle component used to draw filled rectangles.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Rectangle: rectangle.Rectangle

    --- A RoundedCorners component for adding rounded corners to rectangles.
    --- Must be added to an entity that also has a Rectangle component.
    RoundedCorners: RoundedCorners

    --- A Mesh component for GPU-instanced mesh rendering.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    --- The mesh geometry is defined by a MeshDefinition registered via MeshDefinition.new().
    Mesh: meshMod.Mesh

    --- MeshDefinition module for registering mesh geometry for instanced rendering.
    --- Create definitions with MeshDefinition.new(name, mesh, capacity).
    MeshDefinition: meshMod.MeshDefinition

    --- A Text component for pixel-perfect text using BMFont atlases.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    Text: text.Text

    --- TextEffects component for MSDF text effects (outline, glow, drop shadow).
    --- Only takes effect on entities using MSDF/SDF fonts.
    TextEffects: TextEffects

    --- BMFont module for loading and parsing bitmap font atlases.
    --- Supports .fnt (text) and .json formats, including MSDF fonts.
    BMFont: bmfont

    --- A ParticleEmitter component for Love2D particle systems.
    ---
    --- Requires adding the Transform component to get the default rendering logic.
    ParticleEmitter: particles.ParticleEmitter

    --- Configuration for creating a serializable ParticleEmitter.
    ParticleEmitterConfig: particles.ParticleEmitterConfig

    --- Sets a love.graphics.color for a draw call.
    Color: Color

    --- Sets a blendmode for a draw call.
    --- @deprecated Use blend tag components instead (e.g., blend.AdditiveBlend())
    BlendMode: BlendMode

    --- Blend mode tag components for GPU-batched rendering.
    --- Each blend mode is a separate tag component with mutual exclusivity.
    --- Example: gfx.blend.AdditiveBlend(), gfx.blend.MultiplyBlend()
    blend: blend

    --- Sets the pivot point for rendering (0-1 range).
    --- 0,0 = top-left, 0.5,0.5 = center (default), 1,1 = bottom-right.
    Pivot: Pivot

    --- Tag component that opts an entity out of dynamic lighting. Entities
    --- with `Unlit` render at full brightness. Composes with per-layer
    --- unlit (pipeline:setLayerUnlit): either makes the entity unlit.
    Unlit: tecs.Component

    --- Opts an entity into shadow casting. Entities with this component will render
    --- their silhouette to the shadow mask, blocking light and casting shadows.
    --- For sprites, uses alpha channel. For shapes, uses filled geometry.
    Occluder: Occluder

    --- Adds a squashed, darkened copy of a sprite beneath it to simulate
    --- a ground shadow from an overhead light. Independent of the dynamic
    --- lighting system. Renders as lit G-buffer geometry.
    DropShadow: DropShadow

    --- Marks drawable entities as lights, rendering them to the light canvas.
    Light: lightMod.Light

    --- A Material component for GPU fragment shader injection.
    --- Entities with a Material stay fully GPU-batched and participate in deferred lighting.
    --- Create materials with gfx.newMaterial() and use the returned value as a component.
    Material: Material

    --- Register a material and return a Material component value.
    --- The material's fragment shader is injected into each shape type's render shader.
    --- @param name Unique name for this material
    --- @param opts Material options (fragment shader path, optional textures, unlit flag)
    --- @return Material component value ready to add to entities
    newMaterial: function(name: string, opts: material_registry.MaterialOpts): Material

    --- Precompile all registered materials for all shape types.
    --- Call during a loading screen to avoid first-frame compilation hitches.
    precompileMaterials: function()

    --- Marks an entity as the camera target. The camera will smoothly follow the entity.
    --- Requires Transform component.
    CameraTarget: cameratarget.CameraTarget

    --- Optional physics debug rendering plugin.
    --- Add after both physics and render pipeline are initialized.
    physicsDebug: physicsDebug

    --- Event to toggle physics debug shapes on/off. Emit to world address 0.
    PhysicsDebugToggle: physicsDebug.PhysicsDebugToggle

    --- TileChunk component for GPU-driven 16x16 tile grid rendering.
    --- Use this for static tiles. Animated tiles should use Sprite instead.
    TileChunk: tileChunkMod.TileChunk

    --- Marker component for chunks that need GPU sync.
    --- Spawn chunks with this component; add it again after modifying tiles/tint.
    DirtyTileChunk: tileChunkMod.DirtyTileChunk

    --- TileChunk configuration type
    type TileChunkConfig = tileChunkMod.TileChunkConfig

    --- Chunk size constant (16)
    TILE_CHUNK_SIZE: integer

    --- Shader utilities for compiling custom shape shaders.
    --- Provides loadShader, loadRenderShader, loadCullShader, insertAfterPragma,
    --- and common GLSL include strings (CULL_COMMON, RENDER_COMMON, TILE_COMMON, etc.).
    shaders: shaderUtils

    --- GPU buffer module for creating managed SSBO wrappers.
    --- Use GPUBuffer.new(format, capacity, ctypeName) to create buffers with
    --- slot allocation, dirty tracking, and automatic growth.
    GPUBuffer: gpuBuffer

    --- Simple shape plugin factory. Pass a SimpleShapeConfig to generate
    --- a complete RenderPlugin with upload, cull, render, blend, and shadow hooks.
    shapePlugin: shape_utils

    --- Shared sync base types and helpers for building shape sync systems.
    --- Includes SyncRecord, BlendGroup, MaterialGroup, and helper functions
    --- (syncColor, syncClipBounds, syncPivot, etc.).
    syncBase: shape_sync_base

end

-- Set the context key for pipeline to use
pipeline._contextKey = gfx

gfx.Sprite = sprite.Sprite
gfx.SpriteSheet = sprite_sheet.SpriteSheet
gfx.SpriteCollision = sprite.SpriteCollision
gfx.RepeatedSprite = sprite.RepeatedSprite
gfx.ChangeTag = sprite.ChangeTag
gfx.Circle = circle.Circle
gfx.Ellipse = ellipse.Ellipse
gfx.Arc = arc.Arc
gfx.Line = line.Line
gfx.Rectangle = rectangle.Rectangle
gfx.RoundedCorners = RoundedCorners
gfx.Mesh = meshMod.Mesh
gfx.MeshDefinition = meshMod.MeshDefinition
gfx.Text = text.Text
gfx.TextEffects = TextEffects
gfx.BMFont = bmfont
gfx.ParticleEmitter = particles.ParticleEmitter
gfx.ParticleEmitterConfig = particles.ParticleEmitterConfig
gfx.Color = Color
gfx.BlendMode = BlendMode
gfx.blend = blend
gfx.Pivot = Pivot
gfx.Unlit = Unlit
gfx.Occluder = Occluder
gfx.DropShadow = DropShadow
gfx.Light = lightMod.Light
gfx.Material = Material
gfx.CameraTarget = cameratarget.CameraTarget
gfx.physicsDebug = physicsDebug
gfx.PhysicsDebugToggle = physicsDebug.PhysicsDebugToggle
gfx.TileChunk = tileChunkMod.TileChunk
gfx.DirtyTileChunk = tileChunkMod.DirtyTileChunk
gfx.TILE_CHUNK_SIZE = tileChunkMod.CHUNK_SIZE
-- Re-export the pipeline key for external access
gfx.PIPELINE = pipeline_key.PIPELINE
-- Re-export GPU utilities for custom shape plugins
gfx.shaders = shaderUtils
gfx.GPUBuffer = gpuBuffer
gfx.shapePlugin = shape_utils
gfx.syncBase = shape_sync_base

function gfx.newPipeline(config: pipeline.RenderConfig): types.Pipeline
    local result = pipeline.newPipeline(config)

    -- Store render pipeline in resources for gameTime updates and sprite animation
    config.world.resources[pipeline_key.PIPELINE] = result

    config.world:addPlugin(sprite.plugin(result))
    config.world:addPlugin(circle.plugin)
    config.world:addPlugin(ellipse.plugin)
    config.world:addPlugin(arc.plugin)
    config.world:addPlugin(line.plugin)
    config.world:addPlugin(rectangle.plugin)
    config.world:addPlugin(meshMod.plugin)
    config.world:addPlugin(text.plugin)
    config.world:addPlugin(text_sync.plugin(config.world, result:getRenderer() as gpu_types.Renderer, text.Text))
    config.world:addPlugin(particles.plugin)
    config.world:addPlugin(cameratarget.plugin(result))
    config.world:addPlugin(Color.plugin)
    config.world:addPlugin(BlendMode.plugin)
    config.world:addPlugin(lightMod.plugin)
    config.world:addPlugin(tileChunkMod.plugin)

    -- Warm every loaded sprite sheet's GPU texture bucket once, before the first
    -- frame renders, so the first sprite using a sheet doesn't hitch while its
    -- texture array is built. Runs automatically; games don't call preloadAll.
    config.world:addSystem({
        name = "tecs2d.PreloadSpriteBuckets",
        phase = tecs.phases.PostStartup,
        run = function()
            sprite_sheet.SpriteSheet.preloadAll()
        end,
    })

    return result
end

function gfx.newMaterial(name: string, opts: material_registry.MaterialOpts): Material
    return material_registry.register(name, opts)
end

function gfx.precompileMaterials()
    material_compiler.precompileAll()
end

function gfx.newCamera(config: CameraClass.CameraConfig): CameraClass
    return CameraClass.new(config)
end

return gfx

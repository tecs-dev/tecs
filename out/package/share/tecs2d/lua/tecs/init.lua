


require("tecs.internal.compat")

local types = require("tecs.types")
local Context = require("tecs.internal.Context")
local builtins = require("tecs.internal.builtins")
local components = require("tecs.internal.components")
local events = require("tecs.internal.events")
local phases = require("tecs.internal.phases")
local runIfHelpers = require("tecs.internal.runif")
local json = require("tecs.utils.json")
local IdAllocator = require("tecs.internal.IdAllocator")
local WorldImpl = require("tecs.internal.world")







local tecs = {}





































































































































tecs.newComponent = components.newComponent

tecs.newScalarComponent = components.newScalarComponent

tecs.newTagComponent = components.newTagComponent

tecs.newFFIComponent = components.newFFIComponent

tecs.newRelationship = components.newRelationship

tecs.newFFIRelationship = components.newFFIRelationship


function tecs.getComponentById(id)
   return components.componentsById[id]
end

function tecs.componentByName(name)
   return components.registeredComponents[name]
end

tecs.newWorld = WorldImpl.new
tecs.newKey = Context.newKey
tecs.findKey = Context.findKey
tecs.listKeys = Context.listKeys
tecs.newContext = Context.new
tecs.newEvent = events.newEvent
tecs.newFFIEvent = events.newFFIEvent
tecs.newMessageBus = events.MessageBus.new
tecs.json = json
tecs.phases = phases
tecs.builtins = builtins
tecs.runif = runIfHelpers
tecs.MAX_ENTITIES = IdAllocator.ABSOLUTE_MAX_SLOT_COUNT
tecs.DEFAULT_MAX_ENTITIES = IdAllocator.DEFAULT_MAX_SLOT_COUNT

return tecs

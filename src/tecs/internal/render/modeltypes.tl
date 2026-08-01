local components <const> = require("tecs.components")

local record modeltypes
    interface Domain
        registerSkin: function(self, name: string, matrices: {number}): components.MeshSkin
        updateSkin: function(self, skin: components.MeshSkin, matrices: {number})
        registerMorph: function(self, name: string, weights: {number}): components.MeshMorph
        updateMorph: function(self, morph: components.MeshMorph, weights: {number})
    end
end

return modeltypes

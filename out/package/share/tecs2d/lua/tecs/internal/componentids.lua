





local componentIds = {}

local AUTO_COMPONENT_ID = 0

function componentIds.allocate()
   AUTO_COMPONENT_ID = AUTO_COMPONENT_ID + 1
   return AUTO_COMPONENT_ID
end

return componentIds

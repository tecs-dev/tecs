local types = require("tecs.types")






local Bundle = {}





local bundle = {}








function bundle.create(world, name, def)
   assert(world, "Bundle requires a world")
   assert(name and name ~= "", "Bundle requires a name")

   local required = def and def.required or {}
   local withEntries = def and def.with or {}
   local requiredCount = #required


   local seen = {}
   for i = 1, requiredCount do
      local comp = required[i]
      assert(not seen[comp], "Component already in bundle: " .. comp.componentName)
      seen[comp] = true
   end



   local typeArray = {}
   local factoryArray = {}
   local requiredNames = {}
   local defaultedNames = {}

   for i = 1, requiredCount do
      local t = required[i]
      typeArray[i] = t
      requiredNames[i] = t.componentName
   end
   local withIndex = 0
   for t, value in pairs(withEntries) do
      assert(not seen[t], "Component already in bundle: " .. t.componentName)
      seen[t] = true
      withIndex = withIndex + 1
      typeArray[requiredCount + withIndex] = t
      local factory
      if type(value) == "function" then
         factory = value
      elseif value == true then
         factory = function() return t() end
      else
         error("Bundle 'with' value for " .. t.componentName ..
         " must be a factory function or `true`")
      end
      factoryArray[requiredCount + withIndex] = factory
      defaultedNames[withIndex] = t.componentName
   end





   local worldAny = world
   local codegen = worldAny._codegenBundleSpawn

   local spawnFn = codegen(world, typeArray, factoryArray, requiredCount)




   local bundleObj = {
      name = name,
      required = requiredNames,
      defaulted = defaultedNames,
      _world = world,
   };
   (bundleObj).spawn = spawnFn
   setmetatable(bundleObj, { __index = Bundle })


   local bundles = worldAny._bundles
   if not bundles then
      bundles = {}
      worldAny._bundles = bundles
   end
   assert(not bundles[name], "Bundle with name '" .. name .. "' already exists")
   bundles[name] = bundleObj

   return bundleObj
end

return bundle

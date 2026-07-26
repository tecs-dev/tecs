file(REMOVE_RECURSE
  "CMakeFiles/tecs2d_bindings"
  "lua/tecs2d/ffi/box2dcdef.lua"
  "lua/tecs2d/ffi/box2dconst.lua"
  "lua/tecs2d/ffi/sdl3cdef.lua"
  "lua/tecs2d/ffi/sdl3const.lua"
  "lua/tecs2d/ffi/sdl3imagecdef.lua"
  "lua/tecs2d/ffi/sdl3imageconst.lua"
  "lua/tecs2d/ffi/shaderccdef.lua"
  "lua/tecs2d/ffi/shadercconst.lua"
  "lua/tecs2d/ffi/spvccdef.lua"
  "lua/tecs2d/ffi/spvcconst.lua"
  "lua/tecs2d/ffi/workercdef.lua"
  "lua/tecs2d/ffi/workerconst.lua"
)

# Per-language clean rules from dependency scanning.
foreach(lang )
  include(CMakeFiles/tecs2d_bindings.dir/cmake_clean_${lang}.cmake OPTIONAL)
endforeach()

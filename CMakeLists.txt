cmake_minimum_required(VERSION 3.24)
# C++ is enabled only to link SPIRV-Cross, which is a C++ library behind a C
# API. No engine source is C++.
project(tecs2d C CXX)

# The canonical build. Make, Gradle, and Xcode are thin wrappers over this, so
# there is one description of how the engine is assembled rather than one per
# platform to keep in step.

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(TECS2D_SYSTEM_DEPS
    "Resolve dependencies from the system rather than pinned sources" ON)
option(TECS2D_BUILD_LUA
    "Generate FFI bindings and compile the Teal sources" ON)

set(TECS2D_LUA_OUT "${CMAKE_BINARY_DIR}/lua" CACHE PATH
    "Where compiled Lua and generated bindings are written")

# The ECS is developed alongside this engine rather than vendored. Only its
# source and type definitions are referenced; its own engine tree must not be
# on the include path, or it would shadow this one.
set(TECS2D_TECS_DIR "${CMAKE_SOURCE_DIR}/../tecs" CACHE PATH
    "Root of the Tecs ECS checkout")

# ---------------------------------------------------------------- dependencies

if(NOT TECS2D_SYSTEM_DEPS)
    # Pinned revisions for anything shipped. Left declared rather than fetched
    # by default because building this set from source is a long build, and
    # desktop development does not need it.
    include(cmake/Pinned.cmake)
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL3 REQUIRED IMPORTED_TARGET sdl3)
    pkg_check_modules(SDL3_IMAGE REQUIRED IMPORTED_TARGET sdl3-image)
    pkg_check_modules(LUAJIT REQUIRED IMPORTED_TARGET luajit)
    pkg_check_modules(SHADERC REQUIRED IMPORTED_TARGET shaderc)
    pkg_check_modules(SPIRV_CROSS REQUIRED spirv-cross-c)

    # Box2D ships no pkg-config or CMake config, so it is located directly.
    find_path(BOX2D_INCLUDE_DIR box2d/box2d.h)
    find_library(BOX2D_LIBRARY NAMES box2d)
    if(NOT BOX2D_INCLUDE_DIR OR NOT BOX2D_LIBRARY)
        message(FATAL_ERROR "Box2D 3 not found. Set BOX2D_INCLUDE_DIR and BOX2D_LIBRARY.")
    endif()
endif()

# Runtime search paths are relative to the executable, so a package finds its
# own libraries wherever it is unpacked.
if(APPLE)
    set(CMAKE_INSTALL_RPATH "@executable_path/../lib")
elseif(UNIX)
    set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib")
endif()
set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)

# A development build also needs to find the system libraries it linked
# against. A packaged one must not: leaving a developer's package-manager path
# in a shipped binary is how a build that works only on the machine that made
# it gets shipped.
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH ${TECS2D_SYSTEM_DEPS})

# ----------------------------------------------------------------- native code

# Worker threads and channels. Native because a LuaJIT FFI callback invoked
# from a thread the VM did not create is unsafe, so a thread entry point cannot
# be a Lua function.
add_library(tecs2d_worker SHARED native/worker.c)
set_target_properties(tecs2d_worker PROPERTIES
    OUTPUT_NAME tecs2dworker
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_link_libraries(tecs2d_worker PRIVATE
    PkgConfig::SDL3 PkgConfig::LUAJIT)

# SPIRV-Cross ships static archives only, and the FFI needs a shared object.
# Whole-archive linking is deliberate: the C API's symbols are not referenced
# from this stub, so without it the linker would discard all of them.
add_library(tecs2d_spirvcross SHARED native/spirvcross.c)
set_target_properties(tecs2d_spirvcross PROPERTIES
    OUTPUT_NAME spirvcrossc
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_include_directories(tecs2d_spirvcross PRIVATE ${SPIRV_CROSS_INCLUDE_DIRS})

set(TECS2D_SPVC_ARCHIVES
    spirv-cross-c spirv-cross-cpp spirv-cross-msl
    spirv-cross-glsl spirv-cross-hlsl spirv-cross-reflect
    spirv-cross-util spirv-cross-core)
set(TECS2D_SPVC_WHOLE "")
foreach(archive IN LISTS TECS2D_SPVC_ARCHIVES)
    find_library(SPVC_${archive}_LIB NAMES ${archive}
        HINTS ${SPIRV_CROSS_LIBRARY_DIRS})
    if(NOT SPVC_${archive}_LIB)
        message(FATAL_ERROR "SPIRV-Cross archive ${archive} not found")
    endif()
    list(APPEND TECS2D_SPVC_WHOLE "${SPVC_${archive}_LIB}")
endforeach()

if(APPLE)
    target_link_options(tecs2d_spirvcross PRIVATE -Wl,-all_load)
else()
    target_link_options(tecs2d_spirvcross PRIVATE -Wl,--whole-archive)
endif()
target_link_libraries(tecs2d_spirvcross PRIVATE ${TECS2D_SPVC_WHOLE})
if(NOT APPLE)
    target_link_options(tecs2d_spirvcross PRIVATE -Wl,--no-whole-archive)
endif()
set_target_properties(tecs2d_spirvcross PROPERTIES LINKER_LANGUAGE CXX)

# The application host. SDL owns the loop, so this implements SDL's callback
# entry points and reaches Lua through the Lua C API.
add_executable(tecs2d native/host.c)
set_target_properties(tecs2d PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_link_libraries(tecs2d PRIVATE PkgConfig::SDL3 PkgConfig::LUAJIT)

if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    # LuaJIT on x64 macOS needs its allocations below 2GB.
    target_link_options(tecs2d PRIVATE
        -pagezero_size 10000 -image_base 100000000)
endif()

# ------------------------------------------------------- generated bindings

if(TECS2D_BUILD_LUA)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(GEN "${TECS2D_LUA_OUT}/tecs2d/ffi")
    file(MAKE_DIRECTORY "${GEN}")

    # Include directories come from dependency discovery rather than from a
    # hardcoded package-manager prefix, which is what lets this cross-compile.
    function(tecs2d_cdef name header keep prefix)
        set(includes "")
        foreach(dir IN LISTS ARGN)
            list(APPEND includes --include ${dir})
        endforeach()
        add_custom_command(
            OUTPUT "${GEN}/${name}cdef.lua" "${GEN}/${name}const.lua"
            COMMAND ${Python3_EXECUTABLE}
                "${CMAKE_SOURCE_DIR}/scripts/gencdef.py"
                --header ${header} ${includes}
                --keep ${keep} --define-prefix ${prefix}
                --defines-out "${GEN}/${name}const.lua"
                --out "${GEN}/${name}cdef.lua"
            DEPENDS "${CMAKE_SOURCE_DIR}/scripts/gencdef.py"
            COMMENT "Generating ${name} FFI bindings"
            VERBATIM)
    endfunction()

    tecs2d_cdef(sdl3 SDL3/SDL.h /SDL3/ SDL_ ${SDL3_INCLUDE_DIRS})
    tecs2d_cdef(sdl3image SDL3_image/SDL_image.h /SDL3_image/ IMG_
        ${SDL3_IMAGE_INCLUDE_DIRS} ${SDL3_INCLUDE_DIRS})
    tecs2d_cdef(box2d box2d/box2d.h /box2d/ B2_ ${BOX2D_INCLUDE_DIR})
    tecs2d_cdef(shaderc shaderc/shaderc.h /shaderc/ shaderc_
        ${SHADERC_INCLUDE_DIRS})
    # pkg-config points into the spirv_cross directory rather than at its
    # parent, so the header is named relative to that.
    tecs2d_cdef(spvc spirv_cross_c.h /spirv_cross/ SPVC_
        ${SPIRV_CROSS_INCLUDE_DIRS})

    # The engine's own native API. Generated the same way as a third-party
    # header so the binding cannot drift from the C even though both live here.
    tecs2d_cdef(worker worker.h /native/ TECS2D_ "${CMAKE_SOURCE_DIR}/native")

    add_custom_target(tecs2d_bindings ALL DEPENDS
        "${GEN}/workercdef.lua"
        "${GEN}/sdl3cdef.lua" "${GEN}/sdl3imagecdef.lua"
        "${GEN}/box2dcdef.lua" "${GEN}/shaderccdef.lua"
        "${GEN}/spvccdef.lua")

    # Teal compilation. Kept as one custom target rather than per-file rules
    # because the compiler resolves the module graph itself.
    file(GLOB_RECURSE TECS2D_TL "${CMAKE_SOURCE_DIR}/src/*.tl")
    add_custom_target(tecs2d_lua ALL
        COMMAND tl -q gen -I "${CMAKE_SOURCE_DIR}/vendor/tl"
            -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
            -I "${TECS2D_TECS_DIR}/vendor/share/lua/5.1"
            --root "${CMAKE_SOURCE_DIR}/src"
            --output-dir "${TECS2D_LUA_OUT}" ${TECS2D_TL}
        DEPENDS ${TECS2D_TL} tecs2d_bindings
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Compiling Teal sources"
        VERBATIM)
endif()

# --------------------------------------------------------------- packaging

# Records how the tree was built, so a check can tell a development install
# from a shippable one rather than guessing from what it finds.
file(WRITE "${CMAKE_BINARY_DIR}/build-info.txt"
    "systemDeps=${TECS2D_SYSTEM_DEPS}\n"
    "system=${CMAKE_SYSTEM_NAME}\n"
    "arch=${CMAKE_SYSTEM_PROCESSOR}\n")
install(FILES "${CMAKE_BINARY_DIR}/build-info.txt"
    DESTINATION share/tecs2d)

install(TARGETS tecs2d RUNTIME DESTINATION bin)
install(TARGETS tecs2d_worker tecs2d_spirvcross LIBRARY DESTINATION lib)
if(TECS2D_BUILD_LUA)
    install(DIRECTORY "${TECS2D_LUA_OUT}/" DESTINATION share/tecs2d/lua)
endif()

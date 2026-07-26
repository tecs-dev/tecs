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
option(TECS2D_RUNTIME_SHADERS
    "Link a shader compiler, for development. Releases use packaged artifacts." ON)

set(TECS2D_SPEC_OUT "${CMAKE_BINARY_DIR}/spec" CACHE PATH
    "Where compiled Teal specs are written")
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
    # Found by hand rather than through its .pc file: Homebrew's sdl3-net.pc
    # sets includedir to /include and libdir to /lib, which CMake rejects when
    # it builds an imported target. The real paths are on the same prefix as
    # SDL3 itself.
    find_path(SDL3_NET_INCLUDE_DIR SDL3_net/SDL_net.h)
    find_library(SDL3_NET_LIBRARY NAMES SDL3_net)
    if(NOT SDL3_NET_INCLUDE_DIR OR NOT SDL3_NET_LIBRARY)
        message(FATAL_ERROR
            "SDL3_net not found. Set SDL3_NET_INCLUDE_DIR and SDL3_NET_LIBRARY.")
    endif()
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
# JSON. Vendored rather than depended on, because a Lua C module cannot be
# found by `require` on a target with no dlopen: it has to be compiled in and
# announced through package.preload. Built twice from one set of sources, as a
# static library for that, and as a loadable module so specs running under a
# plain interpreter can require it the ordinary way.
# fpconv.c is deliberately absent: with USE_INTERNAL_FPCONV the header defines
# fpconv_init inline and the conversions come from g_fmt.c and dtoa.c instead.
set(TECS2D_CJSON_SOURCES
    vendor/cjson/lua_cjson.c vendor/cjson/strbuf.c
    vendor/cjson/g_fmt.c vendor/cjson/dtoa.c)
set(TECS2D_CJSON_DEFINES USE_INTERNAL_FPCONV MULTIPLE_THREADS)

add_library(tecs2d_cjson STATIC ${TECS2D_CJSON_SOURCES})
target_compile_definitions(tecs2d_cjson PRIVATE ${TECS2D_CJSON_DEFINES})
target_include_directories(tecs2d_cjson PRIVATE ${LUAJIT_INCLUDE_DIRS})
set_target_properties(tecs2d_cjson PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(cjson MODULE ${TECS2D_CJSON_SOURCES})
target_compile_definitions(cjson PRIVATE ${TECS2D_CJSON_DEFINES})
target_include_directories(cjson PRIVATE ${LUAJIT_INCLUDE_DIRS})
set_target_properties(cjson PROPERTIES
    PREFIX "" SUFFIX ".so"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_link_libraries(cjson PRIVATE ${LUAJIT_LINK_LIBRARIES})

add_library(tecs2d_worker SHARED native/worker.c native/logsink.c native/luamods.c)
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
add_executable(tecs2d native/host.c native/luamods.c)

# Where content sits relative to the executable, in the tree this build
# installs. The host resolves its entry chunk and the engine resolves assets
# against it, so the layout is described once here instead of being sniffed for
# at run time.
set(TECS2D_CONTENT "../share/tecs2d/lua/" CACHE STRING
    "Content directory relative to the installed executable")
target_compile_definitions(tecs2d PRIVATE TECS2D_CONTENT="${TECS2D_CONTENT}")
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

    # Bindings must be generated with the same preprocessor state the C is
    # compiled with. A header that declares different things under NDEBUG
    # would otherwise produce a binding for a function the build does not
    # have, which surfaces as a link error far from the cause.
    set(TECS2D_CDEF_DEFINES "")
    if(CMAKE_BUILD_TYPE MATCHES "Release|RelWithDebInfo|MinSizeRel")
        list(APPEND TECS2D_CDEF_DEFINES --define NDEBUG)
    endif()

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
                --header ${header} ${includes} ${TECS2D_CDEF_DEFINES}
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
    tecs2d_cdef(sdl3net SDL3_net/SDL_net.h /SDL3_net/ NET_
        ${SDL3_NET_INCLUDE_DIR} ${SDL3_INCLUDE_DIRS})
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
    tecs2d_cdef(logsink logsink.h /native/ TECS2D_ "${CMAKE_SOURCE_DIR}/native")

    # Each library also gets a table of function pointers, taken at build
    # time. A target that cannot dlopen still links, and the engine calls
    # through the table rather than through a handle it had to resolve.
    set(TECS2D_REGISTRY_SOURCES "")
    set(TECS2D_REGISTRY_ENTRIES "")
    set(TECS2D_REGISTRY_PAIRS "")

    function(tecs2d_registry name struct prefix)
        set(source "${CMAKE_BINARY_DIR}/generated/${name}api.c")
        set(headers "")
        foreach(header IN LISTS ARGN)
            list(APPEND headers --header ${header})
        endforeach()
        add_custom_command(
            OUTPUT "${source}" "${GEN}/${name}apicdef.lua"
            COMMAND ${Python3_EXECUTABLE}
                "${CMAKE_SOURCE_DIR}/scripts/genregistry.py"
                --cdef "${GEN}/${name}cdef.lua"
                --name ${name} --struct ${struct} --prefix ${prefix}
                ${headers}
                --source-out "${source}"
                --cdef-out "${GEN}/${name}apicdef.lua"
            DEPENDS "${GEN}/${name}cdef.lua"
                    "${CMAKE_SOURCE_DIR}/scripts/genregistry.py"
            COMMENT "Generating ${name} native API table"
            VERBATIM)
        set(TECS2D_REGISTRY_PAIRS ${TECS2D_REGISTRY_PAIRS} "${name}:${struct}"
            PARENT_SCOPE)
        set(TECS2D_REGISTRY_SOURCES ${TECS2D_REGISTRY_SOURCES} "${source}"
            PARENT_SCOPE)
        set(TECS2D_REGISTRY_ENTRIES
            "${TECS2D_REGISTRY_ENTRIES}TECS2D_API(${name}, ${struct})\n"
            PARENT_SCOPE)
    endfunction()

    tecs2d_registry(sdl3 Tecs2dSdl3Api SDL_ SDL3/SDL.h)
    tecs2d_registry(sdl3image Tecs2dSdl3ImageApi IMG_ SDL3_image/SDL_image.h)
    tecs2d_registry(sdl3net Tecs2dSdl3NetApi NET_ SDL3_net/SDL_net.h)
    tecs2d_registry(box2d Tecs2dBox2dApi b2 box2d/box2d.h)
    tecs2d_registry(worker Tecs2dWorkerApi tecs2d worker.h)
    tecs2d_registry(logsink Tecs2dLogsinkApi tecs2d logsink.h)

    # Shader compilation is a development capability. A release consumes
    # packaged artifacts, so a target built without it links no compiler and
    # the registry simply has no entry for one.
    if(TECS2D_RUNTIME_SHADERS)
        tecs2d_registry(shaderc Tecs2dShadercApi shaderc_ shaderc/shaderc.h)
        tecs2d_registry(spvc Tecs2dSpvcApi spvc_ spirv_cross_c.h)
    endif()

    # The same mapping the loader needs, so the two cannot drift. It was a
    # hand-written table, and adding a library to the build without adding it
    # here failed only under the host, where the registry path is the one that
    # runs.
    set(TECS2D_REGISTRY_LUA
        "-- Generated. Library name to the struct its registry table has.\nreturn {\n")
    foreach(pair IN LISTS TECS2D_REGISTRY_PAIRS)
        string(REPLACE ":" ";" parts "${pair}")
        list(GET parts 0 pairName)
        list(GET parts 1 pairStruct)
        set(TECS2D_REGISTRY_LUA
            "${TECS2D_REGISTRY_LUA}    ${pairName} = \"${pairStruct}\",\n")
    endforeach()
    file(WRITE "${TECS2D_LUA_OUT}/tecs2d/ffi/registrystructs.lua"
        "${TECS2D_REGISTRY_LUA}}\n")

    file(WRITE "${CMAKE_BINARY_DIR}/generated/registry_entries.h"
        "/* Generated. Which libraries this target links. */\n"
        "${TECS2D_REGISTRY_ENTRIES}")

    add_library(tecs2d_registry STATIC
        native/registry.c ${TECS2D_REGISTRY_SOURCES})
    target_include_directories(tecs2d_registry PUBLIC
        "${CMAKE_BINARY_DIR}/generated" "${CMAKE_SOURCE_DIR}/native")
    target_link_libraries(tecs2d_registry PUBLIC
        PkgConfig::SDL3 PkgConfig::SDL3_IMAGE PkgConfig::LUAJIT
        ${BOX2D_LIBRARY} ${SDL3_NET_LIBRARY})

    # Taking the address of a shader compiler's functions means linking it.
    # That is the coupling TECS2D_RUNTIME_SHADERS exists to remove: a release
    # generates no table for them and links neither.
    if(TECS2D_RUNTIME_SHADERS)
        target_link_libraries(tecs2d_registry PUBLIC
            PkgConfig::SHADERC tecs2d_spirvcross)
    endif()
    target_include_directories(tecs2d_registry PRIVATE
        ${BOX2D_INCLUDE_DIR} ${SDL3_NET_INCLUDE_DIR}
        ${SHADERC_INCLUDE_DIRS} ${SPIRV_CROSS_INCLUDE_DIRS})

    # Linked here rather than where the executables are declared, because the
    # registry's sources are generated from bindings produced above.
    # The host also links the worker library, because its table holds the
    # addresses of that library's functions.
    target_link_libraries(tecs2d PRIVATE tecs2d_registry tecs2d_worker tecs2d_cjson)
    target_link_libraries(tecs2d_worker PRIVATE tecs2d_registry tecs2d_cjson)

    add_custom_target(tecs2d_bindings ALL DEPENDS
        "${GEN}/workercdef.lua" "${GEN}/logsinkcdef.lua"
        "${GEN}/sdl3cdef.lua" "${GEN}/sdl3imagecdef.lua" "${GEN}/sdl3netcdef.lua"
        "${GEN}/box2dcdef.lua" "${GEN}/shaderccdef.lua"
        "${GEN}/spvccdef.lua")

    # Teal compilation. Kept as one custom target rather than per-file rules
    # because the compiler resolves the module graph itself.
    # CONFIGURE_DEPENDS so adding a source is a build, not a reconfigure.
    # Without it a new module is silently absent until someone remembers.
    file(GLOB_RECURSE TECS2D_TL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/*.tl")
    add_custom_target(tecs2d_lua ALL
        # tl searches include paths last-first, so ours come last and win.
        COMMAND tl -q gen -I "${TECS2D_TECS_DIR}/vendor/share/lua/5.1"
            -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
            -I "${CMAKE_SOURCE_DIR}/vendor/tl"
            --root "${CMAKE_SOURCE_DIR}/src"
            --output-dir "${TECS2D_LUA_OUT}" ${TECS2D_TL}
        DEPENDS ${TECS2D_TL} tecs2d_bindings
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Compiling Teal sources"
        VERBATIM)

    # Content lives beside the compiled Lua, because that directory is the
    # content root a development run resolves against and the one an install
    # copies. CONFIGURE_DEPENDS so adding a shader is a build, not a
    # reconfigure.
    file(GLOB_RECURSE TECS2D_ASSET_FILES CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/assets/*")
    add_custom_target(tecs2d_assets ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/assets" "${TECS2D_LUA_OUT}"
        DEPENDS ${TECS2D_ASSET_FILES}
        COMMENT "Copying assets"
        VERBATIM)

    # Specs written in Teal, compiled the same way. Subsystems migrating from
    # the Love-backed engine arrive with their suites, and a suite rewritten
    # into Lua on the way across would no longer be the proof it was.
    file(GLOB_RECURSE TECS2D_SPEC_TL CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/spec/*.tl")
    if(TECS2D_SPEC_TL)
        add_custom_target(tecs2d_spec ALL
            COMMAND tl -q gen -I "${TECS2D_TECS_DIR}/vendor/share/lua/5.1"
                -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
                -I "${CMAKE_SOURCE_DIR}/vendor/tl"
                --root "${CMAKE_SOURCE_DIR}/spec"
                --output-dir "${TECS2D_SPEC_OUT}" ${TECS2D_SPEC_TL}
            DEPENDS ${TECS2D_SPEC_TL} tecs2d_lua
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            COMMENT "Compiling Teal specs"
            VERBATIM)
    endif()
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
install(TARGETS cjson LIBRARY DESTINATION lib)
if(TECS2D_BUILD_LUA)
    install(DIRECTORY "${TECS2D_LUA_OUT}/" DESTINATION share/tecs2d/lua)
    # The ECS is part of what ships: a game is written against it directly, so
    # an install without it is an install that cannot run.
    install(DIRECTORY "${TECS2D_TECS_DIR}/build/tecs"
        DESTINATION share/tecs2d/lua)
endif()

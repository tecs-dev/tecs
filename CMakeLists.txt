cmake_minimum_required(VERSION 3.24)
# C++ is enabled only to link SPIRV-Cross, which is a C++ library behind a C
# API. No engine source is C++.
project(tecs C CXX)

# The canonical build. Make, Gradle, and Xcode are thin wrappers over this, so
# there is one description of how the engine is assembled rather than one per
# platform to keep in step.

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(TECS_SYSTEM_DEPS
    "Resolve dependencies from the system rather than pinned sources" ON)
option(TECS_BUILD_LUA
    "Generate FFI bindings and compile the Teal sources" ON)
option(TECS_RUNTIME_SHADERS
    "Link a shader compiler, for development. Releases use packaged artifacts." ON)

set(TECS_SPEC_OUT "${CMAKE_BINARY_DIR}/spec" CACHE PATH
    "Where compiled Teal specs are written")
set(TECS_LUA_OUT "${CMAKE_BINARY_DIR}/lua" CACHE PATH
    "Where compiled Lua and generated bindings are written")

# ---------------------------------------------------------------- dependencies

if(NOT TECS_SYSTEM_DEPS)
    # Pinned revisions for anything shipped. Left declared rather than fetched
    # by default because building this set from source is a long build, and
    # desktop development does not need it.
    include(cmake/Pinned.cmake)
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL3 REQUIRED IMPORTED_TARGET sdl3)
    pkg_check_modules(SDL3_IMAGE REQUIRED IMPORTED_TARGET sdl3-image)
    pkg_check_modules(SDL3_MIXER REQUIRED IMPORTED_TARGET sdl3-mixer)
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

# Runtime search paths are relative, so a package finds its own libraries
# wherever it is unpacked.
#
# Both forms are needed, because two different things load these libraries. The
# executable-relative one is for the host in bin. The loader-relative one is for
# a library resolving a sibling, which is what happens when the process is not
# ours at all: a command line tool or a resource pipeline runs under a plain
# luajit, and there `@executable_path` is that interpreter's own bin directory,
# so a package would reach past itself into whatever the machine has installed.
if(APPLE)
    set(CMAKE_INSTALL_RPATH "@executable_path/../lib;@loader_path")
elseif(UNIX)
    set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib;$ORIGIN")
endif()
set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)

# A development build also needs to find the system libraries it linked
# against. A packaged one must not: leaving a developer's package-manager path
# in a shipped binary is how a build that works only on the machine that made
# it gets shipped.
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH ${TECS_SYSTEM_DEPS})

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
set(TECS_CJSON_SOURCES
    vendor/cjson/lua_cjson.c vendor/cjson/strbuf.c
    vendor/cjson/g_fmt.c vendor/cjson/dtoa.c)
set(TECS_CJSON_DEFINES USE_INTERNAL_FPCONV MULTIPLE_THREADS)

add_library(tecs_cjson STATIC ${TECS_CJSON_SOURCES})
target_compile_definitions(tecs_cjson PRIVATE ${TECS_CJSON_DEFINES})
target_include_directories(tecs_cjson PRIVATE ${LUAJIT_INCLUDE_DIRS})
set_target_properties(tecs_cjson PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(cjson MODULE ${TECS_CJSON_SOURCES})
target_compile_definitions(cjson PRIVATE ${TECS_CJSON_DEFINES})
target_include_directories(cjson PRIVATE ${LUAJIT_INCLUDE_DIRS})
set_target_properties(cjson PROPERTIES
    PREFIX "" SUFFIX ".so"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_link_libraries(cjson PRIVATE ${LUAJIT_LINK_LIBRARIES})

add_library(tecs_worker SHARED
    native/worker.c native/logsink.c native/taskpool.c
    native/framepipeline.c native/luamods.c)
set_target_properties(tecs_worker PROPERTIES
    OUTPUT_NAME tecsworker
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_link_libraries(tecs_worker PRIVATE
    PkgConfig::SDL3 PkgConfig::LUAJIT)
# Box2D's headers, for the task callback types the pool is declared with. No
# Box2D symbol is referenced: the solver calls in, through pointers it was
# given, so this links nothing.
target_include_directories(tecs_worker PRIVATE ${BOX2D_INCLUDE_DIR})

# SPIRV-Cross ships static archives only, and the FFI needs a shared object.
# Whole-archive linking is deliberate: the C API's symbols are not referenced
# from this stub, so without it the linker would discard all of them.
add_library(tecs_spirvcross SHARED native/spirvcross.c)
set_target_properties(tecs_spirvcross PROPERTIES
    OUTPUT_NAME spirvcrossc
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_include_directories(tecs_spirvcross PRIVATE ${SPIRV_CROSS_INCLUDE_DIRS})

set(TECS_SPVC_ARCHIVES
    spirv-cross-c spirv-cross-cpp spirv-cross-msl
    spirv-cross-glsl spirv-cross-hlsl spirv-cross-reflect
    spirv-cross-util spirv-cross-core)
set(TECS_SPVC_WHOLE "")
foreach(archive IN LISTS TECS_SPVC_ARCHIVES)
    find_library(SPVC_${archive}_LIB NAMES ${archive}
        HINTS ${SPIRV_CROSS_LIBRARY_DIRS})
    if(NOT SPVC_${archive}_LIB)
        message(FATAL_ERROR "SPIRV-Cross archive ${archive} not found")
    endif()
    list(APPEND TECS_SPVC_WHOLE "${SPVC_${archive}_LIB}")
endforeach()

if(APPLE)
    target_link_options(tecs_spirvcross PRIVATE -Wl,-all_load)
else()
    target_link_options(tecs_spirvcross PRIVATE -Wl,--whole-archive)
endif()
target_link_libraries(tecs_spirvcross PRIVATE ${TECS_SPVC_WHOLE})
if(NOT APPLE)
    target_link_options(tecs_spirvcross PRIVATE -Wl,--no-whole-archive)
endif()
set_target_properties(tecs_spirvcross PROPERTIES LINKER_LANGUAGE CXX)

# The application host. SDL owns the loop, so this implements SDL's callback
# entry points and reaches Lua through the Lua C API.
add_executable(tecs native/host.c native/luamods.c)

# Where content sits relative to the executable, in the tree this build
# installs. The host resolves its entry chunk and the engine resolves assets
# against it, so the layout is described once here instead of being sniffed for
# at run time.
set(TECS_CONTENT "../share/tecs/lua/" CACHE STRING
    "Content directory relative to the installed executable")
target_compile_definitions(tecs PRIVATE TECS_CONTENT="${TECS_CONTENT}")
set_target_properties(tecs PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_link_libraries(tecs PRIVATE PkgConfig::SDL3 PkgConfig::LUAJIT)

if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    # LuaJIT on x64 macOS needs its allocations below 2GB.
    target_link_options(tecs PRIVATE
        -pagezero_size 10000 -image_base 100000000)
endif()

# ------------------------------------------------------- generated bindings

if(TECS_BUILD_LUA)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(GEN "${TECS_LUA_OUT}/tecs/ffi")
    file(MAKE_DIRECTORY "${GEN}")

    # Bindings must be generated with the same preprocessor state the C is
    # compiled with. A header that declares different things under NDEBUG
    # would otherwise produce a binding for a function the build does not
    # have, which surfaces as a link error far from the cause.
    set(TECS_CDEF_DEFINES "")
    if(CMAKE_BUILD_TYPE MATCHES "Release|RelWithDebInfo|MinSizeRel")
        list(APPEND TECS_CDEF_DEFINES --define NDEBUG)
    endif()

    # Include directories come from dependency discovery rather than from a
    # hardcoded package-manager prefix, which is what lets this cross-compile.
    function(tecs_cdef name header keep prefix)
        set(includes "")
        # The header is named the way a C file would name it, so it is resolved
        # against the same directories the generator searches. Found, it becomes
        # a dependency: editing a header this project owns has to regenerate its
        # binding, and without this the build is happy to link Lua declarations
        # that no longer describe the C. That failure is a wrong offset rather
        # than a missing symbol, so it does not announce itself.
        set(headerPath "")
        foreach(dir IN LISTS ARGN)
            list(APPEND includes --include ${dir})
            if(headerPath STREQUAL "" AND EXISTS "${dir}/${header}")
                set(headerPath "${dir}/${header}")
            endif()
        endforeach()
        add_custom_command(
            OUTPUT "${GEN}/${name}cdef.lua" "${GEN}/${name}const.lua"
            COMMAND ${Python3_EXECUTABLE}
                "${CMAKE_SOURCE_DIR}/scripts/gencdef.py"
                --header ${header} ${includes} ${TECS_CDEF_DEFINES}
                --keep ${keep} --define-prefix ${prefix}
                --defines-out "${GEN}/${name}const.lua"
                --out "${GEN}/${name}cdef.lua"
            DEPENDS "${CMAKE_SOURCE_DIR}/scripts/gencdef.py" ${headerPath}
            COMMENT "Generating ${name} FFI bindings"
            VERBATIM)
    endfunction()

    tecs_cdef(sdl3 SDL3/SDL.h /SDL3/ SDL_ ${SDL3_INCLUDE_DIRS})
    tecs_cdef(sdl3image SDL3_image/SDL_image.h /SDL3_image/ IMG_
        ${SDL3_IMAGE_INCLUDE_DIRS} ${SDL3_INCLUDE_DIRS})
    tecs_cdef(sdl3net SDL3_net/SDL_net.h /SDL3_net/ NET_
        ${SDL3_NET_INCLUDE_DIR} ${SDL3_INCLUDE_DIRS})
    tecs_cdef(sdl3mixer SDL3_mixer/SDL_mixer.h /SDL3_mixer/ MIX_
        ${SDL3_MIXER_INCLUDE_DIRS} ${SDL3_INCLUDE_DIRS})
    tecs_cdef(box2d box2d/box2d.h /box2d/ B2_ ${BOX2D_INCLUDE_DIR})
    tecs_cdef(shaderc shaderc/shaderc.h /shaderc/ shaderc_
        ${SHADERC_INCLUDE_DIRS})
    # pkg-config points into the spirv_cross directory rather than at its
    # parent, so the header is named relative to that.
    tecs_cdef(spvc spirv_cross_c.h /spirv_cross/ SPVC_
        ${SPIRV_CROSS_INCLUDE_DIRS})

    # The engine's own native API. Generated the same way as a third-party
    # header so the binding cannot drift from the C even though both live here.
    tecs_cdef(worker worker.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")
    tecs_cdef(logsink logsink.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")
    tecs_cdef(taskpool taskpool.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")
    tecs_cdef(framepipeline framepipeline.h /native/ TECS_
        "${CMAKE_SOURCE_DIR}/native")

    # Each library also gets a table of function pointers, taken at build
    # time. A target that cannot dlopen still links, and the engine calls
    # through the table rather than through a handle it had to resolve.
    set(TECS_REGISTRY_SOURCES "")
    set(TECS_REGISTRY_ENTRIES "")
    set(TECS_REGISTRY_PAIRS "")

    function(tecs_registry name struct prefix)
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
        set(TECS_REGISTRY_PAIRS ${TECS_REGISTRY_PAIRS} "${name}:${struct}"
            PARENT_SCOPE)
        set(TECS_REGISTRY_SOURCES ${TECS_REGISTRY_SOURCES} "${source}"
            PARENT_SCOPE)
        set(TECS_REGISTRY_ENTRIES
            "${TECS_REGISTRY_ENTRIES}TECS_API(${name}, ${struct})\n"
            PARENT_SCOPE)
    endfunction()

    tecs_registry(sdl3 TecsSdl3Api SDL_ SDL3/SDL.h)
    tecs_registry(sdl3image TecsSdl3ImageApi IMG_ SDL3_image/SDL_image.h)
    tecs_registry(sdl3net TecsSdl3NetApi NET_ SDL3_net/SDL_net.h)
    tecs_registry(sdl3mixer TecsSdl3MixerApi MIX_ SDL3_mixer/SDL_mixer.h)
    tecs_registry(box2d TecsBox2dApi b2 box2d/box2d.h)
    tecs_registry(worker TecsWorkerApi tecs worker.h)
    tecs_registry(logsink TecsLogsinkApi tecs logsink.h)
    tecs_registry(taskpool TecsTaskpoolApi tecs taskpool.h)
    tecs_registry(framepipeline TecsFramePipelineApi tecs framepipeline.h)

    # Shader compilation is a development capability. A release consumes
    # packaged artifacts, so a target built without it links no compiler and
    # the registry simply has no entry for one.
    if(TECS_RUNTIME_SHADERS)
        tecs_registry(shaderc TecsShadercApi shaderc_ shaderc/shaderc.h)
        tecs_registry(spvc TecsSpvcApi spvc_ spirv_cross_c.h)
    endif()

    # The same mapping the loader needs, so the two cannot drift. It was a
    # hand-written table, and adding a library to the build without adding it
    # here failed only under the host, where the registry path is the one that
    # runs.
    set(TECS_REGISTRY_LUA
        "-- Generated. Library name to the struct its registry table has.\nreturn {\n")
    foreach(pair IN LISTS TECS_REGISTRY_PAIRS)
        string(REPLACE ":" ";" parts "${pair}")
        list(GET parts 0 pairName)
        list(GET parts 1 pairStruct)
        set(TECS_REGISTRY_LUA
            "${TECS_REGISTRY_LUA}    ${pairName} = \"${pairStruct}\",\n")
    endforeach()
    file(WRITE "${TECS_LUA_OUT}/tecs/ffi/registrystructs.lua"
        "${TECS_REGISTRY_LUA}}\n")

    file(WRITE "${CMAKE_BINARY_DIR}/generated/registry_entries.h"
        "/* Generated. Which libraries this target links. */\n"
        "${TECS_REGISTRY_ENTRIES}")

    add_library(tecs_registry STATIC
        native/registry.c ${TECS_REGISTRY_SOURCES})
    target_include_directories(tecs_registry PUBLIC
        "${CMAKE_BINARY_DIR}/generated" "${CMAKE_SOURCE_DIR}/native")
    target_link_libraries(tecs_registry PUBLIC
        PkgConfig::SDL3 PkgConfig::SDL3_IMAGE PkgConfig::SDL3_MIXER
        PkgConfig::LUAJIT ${BOX2D_LIBRARY} ${SDL3_NET_LIBRARY})

    # Taking the address of a shader compiler's functions means linking it.
    # That is the coupling TECS_RUNTIME_SHADERS exists to remove: a release
    # generates no table for them and links neither.
    if(TECS_RUNTIME_SHADERS)
        target_link_libraries(tecs_registry PUBLIC
            PkgConfig::SHADERC tecs_spirvcross)
    endif()
    target_include_directories(tecs_registry PRIVATE
        ${BOX2D_INCLUDE_DIR} ${SDL3_NET_INCLUDE_DIR}
        ${SHADERC_INCLUDE_DIRS} ${SPIRV_CROSS_INCLUDE_DIRS})

    # Linked here rather than where the executables are declared, because the
    # registry's sources are generated from bindings produced above.
    # The host also links the worker library, because its table holds the
    # addresses of that library's functions.
    target_link_libraries(tecs PRIVATE tecs_registry tecs_worker tecs_cjson)
    target_link_libraries(tecs_worker PRIVATE tecs_registry tecs_cjson)

    add_custom_target(tecs_bindings ALL DEPENDS
        "${GEN}/workercdef.lua" "${GEN}/logsinkcdef.lua"
        "${GEN}/taskpoolcdef.lua" "${GEN}/framepipelinecdef.lua"
        "${GEN}/sdl3cdef.lua" "${GEN}/sdl3imagecdef.lua" "${GEN}/sdl3netcdef.lua"
        "${GEN}/sdl3mixercdef.lua"
        "${GEN}/box2dcdef.lua" "${GEN}/shaderccdef.lua"
        "${GEN}/spvccdef.lua")

    # Teal compilation. Kept as one custom target rather than per-file rules
    # because the compiler resolves the module graph itself.
    # CONFIGURE_DEPENDS so adding a source is a build, not a reconfigure.
    # Without it a new module is silently absent until someone remembers.
    file(GLOB_RECURSE TECS_TL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/*.tl")
    add_custom_target(tecs_lua ALL
        # tl searches include paths last-first, so ours come last and win.
        COMMAND tl -q gen -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
            -I "${CMAKE_SOURCE_DIR}/vendor/tl"
            --root "${CMAKE_SOURCE_DIR}/src"
            --output-dir "${TECS_LUA_OUT}" ${TECS_TL}
        DEPENDS ${TECS_TL} tecs_bindings
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Compiling Teal sources"
        VERBATIM)

    # Content lives beside the compiled Lua, because that directory is the
    # content root a development run resolves against and the one an install
    # copies. CONFIGURE_DEPENDS so adding a shader is a build, not a
    # reconfigure.
    file(GLOB_RECURSE TECS_ASSET_FILES CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/assets/*")
    add_custom_target(tecs_assets ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_SOURCE_DIR}/assets" "${TECS_LUA_OUT}"
        DEPENDS ${TECS_ASSET_FILES}
        COMMENT "Copying assets"
        VERBATIM)

    # Specs written in Teal, compiled the same way. The ECS suites are written
    # in Teal and the engine's in Lua, so both forms are built and Busted is
    # pointed at both trees.
    file(GLOB_RECURSE TECS_SPEC_TL CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/spec/*.tl")
    if(TECS_SPEC_TL)
        add_custom_target(tecs_spec ALL
            COMMAND luajit "${CMAKE_SOURCE_DIR}/scripts/compile_specs.lua"
                "${CMAKE_SOURCE_DIR}/spec" "${TECS_SPEC_OUT}"
                "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
            DEPENDS ${TECS_SPEC_TL} tecs_lua
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            COMMENT "Compiling Teal specs"
            VERBATIM)
    endif()
endif()

# --------------------------------------------------------------- packaging

# Records how the tree was built, so a check can tell a development install
# from a shippable one rather than guessing from what it finds.
file(WRITE "${CMAKE_BINARY_DIR}/build-info.txt"
    "systemDeps=${TECS_SYSTEM_DEPS}\n"
    "system=${CMAKE_SYSTEM_NAME}\n"
    "arch=${CMAKE_SYSTEM_PROCESSOR}\n")
install(FILES "${CMAKE_BINARY_DIR}/build-info.txt"
    DESTINATION share/tecs)

install(TARGETS tecs RUNTIME DESTINATION bin)
install(TARGETS tecs_worker tecs_spirvcross LIBRARY DESTINATION lib)
install(TARGETS cjson LIBRARY DESTINATION lib)
if(TECS_BUILD_LUA)
    install(DIRECTORY "${TECS_LUA_OUT}/" DESTINATION share/tecs/lua)
endif()

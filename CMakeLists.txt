cmake_minimum_required(VERSION 3.24)
# C++ is enabled only to link SPIRV-Cross, which is a C++ library behind a C
# API. No engine source is C++.
project(tecs C CXX)

# The canonical build. Make, Gradle, and Xcode are thin wrappers over this, so
# there is one description of how the engine is assembled rather than one per
# platform to keep in step.

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

option(TECS_SYSTEM_DEPS "Resolve dependencies from the system rather than pinned sources" ON)
option(TECS_BUILD_LUA "Generate FFI bindings and compile the Teal sources" ON)
option(TECS_RUNTIME_SHADERS "Link a shader compiler, for development. Releases use packaged artifacts." ON)

# One executable and nothing beside it.
#
# Two things happen together and neither is useful alone: every dependency is
# linked as an archive rather than loaded as a library, and the whole content
# root is deflated into an array compiled in. The first is possible because the
# engine already never calls `ffi.load` under its own host: native/registry.c
# installs a table of function pointers taken at build time and
# src/tecs/ffi/loader.tl prefers it, so static linking here is a link
# configuration rather than a design change.
#
# What it costs is the ways of running this tree that are not the host. A spec
# under a plain interpreter loads libraries by name and there are none to load,
# so this is its own preset rather than a flag on the packaged one, and
# `make test` and `make test-package` go on testing what they tested.
option(TECS_SINGLE_FILE "Link everything into one executable and carry the content root inside it" OFF)

if(TECS_SINGLE_FILE AND TECS_SYSTEM_DEPS)
    message(
        FATAL_ERROR
        "tecs: TECS_SINGLE_FILE needs pinned sources. A package manager installs shared libraries, and "
        "there is nothing to link statically. Configure the macos-arm64-single preset."
    )
endif()

set(TECS_SPEC_OUT "${CMAKE_BINARY_DIR}/spec" CACHE PATH "Where compiled Teal specs are written")
set(TECS_LUA_OUT "${CMAKE_BINARY_DIR}/lua" CACHE PATH "Where compiled Lua and generated bindings are written")

# The Teal sources are a build artifact too, even though nothing compiles them.
# `tl` reads types out of `.tl` and a compiled `.lua` carries none, so a game
# type-checking against an installed tecs needs these on its include path. They
# are staged beside the compiled Lua rather than left in the source tree so the
# CLI finds them at the same place in a build tree and in an installed one: the
# content root's sibling, in both.
set(TECS_TEAL_OUT "${CMAKE_BINARY_DIR}/teal" CACHE PATH "Where the Teal type information is staged")

# Which chunk the host loads when it is not given one. A release of the command
# line tool bakes in the CLI; everything else bakes in the demo and reaches the
# CLI through `--entry`, which is the seam that already existed for benchmarks.
set(TECS_ENTRY "main.lua" CACHE STRING "Entry chunk, relative to the content root")

# ---------------------------------------------------------------- dependencies

# Two ways of resolving the same set, and everything below this section is
# written against neither. Each branch answers the same two questions and
# nothing after it knows which one ran:
#
#   tecs::<library>              what to link, one target per library
#   TECS_<LIBRARY>_INCLUDE_DIRS  where its headers are, for the binding
#                                generator and for the C that includes them
#
# Naming a variable only one branch defines is what kept the pinned build from
# reaching generate, and it fails as a missing include or an empty link line
# rather than as anything that says which side is at fault.

if(NOT TECS_SYSTEM_DEPS)
    # Pinned revisions for anything shipped. A long build, which is why
    # desktop development uses the branch below instead.
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
        message(FATAL_ERROR "SDL3_net not found. Set SDL3_NET_INCLUDE_DIR and SDL3_NET_LIBRARY.")
    endif()
    # Its .pc file still answers what version this is, which is the one thing
    # the version check needs from it.
    pkg_check_modules(SDL3_NET QUIET sdl3-net)
    pkg_check_modules(LUAJIT REQUIRED IMPORTED_TARGET luajit)
    pkg_check_modules(SHADERC REQUIRED IMPORTED_TARGET shaderc)
    pkg_check_modules(SPIRV_CROSS REQUIRED spirv-cross-c)
    pkg_check_modules(CURL REQUIRED IMPORTED_TARGET libcurl)
    pkg_check_modules(ZLIB REQUIRED IMPORTED_TARGET zlib)

    # Box2D ships no pkg-config or CMake config, so it is located directly.
    find_path(BOX2D_INCLUDE_DIR box2d/box2d.h)
    find_library(BOX2D_LIBRARY NAMES box2d)
    if(NOT BOX2D_INCLUDE_DIR OR NOT BOX2D_LIBRARY)
        message(FATAL_ERROR "Box2D 3 not found. Set BOX2D_INCLUDE_DIR and BOX2D_LIBRARY.")
    endif()

    include(cmake/SystemVersions.cmake)

    # The common names, from what pkg-config and find_library answered. The two
    # located by hand get a target built around them, so a consumer links a
    # library the same way whichever way it was found.
    add_library(tecs::sdl3 ALIAS PkgConfig::SDL3)
    add_library(tecs::sdl3image ALIAS PkgConfig::SDL3_IMAGE)
    add_library(tecs::sdl3mixer ALIAS PkgConfig::SDL3_MIXER)
    add_library(tecs::luajit ALIAS PkgConfig::LUAJIT)
    add_library(tecs::curl ALIAS PkgConfig::CURL)
    add_library(tecs::zlib ALIAS PkgConfig::ZLIB)

    add_library(tecs_sdl3net INTERFACE)
    target_link_libraries(tecs_sdl3net INTERFACE ${SDL3_NET_LIBRARY})
    target_include_directories(tecs_sdl3net INTERFACE ${SDL3_NET_INCLUDE_DIR})
    add_library(tecs::sdl3net ALIAS tecs_sdl3net)

    add_library(tecs_box2d INTERFACE)
    target_link_libraries(tecs_box2d INTERFACE ${BOX2D_LIBRARY})
    target_include_directories(tecs_box2d INTERFACE ${BOX2D_INCLUDE_DIR})
    add_library(tecs::box2d ALIAS tecs_box2d)

    if(TECS_RUNTIME_SHADERS)
        add_library(tecs::shaderc ALIAS PkgConfig::SHADERC)
    endif()

    set(TECS_SDL3_INCLUDE_DIRS ${SDL3_INCLUDE_DIRS})
    set(TECS_SDL3_IMAGE_INCLUDE_DIRS ${SDL3_IMAGE_INCLUDE_DIRS})
    set(TECS_SDL3_NET_INCLUDE_DIRS ${SDL3_NET_INCLUDE_DIR})
    set(TECS_SDL3_MIXER_INCLUDE_DIRS ${SDL3_MIXER_INCLUDE_DIRS})
    set(TECS_BOX2D_INCLUDE_DIRS ${BOX2D_INCLUDE_DIR})
    set(TECS_LUAJIT_INCLUDE_DIRS ${LUAJIT_INCLUDE_DIRS})
    set(TECS_SHADERC_INCLUDE_DIRS ${SHADERC_INCLUDE_DIRS})
    set(TECS_SPVC_INCLUDE_DIRS ${SPIRV_CROSS_INCLUDE_DIRS})
    set(TECS_SPVC_LIBRARY_DIRS ${SPIRV_CROSS_LIBRARY_DIRS})
    set(TECS_CURL_INCLUDE_DIRS ${CURL_INCLUDE_DIRS})
    set(TECS_ZLIB_INCLUDE_DIRS ${ZLIB_INCLUDE_DIRS})
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
set(TECS_CJSON_SOURCES vendor/cjson/lua_cjson.c vendor/cjson/strbuf.c vendor/cjson/g_fmt.c vendor/cjson/dtoa.c)
set(TECS_CJSON_DEFINES USE_INTERNAL_FPCONV MULTIPLE_THREADS)

add_library(tecs_cjson STATIC ${TECS_CJSON_SOURCES})
target_compile_definitions(tecs_cjson PRIVATE ${TECS_CJSON_DEFINES})
target_link_libraries(tecs_cjson PRIVATE tecs::luajit)
set_target_properties(tecs_cjson PROPERTIES POSITION_INDEPENDENT_CODE ON)

# The loadable copy exists for the ways of running this tree that are not the
# host: a spec or a tool under a plain interpreter requires `cjson` the ordinary
# way. A single-file build has no such way, and a `.so` beside a binary that is
# meant to be the only file is the thing it is meant not to have.
if(NOT TECS_SINGLE_FILE)
    add_library(cjson MODULE ${TECS_CJSON_SOURCES})
    target_compile_definitions(cjson PRIVATE ${TECS_CJSON_DEFINES})
    set_target_properties(
        cjson
        PROPERTIES PREFIX "" SUFFIX ".so" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    )
    target_link_libraries(cjson PRIVATE tecs::luajit)
endif()

# Shared everywhere but a single-file build, where every library the FFI would
# have loaded by name is an archive inside the executable instead.
if(TECS_SINGLE_FILE)
    set(TECS_LIBRARY_KIND STATIC)
else()
    set(TECS_LIBRARY_KIND SHARED)
endif()

add_library(
    tecs_worker
    ${TECS_LIBRARY_KIND}
    native/worker.c
    native/logsink.c
    native/taskpool.c
    native/luamods.c
)
set_target_properties(tecs_worker PROPERTIES OUTPUT_NAME tecsworker LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_link_libraries(tecs_worker PRIVATE tecs::sdl3 tecs::luajit)
# Box2D's headers, for the task callback types the pool is declared with. No
# Box2D symbol is referenced: the solver calls in, through pointers it was
# given, so this links nothing.
target_include_directories(tecs_worker PRIVATE ${TECS_BOX2D_INCLUDE_DIRS})

# SPIRV-Cross ships static archives only, and the FFI needs a shared object.
# Whole-archive linking is deliberate: the C API's symbols are not referenced
# from this stub, so without it the linker would discard all of them.
#
# A single-file build needs no shared object, because the FFI reaches the C API
# through the registry rather than through a handle it had to resolve. The stub
# collapses into the executable and the whole-archive options move with it.
add_library(tecs_spirvcross ${TECS_LIBRARY_KIND} native/spirvcross.c)
set_target_properties(
    tecs_spirvcross
    PROPERTIES OUTPUT_NAME spirvcrossc LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)
target_include_directories(tecs_spirvcross PRIVATE ${TECS_SPVC_INCLUDE_DIRS})

set(TECS_SPVC_ARCHIVES
    spirv-cross-c
    spirv-cross-cpp
    spirv-cross-msl
    spirv-cross-glsl
    spirv-cross-hlsl
    spirv-cross-reflect
    spirv-cross-util
    spirv-cross-core
)
# A pinned build has these as targets and an installed one as files on disk,
# and SPIRV-Cross names them the same either way. So each is taken as a target
# where one exists and looked for otherwise, rather than by asking which
# dependency branch ran.
set(TECS_SPVC_WHOLE "")
foreach(archive IN LISTS TECS_SPVC_ARCHIVES)
    if(TARGET ${archive})
        list(APPEND TECS_SPVC_WHOLE ${archive})
        continue()
    endif()
    find_library(SPVC_${archive}_LIB NAMES ${archive} HINTS ${TECS_SPVC_LIBRARY_DIRS})
    if(NOT SPVC_${archive}_LIB)
        message(FATAL_ERROR "SPIRV-Cross archive ${archive} not found")
    endif()
    list(APPEND TECS_SPVC_WHOLE "${SPVC_${archive}_LIB}")
endforeach()

# Whole-archive linking only applies where something is actually being linked.
# A static `tecs_spirvcross` is an archive of one object file and the eight
# below stay separate archives, so the options move to the executable that
# joins them, which is the only place a linker sees them all at once.
if(NOT TECS_SINGLE_FILE)
    if(APPLE)
        target_link_options(tecs_spirvcross PRIVATE -Wl,-all_load)
    else()
        target_link_options(tecs_spirvcross PRIVATE -Wl,--whole-archive)
    endif()
    target_link_libraries(tecs_spirvcross PRIVATE ${TECS_SPVC_WHOLE})
    if(NOT APPLE)
        target_link_options(tecs_spirvcross PRIVATE -Wl,--no-whole-archive)
    endif()
else()
    target_link_libraries(tecs_spirvcross PUBLIC ${TECS_SPVC_WHOLE})
endif()
set_target_properties(tecs_spirvcross PROPERTIES LINKER_LANGUAGE CXX)

# The application host. SDL owns the loop, so this implements SDL's callback
# entry points and reaches Lua through the Lua C API.
add_executable(tecs native/host.c native/luamods.c native/mcodearena.c)

# Where content sits relative to the executable, in the tree this build
# installs. The host resolves its entry chunk and the engine resolves assets
# against it, so the layout is described once here instead of being sniffed for
# at run time.
set(TECS_CONTENT "../share/tecs/lua/" CACHE STRING "Content directory relative to the installed executable")
target_compile_definitions(tecs PRIVATE TECS_CONTENT="${TECS_CONTENT}" TECS_ENTRY="${TECS_ENTRY}")
set_target_properties(tecs PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_link_libraries(tecs PRIVATE tecs::sdl3 tecs::luajit)

if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64")
    # LuaJIT on x64 macOS needs its allocations below 2GB.
    target_link_options(tecs PRIVATE -pagezero_size 10000 -image_base 100000000)
endif()

# A single-file build needs no whole-archive option anywhere, and the reason is
# the registry. `-all_load` exists on the shared stub because native/spirvcross.c
# references none of the C API's symbols, so a linker resolving normally would
# discard all of them. Here the generated `spvcapi.c` takes the address of every
# one by name, which is exactly the reference ordinary archive resolution needs.
# The same holds for SDL, Box2D, curl and the rest: the registry is what makes
# them reachable, and it is what makes them linkable.

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
    # Types a library's headers use and do not declare, recovered by the
    # generator from the headers they include. Read here rather than passed,
    # because only curl needs any and every other call site would carry an
    # empty argument for it. Reset after the call that sets it.
    set(TECS_CDEF_NEED "")

    function(tecs_cdef name header keep prefix)
        set(includes "")
        # `keep` is a list, because a library's declarations do not always sit
        # in one file: zlib's types are in zconf.h and its functions in zlib.h,
        # and a binding with only one of those does not parse.
        set(filters "")
        foreach(path IN LISTS keep)
            list(APPEND filters --keep ${path})
        endforeach()
        set(needs "")
        foreach(type IN LISTS TECS_CDEF_NEED)
            list(APPEND needs --need ${type})
        endforeach()
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
            COMMAND
                ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/gencdef.py" --header ${header} ${includes}
                ${TECS_CDEF_DEFINES} ${filters} ${needs} --define-prefix ${prefix} --defines-out
                "${GEN}/${name}const.lua" --out "${GEN}/${name}cdef.lua"
            DEPENDS "${CMAKE_SOURCE_DIR}/scripts/gencdef.py" ${headerPath}
            COMMENT "Generating ${name} FFI bindings"
            VERBATIM
        )
    endfunction()

    tecs_cdef(sdl3 SDL3/SDL.h /SDL3/ SDL_ ${TECS_SDL3_INCLUDE_DIRS})
    tecs_cdef(
        sdl3image
        SDL3_image/SDL_image.h
        /SDL3_image/
        IMG_
        ${TECS_SDL3_IMAGE_INCLUDE_DIRS}
        ${TECS_SDL3_INCLUDE_DIRS}
    )
    tecs_cdef(sdl3net SDL3_net/SDL_net.h /SDL3_net/ NET_ ${TECS_SDL3_NET_INCLUDE_DIRS} ${TECS_SDL3_INCLUDE_DIRS})
    tecs_cdef(
        sdl3mixer
        SDL3_mixer/SDL_mixer.h
        /SDL3_mixer/
        MIX_
        ${TECS_SDL3_MIXER_INCLUDE_DIRS}
        ${TECS_SDL3_INCLUDE_DIRS}
    )
    tecs_cdef(box2d box2d/box2d.h /box2d/ B2_ ${TECS_BOX2D_INCLUDE_DIRS})
    tecs_cdef(shaderc shaderc/shaderc.h /shaderc/ shaderc_ ${TECS_SHADERC_INCLUDE_DIRS})
    # The header is named without a directory, because that is how it is
    # reached from both layouts: an installed SPIRV-Cross puts it in a
    # spirv_cross directory pkg-config points into, and its source tree has it
    # at the top. The two headers are named for the same reason.
    tecs_cdef(spvc spirv_cross_c.h "/spirv_cross_c.h;/spirv.h" SPVC_ ${TECS_SPVC_INCLUDE_DIRS})

    # zlib splits itself in two: zconf.h carries the typedefs its declarations
    # are written in, so a binding built from zlib.h alone names types it never
    # declares and does not parse. `off_t` is the platform's, and reaches the
    # binding through the file offset in `gz_header`.
    set(TECS_CDEF_NEED off_t)
    tecs_cdef(zlib zlib.h "/zlib.h;/zconf.h" Z ${TECS_ZLIB_INCLUDE_DIRS})
    set(TECS_CDEF_NEED "")

    # curl's public headers, named one at a time rather than by their directory,
    # so mprintf.h stays out. It declares curl's own printf family, which
    # nothing here calls and which would pull the platform's `FILE` and every
    # struct inside it into a binding the whole engine shares.
    #
    # What is left still refers to four types curl's headers use and do not
    # declare, since they belong to the platform. The generator recovers those
    # from the same preprocessor output rather than having them written here,
    # because a hand-written layout is an ABI claim nothing checks.
    set(TECS_CDEF_NEED socklen_t time_t fd_set "struct sockaddr")
    tecs_cdef(
        curl
        curl/curl.h
        "/curl/curl.h;/curl/easy.h;/curl/multi.h;/curl/system.h;/curl/urlapi.h;/curl/options.h;/curl/header.h;/curl/websockets.h"
        CURL
        ${TECS_CURL_INCLUDE_DIRS}
    )
    set(TECS_CDEF_NEED "")

    # The engine's own native API. Generated the same way as a third-party
    # header so the binding cannot drift from the C even though both live here.
    tecs_cdef(worker worker.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")
    tecs_cdef(logsink logsink.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")
    tecs_cdef(taskpool taskpool.h /native/ TECS_ "${CMAKE_SOURCE_DIR}/native")

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
            COMMAND
                ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/genregistry.py" --cdef "${GEN}/${name}cdef.lua"
                --name ${name} --struct ${struct} --prefix "${prefix}" ${headers} --source-out "${source}" --cdef-out
                "${GEN}/${name}apicdef.lua"
            DEPENDS "${GEN}/${name}cdef.lua" "${CMAKE_SOURCE_DIR}/scripts/genregistry.py"
            COMMENT "Generating ${name} native API table"
            VERBATIM
        )
        set(TECS_REGISTRY_PAIRS ${TECS_REGISTRY_PAIRS} "${name}:${struct}" PARENT_SCOPE)
        set(TECS_REGISTRY_SOURCES ${TECS_REGISTRY_SOURCES} "${source}" PARENT_SCOPE)
        set(TECS_REGISTRY_ENTRIES "${TECS_REGISTRY_ENTRIES}TECS_API(${name}, ${struct})\n" PARENT_SCOPE)
    endfunction()

    tecs_registry(sdl3 TecsSdl3Api SDL_ SDL3/SDL.h)
    tecs_registry(sdl3image TecsSdl3ImageApi IMG_ SDL3_image/SDL_image.h)
    tecs_registry(sdl3net TecsSdl3NetApi NET_ SDL3_net/SDL_net.h)
    tecs_registry(sdl3mixer TecsSdl3MixerApi MIX_ SDL3_mixer/SDL_mixer.h)
    tecs_registry(box2d TecsBox2dApi b2 box2d/box2d.h)
    tecs_registry(curl TecsCurlApi curl_ curl/curl.h)
    # zlib names its functions after what they do rather than after itself, so
    # there is no prefix to filter on. Nothing else is in its binding, since
    # only its own two headers are kept, so exporting all of it is exact.
    tecs_registry(zlib TecsZlibApi "" zlib.h)
    tecs_registry(worker TecsWorkerApi tecs worker.h)
    tecs_registry(logsink TecsLogsinkApi tecs logsink.h)
    tecs_registry(taskpool TecsTaskpoolApi tecs taskpool.h)

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
    set(TECS_REGISTRY_LUA "-- Generated. Library name to the struct its registry table has.\nreturn {\n")
    foreach(pair IN LISTS TECS_REGISTRY_PAIRS)
        string(REPLACE ":" ";" parts "${pair}")
        list(GET parts 0 pairName)
        list(GET parts 1 pairStruct)
        set(TECS_REGISTRY_LUA "${TECS_REGISTRY_LUA}    ${pairName} = \"${pairStruct}\",\n")
    endforeach()
    file(WRITE "${TECS_LUA_OUT}/tecs/ffi/registrystructs.lua" "${TECS_REGISTRY_LUA}}\n")

    file(
        WRITE "${CMAKE_BINARY_DIR}/generated/registry_entries.h"
        "/* Generated. Which libraries this target links. */\n"
        "${TECS_REGISTRY_ENTRIES}"
    )

    add_library(tecs_registry STATIC native/registry.c ${TECS_REGISTRY_SOURCES})
    target_include_directories(tecs_registry PUBLIC "${CMAKE_BINARY_DIR}/generated" "${CMAKE_SOURCE_DIR}/native")
    target_link_libraries(
        tecs_registry
        PUBLIC tecs::sdl3 tecs::sdl3image tecs::sdl3mixer tecs::sdl3net tecs::luajit tecs::curl tecs::zlib tecs::box2d
    )

    # Taking the address of a shader compiler's functions means linking it.
    # That is the coupling TECS_RUNTIME_SHADERS exists to remove: a release
    # generates no table for them and links neither.
    if(TECS_RUNTIME_SHADERS)
        target_link_libraries(tecs_registry PUBLIC tecs::shaderc tecs_spirvcross)
    endif()
    target_include_directories(
        tecs_registry
        PRIVATE
            ${TECS_BOX2D_INCLUDE_DIRS}
            ${TECS_SDL3_NET_INCLUDE_DIRS}
            ${TECS_SHADERC_INCLUDE_DIRS}
            ${TECS_SPVC_INCLUDE_DIRS}
            ${TECS_CURL_INCLUDE_DIRS}
            ${TECS_ZLIB_INCLUDE_DIRS}
    )

    # Linked here rather than where the executables are declared, because the
    # registry's sources are generated from bindings produced above.
    # The host also links the worker library, because its table holds the
    # addresses of that library's functions.
    target_link_libraries(tecs PRIVATE tecs_registry tecs_worker tecs_cjson)
    target_link_libraries(tecs_worker PRIVATE tecs_registry tecs_cjson)

    add_custom_target(
        tecs_bindings
        ALL
        DEPENDS
            "${GEN}/workercdef.lua"
            "${GEN}/logsinkcdef.lua"
            "${GEN}/taskpoolcdef.lua"
            "${GEN}/sdl3cdef.lua"
            "${GEN}/sdl3imagecdef.lua"
            "${GEN}/sdl3netcdef.lua"
            "${GEN}/sdl3mixercdef.lua"
            "${GEN}/box2dcdef.lua"
            "${GEN}/shaderccdef.lua"
            "${GEN}/spvccdef.lua"
            "${GEN}/curlcdef.lua"
            "${GEN}/zlibcdef.lua"
    )

    # Teal compilation. Kept as one custom target rather than per-file rules
    # because the compiler resolves the module graph itself.
    # CONFIGURE_DEPENDS so adding a source is a build, not a reconfigure.
    # Without it a new module is silently absent until someone remembers.
    file(GLOB_RECURSE TECS_TL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/*.tl")
    # Declaration files describe types and emit no code, so compiling one only
    # writes an empty .lua beside the module it describes. They are installed as
    # sources instead, which is where a type checker wants them.
    list(FILTER TECS_TL EXCLUDE REGEX "\\.d\\.tl$")
    add_custom_target(
        tecs_lua
        ALL
        # tl searches include paths last-first, so ours come last and win.
        COMMAND
            tl -q gen -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1" -I "${CMAKE_SOURCE_DIR}/vendor/tl" --root
            "${CMAKE_SOURCE_DIR}/src" --output-dir "${TECS_LUA_OUT}" ${TECS_TL}
        DEPENDS ${TECS_TL} tecs_bindings
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Compiling Teal sources"
        VERBATIM
    )

    # Content lives beside the compiled Lua, because that directory is the
    # content root a development run resolves against and the one an install
    # copies. CONFIGURE_DEPENDS so adding a shader is a build, not a
    # reconfigure.
    file(GLOB_RECURSE TECS_ASSET_FILES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/assets/*")
    add_custom_target(
        tecs_assets
        ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/assets" "${TECS_LUA_OUT}"
        DEPENDS ${TECS_ASSET_FILES}
        COMMENT "Copying assets"
        VERBATIM
    )

    # ------------------------------------------------------------------- CLI
    #
    # The command line tool is Teal like everything else, compiled by the same
    # compiler into the same content root, and it is reached the same way a
    # game is: the host loads an entry chunk that returns an application. So
    # `tecs check` and a running game are one binary with two entry chunks, and
    # nothing here is a second program.
    #
    # `cli/tecscli.tl` is that chunk and `cli/tecscli/` is everything under it.
    # Templates are excluded from compilation because they are a project's
    # sources, not this one's: they name a `tecs` global this tree's `tl check`
    # does not declare, and they are written out verbatim rather than run.
    file(GLOB_RECURSE TECS_CLI_TL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/cli/*.tl")
    list(FILTER TECS_CLI_TL EXCLUDE REGEX "/templates/")
    list(FILTER TECS_CLI_TL EXCLUDE REGEX "\\.d\\.tl$")
    add_custom_target(
        tecs_cli_lua
        ALL
        COMMAND
            tl -q gen -I "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1" -I "${CMAKE_SOURCE_DIR}/vendor/tl" -I
            "${CMAKE_SOURCE_DIR}/src" -I "${CMAKE_SOURCE_DIR}/cli" --root "${CMAKE_SOURCE_DIR}/cli" --output-dir
            "${TECS_LUA_OUT}" ${TECS_CLI_TL}
        DEPENDS ${TECS_CLI_TL} tecs_lua
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Compiling the CLI"
        VERBATIM
    )

    # What `tecs new` writes out. Inside the binary rather than fetched, which
    # is what makes a cold install able to scaffold with no network.
    file(GLOB_RECURSE TECS_CLI_TEMPLATES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/cli/tecscli/templates/*")
    add_custom_target(
        tecs_cli_templates
        ALL
        COMMAND
            ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/cli/tecscli/templates"
            "${TECS_LUA_OUT}/tecscli/templates"
        DEPENDS ${TECS_CLI_TEMPLATES}
        COMMENT "Copying project templates"
        VERBATIM
    )

    # The pinned type checker and formatter, staged out of the vendor tree.
    # Both are pure Lua and both are dependencies in the same sense as SDL:
    # cmake/Revisions.cmake names the commit, and a tree checked by one
    # revision and formatted by another is what the pin exists to prevent.
    add_custom_command(
        OUTPUT "${TECS_LUA_OUT}/tecstools/tl.lua"
        COMMAND
            ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/stagetools.py" --vendor
            "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1" --licenses "${CMAKE_SOURCE_DIR}/vendor/licenses" --out
            "${TECS_LUA_OUT}/tecstools"
        DEPENDS "${CMAKE_SOURCE_DIR}/scripts/stagetools.py"
        COMMENT "Staging the pinned Teal and Cerulean"
        VERBATIM
    )

    # What gets formatted and by what, taken from scripts/format.py rather than
    # restated, plus the two revisions above. `tecs format` reads this, so the
    # repository's own `make format` and a user's `tecs format` cannot disagree
    # about one file.
    include(cmake/Revisions.cmake)
    add_custom_command(
        OUTPUT "${TECS_LUA_OUT}/tecscli/toolchain.lua"
        COMMAND
            ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/gentooling.py" --teal-ref "${TECS_TL_REF}" --cerulean-ref
            "${TECS_CERULEAN_REF}" --out "${TECS_LUA_OUT}/tecscli/toolchain.lua"
        DEPENDS
            "${CMAKE_SOURCE_DIR}/scripts/gentooling.py"
            "${CMAKE_SOURCE_DIR}/scripts/format.py"
            "${CMAKE_SOURCE_DIR}/cmake/Revisions.cmake"
        COMMENT "Generating the toolchain table"
        VERBATIM
    )

    add_custom_target(
        tecs_cli_tools
        ALL
        DEPENDS "${TECS_LUA_OUT}/tecstools/tl.lua" "${TECS_LUA_OUT}/tecscli/toolchain.lua"
    )

    # LuaJIT's own Lua library, beside the engine's.
    #
    # `jit.zone` is what `src/tecs/internal/pipeline.tl` attributes a frame's
    # systems with and `jit.vmdef` is what turns a trace abort code into a
    # sentence, so both are load-bearing for the profiler rather than optional.
    # They are ordinary Lua files that ship with LuaJIT and are not inside it,
    # so a package that carries a LuaJIT and not these has a `require` that
    # fails at the moment somebody profiles.
    #
    # Copied rather than shimmed. Hand-written stand-ins for the two were what
    # was here, and a table of trace-abort strings transcribed from a version of
    # LuaJIT is a copy that goes stale silently: the pin moves, a code changes
    # meaning, and the profiler reports the old sentence.
    find_path(
        TECS_LUAJIT_JIT_DIR
        NAMES jit/vmdef.lua
        HINTS "${TECS_LUAJIT_PREFIX}/share/luajit-2.1"
        PATHS /opt/homebrew/share/luajit-2.1 /usr/local/share/luajit-2.1 /usr/share/luajit-2.1
        NO_DEFAULT_PATH
    )
    if(NOT TECS_LUAJIT_JIT_DIR)
        message(
            FATAL_ERROR
            "tecs: LuaJIT's jit/*.lua were not found. Set TECS_LUAJIT_JIT_DIR to the directory holding jit/vmdef.lua."
        )
    endif()
    add_custom_target(
        tecs_jitlib
        ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${TECS_LUAJIT_JIT_DIR}/jit" "${TECS_LUA_OUT}/jit"
        COMMENT "Copying LuaJIT's Lua library"
        VERBATIM
    )

    # The notices, staged as a directory so they can be packed like everything
    # else. A statically linked binary has no adjacent file to put them in, and
    # permissive still means the notice travels with the code: a package
    # carrying the code and not the notice is the only licence failure this
    # engine is capable of committing on its own. `tecs info --licenses` prints
    # what lands here.
    add_custom_target(
        tecs_notices
        ALL
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/notices"
        COMMAND
            ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
            "${CMAKE_SOURCE_DIR}/LICENSE-MIT" "${CMAKE_SOURCE_DIR}/LICENSE-APACHE" "${CMAKE_BINARY_DIR}/notices"
        COMMENT "Staging licence notices"
        VERBATIM
    )

    # Type information, staged beside the compiled Lua. `tl` reads types out of
    # `.tl` and a compiled `.lua` carries none, so a game checking against an
    # installed tecs needs these; the CLI's own go too, because a spec requires
    # `tecscli.testing` and a require that cannot be typed is a spec that
    # cannot be checked. Staged rather than read from `src/` so the CLI finds
    # them at the content root's sibling in a build tree and in an install
    # alike, and there is one rule rather than two.
    add_custom_target(
        tecs_teal
        ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/src" "${TECS_TEAL_OUT}"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/cli/tecscli" "${TECS_TEAL_OUT}/tecscli"
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${TECS_TEAL_OUT}/tecscli/templates"
        DEPENDS ${TECS_TL} ${TECS_CLI_TL}
        COMMENT "Staging Teal type information"
        VERBATIM
    )

    # ------------------------------------------------------------- payload
    #
    # Everything above, deflated into an array the executable carries. Only a
    # single-file build generates it; every other configuration has the same
    # files in a directory beside the binary and compiles none of this.
    #
    # It depends on the targets for ordering and on their *sources* for
    # freshness, and it needs both. A target dependency says the trees are
    # populated before this runs; it does not make this run again when one of
    # them changes, because a custom command is rebuilt from file timestamps and
    # a target has none. Depending only on the targets produced a build that
    # relinked happily around a payload nobody had regenerated, and the only
    # sign was a fix that had landed in `src/` still being absent from what the
    # binary carried. The digest in `tecs info` was the giveaway: unchanged
    # across a change.
    if(TECS_SINGLE_FILE)
        set(TECS_PAYLOAD_SOURCE "${CMAKE_BINARY_DIR}/generated/payload_data.c")
        add_custom_command(
            OUTPUT "${TECS_PAYLOAD_SOURCE}"
            COMMAND
                ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/genpayload.py" --root "lua=${TECS_LUA_OUT}" --root
                "teal=${TECS_TEAL_OUT}" --root "notices=${CMAKE_BINARY_DIR}/notices" --out "${TECS_PAYLOAD_SOURCE}"
            DEPENDS
                "${CMAKE_SOURCE_DIR}/scripts/genpayload.py"
                "${CMAKE_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
                ${TECS_TL}
                ${TECS_CLI_TL}
                ${TECS_CLI_TEMPLATES}
                ${TECS_ASSET_FILES}
                tecs_lua
                tecs_assets
                tecs_cli_lua
                tecs_cli_templates
                tecs_cli_tools
                tecs_teal
                tecs_notices
                tecs_jitlib
            COMMENT "Packing the content root"
            VERBATIM
        )
        target_sources(tecs PRIVATE "${TECS_PAYLOAD_SOURCE}" "${CMAKE_SOURCE_DIR}/cli/payload.c")
        target_include_directories(tecs PRIVATE "${CMAKE_SOURCE_DIR}/cli" ${TECS_ZLIB_INCLUDE_DIRS})
        target_compile_definitions(tecs PRIVATE TECS_PAYLOAD=1)
        target_link_libraries(tecs PRIVATE tecs::zlib)
    endif()

    # Specs written in Teal, compiled the same way. The ECS suites are written
    # in Teal and the engine's in Lua, so both forms are built and Busted is
    # pointed at both trees.
    file(GLOB_RECURSE TECS_SPEC_TL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/spec/*.tl")
    if(TECS_SPEC_TL)
        add_custom_target(
            tecs_spec
            ALL
            COMMAND
                luajit "${CMAKE_SOURCE_DIR}/scripts/compile_specs.lua" "${CMAKE_SOURCE_DIR}/spec" "${TECS_SPEC_OUT}"
                "${CMAKE_SOURCE_DIR}/vendor/share/lua/5.1"
            DEPENDS ${TECS_SPEC_TL} tecs_lua
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            COMMENT "Compiling Teal specs"
            VERBATIM
        )
    endif()
endif()

# --------------------------------------------------------------- formatting

# Which files are formatted, and by what, is described once in the script. These
# targets exist so a CMake-driven workflow has them; the Makefile calls the same
# script directly, since formatting a source tree does not need a build.
find_package(Python3 QUIET COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_custom_target(
        format
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/format.py"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Formatting sources"
        VERBATIM
    )
    add_custom_target(
        format-check
        COMMAND ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/scripts/format.py" --check
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Checking formatting"
        VERBATIM
    )
endif()

# --------------------------------------------------------------- packaging

# Every rule below names the `tecs` component, and `make package` installs that
# component and nothing else. A pinned build adds ten other projects to this
# tree, each with install rules of its own, and taking the default would ship
# their headers, their pkg-config files, their CMake package definitions and in
# curl's case a shell script, none of which a game unpacks this to use.
#
# The point is not the size. It is that a package then holds exactly what
# something here asked for by name, so "carries its own dependencies" is a list
# somebody wrote rather than whatever ten projects happened to install.
# cmake/Pinned.cmake names the libraries a packaged build links.

# Records how the tree was built, so a check can tell a development install
# from a shippable one rather than guessing from what it finds.
file(
    WRITE "${CMAKE_BINARY_DIR}/build-info.txt"
    "systemDeps=${TECS_SYSTEM_DEPS}\n"
    "system=${CMAKE_SYSTEM_NAME}\n"
    "arch=${CMAKE_SYSTEM_PROCESSOR}\n"
)
if(NOT TECS_SINGLE_FILE)
    install(FILES "${CMAKE_BINARY_DIR}/build-info.txt" DESTINATION share/tecs COMPONENT tecs)
endif()

# The notices ship with the binaries they describe. Almost everything linked
# here is permissive, and permissive still means the copyright notice travels
# with the code: a package carrying the code and not the notice is the only
# licence failure this engine is actually capable of committing. The engine's
# own two licences go for the same reason, since MIT asks the same thing.
# `scripts/checkpackage.py` fails an install that is missing any of them.
if(NOT TECS_SINGLE_FILE)
    install(
        FILES
            "${CMAKE_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
            "${CMAKE_SOURCE_DIR}/LICENSE-MIT"
            "${CMAKE_SOURCE_DIR}/LICENSE-APACHE"
        DESTINATION share/tecs
        COMPONENT tecs
    )
endif()

install(TARGETS tecs RUNTIME DESTINATION bin COMPONENT tecs)

# One file means one file. A single-file install is the executable and nothing
# else: no libraries to sit beside it, no content root to resolve against, and
# no notices file, because all three are inside it.
if(NOT TECS_SINGLE_FILE)
    install(TARGETS tecs_worker tecs_spirvcross LIBRARY DESTINATION lib COMPONENT tecs)
    install(TARGETS cjson LIBRARY DESTINATION lib COMPONENT tecs)
    if(TECS_BUILD_LUA)
        install(DIRECTORY "${TECS_LUA_OUT}/" DESTINATION share/tecs/lua COMPONENT tecs)
    endif()
endif()

# The Teal sources are the package's type information. `tl` reads types out of
# `.tl`, and a compiled `.lua` carries none, so a game that type-checks against
# an installed tecs needs these on its include path even though it never runs
# them. `tecs/global.d.tl` is among them, and is what declares the `tecs`
# global; it derives its type from `tecs/init.tl` rather than restating it, so
# it only works with the rest of the tree beside it.
#
# Taken from the staged tree rather than from `src/`, because the CLI's own
# `.tl` go here too and they come from a second directory. Staging is what
# makes the answer one directory in both trees.
if(TECS_SINGLE_FILE)
    # In the payload with everything else, under the same `teal` name, so the
    # CLI reaches it the same way in all three trees.
elseif(TECS_BUILD_LUA)
    install(DIRECTORY "${TECS_TEAL_OUT}/" DESTINATION share/tecs/teal COMPONENT tecs FILES_MATCHING PATTERN "*.tl")
else()
    install(
        DIRECTORY "${CMAKE_SOURCE_DIR}/src/"
        DESTINATION share/tecs/teal
        COMPONENT tecs
        FILES_MATCHING
        PATTERN "*.tl"
    )
endif()

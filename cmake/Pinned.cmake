# Pinned dependency sources for anything shipped.
#
# Desktop development uses TECS_SYSTEM_DEPS instead. Packaged output cannot:
# a build that resolved SDL from a developer's package manager would leave that
# path baked into a shipped binary, and mobile has no package manager to
# resolve from at all.
#
# Revisions are pinned rather than tracked so a release is reproducible.

include(ExternalProject)
include(FetchContent)
include(${CMAKE_CURRENT_LIST_DIR}/Revisions.cmake)

# Whether these are built as libraries to load or as archives to link.
#
# The engine reaches every one of them through the FFI, which loads a library by
# name, so the default is shared and a static archive would leave every way of
# running this tree that is not the host with nothing to load. TECS_SINGLE_FILE
# is the configuration that gives that up deliberately: under the host the FFI
# reaches a library through the registry, which holds addresses taken at
# build time, so nothing is loaded by name and there is nothing to leave behind.
#
# Two spellings of the same answer, because these projects disagree about which
# variable decides. Most read BUILD_SHARED_LIBS; SDL and its satellites, Mbed
# Rustls and Reqwest are pinned by Cargo instead.
if(TECS_SINGLE_FILE)
    set(TECS_DEPS_SHARED OFF)
    set(TECS_DEPS_STATIC ON)
else()
    set(TECS_DEPS_SHARED ON)
    set(TECS_DEPS_STATIC OFF)
endif()

# Everything here ends up inside a shared object, so it is all compiled to be
# placeable. Stated once rather than left to each dependency's own opinion,
# because a static archive built without it links into a library only on the
# platforms where that happens to be the default.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

FetchContent_Declare(
    SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG ${TECS_SDL3_TAG}
    GIT_SHALLOW TRUE
)

# SDL_mixer's decoders are separate options, several of them LGPL and on by
# default. A statically linked game must not import those, so each is named
# here rather than left to whatever the version's defaults happen to be.
#
# Off, and why:
#   GME           game-music-emu, LGPL, and no permissive alternative backend
#   MOD           libxmp, which is MIT rather than LGPL as it is often called;
#                 off because no format here needs it, not for its license
#   MIDI          FluidSynth, LGPL, and the bundled TiMidity with it, Artistic-1.0
#   MP3_MPG123    LGPL; dr_mp3 decodes the same files under a permissive one
#   VORBIS_VORBISFILE, FLAC_LIBFLAC
#                 permissive, but redundant beside the single-file decoders
#                 SDL_mixer already carries, and each is another dependency to
#                 fetch and build
#
# On: stb_vorbis, dr_flac, dr_mp3, WavPack, Opus, and the WAV/AIFF/VOC/AU
# readers SDL_mixer implements itself. Opus and WavPack are the two that need
# sources of their own, so those submodules are fetched and nothing else is.
#
# STRICT turns a dependency SDL_mixer cannot find into a configure failure.
# Without it a missing one silently drops its decoder, and the first sign is a
# shipped build that cannot open a file the developer's machine played.
# DEPS_SHARED off links them instead of loading them by name at run time,
# which is what a package that carries its own dependencies needs.
set(SDLMIXER_VENDORED ON CACHE BOOL "" FORCE)
set(SDLMIXER_STRICT ON CACHE BOOL "" FORCE)
set(SDLMIXER_DEPS_SHARED OFF CACHE BOOL "" FORCE)
set(SDLMIXER_TESTS OFF CACHE BOOL "" FORCE)
set(SDLMIXER_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDLMIXER_GME OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MOD OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MIDI OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MP3_MPG123 OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MP3_DRMP3 ON CACHE BOOL "" FORCE)
set(SDLMIXER_FLAC_LIBFLAC OFF CACHE BOOL "" FORCE)
set(SDLMIXER_FLAC_DRFLAC ON CACHE BOOL "" FORCE)
set(SDLMIXER_VORBIS_VORBISFILE OFF CACHE BOOL "" FORCE)
set(SDLMIXER_VORBIS_TREMOR OFF CACHE BOOL "" FORCE)
set(SDLMIXER_VORBIS_STB ON CACHE BOOL "" FORCE)
set(SDLMIXER_OPUS ON CACHE BOOL "" FORCE)
set(SDLMIXER_WAVPACK ON CACHE BOOL "" FORCE)

FetchContent_Declare(
    SDL3_mixer
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_mixer.git
    GIT_TAG ${TECS_SDL3_MIXER_TAG}
    GIT_SHALLOW TRUE
    GIT_SUBMODULES "external/ogg;external/opus;external/opusfile;external/wavpack"
)
# zlib is a public FFI service and the implementation behind its public module.
# It is pinned rather than borrowed so a packaged build does not inherit the
# build machine's copy. Tests and upstream install rules are disabled because
# this file installs the one library the package carries itself.
set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED ${TECS_DEPS_SHARED} CACHE BOOL "" FORCE)
set(ZLIB_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ZLIB_INSTALL OFF CACHE BOOL "" FORCE)

FetchContent_Declare(zlib GIT_REPOSITORY https://github.com/madler/zlib.git GIT_TAG ${TECS_ZLIB_TAG} GIT_SHALLOW TRUE)

# SPIRV-Cross ships static archives, which the generated wrapper links whole into
# one shared object the FFI can load. So its own install rules have nothing to
# contribute, and its command line tool and tests are not built.
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL ON CACHE BOOL "" FORCE)

FetchContent_Declare(
    SPIRV-Cross
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Cross.git
    GIT_TAG ${TECS_SPVC_TAG}
    GIT_SHALLOW TRUE
)

message(STATUS "tecs: fetching pinned dependencies")

# SDL and its two satellites each decide for themselves rather than reading
# BUILD_SHARED_LIBS, so each is told. Static SDL on Apple carries the frameworks
# it needs as interface link libraries, so nothing here has to name them.
set(SDL_SHARED ${TECS_DEPS_SHARED} CACHE BOOL "" FORCE)
set(SDL_STATIC ${TECS_DEPS_STATIC} CACHE BOOL "" FORCE)
set(SDLMIXER_BUILD_SHARED_LIBS ${TECS_DEPS_SHARED} CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(SDL3 SDL3_mixer zlib SPIRV-Cross)

# ------------------------------------------------------------------- LuaJIT

# LuaJIT is the one dependency here with no CMake build, so it is driven as an
# external project: its own make, into a prefix inside the build tree, and
# linked out of there.
#
# Two things have to be said to it that a CMake dependency would infer.
# MACOSX_DEPLOYMENT_TARGET is refused rather than defaulted by its Makefile, so
# it is passed through from the toolchain. And its install name is otherwise
# the absolute prefix it was installed to, which would bake this build tree
# into every binary that links it; @rpath is what lets the same library answer
# from a build tree and from an unpacked package.

set(TECS_LUAJIT_PREFIX "${CMAKE_BINARY_DIR}/luajit")
set(TECS_LUAJIT_INCLUDE_DIRS "${TECS_LUAJIT_PREFIX}/include/luajit-2.1")

# What LuaJIT's own Makefile calls these: ABIVER is 5.1, and its install leaves
# an unversioned link beside the file the version number is in. Its `make
# install` produces both kinds whatever this asks for, so a single-file build
# simply names the archive and leaves the library where it was built.
if(APPLE)
    set(tecsLuajitSoname "libluajit-5.1.dylib")
else()
    set(tecsLuajitSoname "libluajit-5.1.so")
endif()

if(TECS_SINGLE_FILE)
    set(tecsLuajitLibrary "${TECS_LUAJIT_PREFIX}/lib/libluajit-5.1.a")
else()
    set(tecsLuajitLibrary "${TECS_LUAJIT_PREFIX}/lib/${tecsLuajitSoname}")
endif()

# The versioned file that link points at. Its name carries the rolling version,
# which is the other half of what Revisions.cmake pins, so a commit raised
# without its version raised beside it fails the install rather than quietly
# packaging a name that resolves to nothing.
if(APPLE)
    set(tecsLuajitVersioned "libluajit-5.1.${TECS_LUAJIT_ROLLING}.dylib")
else()
    set(tecsLuajitVersioned "libluajit-5.1.so.${TECS_LUAJIT_ROLLING}")
endif()

set(tecsLuajitFlags PREFIX=${TECS_LUAJIT_PREFIX})
set(tecsLuajitEnv "")
if(NOT APPLE)
    list(APPEND tecsLuajitFlags TARGET_SONAME=${tecsLuajitSoname})
endif()
if(APPLE)
    list(APPEND tecsLuajitFlags TARGET_DYLIBPATH=@rpath/${tecsLuajitSoname})
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        message(FATAL_ERROR "tecs: set CMAKE_OSX_DEPLOYMENT_TARGET; LuaJIT's build requires one and will not guess.")
    endif()
    list(APPEND tecsLuajitEnv MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET})
endif()
# One architecture at a time. LuaJIT generates its own interpreter for the
# architecture it is built for, so a universal binary is two builds joined
# afterwards rather than a flag, and nothing here asks for one.
list(LENGTH CMAKE_OSX_ARCHITECTURES tecsLuajitArchCount)
if(tecsLuajitArchCount GREATER 1)
    message(FATAL_ERROR "tecs: LuaJIT builds one architecture at a time, and CMAKE_OSX_ARCHITECTURES names several.")
elseif(CMAKE_OSX_ARCHITECTURES)
    list(APPEND tecsLuajitFlags "CFLAGS=-arch ${CMAKE_OSX_ARCHITECTURES}" "LDFLAGS=-arch ${CMAKE_OSX_ARCHITECTURES}")
endif()

# No GIT_SHALLOW: the revision is a commit rather than a branch or a tag, and
# a shallow fetch can only ask a server for a ref it advertises.
ExternalProject_Add(
    tecs_luajit_build
    GIT_REPOSITORY https://github.com/LuaJIT/LuaJIT.git
    GIT_TAG ${TECS_LUAJIT_TAG}
    PREFIX "${CMAKE_BINARY_DIR}/luajit-build"
    BUILD_IN_SOURCE TRUE
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${CMAKE_COMMAND} -E env ${tecsLuajitEnv} -- make ${tecsLuajitFlags}
    INSTALL_COMMAND ${CMAKE_COMMAND} -E env ${tecsLuajitEnv} -- make ${tecsLuajitFlags} install
    BUILD_BYPRODUCTS "${tecsLuajitLibrary}"
    USES_TERMINAL_BUILD TRUE
)

add_library(tecs_luajit INTERFACE)
add_dependencies(tecs_luajit tecs_luajit_build)
target_include_directories(tecs_luajit INTERFACE "${TECS_LUAJIT_INCLUDE_DIRS}")
target_link_libraries(tecs_luajit INTERFACE "${tecsLuajitLibrary}")
add_library(tecs::luajit ALIAS tecs_luajit)

# The versioned file, under the unversioned name its install name announces.
# Installing the link instead copies a link, and the file it points at is not
# one of the two this package wants, so what would arrive is a name resolving
# to nothing. A single-file build installs no library at all: the archive is
# inside the executable.
if(NOT TECS_SINGLE_FILE)
    install(
        FILES "${TECS_LUAJIT_PREFIX}/lib/${tecsLuajitVersioned}"
        DESTINATION lib
        COMPONENT tecs
        RENAME ${tecsLuajitSoname}
    )
endif()

# ------------------------------------------------------------------- shaderc

# shaderc is a CMake project, so it is added as a subdirectory like the rest.
# What it is not is self-contained: it carries a DEPS file naming a commit of
# glslang, SPIRV-Tools and SPIRV-Headers and a utils/git-sync-deps script that
# clones whatever that names. A build which pins shaderc and then lets that
# script run has pinned the wrapper and left the compiler inside it floating,
# so the three are fetched here at the revisions that file names and shaderc is
# pointed at them through the cache variables it reads.
#
# The three are added here rather than under shaderc, which is what makes their
# options reachable. shaderc's third_party directory adds each only when the
# target it defines does not exist yet, so defining them first leaves it with
# nothing to do and leaves the install rules, the test suites and the command
# line programs of all three settable from one place.
#
# All three are compiled into libshaderc_shared and are static for that, and
# none of them installs: the one artifact this needs out of the whole subtree
# is that library, and the rest is headers and archives a package would carry
# and never open.
set(BUILD_SHARED_LIBS OFF)

set(SPIRV_HEADERS_SKIP_EXAMPLES ON CACHE BOOL "" FORCE)
set(SPIRV_HEADERS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
    spirv-headers
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Headers.git
    GIT_TAG ${TECS_SPIRV_HEADERS_TAG}
)
FetchContent_MakeAvailable(spirv-headers)

set(SPIRV_SKIP_EXECUTABLES ON CACHE BOOL "" FORCE)
set(SPIRV_SKIP_TESTS ON CACHE BOOL "" FORCE)
set(SPIRV_WERROR OFF CACHE BOOL "" FORCE)
set(SKIP_SPIRV_TOOLS_INSTALL ON)
FetchContent_Declare(
    spirv-tools
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Tools.git
    GIT_TAG ${TECS_SPIRV_TOOLS_TAG}
)
FetchContent_MakeAvailable(spirv-tools)

set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)
set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_SPVREMAPPER OFF CACHE BOOL "" FORCE)
FetchContent_Declare(glslang GIT_REPOSITORY https://github.com/KhronosGroup/glslang.git GIT_TAG ${TECS_GLSLANG_TAG})
FetchContent_MakeAvailable(glslang)

set(SHADERC_SKIP_TESTS ON CACHE BOOL "" FORCE)
set(SHADERC_SKIP_EXAMPLES ON CACHE BOOL "" FORCE)
set(SHADERC_SKIP_EXECUTABLES ON CACHE BOOL "" FORCE)
set(SHADERC_SKIP_COPYRIGHT_CHECK ON CACHE BOOL "" FORCE)
set(SHADERC_SKIP_INSTALL ON CACHE BOOL "" FORCE)
# shaderc compiles itself with warnings as errors, which turns a compiler newer
# than the pin into a build failure in a dependency rather than a warning.
set(SHADERC_ENABLE_WERROR_COMPILE OFF CACHE BOOL "" FORCE)
# SPIRV-Headers is the one of the three shaderc adds without first asking
# whether the target already exists, so it is pointed at a path that is not a
# directory. Existing is the whole of the test it makes.
set(SHADERC_SPIRV_HEADERS_DIR "${CMAKE_BINARY_DIR}/spirv-headers-added-already" CACHE STRING "" FORCE)

FetchContent_Declare(
    shaderc
    GIT_REPOSITORY https://github.com/google/shaderc.git
    GIT_TAG ${TECS_SHADERC_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(shaderc)

set(TECS_SHADERC_INCLUDE_DIRS "${shaderc_SOURCE_DIR}/libshaderc/include")

# ------------------------------------------------- what the rest is built from

# The common names the two dependency branches agree on. Everything above is
# about how these are obtained; everything below this file only uses them.
#
# Wrapped rather than aliased, because most of what these name is itself an
# alias its project publishes and CMake will not alias one of those again.
# Several of these publish one name for a shared build and another for a static
# one, so each is given both, shared first, and the first that exists is taken.
# Asking which kind of build this is at every call site would be the same test
# written eight times, and would be wrong the day one of these projects renamed
# a target.
#
# The order is reversed for a static build, and that is not tidiness. Several of
# these define *both* targets whatever they were asked for: shaderc builds
# `shaderc` as an archive and `shaderc_shared` as a library every time, so
# taking the first that exists linked a dylib into what was supposed to be one
# file, and the only sign was one `@rpath` entry in `otool -L`.
function(tecs_pinned_library name)
    set(candidates ${ARGN})
    if(TECS_DEPS_STATIC)
        list(REVERSE candidates)
    endif()
    foreach(candidate IN LISTS candidates)
        if(TARGET ${candidate})
            add_library(tecs_${name} INTERFACE)
            target_link_libraries(tecs_${name} INTERFACE ${candidate})
            add_library(tecs::${name} ALIAS tecs_${name})
            return()
        endif()
    endforeach()
    message(FATAL_ERROR "tecs: none of these targets exist for ${name}: ${ARGN}")
endfunction()

tecs_pinned_library(sdl3 SDL3::SDL3 SDL3::SDL3-static)
tecs_pinned_library(sdl3mixer SDL3_mixer::SDL3_mixer SDL3_mixer::SDL3_mixer-static)
tecs_pinned_library(zlib ZLIB::ZLIB zlibstatic)
tecs_pinned_library(shaderc shaderc_shared shaderc)

# Header directories, for the binding generator. It runs the preprocessor
# itself rather than compiling through a target, so it is given directories
# rather than the targets that carry them. A source tree splits its headers
# across the checkout and the build directory wherever one of them is
# generated, which is why several of these name both.
set(TECS_SDL3_INCLUDE_DIRS "${sdl3_SOURCE_DIR}/include" "${sdl3_BINARY_DIR}/include")
set(TECS_SDL3_MIXER_INCLUDE_DIRS "${sdl3_mixer_SOURCE_DIR}/include")
set(TECS_SPVC_INCLUDE_DIRS "${spirv-cross_SOURCE_DIR}")
set(TECS_ZLIB_INCLUDE_DIRS "${zlib_SOURCE_DIR}" "${zlib_BINARY_DIR}")

# ---------------------------------------------- what a packaged tree carries

# The shared libraries a packaged binary references, named one at a time.
#
# Their own projects install more than this, and several install nothing at all
# as a subproject, so neither taking their rules nor leaving them produces a
# package. Naming them here does, and it makes the set enumerable: this list
# and the link table of an installed binary have to agree, which is what
# scripts/checkpackage.py reads and what its LINKED_LIBRARIES declares a
# license for.
#
# Everything absent is absent for a reason worth knowing. SPIRV-Cross, glslang,
# SPIRV-Tools and SDL_mixer's four decoders are static, and are inside
# the libraries above rather than beside them. LuaJIT is installed further up,
# by name, because its build is not one of these.
#
# A single-file build installs none of them, because every one is an archive
# inside the executable and there is nothing left to put beside it. The license
# obligation does not go away with the file: the notices travel in the payload,
# and `tecs info --licenses` is where they are read.
if(NOT TECS_SINGLE_FILE)
    install(TARGETS SDL3-shared SDL3_mixer-shared zlib shaderc_shared LIBRARY DESTINATION lib COMPONENT tecs)
endif()

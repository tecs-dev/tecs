# Pinned dependency sources for anything shipped.
#
# Desktop development uses TECS_SYSTEM_DEPS instead. Packaged output cannot:
# a build that resolved SDL from a developer's package manager would leave that
# path baked into a shipped binary, and mobile has no package manager to
# resolve from at all.
#
# Revisions are pinned rather than tracked so a release is reproducible.

include(FetchContent)
include(${CMAKE_CURRENT_LIST_DIR}/Revisions.cmake)

FetchContent_Declare(
    SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG ${TECS_SDL3_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_Declare(
    SDL3_image
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_image.git
    GIT_TAG ${TECS_SDL3_IMAGE_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_Declare(
    SDL3_net
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_net.git
    GIT_TAG ${TECS_SDL3_NET_TAG}
    GIT_SHALLOW TRUE
)

# SDL_mixer's decoders are separate options, several of them LGPL and on by
# default. A statically linked game must not import those, so each is named
# here rather than left to whatever the version's defaults happen to be.
#
# Off, and why:
#   GME           game-music-emu, LGPL, and no permissive alternative backend
#   MOD           libxmp, LGPL, likewise
#   MIDI          FluidSynth, LGPL
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
FetchContent_Declare(
    box2d
    GIT_REPOSITORY https://github.com/erincatto/box2d.git
    GIT_TAG ${TECS_BOX2D_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_Declare(
    SPIRV-Cross
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Cross.git
    GIT_TAG ${TECS_SPVC_TAG}
    GIT_SHALLOW TRUE
)

# LuaJIT and shaderc build with their own systems rather than CMake, so they
# are driven as external projects rather than added as subdirectories.
message(STATUS "tecs: pinned dependencies declared; run cmake --build to fetch")

FetchContent_MakeAvailable(
    SDL3
    SDL3_image
    SDL3_net
    SDL3_mixer
    box2d
    SPIRV-Cross
)

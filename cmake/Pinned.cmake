# Pinned dependency sources for anything shipped.
#
# Desktop development uses TECS_SYSTEM_DEPS instead. Packaged output cannot:
# a build that resolved SDL from a developer's package manager would leave that
# path baked into a shipped binary, and mobile has no package manager to
# resolve from at all.
#
# Revisions are pinned rather than tracked so a release is reproducible.

include(FetchContent)

set(TECS_SDL3_TAG      "release-3.4.12"  CACHE STRING "SDL3 revision")
set(TECS_SDL3_IMAGE_TAG "release-3.4.4"  CACHE STRING "SDL3_image revision")
set(TECS_SDL3_NET_TAG  "release-3.2.0"   CACHE STRING "SDL3_net revision")
set(TECS_BOX2D_TAG     "v3.1.1"          CACHE STRING "Box2D revision")
set(TECS_LUAJIT_TAG    "v2.1"            CACHE STRING "LuaJIT revision")
set(TECS_SHADERC_TAG   "v2026.3"         CACHE STRING "shaderc revision")
set(TECS_SPVC_TAG      "vulkan-sdk-1.4.313.0" CACHE STRING "SPIRV-Cross revision")

FetchContent_Declare(SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG ${TECS_SDL3_TAG} GIT_SHALLOW TRUE)
FetchContent_Declare(SDL3_image
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_image.git
    GIT_TAG ${TECS_SDL3_IMAGE_TAG} GIT_SHALLOW TRUE)
FetchContent_Declare(SDL3_net
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_net.git
    GIT_TAG ${TECS_SDL3_NET_TAG} GIT_SHALLOW TRUE)
FetchContent_Declare(box2d
    GIT_REPOSITORY https://github.com/erincatto/box2d.git
    GIT_TAG ${TECS_BOX2D_TAG} GIT_SHALLOW TRUE)
FetchContent_Declare(SPIRV-Cross
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Cross.git
    GIT_TAG ${TECS_SPVC_TAG} GIT_SHALLOW TRUE)

# LuaJIT and shaderc build with their own systems rather than CMake, so they
# are driven as external projects rather than added as subdirectories.
message(STATUS "tecs: pinned dependencies declared; run cmake --build to fetch")

FetchContent_MakeAvailable(SDL3 SDL3_image SDL3_net box2d SPIRV-Cross)

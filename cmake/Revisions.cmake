# The revision of every dependency this engine builds on.
#
# Declared apart from how they are obtained, because both ways of obtaining
# them need to agree about what they are. A packaged preset fetches these from
# source through cmake/Pinned.cmake. A development preset resolves them from
# the system instead, and cmake/SystemVersions.cmake holds what it found
# against this list so the convenience does not quietly become a difference.

set(TECS_SDL3_TAG "release-3.4.12" CACHE STRING "SDL3 revision")
set(TECS_SDL3_IMAGE_TAG "release-3.4.4" CACHE STRING "SDL3_image revision")
set(TECS_SDL3_NET_TAG "release-3.2.0" CACHE STRING "SDL3_net revision")
set(TECS_SDL3_MIXER_TAG "release-3.2.4" CACHE STRING "SDL3_mixer revision")
set(TECS_BOX2D_TAG "v3.1.1" CACHE STRING "Box2D revision")
set(TECS_LUAJIT_TAG "v2.1" CACHE STRING "LuaJIT revision")
set(TECS_SHADERC_TAG "v2026.3" CACHE STRING "shaderc revision")
set(TECS_SPVC_TAG "vulkan-sdk-1.4.313.0" CACHE STRING "SPIRV-Cross revision")

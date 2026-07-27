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

# LuaJIT has published no release on v2.1 since 2017 and does not intend to.
# What it has instead is a rolling version, whose number is the committer
# timestamp of the commit built. So there is no tag to name here: v2.1 is a
# branch that moves, and pinning to it pins nothing.
#
# This commit is the one the development preset's LuaJIT reports, which is what
# makes the choice checkable rather than arbitrary. The suite runs against the
# system's LuaJIT on a development preset and against this one on a packaged
# preset, and naming the same revision is what keeps those two the same VM. The
# rolling version is carried beside the commit because that is what a build
# reports about itself, and cmake/SystemVersions.cmake compares against it.
set(TECS_LUAJIT_TAG "871db2c84ecefd70a850e03a6c340214a81739f0" CACHE STRING "LuaJIT revision")
set(TECS_LUAJIT_ROLLING "2.1.1753364724" CACHE STRING "Version the pinned LuaJIT reports")

# shaderc, and the three projects it compiles into itself.
#
# shaderc does not vendor glslang, SPIRV-Tools or SPIRV-Headers. It carries a
# DEPS file naming a commit of each and a utils/git-sync-deps script that
# clones them, so a build that pins shaderc and lets that script run has pinned
# one of four things and left the compiler itself floating. The three below are
# the revisions shaderc's own DEPS names at TECS_SHADERC_TAG, lifted out so
# they are visible, diffable, and raised deliberately when the tag moves.
#
# The other four entries in that DEPS file are abseil, effcee, googletest and
# re2, which SPIRV-Tools and shaderc need only to build their tests. Those are
# off here, so none of them is fetched.
set(TECS_SHADERC_TAG "v2026.3" CACHE STRING "shaderc revision")
set(TECS_GLSLANG_TAG "168d452a4f460d24b588fed08477a81c44ee27a1" CACHE STRING "glslang revision, from shaderc's DEPS")
set(TECS_SPIRV_TOOLS_TAG
    "b707790a898e44038547df54580022fc1cf89c3d"
    CACHE STRING
    "SPIRV-Tools revision, from shaderc's DEPS"
)
set(TECS_SPIRV_HEADERS_TAG
    "29981f65241605e08b0ede4cfeb999fe3b723c6a"
    CACHE STRING
    "SPIRV-Headers revision, from shaderc's DEPS"
)

set(TECS_SPVC_TAG "vulkan-sdk-1.4.313.0" CACHE STRING "SPIRV-Cross revision")
set(TECS_ZLIB_TAG "v1.3.2" CACHE STRING "zlib revision")
set(TECS_CURL_TAG "curl-8_21_0" CACHE STRING "libcurl revision")
set(TECS_MBEDTLS_TAG "mbedtls-4.1.1" CACHE STRING "Mbed TLS revision, curl's TLS backend")

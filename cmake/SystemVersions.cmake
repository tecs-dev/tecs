# Holds what a development preset resolved against what a release ships.
#
# A development preset takes its dependencies from the system because building
# the set from source is a long build that desktop work does not need. That is
# only honest while the two agree. The spec suite runs against whatever is
# installed here, and a spec that asserts on a library's behaviour proves
# nothing about the library a release carries once the two have drifted: the
# renderer specs read back pixels through SDL's GPU API, and the physics specs
# assert positions out of Box2D's solver.
#
# Drift is therefore a configure failure rather than something discovered later
# as a spec that passes on one machine and not another. Set
# TECS_ALLOW_VERSION_DRIFT to work on a dependency before its revision is
# raised, which is the one case where disagreeing is the point.

include(${CMAKE_CURRENT_LIST_DIR}/Revisions.cmake)

set(TECS_VERSION_DRIFT "")

#[[
Compares one resolved version against the revision Revisions.cmake names.

`mode` is EXACT where a tag is a version, or PREFIX where a tag names
something coarser than what the system reports: LuaJIT's v2.1 is a branch
whose builds carry a timestamp, and shaderc's release tags carry no patch
component while its builds do.
]]
function(tecs_check_version name found tag mode)
    if(NOT found)
        list(APPEND TECS_VERSION_DRIFT
            "  ${name}: installed, but reports no version to compare")
        set(TECS_VERSION_DRIFT "${TECS_VERSION_DRIFT}" PARENT_SCOPE)
        return()
    endif()

    # Tags carry a prefix naming the project's release convention rather than
    # anything about the version, so both spellings reduce to the same number.
    string(REGEX REPLACE "^(release-|v)" "" expected "${tag}")

    if(mode STREQUAL "PREFIX")
        string(FIND "${found}" "${expected}" at)
        if(at EQUAL 0)
            return()
        endif()
    elseif(found VERSION_EQUAL expected)
        return()
    endif()

    list(APPEND TECS_VERSION_DRIFT
        "  ${name}: system has ${found}, this tree pins ${tag}")
    set(TECS_VERSION_DRIFT "${TECS_VERSION_DRIFT}" PARENT_SCOPE)
endfunction()

tecs_check_version("SDL3" "${SDL3_VERSION}" "${TECS_SDL3_TAG}" EXACT)
tecs_check_version("SDL3_image" "${SDL3_IMAGE_VERSION}" "${TECS_SDL3_IMAGE_TAG}" EXACT)
tecs_check_version("SDL3_mixer" "${SDL3_MIXER_VERSION}" "${TECS_SDL3_MIXER_TAG}" EXACT)
tecs_check_version("SDL3_net" "${SDL3_NET_VERSION}" "${TECS_SDL3_NET_TAG}" EXACT)
tecs_check_version("LuaJIT" "${LUAJIT_VERSION}" "${TECS_LUAJIT_TAG}" PREFIX)
tecs_check_version("shaderc" "${SHADERC_VERSION}" "${TECS_SHADERC_TAG}" PREFIX)

# Four are unchecked, for two different reasons.
#
# SPIRV-Cross is pinned at a Vulkan SDK tag while its pkg-config file reports a
# library version of its own, and the two numbering schemes have no mapping
# between them that this can compute. Box2D ships neither a pkg-config file nor
# a version macro in its headers, so a build resolving it by find_library has
# nothing to ask. Its solver decides what the physics specs assert, which makes
# it the one this most wants. Both are gaps rather than exemptions.
#
# libcurl and zlib are different: they disagree on purpose and cannot be made
# to agree. A package manager ships the copy the platform builds, and on Apple
# that is a libcurl whose TLS backend curl itself removed in 8.15.0. So there
# is no version of these to install that would match, and holding a build to
# one would fail every configure over a difference nobody can close.
#
# What that costs is named rather than hidden: a development preset speaks TLS
# through a different library than a release does, and cmake/Pinned.cmake says
# so where the revisions are chosen. Nothing the bindings see depends on it,
# because the cdef is generated per build from whichever headers are present,
# and curl.version() and zlib.version() report which answered. A spec that
# rests on a protocol or a compression level being available on both is the
# thing this cannot catch, which is why the curl spec drives a loopback
# listener rather than a URL scheme a build might not have.

if(TECS_VERSION_DRIFT AND NOT TECS_ALLOW_VERSION_DRIFT)
    string(REPLACE ";" "\n" drift "${TECS_VERSION_DRIFT}")
    message(FATAL_ERROR
        "tecs: system dependencies disagree with the revisions this tree "
        "pins.\n\n${drift}\n\n"
        "The spec suite runs against what is installed here, so a difference "
        "means the suite is not testing what a release ships. Install the "
        "pinned version, or raise the revision in cmake/Revisions.cmake if "
        "moving to the newer one is the intent.\n\n"
        "Configure with -DTECS_ALLOW_VERSION_DRIFT=ON to proceed anyway, "
        "which is for working on a dependency before its revision is raised.")
elseif(TECS_VERSION_DRIFT)
    string(REPLACE ";" "\n" drift "${TECS_VERSION_DRIFT}")
    message(WARNING "tecs: proceeding with system dependencies that disagree "
        "with the pinned revisions.\n${drift}")
endif()

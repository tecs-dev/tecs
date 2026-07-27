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

# Everything here ends up inside a shared object, so it is all compiled to be
# placeable. Stated once rather than left to each dependency's own opinion,
# because a static archive built without it links into a library only on the
# platforms where that happens to be the default.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Where the zlib fetched below lands. Named here because SDL_image's
# declaration reads it and comes first; FetchContent puts a dependency's
# checkout at <base>/<name>-src, and the base is the cache variable it defines
# when it is included.
set(TECS_ZLIB_SOURCE "${FETCHCONTENT_BASE_DIR}/zlib-src")

FetchContent_Declare(
    SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG ${TECS_SDL3_TAG}
    GIT_SHALLOW TRUE
)
# SDL_image's formats are separate options as well, and every one of them is on
# by default. Four of them reach out to a codec library of their own, so the
# defaults cost a shipped binary megabytes for formats nothing here reads.
#
# On: PNG and JPEG. That is what a game built on this engine can decode, and it
# is the whole list. Off: every other format the pinned revision offers. AVIF,
# JXL, TIFF and WebP are the expensive ones, each carrying an external codec.
# The rest are readers SDL_image implements itself and cost little more than
# their own code, and they are off all the same: a format that is on is a format
# a game ships assets in, and then every platform port has to keep it working.
#
# JPEG decodes through SDLIMAGE_BACKEND_STB, so keeping it links no libjpeg.
# PNG keeps libpng rather than falling back to stb_image, because libpng is the
# only decoder here that reads APNG and IMG_SavePNG is what the debug server
# writes a screenshot with.
#
# BACKEND_IMAGEIO is off, and it is the option that makes the rest of this block
# mean anything on Apple. With it on, `IMG_Load` is not SDL_image's own at all:
# `src/IMG.c` compiles its entry point out under `__APPLE__` and `IMG_ImageIO.m`
# hands the file to CoreGraphics, which reads WebP, AVIF, JPEG XL, TIFF, BMP and
# GIF whatever these options say. Measured on release-3.4.4, over one sample of
# each format in its own test suite: with everything below off and ImageIO on,
# eight of the thirteen disabled formats still load, WebP and AVIF among them.
# Leaving it on would be worse than not trimming, because a game would ship a
# WebP atlas that works on macOS and fails everywhere. BACKEND_WIC is off for the
# smaller version of the same reason: it is per-format rather than wholesale,
# but it would still mean PNG and JPEG decoded by a different implementation on
# Windows than everywhere else.
#
# STRICT and DEPS_SHARED are set for the reasons the mixer sets them. Without
# STRICT a libpng that cannot be found silently drops PNG, which is every
# texture this engine loads. DEPS_SHARED off links libpng rather than loading it
# by name at run time, which also makes it visible: `make check-package` reads a
# binary's link table, and a dlopen of a bare name appears in no link table.
set(SDLIMAGE_STRICT ON CACHE BOOL "" FORCE)
set(SDLIMAGE_DEPS_SHARED OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_SAMPLES OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_TESTS OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_BACKEND_STB ON CACHE BOOL "" FORCE)
set(SDLIMAGE_BACKEND_IMAGEIO OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_BACKEND_WIC OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_PNG ON CACHE BOOL "" FORCE)
set(SDLIMAGE_PNG_LIBPNG ON CACHE BOOL "" FORCE)
set(SDLIMAGE_PNG_SAVE ON CACHE BOOL "" FORCE)
set(SDLIMAGE_JPG ON CACHE BOOL "" FORCE)
set(SDLIMAGE_ANI OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_AVIF OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_BMP OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_GIF OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_JXL OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_LBM OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_PCX OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_PNM OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_QOI OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_SVG OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_TGA OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_TIF OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_WEBP OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_XCF OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_XPM OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_XV OFF CACHE BOOL "" FORCE)

# VENDORED is the one that decides whether any of the above describes a shipped
# binary. Without it SDL_image resolves libpng with `find_package(PNG)` against
# the build machine, and on this one that found a header inside
# /Library/Frameworks/Mono.framework declaring libpng 1.4.12 and linked
# Homebrew's 1.6.58 beside it. That configures, builds, links an absolute path
# out of the package, warns at run time that the two disagree, and then
# corrupts memory: `png_struct` is not the same shape in the two versions.
#
# With it on, libpng comes from SDL_image's own submodule at the revision the
# pinned SDL_image names, and is static, so it ends up inside libSDL3_image
# rather than beside it. Only that one submodule is fetched; the zlib beside it
# is replaced by the patch step with the revision this file pins, for the
# reason written at the zlib declaration below.
set(SDLIMAGE_VENDORED ON CACHE BOOL "" FORCE)

FetchContent_Declare(
    SDL3_image
    GIT_REPOSITORY https://github.com/libsdl-org/SDL_image.git
    GIT_TAG ${TECS_SDL3_IMAGE_TAG}
    GIT_SHALLOW TRUE
    GIT_SUBMODULES "external/libpng"
    PATCH_COMMAND ${CMAKE_COMMAND} -E copy_directory "${TECS_ZLIB_SOURCE}" "<SOURCE_DIR>/external/zlib"
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
#   MOD           libxmp, which is MIT rather than LGPL as it is often called;
#                 off because no format here needs it, not for its licence
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
# Box2D. Its samples pull in a windowing toolkit and an immediate-mode UI, and
# its benchmarks and unit tests are programs nothing here runs.
set(BOX2D_SAMPLES OFF CACHE BOOL "" FORCE)
set(BOX2D_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(BOX2D_DOCS OFF CACHE BOOL "" FORCE)
set(BOX2D_PROFILE OFF CACHE BOOL "" FORCE)
set(BOX2D_UNIT_TESTS OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    box2d
    GIT_REPOSITORY https://github.com/erincatto/box2d.git
    GIT_TAG ${TECS_BOX2D_TAG}
    GIT_SHALLOW TRUE
)

# zlib. Pinned rather than borrowed: libcurl needs it to answer a
# Content-Encoding, and SDL3_image needs it under libpng. A shipped build gets
# the one named here instead of whichever copy the machine happens to have.
#
# Both kinds, because two things want it differently. The engine reaches it
# through the FFI, which loads a library rather than links one, so there has to
# be a shared object; libpng goes inside libSDL3_image, so that copy is static
# and leaves no second zlib beside it. The tests build example programs that
# nothing runs.
set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(ZLIB_BUILD_STATIC ON CACHE BOOL "" FORCE)
# No install rules of its own. The package installs the one component it names,
# and zlib's export set is not exportable from where SDL_image adds it: the
# include directory it is given there is inside another project's tree.
set(ZLIB_INSTALL OFF CACHE BOOL "" FORCE)

# Fetched here, and added by SDL_image rather than here.
#
# SDL_image vendors zlib itself, out of a submodule, and its CMakeLists adds it
# whenever it vendors libpng, with no test for whether the target already
# exists. zlib's own CMakeLists creates `zlib` and `zlibstatic` unconditionally,
# so a tree that adds zlib and then adds SDL_image defines both twice and does
# not configure. There is no option either way round: SDL_image treats a
# vendored libpng without a vendored zlib as an internal error.
#
# So there is one add, and this decides what it adds. The submodule is not
# fetched, the source below is copied into its place by SDL_image's patch step,
# and what comes out is one zlib at TECS_ZLIB_TAG: shared for the FFI and
# libcurl, static inside libpng.
#
# SOURCE_SUBDIR names a directory with no CMakeLists.txt in it, which is how
# FetchContent is asked to fetch something and add nothing.
FetchContent_Declare(
    zlib
    GIT_REPOSITORY https://github.com/madler/zlib.git
    GIT_TAG ${TECS_ZLIB_TAG}
    GIT_SHALLOW TRUE
    SOURCE_SUBDIR tecs-added-by-sdl-image
)

# Mbed TLS, which is libcurl's TLS backend here.
#
# Using the platform's own was never really on the table. curl removed its
# Secure Transport backend in 8.15.0, because from mid-2025 it requires every
# backend it keeps to implement TLS 1.3 and that one never did; Apple had
# deprecated the framework in 2019 and offers no successor curl can use. So on
# Apple there is no native backend to pick, and there is none on Linux or
# Android either. Native would mean Schannel on Windows and a pinned library
# everywhere else, which is not one stack but two.
#
# That left OpenSSL, and Mbed TLS wins on every axis that was measured. On this
# machine it builds in 9 seconds against OpenSSL's 65 and adds 1.0 MB of
# library against OpenSSL's 5.5 MB. curl's own comparison grades both as
# supported, with only rustls marked experimental, and a curl built on either
# reports the same protocols and the same features.
#
# What that costs is HTTP/3, which needs a QUIC-capable backend and which Mbed
# TLS is not. Nothing here speaks HTTP/2 either, since that needs nghttp2 and
# nothing has asked for it; if either is ever wanted, the backend is the pin
# that changes.
#
# 4.1 rather than 3.6 for the support window: 3.6 is an LTS that ends in March
# 2027 and 4.1 is the one that follows it, to March 2029. 4.x is also where the
# crypto moved into TF-PSA-Crypto and the PSA interface became the supported
# one, so anything built on this reaches for `psa_hash_compute` rather than the
# legacy `mbedtls_sha256`, and does not have to be written twice.
#
# Building 4.x from a tag rather than a release tarball generates sources on the
# way, so the build host needs Python with `jinja2` and `jsonschema`. Without
# them the failure is a missing module in the middle of a dependency's build,
# which reads as nothing in particular.
#
# Pinning a TLS library means owning its advisories: a shipped game carries the
# revision named here, so a fix is a new build of every target rather than an
# operating system update someone else ships. Mbed TLS published 3 advisories
# in 2021 and 31 in the first half of 2026, arriving in release-day batches, so
# the real shape of this is a few forced upgrades a year rather than a stream.
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
# Mbed TLS compiles itself with warnings as errors, which makes a compiler
# newer than the pin a build failure in a dependency rather than a warning.
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)

# Asked here rather than left to be discovered. Mbed TLS generates part of its
# own source and needs those two modules to do it, and without them the build
# fails a quarter of an hour in, inside a dependency, as an import error naming
# neither Mbed TLS nor this project. The same interpreter is what the build
# generates bindings with, so finding it once here settles both.
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import jinja2, jsonschema"
    RESULT_VARIABLE tecsMbedtlsPythonModules
    OUTPUT_QUIET
    ERROR_QUIET
)
if(NOT tecsMbedtlsPythonModules EQUAL 0)
    message(
        FATAL_ERROR
        "tecs: ${Python3_EXECUTABLE} cannot import jinja2 and jsonschema, and Mbed TLS "
        "generates sources with them when it is built from a git revision rather than "
        "a release archive.\n\n"
        "Install both for that interpreter, or point Python3_EXECUTABLE at one that has "
        "them: python3 -m venv <dir> && <dir>/bin/pip install jinja2 jsonschema, then "
        "configure with -DPython3_EXECUTABLE=<dir>/bin/python."
    )
endif()

FetchContent_Declare(
    mbedtls
    GIT_REPOSITORY https://github.com/Mbed-TLS/mbedtls.git
    GIT_TAG ${TECS_MBEDTLS_TAG}
    GIT_SHALLOW TRUE
    GIT_SUBMODULES_RECURSE TRUE
)

# libcurl, for HTTP. Its defaults speak protocols this engine never will, and
# every one of them is parsing code inside the process that renders the game.
#
# Off, and why:
#   FTP, FILE, TFTP, DICT, GOPHER, TELNET, SMB
#                 file transfer this engine does not do. Local files go through
#                 tecs.platform.filesystem, which is not a URL fetch.
#   IMAP, POP3, SMTP
#                 mail
#   LDAP, LDAPS   directory lookups, and on Apple the LDAP backend is another
#                 deprecated system framework
#   MQTT, RTSP    messaging and streaming, neither asked for
#   NTLM, Kerberos and Negotiate authentication
#                 enterprise single sign-on, which pulls in a GSSAPI
#                 implementation for a case a game client does not have
#   libssh2, libssh, librtmp, libidn2, libpsl, brotli, zstd, c-ares
#                 each is another dependency to pin, and none serves HTTP over
#                 TLS with a zlib Content-Encoding, which is the requirement
#   nghttp2       HTTP/2, which nothing has asked for and which is another pin
#
# On: HTTP, HTTPS, and the WebSocket upgrade that rides on them, with zlib for
# Content-Encoding and Mbed TLS for the transport. The command line tool, the
# tests, the examples and the manual are all off, since this build wants the
# library.
set(BUILD_CURL_EXE OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_LIBCURL_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_CURL_MANUAL OFF CACHE BOOL "" FORCE)
set(CURL_USE_MBEDTLS ON CACHE BOOL "" FORCE)
set(CURL_USE_OPENSSL OFF CACHE BOOL "" FORCE)
set(CURL_ZLIB ON CACHE BOOL "" FORCE)
set(CURL_BROTLI OFF CACHE BOOL "" FORCE)
set(CURL_ZSTD OFF CACHE BOOL "" FORCE)
set(CURL_USE_GSSAPI OFF CACHE BOOL "" FORCE)
# USE_LIBIDN2, not CURL_USE_LIBIDN2. curl names this one without its own
# prefix, and the difference is not cosmetic: the prefixed spelling is an
# option curl has never defined, so what it made was a cache variable nothing
# read, while libidn2 was auto-detected on and linked from the build machine.
set(USE_LIBIDN2 OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH2 OFF CACHE BOOL "" FORCE)
set(ENABLE_ARES OFF CACHE BOOL "" FORCE)
set(USE_NGHTTP2 OFF CACHE BOOL "" FORCE)
set(CURL_DISABLE_DICT ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_FILE ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_FTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_GOPHER ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_IMAP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_KERBEROS_AUTH ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_LDAP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_LDAPS ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_MQTT ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_NEGOTIATE_AUTH ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_POP3 ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_RTSP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_SMTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TELNET ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TFTP ON CACHE BOOL "" FORCE)
# NTLM and SMB are the two curl spells as enables rather than disables, and
# both are off by default at this revision. Named anyway, because a default is
# a decision somebody else gets to change.
set(CURL_ENABLE_NTLM OFF CACHE BOOL "" FORCE)
set(CURL_ENABLE_SMB OFF CACHE BOOL "" FORCE)
# No exported CMake package. Nothing here consumes one, and an export set has
# to name every target its members link, which curl cannot do for a zlib built
# beside it in the same tree.
set(CURL_ENABLE_EXPORT_TARGET OFF CACHE BOOL "" FORCE)

FetchContent_Declare(curl GIT_REPOSITORY https://github.com/curl/curl.git GIT_TAG ${TECS_CURL_TAG} GIT_SHALLOW TRUE)

# SPIRV-Cross ships static archives, which native/spirvcross.c links whole into
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

# Box2D and libcurl take their library kind from BUILD_SHARED_LIBS, and the
# engine reaches both through the FFI, which loads a library by name rather
# than linking one. A static archive would link into the host and leave every
# other way of running this tree, a spec under a plain interpreter among them,
# with nothing to load.
set(BUILD_SHARED_LIBS ON)

# zlib first and alone. It is only fetched here, and it has to be on disk
# before SDL_image is, because SDL_image's patch step copies it into place.
FetchContent_MakeAvailable(zlib)
FetchContent_MakeAvailable(
    SDL3
    SDL3_image
    SDL3_net
    SDL3_mixer
    box2d
    SPIRV-Cross
    mbedtls
)

# curl is asked separately, because it has to be told which Mbed TLS this is.
# Its FindMbedTLS looks the library up on the machine unless all four of these
# are already set, and a pinned TLS backend that a build then resolves from
# Homebrew is the exact failure this whole file exists to prevent: it linked
# 3.6.3 from /opt/homebrew beside the 4.1.1 sitting unused in the build tree.
#
# The three libraries are named as targets rather than as paths, so link order
# and include directories come from the targets themselves. 4.x is where the
# crypto moved into TF-PSA-Crypto, which is why the third is not mbedcrypto.
set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE STRING "" FORCE)
set(MBEDTLS_LIBRARY mbedtls CACHE STRING "" FORCE)
set(MBEDX509_LIBRARY mbedx509 CACHE STRING "" FORCE)
set(MBEDCRYPTO_LIBRARY tfpsacrypto CACHE STRING "" FORCE)

FetchContent_MakeAvailable(curl)

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
# an unversioned link beside the file the version number is in.
if(APPLE)
    set(tecsLuajitLibrary "${TECS_LUAJIT_PREFIX}/lib/libluajit-5.1.dylib")
else()
    set(tecsLuajitLibrary "${TECS_LUAJIT_PREFIX}/lib/libluajit-5.1.so")
endif()

cmake_path(GET tecsLuajitLibrary FILENAME tecsLuajitSoname)

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
# to nothing.
install(
    FILES "${TECS_LUAJIT_PREFIX}/lib/${tecsLuajitVersioned}"
    DESTINATION lib
    COMPONENT tecs
    RENAME ${tecsLuajitSoname}
)

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
function(tecs_pinned_library name target)
    add_library(tecs_${name} INTERFACE)
    target_link_libraries(tecs_${name} INTERFACE ${target})
    add_library(tecs::${name} ALIAS tecs_${name})
endfunction()

tecs_pinned_library(sdl3 SDL3::SDL3)
tecs_pinned_library(sdl3image SDL3_image::SDL3_image)
tecs_pinned_library(sdl3mixer SDL3_mixer::SDL3_mixer)
tecs_pinned_library(sdl3net SDL3_net::SDL3_net)
tecs_pinned_library(box2d box2d)
tecs_pinned_library(curl CURL::libcurl)
tecs_pinned_library(zlib ZLIB::ZLIB)
tecs_pinned_library(shaderc shaderc_shared)

# Header directories, for the binding generator. It runs the preprocessor
# itself rather than compiling through a target, so it is given directories
# rather than the targets that carry them. A source tree splits its headers
# across the checkout and the build directory wherever one of them is
# generated, which is why several of these name both.
set(TECS_SDL3_INCLUDE_DIRS "${sdl3_SOURCE_DIR}/include" "${sdl3_BINARY_DIR}/include")
set(TECS_SDL3_IMAGE_INCLUDE_DIRS "${sdl3_image_SOURCE_DIR}/include")
set(TECS_SDL3_NET_INCLUDE_DIRS "${sdl3_net_SOURCE_DIR}/include")
set(TECS_SDL3_MIXER_INCLUDE_DIRS "${sdl3_mixer_SOURCE_DIR}/include")
set(TECS_BOX2D_INCLUDE_DIRS "${box2d_SOURCE_DIR}/include")
set(TECS_SPVC_INCLUDE_DIRS "${spirv-cross_SOURCE_DIR}")
set(TECS_CURL_INCLUDE_DIRS "${curl_SOURCE_DIR}/include")
# zlib is configured where SDL_image added it, so its generated zconf.h is
# under that build rather than under one of its own.
set(TECS_ZLIB_INCLUDE_DIRS "${sdl3_image_BINARY_DIR}/external/zlib-build" "${sdl3_image_SOURCE_DIR}/external/zlib")

# ---------------------------------------------- what a packaged tree carries

# The shared libraries a packaged binary references, named one at a time.
#
# Their own projects install more than this, and several install nothing at all
# as a subproject, so neither taking their rules nor leaving them produces a
# package. Naming them here does, and it makes the set enumerable: this list
# and the link table of an installed binary have to agree, which is what
# scripts/checkpackage.py reads and what its LINKED_LIBRARIES declares a
# licence for.
#
# Everything absent is absent for a reason worth knowing. SPIRV-Cross, glslang,
# SPIRV-Tools, libpng and SDL_mixer's four decoders are static, and are inside
# the libraries above rather than beside them. LuaJIT is installed further up,
# by name, because its build is not one of these.
install(
    TARGETS
        SDL3-shared
        SDL3_image-shared
        SDL3_mixer-shared
        SDL3_net-shared
        box2d
        libcurl_shared
        zlib
        mbedtls
        mbedx509
        tfpsacrypto
        shaderc_shared
    LIBRARY DESTINATION lib COMPONENT tecs
)

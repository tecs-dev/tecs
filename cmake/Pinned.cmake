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
FetchContent_Declare(
    box2d
    GIT_REPOSITORY https://github.com/erincatto/box2d.git
    GIT_TAG ${TECS_BOX2D_TAG}
    GIT_SHALLOW TRUE
)

# zlib. Pinned rather than borrowed: libcurl needs it to answer a
# Content-Encoding, and SDL3_image already links whichever copy the machine
# happens to have. A shipped build gets the one named here instead.
#
# Shared, because the engine reaches it through the FFI, which loads a library
# rather than linking one. The tests build example programs that nothing runs.
set(ZLIB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(ZLIB_BUILD_STATIC OFF CACHE BOOL "" FORCE)
set(ZLIB_INSTALL ON CACHE BOOL "" FORCE)

FetchContent_Declare(zlib GIT_REPOSITORY https://github.com/madler/zlib.git GIT_TAG ${TECS_ZLIB_TAG} GIT_SHALLOW TRUE)

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
set(CURL_USE_LIBIDN2 OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH2 OFF CACHE BOOL "" FORCE)
set(ENABLE_ARES OFF CACHE BOOL "" FORCE)
set(USE_LIBRTMP OFF CACHE BOOL "" FORCE)
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
set(CURL_DISABLE_NTLM ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_POP3 ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_RTSP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_SMB ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_SMTP ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TELNET ON CACHE BOOL "" FORCE)
set(CURL_DISABLE_TFTP ON CACHE BOOL "" FORCE)

FetchContent_Declare(curl GIT_REPOSITORY https://github.com/curl/curl.git GIT_TAG ${TECS_CURL_TAG} GIT_SHALLOW TRUE)
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
    zlib
    mbedtls
    curl
)

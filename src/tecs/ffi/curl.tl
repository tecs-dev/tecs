--- libcurl binding: the easy interface and the multi interface both.
---
--- The multi interface is the reason this is here. `curl_easy_perform` runs a
--- whole transfer before it returns, which in a game loop is a frame that does
--- not end until the network answers. `curl_multi_perform` does as much as it
--- can without waiting and reports how many transfers are still running, so a
--- request can be driven from a phase the way everything else is. Binding only
--- the easy half would push the API above this into a thread per request.
---
--- Nothing above this exists yet. This module is the binding and no more.
---
--- **Options are typed, and the FFI will not check it.** `curl_easy_setopt` is
--- variadic, so the compiler cannot tell what a given option wants, and
--- LuaJIT passes a Lua number through `...` as a double. An option in the
--- `CURLOPTTYPE_LONG` range handed a bare number therefore reads eight bytes of
--- floating point as a long. The value has to be a `long` cdata, and an option
--- in the `OFF_T` range a `curl_off_t`. The ranges are the option's own value:
--- below 10000 is long, 10000 is a pointer, 20000 a function pointer, 30000 an
--- off_t and 40000 a blob.
---
--- **A callback outlives its Lua closure only if something holds it.**
--- `ffi.cast` to a callback type allocates a slot that is freed when the cast
--- result is collected, and libcurl will call the freed slot. Whatever sets
--- `CURLOPT_WRITEFUNCTION` has to keep the cast alive for as long as the handle
--- can use it, and free it explicitly afterwards: the slots are a small fixed
--- pool and leaking them exhausts it.

local loader <const> = require("tecs.ffi.loader")

loader.declare("curl")

local namespace <const>, libraryPath <const> = loader.library("curl", "curl", "TECS_CURL_PATH", "curl")

--- The libcurl library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when
--- libcurl cannot be found rather than answering a module whose calls fail
--- later. No version is enforced: `version` reports what loaded, and since
--- libcurl only ever adds options, an option newer than the mapped library
--- fails at `curl_easy_setopt` with `CURLE_UNKNOWN_OPTION` rather than here.
local record curl
    --- Functions and enum constants, resolved through the loaded library.
    --- Every `CURLOPT_*`, `CURLINFO_*`, `CURLMOPT_*`, `CURLcode` and
    --- `CURLMcode` is an enumerator and so lives here rather than in `K`.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`. `CURL_GLOBAL_*`,
    --- `CURLAUTH_*`, `CURLPROTO_*` and the option-type bases are all here.
    K: {string: integer}
    --- What satisfied the load: an absolute path, or the bare soname when the
    --- dynamic linker resolved it itself, or `"(registry)"` when the host
    --- linked the symbols in. Diagnostic, and not always openable.
    path: string
end

curl.C = namespace
curl.K = loader.constants("curl")
curl.path = libraryPath

--- The version banner of the library that was actually loaded.
---
--- Reports the TLS backend and the zlib beside it, which is the one thing a
--- development preset and a packaged one are not guaranteed to share: the
--- first resolves libcurl from the system and gets whatever that was built
--- against, the second builds the pinned revision against the pinned Mbed TLS.
---
--- @return One line, space-separated, of the form libcurl's own banner takes:
---     `libcurl/<version>` followed by each backend it was built with. Meant
---     for a log or a bug report, not for parsing a version out of.
function curl.version(): string
    return loader.toString(curl.C.curl_version())
end

--- The message for a `CURLcode`, as a Lua string.
---
--- @param code The enumerator itself, from `C`, not a number: the FFI converts
---     a Lua number to the enum type, but a value outside the range libcurl
---     knows answers its catch-all text rather than raising.
--- @return English, fixed by libcurl and not localised. Static storage inside
---     libcurl, copied here, so the result outlives the handle.
function curl.errorText(code: loader.CValue): string
    return loader.toString(curl.C.curl_easy_strerror(code))
end

--- The message for a `CURLMcode`, as a Lua string.
---
--- The multi interface's codes are a separate enumeration from `CURLcode` and
--- their numbers overlap, so a code from a multi call put through
--- `errorText` answers a plausible message about the wrong failure.
---
--- @param code A `CURLMcode` enumerator from `C`, as returned by a
---     `curl_multi_*` call.
--- @return English, fixed by libcurl and not localised.
function curl.multiErrorText(code: loader.CValue): string
    return loader.toString(curl.C.curl_multi_strerror(code))
end

return curl

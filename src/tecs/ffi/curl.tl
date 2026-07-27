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

local namespace <const>, libraryPath <const> =
    loader.library("curl", "curl", "TECS_CURL_PATH", "curl")

local record curl
    --- Functions and enum constants, resolved through the loaded library.
    --- Every `CURLOPT_*`, `CURLINFO_*`, `CURLMOPT_*`, `CURLcode` and
    --- `CURLMcode` is an enumerator and so lives here rather than in `K`.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`. `CURL_GLOBAL_*`,
    --- `CURLAUTH_*`, `CURLPROTO_*` and the option-type bases are all here.
    K: {string: integer}
    --- Absolute path of the library that satisfied the load.
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
function curl.version(): string
    return loader.toString(curl.C.curl_version())
end

--- The message for a `CURLcode`, as a Lua string.
function curl.errorText(code: loader.CValue): string
    return loader.toString(curl.C.curl_easy_strerror(code))
end

--- The message for a `CURLMcode`, as a Lua string.
function curl.multiErrorText(code: loader.CValue): string
    return loader.toString(curl.C.curl_multi_strerror(code))
end

return curl

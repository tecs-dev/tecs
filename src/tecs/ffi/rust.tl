--- Rust-owned native services.
---
--- Cargo builds these functions into the host's static native archive. They
--- are reached through the registry rather than a shared library, which keeps
--- the same path working in worker Lua states and single-file releases.

local loader <const> = require("tecs.ffi.loader")

loader.declare("rust")

local namespace <const>, libraryPath <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "rust")

local record rust
    --- Functions exported by the Rust static archive.
    C: loader.CNamespace
    --- What satisfied the load. A host build answers `"(registry)"`.
    path: string
end

rust.C = namespace
rust.path = libraryPath

return rust

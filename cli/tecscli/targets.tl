--- What this machine can package a game for, and why it cannot do the rest.
---
--- **One CLI cannot package for every target, and the reason is not effort.**
---
--- ```
---  Host      Can produce                  Cannot, and why
---  ────────  ───────────────────────────  ─────────────────────────────────
---  macOS     macOS arm64, macOS x64, iOS  Windows: needs MSVC
---  Linux     Linux x64, Android           macOS and iOS: the Xcode SDK is
---                                         not redistributable
---  Windows   Windows x64                  macOS and iOS: the same
--- ```
---
--- Two different kinds of obstacle sit in that table and only one of them
--- could ever be engineered away. Windows needs MSVC and there is no mingw
--- toolchain in this tree; that is work nobody has done. macOS and iOS need the
--- Xcode SDK, whose licence forbids redistribution, so no non-Apple machine can
--- ship a toolchain that produces a Mach-O however much work is done. Saying
--- "unsupported" for both would hide that difference.
---
--- The answer is the same one the engine's own build already gives: `make
--- presets` lists nine and any machine configures two or three. A three-OS CI
--- matrix is how a solo developer reaches all five, which is why `tecs new`
--- scaffolds one.

local ffi <const> = require("ffi")

local record targets
    --- One packaging target and whether this machine can reach it.
    record Target
        --- The preset name, as `make presets` lists it.
        name: string
        --- What it produces.
        description: string
        --- Whether this host can build it.
        available: boolean
        --- Why not, when it cannot. Empty when it can.
        reason: string
    end
end

--- The host this binary is running on, as the table above names one.
function targets.host(): string
    local os_ = (ffi as {string: any}).os as string
    if os_ == "OSX" then
        return "macOS"
    end
    if os_ == "Windows" then
        return "Windows"
    end
    return os_
end

--- Every target, with a reason beside each one this machine cannot build.
---
--- Reasons are specific on purpose. "windows-x64: needs a Windows host with
--- MSVC" tells a developer to add a matrix entry; "unsupported" tells them
--- nothing and invites them to find out twenty minutes into a build.
function targets.all(): {targets.Target}
    local host <const> = targets.host()
    local apple <const> = host == "macOS"
    local windows <const> = host == "Windows"
    local linux <const> = host == "Linux"

    local appleReason <const> = "needs a macOS host: the Xcode SDK cannot be redistributed, so no other machine may ship a toolchain for it"

    return {
        {
            name = "macos-arm64",
            description = "macOS on Apple silicon",
            available = apple,
            reason = apple and "" or appleReason,
        },
        {
            name = "macos-x64",
            description = "macOS on Intel",
            available = apple,
            reason = apple and "" or appleReason,
        },
        {
            name = "ios",
            description = "iOS device",
            available = apple,
            reason = apple and "" or appleReason,
        },
        {
            name = "linux-x64",
            description = "Linux on x86-64",
            available = linux,
            reason = linux and "" or "needs a Linux host",
        },
        {
            name = "android-arm64",
            description = "Android on arm64",
            available = linux,
            reason = linux and "" or "needs a Linux host with the Android NDK",
        },
        {
            name = "windows-x64",
            description = "Windows on x86-64",
            available = windows,
            reason = windows and "" or "needs a Windows host with MSVC; there is no mingw toolchain here",
        },
    }
end

return targets

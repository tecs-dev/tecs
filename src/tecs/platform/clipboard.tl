--- The system clipboard, and the primary selection beside it.
---
--- `events.clipboardUpdate` reports that the clipboard changed and lists the
--- mime types now on offer. This is the other half: what those bytes are, and
--- how to put text there.
---
--- Nothing here is cached. The clipboard belongs to the desktop rather than to
--- this process, so a value read a frame ago may already be wrong, and
--- `clipboardUpdate` is the only invalidation there is.
---
--- ## Ownership of what SDL returns
---
--- Every read hands back an allocation the caller frees, and a failed read
--- hands back an empty string rather than nothing, so the free is owed on that
--- case too. `loader.toString` copies and does not free, which is the right
--- converter and only half the job; the pairing lives in `take` here rather
--- than at each call site, because a read that forgot would leak once per
--- paste and nothing would point at the clipboard as the cause.
---
--- ## Offering bytes that are not text
---
--- `setText` is the whole write surface, and SDL copies the string it is
--- given, so the value's lifetime is SDL's from the moment the call returns.
---
--- Offering an arbitrary mime type is the one clipboard entry point that works
--- the other way round. `SDL_SetClipboardData` takes no copy: it retains a
--- callback and calls it when some other application asks for the bytes, which
--- may be long after the call returned and is a moment this process does not
--- choose. In Lua that is an FFI callback pinned for the lifetime of the offer
--- and entered from wherever SDL fulfils the request, and `physics.TaskPool`
--- already records why this engine keeps its callbacks native rather than
--- taking that bet. Reading an arbitrary mime type carries none of it, so
--- `mimeTypes`, `hasData` and `data` are here and the offer side is not.
---
--- ## The primary selection
---
--- A second, independent clipboard: X11 and Wayland fill it with whatever was
--- last selected and paste it on a middle click, with no copy step at all. It
--- is not a flavour of the clipboard and does not track it.
---
--- Elsewhere there is no such concept. SDL does not fail there; it keeps the
--- value in the video device, so `setPrimary` succeeds, `primary` reads back
--- what this process wrote, and nothing outside the process ever sees it. Read
--- it as a hint that may be answered locally rather than as a shared surface.
---
--- ## With no video
---
--- The clipboard is part of SDL's video subsystem and every entry point fails
--- with "Video subsystem has not been initialized" without it. This module
--- answers the same shape without calling SDL at all: `available` is false,
--- reads are empty, writes fail. A headless tool gets an answer rather than a
--- crash, and SDL's error string is left holding whatever last set it instead
--- of being overwritten by a question that was never going to be answered.
---
--- ## Encoding
---
--- Clipboard text is UTF-8 and passes through byte for byte. Line endings are
--- not normalised, so text copied on Windows arrives as CRLF and stays CRLF,
--- and nothing is trimmed from either end. Text stops at the first NUL,
--- because that is what terminates the C string SDL returns and what every
--- producer of clipboard text intends; `data` uses the length SDL reports
--- instead, so a blob keeps its NULs.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local VIDEO <const> = sdl.K.SDL_INIT_VIDEO

-- One scratch cell for the size and count out-parameters. `mimeTypes` and
-- `data` are the only readers that take one, and neither calls the other, so
-- there is nothing here for a second use to overlap with.
local countOut <const> = loader.newArray("size_t[1]")

local record clipboard
end

--- Converts a string SDL allocated and frees it.
---
--- Nil is not expected from any of these calls, since SDL answers a failed
--- read with an allocated empty string, and is handled because a null
--- dereference is a worse way to learn otherwise.
local function take(pointer: loader.CValue): string
    if pointer == nil then return "" end
    local text = loader.toString(pointer)
    C.SDL_free(pointer)
    return text
end

--- Raises when a required string argument is missing.
---
--- SDL reads a null `const char *` as an empty string, so a nil slipping into
--- `setText` would clear the clipboard rather than fail, which is the one
--- outcome nobody meant.
local function required(value: string, what: string)
    if value == nil then
        error(("tecs: clipboard.%s needs a string"):format(what), 3)
    end
end

--- Whether there is a clipboard to read at all.
---
--- False in a process that never brought up video, where every other function
--- here answers empty or false. Distinguishes that from a clipboard that is
--- simply empty, which no other return value can.
function clipboard.available(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- The clipboard's text, or an empty string when it holds none.
---
--- Empty is also the answer when the clipboard holds something that is not
--- text, and when there is no video. Ask `hasText` to tell those from text
--- that is genuinely empty.
function clipboard.text(): string
    if not clipboard.available() then return "" end
    return take(C.SDL_GetClipboardText())
end

--- Puts `text` on the clipboard, replacing whatever was there.
---
--- SDL copies it, so the string is not retained here. Returns false when the
--- platform refused, which includes having no video.
function clipboard.setText(text: string): boolean
    required(text, "setText")
    if not clipboard.available() then return false end
    return C.SDL_SetClipboardText(text) as boolean
end

--- Whether the clipboard holds text.
---
--- Cheaper than reading it: no allocation crosses the boundary, and on a
--- platform where a read negotiates with the owning application, no
--- negotiation happens.
function clipboard.hasText(): boolean
    if not clipboard.available() then return false end
    return C.SDL_HasClipboardText() as boolean
end

--- Withdraws what this application put on the clipboard.
---
--- The clipboard is left empty rather than restored to what preceded the
--- write, because nothing anywhere remembers what that was.
function clipboard.clear(): boolean
    if not clipboard.available() then return false end
    return C.SDL_ClearClipboardData() as boolean
end

--- Mime types the clipboard currently offers, in the order SDL reports them.
---
--- The same list `clipboardUpdate` carries, for a caller that wants to ask
--- rather than wait to be told. Empty when the clipboard is empty.
function clipboard.mimeTypes(): {string}
    local found: {string} = {}
    if not clipboard.available() then return found end

    local list = C.SDL_GetClipboardMimeTypes(countOut)
    if list == nil then return found end
    local items = loader.castPointer("char **", list)
    local count = tonumber(countOut[0]) as integer
    for index = 0, count - 1 do
        found[index + 1] = loader.toString(items[index] as loader.CValue)
    end
    -- One allocation holds the array and the strings it points at, so one
    -- free releases all of it and freeing an entry would be a double free.
    C.SDL_free(list)
    return found
end

--- Whether the clipboard offers `mimeType`.
function clipboard.hasData(mimeType: string): boolean
    required(mimeType, "hasData")
    if not clipboard.available() then return false end
    return C.SDL_HasClipboardData(mimeType) as boolean
end

--- The clipboard's bytes for `mimeType`, or nil when it offers none.
---
--- Nil rather than an empty string, because a mime type can be offered with no
--- bytes behind it and that is not the same as not being offered.
function clipboard.data(mimeType: string): string
    required(mimeType, "data")
    if not clipboard.available() then return nil end

    local bytes = C.SDL_GetClipboardData(mimeType, countOut)
    if bytes == nil then return nil end
    local blob = loader.toBytes(bytes, tonumber(countOut[0]) as integer)
    C.SDL_free(bytes)
    return blob
end

--- The primary selection's text, or an empty string when it holds none.
function clipboard.primary(): string
    if not clipboard.available() then return "" end
    return take(C.SDL_GetPrimarySelectionText())
end

--- Puts `text` in the primary selection.
---
--- Succeeds on a platform that has no primary selection, where SDL keeps the
--- value for this process and nothing else can read it.
function clipboard.setPrimary(text: string): boolean
    required(text, "setPrimary")
    if not clipboard.available() then return false end
    return C.SDL_SetPrimarySelectionText(text) as boolean
end

--- Whether the primary selection holds text.
function clipboard.hasPrimary(): boolean
    if not clipboard.available() then return false end
    return C.SDL_HasPrimarySelectionText() as boolean
end

return clipboard

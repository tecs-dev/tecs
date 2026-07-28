---
description: "Reading and writing the system clipboard, arbitrary mime types, and the primary selection beside it"
outline: deep
---

# tecs.clipboard

`tecs.clipboard` is the system clipboard: text in, text out, the mime types on offer, the bytes behind one of
them, and the primary selection beside it.

It is the other half of the [`clipboardUpdate` event](/modules/events#kind-reference), which reports that the clipboard
changed and lists the mime types now on offer. Being told and having no way to look is the worse of the two
halves to ship alone.

Nothing here is cached. The clipboard belongs to the desktop rather than to this process, so a value read a
frame ago may already be wrong, and `clipboardUpdate` is the only invalidation there is.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.clipboard`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily on
first field access.

## With no video

The clipboard is part of SDL's video subsystem, so a headless tool has none. Every function here answers the
same shape without calling SDL at all: `available` is false, reads are empty, writes fail. That way a headless
tool gets an answer rather than a crash, and SDL's error string is left holding whatever last set it instead of
being overwritten by a question that was never going to be answered.

### available

Whether there is a clipboard to read at all.

```teal
function clipboard.available(): boolean
```

**Returns:** whether the video subsystem is up. This is the only answer that separates no clipboard from an
empty one, since no other return value can.

## Text

### text

The clipboard's text.

```teal
function clipboard.text(): string
```

**Returns:** the text, or an empty string when the clipboard holds none. Empty is also the answer when the
clipboard holds something that is not text, and when there is no video. Ask `hasText` to tell those apart from
text that is genuinely empty.

### setText

Puts `text` on the clipboard, replacing whatever was there.

```teal
function clipboard.setText(text: string): boolean
```

**Parameters:**

- `text`: the text to offer. SDL copies it, so the string is not retained here.

**Returns:** false when the platform refused, which includes having no video. A missing argument raises, because
SDL reads a null `const char *` as an empty string and a nil slipping through would clear the clipboard rather
than fail.

### hasText

Whether the clipboard holds text.

```teal
function clipboard.hasText(): boolean
```

Cheaper than reading it: no allocation crosses the boundary, and on a platform where a read negotiates with the
owning application, no negotiation happens.

### clear

Withdraws what this application put on the clipboard.

```teal
function clipboard.clear(): boolean
```

The clipboard is left empty rather than restored to what preceded the write, because nothing anywhere remembers
what that was.

**Example:**

```teal
world:observe(0, tecs.events.on.clipboardUpdate, function(event: tecs.events.Event)
    if not event.owner and tecs.clipboard.hasText() then
        pasteBuffer = tecs.clipboard.text()
    end
end)
```

## Arbitrary mime types

Reading a mime type is here; offering one is not. `SDL_SetClipboardData` takes no copy: it retains a callback and
calls it when some other application asks for the bytes, which may be long after the call returned and is a
moment this process does not choose. In Lua that is an FFI callback pinned for the lifetime of the offer and
entered from wherever SDL fulfils the request, and this engine keeps its callbacks native. Reading carries none
of that, so `mimeTypes`, `hasData` and `data` are here and the offer side is not. `setText` is the whole write
surface.

### mimeTypes

Mime types the clipboard currently offers, in the order SDL reports them.

```teal
function clipboard.mimeTypes(): {string}
```

**Returns:** the list, empty when the clipboard is empty. The same list a `clipboardUpdate` event carries, for a
caller that wants to ask rather than wait to be told.

### hasData

Whether the clipboard offers `mimeType`.

```teal
function clipboard.hasData(mimeType: string): boolean
```

### data

The clipboard's bytes for `mimeType`.

```teal
function clipboard.data(mimeType: string): string
```

**Returns:** the bytes, or nil when the clipboard offers none. Nil rather than an empty string, because a mime
type can be offered with no bytes behind it and that is not the same as not being offered.

**Example:**

```teal
for _, mime in ipairs(tecs.clipboard.mimeTypes()) do
    if mime == "image/png" then
        local bytes <const> = tecs.clipboard.data(mime)
        if bytes ~= nil then importScreenshot(bytes) end
    end
end
```

## The primary selection

A second, independent clipboard: X11 and Wayland fill it with whatever was last selected and paste it on a
middle click, with no copy step at all. It is not a flavour of the clipboard and does not track it.

Elsewhere there is no such concept. SDL does not fail there; it keeps the value in the video device, so
`setPrimary` succeeds, `primary` reads back what this process wrote, and nothing outside the process ever sees
it. Read it as a hint that may be answered locally rather than as a shared surface.

### primary

```teal
function clipboard.primary(): string
```

**Returns:** the primary selection's text, or an empty string when it holds none.

### setPrimary

```teal
function clipboard.setPrimary(text: string): boolean
```

Succeeds on a platform that has no primary selection, where SDL keeps the value for this process alone.

### hasPrimary

```teal
function clipboard.hasPrimary(): boolean
```

## Encoding

Clipboard text is UTF-8 and passes through byte for byte. Line endings are not normalised, so text copied on
Windows arrives as CRLF and stays CRLF, and nothing is trimmed from either end. Text stops at the first NUL,
because that is what terminates the C string SDL returns and what every producer of clipboard text intends;
`data` uses the length SDL reports instead, so a blob keeps its NULs.

## Design record

- [The clipboard](https://github.com/tecs-dev/tecs/blob/main/README.md#the-clipboard)
- [Events](https://github.com/tecs-dev/tecs/blob/main/README.md#events)

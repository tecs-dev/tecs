--- Press and release pairing for Love input events.
---
--- A press event leaves an input logically down until its matching release
--- arrives, so both the input tape and the replay recorder need to name a
--- press, find the release that ends it, and recognise that release when it
--- comes. One table drives all three, so a new device type is one entry
--- rather than four hand-written branches that can disagree.

local record inputidentity
    --- Identity of a press event, or nil when the event is not a press.
    press: function(event: string, args: {any}): string

    --- The release event that ends a press event, or nil.
    pairedRelease: function(event: string): string

    --- Identity of the press a release event ends, or nil when the event is
    --- not a release.
    release: function(event: string, args: {any}): string
end

local record Kind
    prefix: string
    --- Argument carrying the key, button, or touch id.
    argIndex: integer
    press: string
    release: string
end

local KINDS <const>: {Kind} = {
    {prefix = "key:", argIndex = 1, press = "keypressed", release = "keyreleased"},
    {prefix = "mouse:", argIndex = 3, press = "mousepressed", release = "mousereleased"},
    {prefix = "touch:", argIndex = 1, press = "touchpressed", release = "touchreleased"},
}

local BY_PRESS <const>: {string: Kind} = {}
local BY_RELEASE <const>: {string: Kind} = {}
for i = 1, #KINDS do
    BY_PRESS[KINDS[i].press] = KINDS[i]
    BY_RELEASE[KINDS[i].release] = KINDS[i]
end

-- A press and its release carry the identifying argument in the same slot,
-- so both sides read one identity function.
local function identify(kind: Kind, args: {any}): string
    if not kind then return nil end
    return kind.prefix .. tostring(args[kind.argIndex])
end

function inputidentity.press(event: string, args: {any}): string
    return identify(BY_PRESS[event], args)
end

function inputidentity.pairedRelease(event: string): string
    local kind <const> = BY_PRESS[event]
    return kind and kind.release
end

function inputidentity.release(event: string, args: {any}): string
    return identify(BY_RELEASE[event], args)
end

return inputidentity

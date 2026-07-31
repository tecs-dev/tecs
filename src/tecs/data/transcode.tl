-- Converts complete byte strings between character encodings through SDL.
--
-- This is subordinate to `tecs.data`: the public name stays
-- `tecs.data.transcode`. The lower-level SDL API is used instead of
-- `SDL_iconv_string` because the latter does not report the output length,
-- which makes a NUL-containing encoding such as UTF-16 impossible to return
-- as an exact Lua string.

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")

local C <const> = sdl.C

local iconvOpen <const> = C.SDL_iconv_open as function(toEncoding: string, fromEncoding: string): loader.CPtr
local iconvClose <const> = C.SDL_iconv_close as function(handle: loader.CPtr): integer
local iconv <const> = C.SDL_iconv as function(
    handle: loader.CPtr,
    input: loader.CArray | nil,
    inputLeft: loader.CArray | nil,
    output: loader.CArray,
    outputLeft: loader.CArray
): loader.CValue

-- SDL declares these as `(size_t)-n`, so they remain exact cdata values rather
-- than passing through a Lua number, which cannot represent every `size_t`.
local ICONV_HANDLE_ERROR <const> = ffi.cast("SDL_iconv_t", -1) as loader.CPtr
local ICONV_ERROR <const> = ffi.cast("size_t", -1) as loader.CValue
local ICONV_E2BIG <const> = ffi.cast("size_t", -2) as loader.CValue
local ICONV_EILSEQ <const> = ffi.cast("size_t", -3) as loader.CValue
local ICONV_EINVAL <const> = ffi.cast("size_t", -4) as loader.CValue

local CHUNK_SIZE <const> = 4096

local function continuation(byte: integer): boolean
    return byte >= 0x80 and byte <= 0xBF
end

local function validateUTF8(bytes: string): string
    local index = 1
    while index <= #bytes do
        local first <const> = string.byte(bytes, index) as integer
        local count = 0
        local secondMin = 0x80
        local secondMax = 0xBF
        if first <= 0x7F then
            index = index + 1
        elseif first >= 0xC2 and first <= 0xDF then
            count = 1
        elseif first >= 0xE0 and first <= 0xEF then
            count = 2
            if first == 0xE0 then
                secondMin = 0xA0
            elseif first == 0xED then
                secondMax = 0x9F
            end
        elseif first >= 0xF0 and first <= 0xF4 then
            count = 3
            if first == 0xF0 then
                secondMin = 0x90
            elseif first == 0xF4 then
                secondMax = 0x8F
            end
        else
            return ("tecs.data.transcode: invalid UTF-8 input at byte %d"):format(index)
        end

        if count > 0 then
            if index + count > #bytes then
                return ("tecs.data.transcode: incomplete UTF-8 input at byte %d"):format(index)
            end
            local second <const> = string.byte(bytes, index + 1) as integer
            if second < secondMin or second > secondMax then
                return ("tecs.data.transcode: invalid UTF-8 input at byte %d"):format(index)
            end
            for offset = 2, count do
                if not continuation(string.byte(bytes, index + offset) as integer) then
                    return ("tecs.data.transcode: invalid UTF-8 input at byte %d"):format(index)
                end
            end
            index = index + count + 1
        end
    end
    return nil
end

local function word(bytes: string, index: integer, littleEndian: boolean): integer
    local first <const>, second <const> = string.byte(bytes, index, index + 1)
    if littleEndian then
        return (first as integer) + (second as integer) * 0x100
    end
    return (first as integer) * 0x100 + (second as integer)
end

local function validateUTF16(bytes: string, littleEndian: boolean, name: string): string
    local index = 1
    while index <= #bytes do
        if index + 1 > #bytes then
            return ("tecs.data.transcode: incomplete %s input at byte %d"):format(name, index)
        end
        local first <const> = word(bytes, index, littleEndian)
        if first >= 0xD800 and first <= 0xDBFF then
            if index + 3 > #bytes then
                return ("tecs.data.transcode: incomplete %s input at byte %d"):format(name, index)
            end
            local second <const> = word(bytes, index + 2, littleEndian)
            if second < 0xDC00 or second > 0xDFFF then
                return ("tecs.data.transcode: invalid %s input at byte %d"):format(name, index)
            end
            index = index + 4
        elseif first >= 0xDC00 and first <= 0xDFFF then
            return ("tecs.data.transcode: invalid %s input at byte %d"):format(name, index)
        else
            index = index + 2
        end
    end
    return nil
end

local function validateUTF32(bytes: string, littleEndian: boolean, name: string): string
    local index = 1
    while index <= #bytes do
        if index + 3 > #bytes then
            return ("tecs.data.transcode: incomplete %s input at byte %d"):format(name, index)
        end
        local a <const>, b <const>, c <const>, d <const> = string.byte(bytes, index, index + 3)
        local codepoint: integer
        if littleEndian then
            codepoint = (a as integer) + (b as integer) * 0x100 + (c as integer) * 0x10000 + (d as integer) * 0x1000000
        else
            codepoint = (a as integer) * 0x1000000 + (b as integer) * 0x10000 + (c as integer) * 0x100 + (d as integer)
        end
        if codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
            return ("tecs.data.transcode: invalid %s input at byte %d"):format(name, index)
        end
        index = index + 4
    end
    return nil
end

local function validateInput(bytes: string, encoding: string): string
    local normalized <const> = encoding:upper():gsub("[_%-]", "")
    if normalized == "UTF8" then
        return validateUTF8(bytes)
    elseif normalized == "UTF16LE" then
        return validateUTF16(bytes, true, encoding)
    elseif normalized == "UTF16BE" then
        return validateUTF16(bytes, false, encoding)
    elseif normalized == "UTF32LE" or normalized == "UCS4LE" then
        return validateUTF32(bytes, true, encoding)
    elseif normalized == "UTF32BE" or normalized == "UCS4BE" then
        return validateUTF32(bytes, false, encoding)
    end
    return nil
end

local function validEncoding(name: string, argument: string)
    if name == "" then
        error(("tecs.data.transcode: %s must not be empty"):format(argument), 3)
    end
    if name:find("\0", 1, true) ~= nil then
        error(("tecs.data.transcode: %s must not contain NUL bytes"):format(argument), 3)
    end
end

local function close(handle: loader.CPtr): boolean
    ffi.gc(handle as ffi.CData, nil)
    return iconvClose(handle) == 0
end

local function failAt(kind: string, fromEncoding: string, inputLeft: loader.CArray, length: integer): string
    local remaining <const> = tonumber(inputLeft[0]) as integer
    return ("tecs.data.transcode: %s %s input at byte %d"):format(kind, fromEncoding, length - remaining + 1)
end

local function run(handle: loader.CPtr, bytes: string, fromEncoding: string): string, string
    -- These arrays hold the pointer variables that iconv advances. `bytes`
    -- remains reachable for the whole call, so the borrowed input pointer does
    -- not outlive its Lua string.
    local input <const> = loader.newArray("const char *[1]")
    local inputLeft <const> = loader.newArray("size_t[1]")
    input[0] = bytes
    inputLeft[0] = #bytes

    local chunks: {string} = {}
    local flushing = #bytes == 0
    while true do
        local outputBuffer <const> = loader.newArray("uint8_t[?]", CHUNK_SIZE)
        local output <const> = loader.newArray("char *[1]")
        local outputLeft <const> = loader.newArray("size_t[1]")
        output[0] = outputBuffer
        outputLeft[0] = CHUNK_SIZE

        -- A NULL input after consuming the bytes flushes any final shift
        -- sequence required by a stateful target encoding.
        local result: loader.CValue
        if flushing then
            result = iconv(handle, nil, nil, output, outputLeft)
        else
            result = iconv(handle, input, inputLeft, output, outputLeft)
        end
        local produced <const> = CHUNK_SIZE - (tonumber(outputLeft[0]) as integer)
        if produced > 0 then
            chunks[#chunks + 1] = loader.toBytes(outputBuffer as loader.CValue, produced)
        end

        if result == ICONV_E2BIG then
            -- A full chunk is expected, but accepting a partial one is valid
            -- for a stateful converter. The next call resumes from the
            -- advanced input pointer with the same context.
        elseif result == ICONV_EILSEQ then
            if flushing then
                return nil, "tecs.data.transcode: target encoding could not be finalized"
            end
            return nil, failAt("invalid or unconvertible", fromEncoding, inputLeft, #bytes)
        elseif result == ICONV_EINVAL then
            if flushing then
                return nil, "tecs.data.transcode: target encoding could not be finalized"
            end
            return nil, failAt("incomplete", fromEncoding, inputLeft, #bytes)
        elseif result == ICONV_ERROR then
            if flushing then
                return nil, "tecs.data.transcode: target encoding could not be finalized"
            end
            return nil, failAt("unconvertible", fromEncoding, inputLeft, #bytes)
        else
            if flushing then
                return table.concat(chunks), nil
            end
            if tonumber(inputLeft[0]) ~= 0 then
                return nil, failAt("unconvertible", fromEncoding, inputLeft, #bytes)
            end
            flushing = true
        end
    end
end

local function transcode(bytes: string, fromEncoding: string, toEncoding: string): string
    validEncoding(fromEncoding, "fromEncoding")
    validEncoding(toEncoding, "toEncoding")
    local invalid <const> = validateInput(bytes, fromEncoding)
    if invalid ~= nil then
        error(invalid, 2)
    end

    local handle <const> = iconvOpen(toEncoding, fromEncoding)
    if handle == ICONV_HANDLE_ERROR then
        error(
            ("tecs.data.transcode: cannot convert from %q to %q; an encoding " .. "name is not supported"):format(
                fromEncoding, toEncoding
            ),
            2
        )
    end

    -- A finalizer protects the context if allocation itself raises inside
    -- `run`; the normal path detaches it and closes synchronously below.
    ffi.gc(handle as ffi.CData, iconvClose as function(ffi.CData): integer)
    local ran <const>, converted, reason = pcall(run, handle, bytes, fromEncoding) as (boolean, any, string)
    local closed <const> = close(handle)

    if not ran then
        error(converted, 0)
    end
    if reason ~= nil then
        error(reason, 2)
    end
    if not closed then
        error("tecs.data.transcode: SDL could not close the conversion context", 2)
    end
    return converted as string
end

return transcode

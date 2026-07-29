--[=[
Compiled regular expressions over Lua byte strings.

Patterns use the Rust `regex` crate's syntax. Compilation builds the
automaton once; every method on the returned
[`Regex`](tealdoc:tecs.regex.Regex) reuses it. Inline flags
such as `(?i)` and `(?m)` configure a pattern without a second options
vocabulary.

```teal
local trailingDigits <const> = tecs.regex.compile([[(\d+)$]])

local frame <const> = trailingDigits:find("sprites/hero_04")
if frame ~= nil then
    print(frame.value, frame.first, frame.last)
end

print(trailingDigits:replaceAll("hero_04 orc_11", "N"))
```

Subjects remain byte strings, including strings that are not valid UTF-8.
Match positions therefore follow Lua's string functions: 1-based,
inclusive byte indices. An empty match has `last == first - 1`.
]=]

local ffi <const> = require("ffi")
local binding <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")

local C <const> = binding.C

local record regex
    --- Describes one matched byte range.
    record Match
        --- Read-only. Contains the bytes copied from the matched range.
        value: string
        --- Read-only. Reports the first matched byte using a 1-based index.
        first: integer
        --- Read-only. Reports the inclusive last matched byte. An empty match
        --- reports `first - 1`.
        last: integer
        --- Read-only. Reports the capture-group index, with zero for the whole
        --- match.
        index: integer
        --- Read-only. Contains the capture name, or nil for an unnamed group.
        name: string
    end

    --- Contains a whole match and its populated capture groups.
    record Captures
        --- Read-only. Contains group zero, which covers the whole match.
        whole: Match
        --- Read-only. Contains explicit groups by their 1-based index. An
        --- unmatched optional group leaves a hole.
        groups: {Match}
        --- Read-only. Reports the number of explicit groups in the pattern,
        --- including groups that did not match.
        groupCount: integer
        --- Read-only. Maps matched group names to the same values in `groups`.
        named: {string: Match}
    end

    --- Represents a compiled Rust regular expression.
    record Regex
        --- Read-only. Contains the source pattern unchanged.
        pattern: string
        --- Engine-owned. Stores the compiled native expression. Ordinary game
        --- code should ignore this field.
        _handle: loader.CPtr
        --- Engine-owned. Stores reusable native match spans. Ordinary game
        --- code should ignore this field.
        _spans: loader.CArray
        --- Engine-owned. Maps capture indices to names. Ordinary game code
        --- should ignore this field.
        _captureNames: {integer: string}
        --- Engine-owned. Stores the allocated capture count. Ordinary game
        --- code should ignore this field.
        _captureCount: integer

        --- Reports whether any part of a subject matches.
        ---
        --- ```teal
        --- local imageName <const> = tecs.regex.compile([[\.(png|jpg)$]])
        --- if imageName:isMatch(path) then
        ---     loadImage(path)
        --- end
        --- ```
        ---
        --- @param subject Arbitrary bytes. Unlike the pattern, these need not be UTF-8.
        --- @return True when the expression matches at least once.
        isMatch: function(self: Regex, subject: string): boolean

        --- Finds the first match at or after a byte position.
        ---
        --- ```teal
        --- local number <const> = tecs.regex.compile([[\d+]])
        --- local found <const> = number:find("hp=100")
        --- if found ~= nil then
        ---     print(found.value, found.first, found.last) -- "100", 4, 6
        --- end
        --- ```
        ---
        --- @param subject Arbitrary bytes.
        --- @param init First byte considered, under `string.find`'s rules: 1 by default, a negative
        ---     value counts back from the end, and the method clamps a value before 1 to 1.
        --- @return The matched bytes and their range, or nil when nothing matches.
        find: function(self: Regex, subject: string, init?: integer): Match

        --- Finds the first match and every capture group it populated.
        ---
        --- `groups` may contain holes when optional groups do not participate;
        --- iterate through `groupCount`, not `#groups`. A named entry aliases
        --- the same [`Match`](tealdoc:tecs.regex.Match) stored at its numbered index.
        ---
        --- @param subject Arbitrary bytes.
        --- @param init First byte considered, under the same rules as `find`.
        --- @return The whole match, numbered groups and named aliases, or nil when nothing matches.
        captures: function(self: Regex, subject: string, init?: integer): Captures

        --- Replaces the first match.
        ---
        --- The method expands capture references in the replacement: `$0` is the whole match, `$1` is the
        ---     first group, `$name` and `${name}` select a named group, and `$$` writes one dollar
        ---     sign. A reference the pattern does not declare expands to an empty string.
        ---
        --- ```teal
        --- local assignment <const> = tecs.regex.compile([[(\w+)=(\d+)]])
        --- local text <const> = assignment:replace("hp=100 mp=50", "$1: $2")
        --- -- text is "hp: 100 mp=50"
        --- ```
        ---
        --- @param subject Arbitrary bytes.
        --- @param replacement Arbitrary bytes, with capture references interpreted as described above.
        --- @return A new string when something matched, or the original string unchanged when nothing
        ---     did.
        replace: function(self: Regex, subject: string, replacement: string): string

        --- Replaces every non-overlapping match.
        ---
        --- ```teal
        --- local digits <const> = tecs.regex.compile([[\d+]])
        --- local redacted <const> = digits:replaceAll("room 12, floor 3", "#")
        --- -- redacted is "room #, floor #"
        --- ```
        ---
        --- @param subject Arbitrary bytes.
        --- @param replacement The same capture-reference syntax as `replace`.
        --- @return A new string when something matched, or the original string unchanged when nothing
        ---     did.
        replaceAll: function(self: Regex, subject: string, replacement: string): string
    end

    --- Compiles a Rust regular expression.
    ---
    --- Compilation raises on malformed syntax or a pattern that is not UTF-8.
    --- Rust's Unicode character classes work by default; use inline
    --- flags to change the expression, such as `(?i)` for case-insensitive
    --- matching or `(?-u:.)` for one arbitrary byte.
    ---
    --- Keep the returned object and reuse it. The Lua collector releases its
    --- native allocation automatically.
    ---
    --- @param pattern Rust regex syntax, with NUL bytes allowed where that syntax allows them.
    --- @return A compiled expression whose native allocation the Lua collector releases.
    compile: function(pattern: string): Regex
end

local RegexMT <const>: metatable<regex.Regex> = {__index = regex.Regex}

local function startOffset(subject: string, init: integer, level: integer): integer
    if init == nil then
        return 0
    end
    if type(init) ~= "number" or init ~= math.floor(init) then
        error("tecs: regex init must be an integer", level)
    end
    if init < 0 then
        init = #subject + init + 1
    end
    if init < 1 then
        init = 1
    end
    if init > #subject + 1 then
        return nil
    end
    return init - 1
end

local function matched(subject: string, span: loader.CStruct, index: integer, name: string): regex.Match
    local first <const> = (tonumber(span.start) as integer) + 1
    local last <const> = tonumber(span["end"]) as integer
    return {
        value = subject:sub(first, last),
        first = first,
        last = last,
        index = index,
        name = name,
    }
end

function regex.Regex:isMatch(subject: string): boolean
    return C.tecsRegexIsMatch(self._handle, subject, #subject) as boolean
end

function regex.Regex:find(subject: string, init?: integer): regex.Match
    local start <const> = startOffset(subject, init, 2)
    if start == nil then
        return nil
    end
    if not C.tecsRegexFind(self._handle, subject, #subject, start, self._spans) as boolean then
        return nil
    end
    local span <const> = (self._spans as {integer: loader.CStruct})[0]
    return matched(subject, span, 0, nil)
end

function regex.Regex:captures(subject: string, init?: integer): regex.Captures
    local start <const> = startOffset(subject, init, 2)
    if start == nil then
        return nil
    end
    if not C.tecsRegexCaptures(self._handle, subject, #subject, start, self._spans, self._captureCount) as boolean then
        return nil
    end

    local spans <const> = self._spans as {integer: loader.CStruct}
    local groups: {regex.Match} = {}
    local named: {string: regex.Match} = {}
    local whole <const> = matched(subject, spans[0], 0, nil)
    for index = 1, self._captureCount - 1 do
        local span <const> = spans[index]
        if span.matched as boolean then
            local name <const> = self._captureNames[index]
            local capture <const> = matched(subject, span, index, name)
            groups[index] = capture
            if name ~= nil then
                named[name] = capture
            end
        end
    end
    return {
        whole = whole,
        groups = groups,
        groupCount = self._captureCount - 1,
        named = named,
    }
end

local function replaceMatches(expression: regex.Regex, subject: string, replacement: string, limit: integer): string
    local bytes <const> = C.tecsRegexReplace(expression._handle, subject, #subject, replacement, #replacement, limit)
    if bytes == nil then
        return subject
    end
    local length <const> = tonumber(C.tecsBytesLength(bytes)) as integer
    local output <const> = loader.toBytes(C.tecsBytesData(bytes), length)
    C.tecsBytesDestroy(bytes)
    return output
end

function regex.Regex:replace(subject: string, replacement: string): string
    return replaceMatches(self, subject, replacement, 1)
end

function regex.Regex:replaceAll(subject: string, replacement: string): string
    return replaceMatches(self, subject, replacement, 0)
end

function regex.compile(pattern: string): regex.Regex
    local handle = C.tecsRegexCompile(pattern, #pattern)
    if handle == nil then
        error("tecs: invalid regex: " .. loader.toString(C.tecsRustError()), 2)
    end
    handle = ffi.gc(handle as ffi.CData, C.tecsRegexDestroy as function(ffi.CData)) as loader.CPtr

    local count <const> = tonumber(C.tecsRegexCaptureCount(handle)) as integer
    local names: {integer: string} = {}
    local length <const> = loader.newArray("size_t[1]")
    for index = 1, count - 1 do
        local name <const> = C.tecsRegexCaptureName(handle, index, length)
        if name ~= nil then
            names[index] = loader.toBytes(name, tonumber(length[0]) as integer)
        end
    end

    local compiled = setmetatable({} as regex.Regex, RegexMT)
    compiled.pattern = pattern
    compiled._handle = handle
    compiled._spans = loader.newArray("TecsRegexSpan[?]", count)
    compiled._captureNames = names
    compiled._captureCount = count
    return compiled
end

return regex

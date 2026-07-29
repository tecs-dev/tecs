--- Compiled regular expressions over Lua byte strings.
---
--- Patterns use the Rust `regex` crate's syntax. Compilation builds the
--- automaton once; every method on the returned value reuses it. Inline flags
--- such as `(?i)` and `(?m)` configure a pattern without a second options
--- vocabulary.
---
--- ```teal
--- local trailingDigits <const> = tecs.regex.compile([[(\d+)$]])
---
--- local frame <const> = trailingDigits:find("sprites/hero_04")
--- if frame ~= nil then
---     print(frame.value, frame.first, frame.last)
--- end
---
--- print(trailingDigits:replaceAll("hero_04 orc_11", "N"))
--- ```
---
--- Subjects remain byte strings, including strings that are not valid UTF-8.
--- Match positions therefore follow Lua's string functions: 1-based,
--- inclusive byte indices. An empty match has `last == first - 1`.

local ffi <const> = require("ffi")
local binding <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")

local C <const> = binding.C

--- Compiled regular expressions over Lua byte strings.
---
--- ## Compile once
---
--- `compile` builds the automaton once. Keep the returned `Regex` and reuse it
--- for every subject rather than compiling inside a frame loop:
---
--- ```teal
--- local assignment <const> = tecs.regex.compile([[(?<name>[a-z]+)=(\d+)]])
--- local captures <const> = assignment:captures("health=100")
--- if captures ~= nil then
---     print(captures.named.name.value) -- "health"
---     print(captures.groups[2].value)  -- "100"
--- end
--- ```
---
--- Patterns use Rust `regex` syntax. Inline flags such as `(?i)` and `(?m)`
--- configure them; look-around and backreferences are deliberately unsupported
--- so searches remain linear in the pattern and subject sizes.
---
--- ## Byte strings and positions
---
--- Subjects may contain arbitrary bytes, including invalid UTF-8. `first` and
--- `last` are 1-based inclusive byte positions, matching `string.find`; an
--- empty match has `last == first - 1`. Patterns themselves must be UTF-8.
--- Disable Unicode for a pattern fragment that intentionally matches arbitrary
--- bytes, for example `(?-u:.)`.
---
--- ## Replacement
---
--- `replace` changes the first match and `replaceAll` changes every
--- non-overlapping match. Replacement strings expand `$0`, `$1`, `$name`,
--- `${name}`, and `$$`:
---
--- ```teal
--- local name <const> = tecs.regex.compile([[(?<last>[A-Za-z]+),\s+([A-Za-z]+)]])
--- local display <const> = name:replace("Dowling, Michael", "$2 $last")
--- -- display is "Michael Dowling"
--- ```
local record regex
    --- One matched byte range.
    record Match
        --- The bytes inside the range, copied from the subject.
        value: string
        --- First byte in the subject, 1-based.
        first: integer
        --- Last byte in the subject, inclusive. One less than `first` for an empty match.
        last: integer
        --- Capture-group index, with zero reserved for the whole match.
        index: integer
        --- Capture name, or nil for the whole match and an unnamed group.
        name: string
    end

    --- A whole match and the capture groups populated by it.
    record Captures
        --- Group zero: the whole expression's match.
        whole: Match
        --- Explicit groups, indexed by their 1-based group number. An unmatched optional group leaves
        ---     a hole; use `groupCount` rather than `#groups`.
        groups: {Match}
        --- Number of explicit groups in the pattern, including groups that did not match this subject.
        groupCount: integer
        --- Matched named groups, pointing at the same `Match` values as `groups`.
        named: {string: Match}
    end

    --- A compiled Rust regular expression.
    record Regex
        --- Source pattern, unchanged.
        pattern: string
        _handle: loader.CPtr
        _spans: loader.CArray
        _captureNames: {integer: string}
        _captureCount: integer

        --- Whether any part of a subject matches.
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
        ---     value counts back from the end, and a value before 1 is clamped to 1.
        --- @return The matched bytes and their range, or nil when nothing matches.
        find: function(self: Regex, subject: string, init?: integer): Match

        --- Finds the first match and every capture group it populated.
        ---
        --- `groups` may contain holes when optional groups do not participate;
        --- iterate through `groupCount`, not `#groups`. A named entry aliases
        --- the same `Match` stored at its numbered index.
        ---
        --- @param subject Arbitrary bytes.
        --- @param init First byte considered, under the same rules as `find`.
        --- @return The whole match, numbered groups and named aliases, or nil when nothing matches.
        captures: function(self: Regex, subject: string, init?: integer): Captures

        --- Replaces the first match.
        ---
        --- Capture references in the replacement are expanded: `$0` is the whole match, `$1` is the
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
    --- Rust's Unicode character classes are enabled by default; use inline
    --- flags to change the expression, such as `(?i)` for case-insensitive
    --- matching or `(?-u:.)` for one arbitrary byte.
    ---
    --- Keep the returned object and reuse it. Its native allocation is released
    --- automatically when Lua collects it.
    ---
    --- @param pattern Rust regex syntax, with NUL bytes allowed where that syntax allows them.
    --- @return A compiled expression whose native allocation is released by the Lua collector.
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

---
description: "Compiled Rust regular expressions over Lua byte strings, with positions and capture groups"
outline: deep
---

# tecs.regex

`tecs.regex` compiles a pattern once and reuses its automaton:

```teal
local assignment <const> = tecs.regex.compile([[(?<name>[a-z]+)=(\d+)]])

if assignment:isMatch("health=100") then
    local captures <const> = assignment:captures("health=100")
    print(captures.named.name.value) -- "health"
    print(captures.groups[2].value)  -- "100"
end
```

The implementation is Rust's `regex` crate. Its syntax has Unicode character classes and the inline flags
`(?i)`, `(?m)`, `(?s)`, `(?U)`, `(?u)` and `(?x)`, but deliberately has no look-around or backreferences.
Those omissions keep searches linear in the size of the pattern and subject rather than letting a pattern
produce exponential backtracking.

## Why it has its own module

A regex is compiled state that is applied repeatedly. It therefore does not belong in [`tecs.data`](/modules/data),
whose operations consume one whole byte string and answer another without keeping an object between calls.
`tecs.regex` also describes the vocabulary a game already uses: `compile`, `isMatch`, `find` and `captures`
are about regular expressions rather than an invented text-processing category.

The surface is intentionally smaller than `RegexBuilder`. Flags live in the pattern, where Rust regex syntax
already defines them, and the common operations are methods on the compiled value. Explicit match iteration
is absent; repeatedly calling `find` with its optional start position gives code control over empty matches
and advancement rather than hiding those decisions in a stateful iterator.

## Byte strings and positions

Lua strings are bytes, so subjects may contain invalid UTF-8 and every position is a byte position. `first`
and `last` use the same convention as `string.find`: 1-based and inclusive. That makes the matched value
exactly `subject:sub(found.first, found.last)`. An empty match has `last == first - 1`, again like
`string.find`.

Patterns are different. Rust regex syntax is text, so the pattern passed to `compile` must be UTF-8.
Unicode mode is on by default even though the subject is a byte string: `\w`, `\b` and `.` use Unicode
semantics. A pattern that deliberately matches arbitrary non-UTF-8 bytes disables Unicode for that part:

```teal
local anyByte <const> = tecs.regex.compile([[(?-u:.)]])
```

The optional `init` on `find` and `captures` follows Lua's rules. It defaults to 1, a negative value counts
back from the end, and anything before 1 is clamped to 1. A value after `#subject + 1` finds nothing.

## Captures

`captures` answers one `Captures` record:

- `whole` is group zero.
- `groups[1]` through `groups[groupCount]` are the explicit groups.
- `named.name` aliases the same `Match` as the numbered group carrying that name.

An optional group that did not participate leaves a hole in `groups`, and an unmatched named group is absent
from `named`. `groupCount` remains the number declared by the pattern, so `#groups` is never needed and never
lies because a trailing group was absent.

Every `Match` carries its copied `value`, `first`, `last`, zero- or one-based `index`, and optional `name`.
The native call itself borrows the subject only while it searches; no returned value keeps a pointer into a
Lua string.

## Replacement

`replace` changes the first match and `replaceAll` changes every non-overlapping match. Replacement strings
use Rust regex capture syntax: `$0` is the whole match, `$1` is the first explicit group, `$name` and
`${name}` select a named group, and `$$` writes one dollar sign. An unknown or unmatched group expands to an
empty string.

```teal
local name <const> = tecs.regex.compile([[(?<last>[A-Za-z]+),\s+([A-Za-z]+)]])
local display <const> = name:replace("Dowling, Michael", "$2 $last")
-- display is "Michael Dowling"

local digits <const> = tecs.regex.compile([[\d+]])
local redacted <const> = digits:replaceAll("room 12, floor 3", "#")
-- redacted is "room #, floor #"
```

When nothing matches, both methods return the original subject unchanged. Subjects and replacements remain
arbitrary byte strings. Only the replacement template syntax is interpreted.

## Lifetime

`compile` owns a Rust allocation. The returned Lua value has a native finalizer, so ordinary code does not
close it and collection releases it. Each compiled expression also reuses one span buffer for `find` and
`captures`; `isMatch` and `find` create no native match allocation, while `captures` creates only the Lua
tables it returns.

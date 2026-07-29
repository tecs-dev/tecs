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

Every function and type this module carries, rendered from `src/tecs/regex.tl`.

<a id="tecs.regex.Captures"></a>

### tecs.regex.Captures

<pre><code v-pre>record <a href="#tecs.regex.Captures">tecs.regex.Captures</a>
</code></pre>

A whole match and the capture groups populated by it.

<a id="tecs.regex.Captures.whole"></a>

### tecs.regex.Captures.whole

<pre><code v-pre><a href="#tecs.regex.Captures.whole">tecs.regex.Captures.whole</a>: <a href="#tecs.regex.Match">Match</a>
</code></pre>

Group zero: the whole expression's match.

<a id="tecs.regex.Captures.groups"></a>

### tecs.regex.Captures.groups

<pre><code v-pre><a href="#tecs.regex.Captures.groups">tecs.regex.Captures.groups</a>: {<a href="#tecs.regex.Match">Match</a>}
</code></pre>

Explicit groups, indexed by their 1-based group number. An unmatched optional group leaves
a hole; use `groupCount` rather than `#groups`.

<a id="tecs.regex.Captures.groupCount"></a>

### tecs.regex.Captures.groupCount

<pre><code v-pre><a href="#tecs.regex.Captures.groupCount">tecs.regex.Captures.groupCount</a>: integer
</code></pre>

Number of explicit groups in the pattern, including groups that did not match this subject.

<a id="tecs.regex.Captures.named"></a>

### tecs.regex.Captures.named

<pre><code v-pre><a href="#tecs.regex.Captures.named">tecs.regex.Captures.named</a>: {string : <a href="#tecs.regex.Match">Match</a>}
</code></pre>

Matched named groups, pointing at the same `Match` values as `groups`.

<a id="tecs.regex.Match"></a>

### tecs.regex.Match

<pre><code v-pre>record <a href="#tecs.regex.Match">tecs.regex.Match</a>
</code></pre>

One matched byte range.

<a id="tecs.regex.Match.value"></a>

### tecs.regex.Match.value

<pre><code v-pre><a href="#tecs.regex.Match.value">tecs.regex.Match.value</a>: string
</code></pre>

The bytes inside the range, copied from the subject.

<a id="tecs.regex.Match.first"></a>

### tecs.regex.Match.first

<pre><code v-pre><a href="#tecs.regex.Match.first">tecs.regex.Match.first</a>: integer
</code></pre>

First byte in the subject, 1-based.

<a id="tecs.regex.Match.last"></a>

### tecs.regex.Match.last

<pre><code v-pre><a href="#tecs.regex.Match.last">tecs.regex.Match.last</a>: integer
</code></pre>

Last byte in the subject, inclusive. One less than `first` for an empty match.

<a id="tecs.regex.Match.index"></a>

### tecs.regex.Match.index

<pre><code v-pre><a href="#tecs.regex.Match.index">tecs.regex.Match.index</a>: integer
</code></pre>

Capture-group index, with zero reserved for the whole match.

<a id="tecs.regex.Match.name"></a>

### tecs.regex.Match.name

<pre><code v-pre><a href="#tecs.regex.Match.name">tecs.regex.Match.name</a>: string
</code></pre>

Capture name, or nil for the whole match and an unnamed group.

<a id="tecs.regex.Regex"></a>

### tecs.regex.Regex

<pre><code v-pre>record <a href="#tecs.regex.Regex">tecs.regex.Regex</a>
</code></pre>

A compiled Rust regular expression.

<a id="tecs.regex.Regex.pattern"></a>

### tecs.regex.Regex.pattern

<pre><code v-pre><a href="#tecs.regex.Regex.pattern">tecs.regex.Regex.pattern</a>: string
</code></pre>

Source pattern, unchanged.

<a id="tecs.regex.Regex.isMatch"></a>

### tecs.regex.Regex.isMatch

<pre><code v-pre>function <a href="#tecs.regex.Regex.isMatch">tecs.regex.Regex.isMatch</a>(self: <a href="#tecs.regex.Regex">Regex</a>, subject: string): boolean
</code></pre>

Whether any part of a subject matches.

```teal
local imageName <const> = tecs.regex.compile([[\.(png|jpg)$]])
if imageName:isMatch(path) then
loadImage(path)
end
```

#### Parameters

| Type                                                     | Name                       | Description                                                   |
| -------------------------------------------------------- | -------------------------- | ------------------------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | <code v-pre>self</code>    |                                                               |
| <code v-pre>string</code>                                | <code v-pre>subject</code> | Arbitrary bytes. Unlike the pattern, these need not be UTF-8. |

#### Returns

| Type                       | Description                                     |
| -------------------------- | ----------------------------------------------- |
| <code v-pre>boolean</code> | True when the expression matches at least once. |

<a id="tecs.regex.Regex.find"></a>

### tecs.regex.Regex.find

<pre><code v-pre>function <a href="#tecs.regex.Regex.find">tecs.regex.Regex.find</a>(self: <a href="#tecs.regex.Regex">Regex</a>, subject: string, init: integer): <a href="#tecs.regex.Match">Match</a>
</code></pre>

Finds the first match at or after a byte position.

```teal
local number <const> = tecs.regex.compile([[\d+]])
local found <const> = number:find("hp=100")
if found ~= nil then
print(found.value, found.first, found.last) -- "100", 4, 6
end
```

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                        |
| -------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | <code v-pre>self</code>    |                                                                                                                                                    |
| <code v-pre>string</code>                                | <code v-pre>subject</code> | Arbitrary bytes.                                                                                                                                   |
| <code v-pre>integer</code>                               | <code v-pre>init</code>    | First byte considered, under `string.find`'s rules: 1 by default, a negative value counts back from the end, and a value before 1 is clamped to 1. |

#### Returns

| Type                                                     | Description                                                     |
| -------------------------------------------------------- | --------------------------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Match">Match</a></code> | The matched bytes and their range, or nil when nothing matches. |

<a id="tecs.regex.Regex.captures"></a>

### tecs.regex.Regex.captures

<pre><code v-pre>function <a href="#tecs.regex.Regex.captures">tecs.regex.Regex.captures</a>(self: <a href="#tecs.regex.Regex">Regex</a>, subject: string, init: integer): <a href="#tecs.regex.Captures">Captures</a>
</code></pre>

Finds the first match and every capture group it populated.

`groups` may contain holes when optional groups do not participate;
iterate through `groupCount`, not `#groups`. A named entry aliases
the same `Match` stored at its numbered index.

#### Parameters

| Type                                                     | Name                       | Description                                            |
| -------------------------------------------------------- | -------------------------- | ------------------------------------------------------ |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | <code v-pre>self</code>    |                                                        |
| <code v-pre>string</code>                                | <code v-pre>subject</code> | Arbitrary bytes.                                       |
| <code v-pre>integer</code>                               | <code v-pre>init</code>    | First byte considered, under the same rules as `find`. |

#### Returns

| Type                                                           | Description                                                                      |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Captures">Captures</a></code> | The whole match, numbered groups and named aliases, or nil when nothing matches. |

<a id="tecs.regex.Regex.replace"></a>

### tecs.regex.Regex.replace

<pre><code v-pre>function <a href="#tecs.regex.Regex.replace">tecs.regex.Regex.replace</a>(self: <a href="#tecs.regex.Regex">Regex</a>, subject: string, replacement: string): string
</code></pre>

Replaces the first match.

Capture references in the replacement are expanded: `$0` is the whole match, `$1` is the
first group, `$name` and `${name}` select a named group, and `$$` writes one dollar
sign. A reference the pattern does not declare expands to an empty string.

```teal
local assignment <const> = tecs.regex.compile([[(\w+)=(\d+)]])
local text <const> = assignment:replace("hp=100 mp=50", "$1: $2")
-- text is "hp: 100 mp=50"
```

#### Parameters

| Type                                                     | Name                           | Description                                                              |
| -------------------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | <code v-pre>self</code>        |                                                                          |
| <code v-pre>string</code>                                | <code v-pre>subject</code>     | Arbitrary bytes.                                                         |
| <code v-pre>string</code>                                | <code v-pre>replacement</code> | Arbitrary bytes, with capture references interpreted as described above. |

#### Returns

| Type                      | Description                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | A new string when something matched, or the original string unchanged when nothing did. |

<a id="tecs.regex.Regex.replaceAll"></a>

### tecs.regex.Regex.replaceAll

<pre><code v-pre>function <a href="#tecs.regex.Regex.replaceAll">tecs.regex.Regex.replaceAll</a>(self: <a href="#tecs.regex.Regex">Regex</a>, subject: string, replacement: string): string
</code></pre>

Replaces every non-overlapping match.

```teal
local digits <const> = tecs.regex.compile([[\d+]])
local redacted <const> = digits:replaceAll("room 12, floor 3", "#")
-- redacted is "room #, floor #"
```

#### Parameters

| Type                                                     | Name                           | Description                                     |
| -------------------------------------------------------- | ------------------------------ | ----------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | <code v-pre>self</code>        |                                                 |
| <code v-pre>string</code>                                | <code v-pre>subject</code>     | Arbitrary bytes.                                |
| <code v-pre>string</code>                                | <code v-pre>replacement</code> | The same capture-reference syntax as `replace`. |

#### Returns

| Type                      | Description                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | A new string when something matched, or the original string unchanged when nothing did. |

<a id="tecs.regex.compile"></a>

### tecs.regex.compile

<pre><code v-pre>function <a href="#tecs.regex.compile">tecs.regex.compile</a>(pattern: string): <a href="#tecs.regex.Regex">Regex</a>
</code></pre>

Compiles a Rust regular expression.

Compilation raises on malformed syntax or a pattern that is not UTF-8.
Rust's Unicode character classes are enabled by default; use inline
flags to change the expression, such as `(?i)` for case-insensitive
matching or `(?-u:.)` for one arbitrary byte.

Keep the returned object and reuse it. Its native allocation is released
automatically when Lua collects it.

#### Parameters

| Type                      | Name                       | Description                                                              |
| ------------------------- | -------------------------- | ------------------------------------------------------------------------ |
| <code v-pre>string</code> | <code v-pre>pattern</code> | Rust regex syntax, with NUL bytes allowed where that syntax allows them. |

#### Returns

| Type                                                     | Description                                                                     |
| -------------------------------------------------------- | ------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.regex.Regex">Regex</a></code> | A compiled expression whose native allocation is released by the Lua collector. |

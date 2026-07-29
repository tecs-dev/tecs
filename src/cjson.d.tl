-- lua-cjson, declared so the one module that reaches it by name type-checks.
--
-- `src/tecs/data.tl` requires it and presents it under `tecs.data`, and Teal
-- has to know what it is. This lived only in an ignored vendor directory until
-- now, produced by nothing in the tree, so `cargo xtask check` passed on the machine
-- that happened to have it and failed everywhere else.
--
-- Nothing else reaches the library by this name: `tecs.data` is where the
-- engine and a game both read JSON, and it declares what it carries.

local record cjson
    --- Sentinel that encodes as `[]` rather than `{}`.
    empty_array: any
    --- Sentinel that encodes as `null`, and what a decoded null becomes.
    null: any
    --- Marks a table to encode as an array regardless of its contents.
    empty_array_mt: any

    encode: function(value: any): string
    decode: function(text: string): any

    --- Sets and returns the maximum nesting depth accepted.
    encode_max_depth: function(depth?: integer): integer
    decode_max_depth: function(depth?: integer): integer
    --- Whether invalid numbers (nan, inf) are accepted.
    encode_invalid_numbers: function(allow?: boolean | string): boolean | string
    decode_invalid_numbers: function(allow?: boolean): boolean
    --- Digits used when encoding a number.
    encode_number_precision: function(digits?: integer): integer
    --- Whether encoding keeps the buffer between calls.
    encode_keep_buffer: function(keep?: boolean): boolean

    _NAME: string
    _VERSION: string
end

return cjson

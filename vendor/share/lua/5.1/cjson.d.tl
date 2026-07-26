-- lua-cjson.
--
-- Encoding rejects functions, cdata and userdata, and cannot tell an empty
-- array from an empty object without `cjson.empty_array`, which matters
-- wherever a structure round-trips.

local record cjson
    --- Sentinel that encodes as `[]` rather than `{}`.
    empty_array: any
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

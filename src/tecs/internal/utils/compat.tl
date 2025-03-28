--- Compatibility layer for LuaJIT extensions on standard Lua interpreters.
--- Provides fallback implementations for LuaJIT-specific functions.

local record compat
    --- Clear all elements from a table efficiently
    --- @param t Table to clear
    clear: function({any})

    --- Create a new table with pre-allocated array and hash parts (LuaJIT table.new fallback)
    --- @param narr Number of array elements to pre-allocate
    --- @param nrec Number of hash elements to pre-allocate
    --- @return New empty table
    new: function(narr: integer, nrec: integer): {any}

    --- Bitwise operations compatibility
    bor: function(integer, integer): integer
    band: function(integer, integer): integer
    bxor: function(integer, integer): integer
    bnot: function(integer): integer
    lshift: function(integer, integer): integer
    rshift: function(integer, integer): integer
    tobit: function(integer): integer
end

-- Try to use native implementations first, fall back to pure Lua
local table_clear: function({any})
local table_new: function(integer, integer): {any}

-- Table.clear compatibility
local success_clear, native_clear: any = pcall(require, "table.clear" as string)
if success_clear and type(native_clear) == "function" then
    table_clear = native_clear as function({any})
else
    -- Pure Lua fallback for table.clear
    table_clear = function(t: {any})
        for k in pairs(t as {any:any}) do
            (t as {any:any})[k] = nil
        end
    end
end

-- Table.new compatibility
local success_new, native_new: any = pcall(require, "table.new" as string)
if success_new and type(native_new) == "function" then
    table_new = native_new as function(integer, integer): {any}
else
    -- Pure Lua fallback for table.new (just returns empty table)
    table_new = function(_narr: integer, _nrec: integer): {any}
        return {}
    end
end

-- Bit operations compatibility
local bit_module: {string:function}
local success_bit, native_bit: any = pcall(require, "bit" as string)
if success_bit and native_bit then
    bit_module = native_bit as {string:function}
else
    -- Try bit32 (available in Lua 5.2+)
    local success_bit32, native_bit32: any = pcall(require, "bit32" as string)
    if success_bit32 and native_bit32 then
        local bit32_mod = native_bit32 as {string:function}
        bit_module = {
            bor = bit32_mod.bor,
            band = bit32_mod.band,
            bxor = bit32_mod.bxor,
            bnot = bit32_mod.bnot,
            lshift = bit32_mod.lshift,
            rshift = bit32_mod.rshift,
            tobit = function(x: integer): integer return x end  -- bit32 doesn't have tobit
        }
    else
        -- Pure Lua fallback for bit operations
        bit_module = {
            bor = function(a: integer, b: integer): integer
                local result = 0
                local bit = 1
                while a > 0 or b > 0 do
                    if (a % 2 == 1) or (b % 2 == 1) then
                        result = result + bit
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit = bit * 2
                end
                return result
            end,
            band = function(a: integer, b: integer): integer
                local result = 0
                local bit = 1
                while a > 0 and b > 0 do
                    if (a % 2 == 1) and (b % 2 == 1) then
                        result = result + bit
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit = bit * 2
                end
                return result
            end,
            bxor = function(a: integer, b: integer): integer
                local result = 0
                local bit = 1
                while a > 0 or b > 0 do
                    if (a % 2 == 1) ~= (b % 2 == 1) then
                        result = result + bit
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit = bit * 2
                end
                return result
            end,
            bnot = function(a: integer): integer
                -- 32-bit NOT operation
                return math.floor((-a - 1) % (2 ^ 32))
            end,
            lshift = function(a: integer, n: integer): integer
                return math.floor((a * (2 ^ n)) % (2 ^ 32))
            end,
            rshift = function(a: integer, n: integer): integer
                return math.floor(a / (2 ^ n))
            end,
            tobit = function(x: integer): integer
                return math.floor(x % (2 ^ 32))
            end
        }
    end
end

compat.clear = table_clear
compat.new = table_new
compat.bor = bit_module.bor as function(integer, integer): integer
compat.band = bit_module.band as function(integer, integer): integer
compat.bxor = bit_module.bxor as function(integer, integer): integer
compat.bnot = bit_module.bnot as function(integer): integer
compat.lshift = bit_module.lshift as function(integer, integer): integer
compat.rshift = bit_module.rshift as function(integer, integer): integer
compat.tobit = bit_module.tobit as function(integer): integer

return compat
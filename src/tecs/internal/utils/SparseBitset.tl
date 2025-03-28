--[[
    SparseBitset.tl - Sparse bitset implementation for efficient storage

    Uses 32-bit words to pack bits, but only allocates memory for words
    that actually contain set bits (sparse representation).
]]

local compat <const> = require("tecs.internal.utils.compat")
local band <const> = compat.band
local bor <const> = compat.bor
local bnot <const> = compat.bnot
local lshift <const> = compat.lshift
local rshift <const> = compat.rshift

local WORD_SHIFT <const> = 5  -- log2(32)
local WORD_MASK <const> = 31  -- 32 - 1

local record SparseBitset
    words: {integer: integer}  -- word index -> 32-bit word (sparse)
    minWord: integer
    maxWord: integer
end

function SparseBitset.new(): SparseBitset
    return {
        words = {},
        minWord = 0x7FFFFFFF,
        maxWord = -1
    }
end

-- Set a bit
function SparseBitset:set(id: integer)
    local wordIdx = rshift(id, WORD_SHIFT)
    local bitIdx = band(id, WORD_MASK)

    local word = self.words[wordIdx] or 0
    self.words[wordIdx] = bor(word, lshift(1, bitIdx))

    if wordIdx < self.minWord then
        self.minWord = wordIdx
    end
    if wordIdx > self.maxWord then
        self.maxWord = wordIdx
    end
end

-- Clear a bit
function SparseBitset:clear(id: integer)
    local wordIdx = rshift(id, WORD_SHIFT)
    local bitIdx = band(id, WORD_MASK)

    local word = self.words[wordIdx]
    if word then
        self.words[wordIdx] = band(word, bnot(lshift(1, bitIdx)))
        -- Remove word if empty
        if self.words[wordIdx] == 0 then
            self.words[wordIdx] = nil
        end
    end
end

-- Test if a bit is set
function SparseBitset:test(id: integer): boolean
    local wordIdx = rshift(id, WORD_SHIFT)
    local bitIdx = band(id, WORD_MASK)

    local word = self.words[wordIdx]
    if not word then
        return false
    end

    return band(word, lshift(1, bitIdx)) ~= 0
end


-- Clear all bits
function SparseBitset:clearAll()
    for k in pairs(self.words) do
        self.words[k] = nil
    end
    self.minWord = 0x7FFFFFFF
    self.maxWord = -1
end

return SparseBitset
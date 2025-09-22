--- Simple FFI-based bitset.

local cffi <const> = require("ffi")
local bit <const> = require("bit")

local bnot <const> = bit.bnot
local band <const> = bit.band
local bor <const> = bit.bor
local lshift <const> = bit.lshift
local rshift <const> = bit.rshift
local tobit <const> = bit.tobit
local max <const> = math.max

local record Bitset
    --- The underlying uint32 array (each uint32 holds 32 bits)
    _data: {integer}

    --- Number of uint32 words allocated
    wordCount: integer

    --- Number of words currently in use (i.e. highest set bit index / 32 + 1)
    usedWordCount: integer

    --- Number of dirty bits set
    count: integer

    --- Active resumable scan state
    _scanActive: boolean
    _scanWordIndex: integer
    _scanWord: integer
    _scanUsed: integer

    --- Create a new bitset with initial capacity for n bits
    new: function(initialCapacity?: integer): Bitset

    --- Set bit at index (0-based)
    set: function(self, index: integer)

    --- Set all bits in the inclusive range [lo, hi] (0-based).
    --- Equivalent to `for i = lo, hi do set(i) end` but uses word-
    --- aligned OR-mask writes (3 cases: head-partial-word + full-
    --- middle-words + tail-partial-word), turning a 1000-bit set
    --- from ~1000 bit-level ops into ~32 word-level ops while
    --- preserving an exact `count`. Each word write also pays for
    --- one popcount delta, so per-call overhead remains word-linear.
    setRange: function(self, lo: integer, hi: integer)

    --- Clear bit at index (0-based)
    clear: function(self, index: integer)

    --- Check if bit at index is set
    get: function(self, index: integer): boolean

    --- Clear all bits
    clearAll: function(self)

    --- Clear all bits, then set exactly one bit.
    setOnly: function(self, index: integer)

    --- Returns true when every bit set in `other` is also set in `self`.
    containsAll: function(self, other: Bitset): boolean

    --- Returns true when `self` and `other` share at least one set bit.
    overlaps: function(self, other: Bitset): boolean

    --- Returns true when `self` and `other` share no set bits.
    disjoint: function(self, other: Bitset): boolean = macroexp(self: Bitset, other: Bitset): boolean
        return not self:overlaps(other)
    end

    --- Replace `self` with a copy of `other`.
    copyFrom: function(self, other: Bitset)

    --- In-place set union.
    orWith: function(self, other: Bitset)

    --- In-place set intersection.
    andWith: function(self, other: Bitset)

    --- In-place set difference (`self = self & ~other`).
    andNotWith: function(self, other: Bitset)

    --- Returns true when no bits are set.
    isEmpty: function(self): boolean = macroexp(self: Bitset): boolean
        return self.count == 0
    end

    --- Return the number of words with any possible set bit.
    getWordCount: function(self): integer = macroexp(self: Bitset): integer
        return self.usedWordCount
    end

    --- Return the raw uint32 word at `index` (0-based).
    getWord: function(self, index: integer): integer

    --- Ensure capacity for at least n bits
    ensureCapacity: function(self, n: integer)

    --- Begin a resumable scan at or after `start`.
    --- Only one scan may be active per bitset at a time. Bits set
    --- above the captured used-word bound after `beginScan` starts
    --- are not visible to the active scan.
    beginScan: function(self, start: integer): integer

    --- Continue the active resumable scan.
    nextScan: function(self): integer

    --- Return the index of the first set bit >= start, or nil if none.
    nextSetBit: function(self, start: integer): integer
end

local BITSET_MT <const>: metatable<Bitset> = { __index = Bitset }

local macro bitsToWords!(nExpr: Expression)
    return `rshift($nExpr + 31, 5)`
end

local POPCOUNT_TABLE = cffi.new("uint8_t[256]") as {integer}
for i = 0, 255 do
    local n = 0
    local v = i
    while v ~= 0 do
        n = n + band(v, 1)
        v = rshift(v, 1)
    end
    POPCOUNT_TABLE[i] = n
end

local function popcount32(word: integer): integer
    return POPCOUNT_TABLE[band(word, 0xFF)]
        + POPCOUNT_TABLE[band(rshift(word, 8), 0xFF)]
        + POPCOUNT_TABLE[band(rshift(word, 16), 0xFF)]
        + POPCOUNT_TABLE[band(rshift(word, 24), 0xFF)]
end

local function trimUsedWordCount(self: Bitset)
    local data = self._data
    for w = self.usedWordCount - 1, 0, -1 do
        if data[w] ~= 0 then
            self.usedWordCount = w + 1
            return
        end
    end
    self.usedWordCount = 0
end

function Bitset.new(initialCapacity?: integer): Bitset
    local capacity = initialCapacity or 64
    local wordCount = max(1, bitsToWords!(capacity)) as integer
    return setmetatable({
        _data = cffi.new("uint32_t[?]", wordCount) as {integer},
        wordCount = wordCount,
        usedWordCount = 0,
        count = 0,
        _scanActive = false,
        _scanWordIndex = 0,
        _scanWord = 0,
        _scanUsed = 0,
    }, BITSET_MT)
end

function Bitset:ensureCapacity(n: integer)
    local wordCount = self.wordCount
    local neededWords = bitsToWords!(n)
    if neededWords <= wordCount then
        return
    end

    local newWordCount = max(neededWords, wordCount * 2)
    local newData = cffi.new("uint32_t[?]", newWordCount) as {integer}
    cffi.copy(newData as cffi.CData, self._data as cffi.CData, wordCount * 4)
    self._data = newData
    self.wordCount = newWordCount
end

function Bitset:set(index: integer)
    local word = rshift(index, 5)
    if word >= self.wordCount then
        self:ensureCapacity(index + 1)
    end

    local data = self._data
    local old = tobit(data[word])
    local mask = lshift(1, band(index, 31))
    if band(old, mask) == 0 then
        data[word] = bor(old, mask)
        self.count = self.count + 1
        local used = word + 1
        if used > self.usedWordCount then
            self.usedWordCount = used
        end
    end
end

function Bitset:setRange(lo: integer, hi: integer)
    if hi < lo then return end
    -- Grow backing storage before we start issuing word writes.
    local neededWords = bitsToWords!(hi + 1)
    if neededWords > self.wordCount then
        self:ensureCapacity(hi + 1)
    end
    local data = self._data
    local oldUsed = self.usedWordCount
    local firstWord = rshift(lo, 5) as integer
    local lastWord = rshift(hi, 5) as integer
    local loBit = band(lo, 31) as integer
    local hiBit = band(hi, 31) as integer
    local tailMask = hiBit == 31 and -1 or (lshift(1, hiBit + 1) - 1) as integer

    if firstWord == lastWord then
        -- Single-word case: bits loBit..hiBit within one word.
        local highMask = tailMask
        local lowMask = (lshift(1, loBit) - 1) as integer
        local old = tobit(data[firstWord])
        local new = bor(old, band(highMask, bnot(lowMask)))
        data[firstWord] = new
        self.count = self.count + (popcount32(new) - popcount32(old))
    else
        -- Head partial word: bits loBit..31.
        do
            local old = tobit(data[firstWord])
            local new = bor(old, bnot(lshift(1, loBit) - 1))
            data[firstWord] = new
            self.count = self.count + (popcount32(new) - popcount32(old))
        end
        -- Middle full words: set everything.
        local midStart = firstWord + 1
        local midEnd = lastWord - 1
        local usedMidEnd = oldUsed - 1
        local dirtyMidEnd = usedMidEnd < midEnd and usedMidEnd or midEnd
        if dirtyMidEnd >= midStart then
            for w = midStart, dirtyMidEnd do
                local old = tobit(data[w])
                data[w] = 0xFFFFFFFF
                self.count = self.count + (32 - popcount32(old))
            end
            if dirtyMidEnd < midEnd then
                self.count = self.count + 32 * (midEnd - dirtyMidEnd)
                for w = dirtyMidEnd + 1, midEnd do
                    data[w] = 0xFFFFFFFF
                end
            end
        else
            self.count = self.count + 32 * (midEnd - midStart + 1)
            for w = midStart, midEnd do
                data[w] = 0xFFFFFFFF
            end
        end
        -- Tail partial word: bits 0..hiBit.
        do
            local old = tobit(data[lastWord])
            local new = bor(old, tailMask)
            data[lastWord] = new
            self.count = self.count + (popcount32(new) - popcount32(old))
        end
    end

    local used = lastWord + 1
    if used > self.usedWordCount then
        self.usedWordCount = used
    end
end

function Bitset:clear(index: integer)
    local word = rshift(index, 5)
    local used = self.usedWordCount
    if word >= used then
        return
    end

    local data = self._data
    local old = tobit(data[word])
    local mask = lshift(1, band(index, 31))
    if band(old, mask) ~= 0 then
        local new = band(old, bnot(mask))
        data[word] = new
        self.count = self.count - 1
        -- Shrink usedWordCount when the top word becomes zero.
        if new == 0 and word + 1 == used then
            local newUsed = 0
            for w = used - 2, 0, -1 do
                if data[w] ~= 0 then
                    newUsed = w + 1
                    break
                end
            end
            self.usedWordCount = newUsed
        end
    end
end

function Bitset:get(index: integer): boolean
    local word = rshift(index, 5)
    if word >= self.usedWordCount then
        return false
    end
    local mask = lshift(1, band(index, 31))
    return band(self._data[word], mask) ~= 0
end

function Bitset:clearAll()
    local used = self.usedWordCount
    if used > 0 then
        cffi.fill(self._data as cffi.CData, used * 4, 0)
        self.usedWordCount = 0
    end
    self._scanActive = false
    self._scanWordIndex = 0
    self._scanWord = 0
    self._scanUsed = 0
    self.count = 0
end

function Bitset:setOnly(index: integer)
    self:clearAll()
    self:set(index)
end

-- 256-byte lookup table for CTZ of a single byte
local CTZ_TABLE = cffi.new("uint8_t[256]") as {integer}
CTZ_TABLE[0] = 8  -- no bits set in this byte
for i = 1, 255 do
    local n = 0
    local v = i
    while band(v, 1) == 0 do
        n = n + 1
        v = rshift(v, 1)
    end
    CTZ_TABLE[i] = n
end

function Bitset:containsAll(other: Bitset): boolean
    local otherUsed = other.usedWordCount
    if otherUsed == 0 then
        return true
    elseif self.count < other.count then
        return false
    end

    local selfUsed = self.usedWordCount
    if selfUsed < otherUsed then
        return false
    end

    local selfData = self._data
    local otherData = other._data
    local tobit, band = tobit, band
    for i = 0, otherUsed - 1 do
        local o = tobit(otherData[i])
        if band(tobit(selfData[i]), o) ~= o then
            return false
        end
    end

    return true
end

function Bitset:overlaps(other: Bitset): boolean
    if self.count == 0 or other.count == 0 then
        return false
    end

    local selfUsed = self.usedWordCount
    local otherUsed = other.usedWordCount
    local limit = selfUsed < otherUsed and selfUsed or otherUsed

    local selfData = self._data
    local otherData = other._data
    local tobit, band = tobit, band
    for i = 0, limit - 1 do
        if band(tobit(selfData[i]), tobit(otherData[i])) ~= 0 then
            return true
        end
    end

    return false
end

function Bitset:disjoint(other: Bitset): boolean
    return not self:overlaps(other)
end

function Bitset:copyFrom(other: Bitset)
    local otherUsed = other.usedWordCount
    if otherUsed > self.wordCount then
        self:ensureCapacity(lshift(otherUsed, 5))
    end

    local selfUsed = self.usedWordCount
    if otherUsed > 0 then
        cffi.copy(self._data as cffi.CData, other._data as cffi.CData, otherUsed * 4)
    end
    if selfUsed > otherUsed then
        for i = otherUsed, selfUsed - 1 do
            self._data[i] = 0
        end
    end

    self.usedWordCount = otherUsed
    self.count = other.count
    self._scanActive = false
end

function Bitset:orWith(other: Bitset)
    local otherUsed = other.usedWordCount
    if otherUsed == 0 then return end
    if otherUsed > self.wordCount then
        self:ensureCapacity(lshift(otherUsed, 5))
    end

    local selfData = self._data
    local otherData = other._data
    for i = 0, otherUsed - 1 do
        local old = tobit(selfData[i])
        local new = bor(old, tobit(otherData[i]))
        if new ~= old then
            selfData[i] = new
            self.count = self.count + (popcount32(new) - popcount32(old))
        end
    end

    if otherUsed > self.usedWordCount then
        self.usedWordCount = otherUsed
    end
    self._scanActive = false
end

function Bitset:andWith(other: Bitset)
    local selfUsed = self.usedWordCount
    if selfUsed == 0 then return end

    local otherUsed = other.usedWordCount
    local selfData = self._data
    local otherData = other._data
    local common = selfUsed < otherUsed and selfUsed or otherUsed

    for i = 0, common - 1 do
        local old = tobit(selfData[i])
        local new = band(old, tobit(otherData[i]))
        if new ~= old then
            selfData[i] = new
            self.count = self.count + (popcount32(new) - popcount32(old))
        end
    end

    for i = common, selfUsed - 1 do
        local old = tobit(selfData[i])
        if old ~= 0 then
            selfData[i] = 0
            self.count = self.count - popcount32(old)
        end
    end

    trimUsedWordCount(self)
    self._scanActive = false
end

function Bitset:andNotWith(other: Bitset)
    local limit = self.usedWordCount < other.usedWordCount and self.usedWordCount or other.usedWordCount
    if limit == 0 then return end

    local selfData = self._data
    local otherData = other._data
    for i = 0, limit - 1 do
        local old = tobit(selfData[i])
        local new = band(old, bnot(tobit(otherData[i])))
        if new ~= old then
            selfData[i] = new
            self.count = self.count + (popcount32(new) - popcount32(old))
        end
    end

    trimUsedWordCount(self)
    self._scanActive = false
end

function Bitset:isEmpty(): boolean
    return self.count == 0
end

function Bitset:getWordCount(): integer
    return self.usedWordCount
end

function Bitset:getWord(index: integer): integer
    if index < 0 or index >= self.usedWordCount then
        return 0
    end
    return tobit(self._data[index])
end

local function decodeBitPos(word: integer): integer
    local b = band(word, 0xFF)
    if b ~= 0 then
        return CTZ_TABLE[b]
    end

    b = band(rshift(word, 8), 0xFF)
    if b ~= 0 then
        return 8 + CTZ_TABLE[b]
    end

    b = band(rshift(word, 16), 0xFF)
    if b ~= 0 then
        return 16 + CTZ_TABLE[b]
    end

    return 24 + CTZ_TABLE[band(rshift(word, 24), 0xFF)]
end

function Bitset:beginScan(start: integer): integer
    local used = self.usedWordCount
    local wordIndex = rshift(start, 5)
    if wordIndex >= used then
        self._scanActive = false
        return nil
    end

    local word = self._data[wordIndex]
    local bitOffset = band(start, 31)
    if bitOffset ~= 0 then
        word = band(word, bnot(lshift(1, bitOffset) - 1))
    end

    self._scanActive = true
    self._scanUsed = used
    self._scanWordIndex = wordIndex
    self._scanWord = word

    return self:nextScan()
end

function Bitset:nextScan(): integer
    if not self._scanActive then
        return nil
    end

    local data = self._data
    local used = self._scanUsed
    local wordIndex = self._scanWordIndex
    local word = self._scanWord

    for scanWordIndex = wordIndex, used - 1 do
        if scanWordIndex ~= wordIndex then
            word = data[scanWordIndex]
            wordIndex = scanWordIndex
        end

        if word ~= 0 then
            local bitPos = decodeBitPos(word)
            self._scanWordIndex = wordIndex
            self._scanWord = band(word, word - 1)
            return lshift(wordIndex, 5) + bitPos
        end
    end

    self._scanActive = false
    return nil
end

function Bitset:nextSetBit(start: integer): integer
    return self:beginScan(start)
end

return Bitset

--[=[
FFI-backed bitset with zero-based indexes.
]=]

local cffi <const> = require("ffi")
local bit <const> = require("bit")

local bnot <const> = bit.bnot
local band <const> = bit.band
local bor <const> = bit.bor
local lshift <const> = bit.lshift
local rshift <const> = bit.rshift
local tobit <const> = bit.tobit
local max <const> = math.max

--- FFI-backed bitset with zero-based indexes.
---
--- Indexes are bit positions counting from 0. Negative is not one, and the two calls that
--- would act on it rather than ignore it say so: the shifts that turn an index into a word
--- are unsigned, so a negative index reads as a word near 2^27, which `get`, `clear` and
--- `beginScan` see as past the end and answer with nothing, while `set` and `setRange`
--- would write there. Those two raise instead.
---
--- Capacity grows on its own when a bit is set past the end, and the calls that can
--- allocate are `set`, `setRange`, `setOnly`, `ensureCapacity`, `copyFrom` and `orWith`.
--- Nothing else does: reading, clearing or testing past the end is defined and cheap, and
--- nothing here ever gives storage back.
---
--- Not thread-safe, and holding one across a call that grows is not either: growing
--- replaces the backing array, so a caller that cached `_data` is left looking at the old one.
local record Bitset
    --- The underlying uint32 array (each uint32 holds 32 bits)
    ---
    --- Private. Zero-based, and every word from `usedWordCount` up to `wordCount` is zero,
    --- which is the invariant the word-at-a-time paths rely on. Replaced wholesale when
    --- capacity grows, so it must not be cached across a call that grows.
    _data: {integer}

    --- Number of uint32 words allocated
    wordCount: integer

    --- Number of words currently in use (i.e. highest set bit index / 32 + 1), and 0 when
    --- nothing is set.
    usedWordCount: integer

    --- Number of set bits.
    count: integer

    --- Active resumable scan state
    _scanActive: boolean

    --- Private. Which word the scan stopped in, zero-based.
    _scanWordIndex: integer

    --- Private. What is left of that word: bits already returned are cleared out of it, so
    --- a bit cleared through `clear` after the scan reached its word is still reported.
    _scanWord: integer

    --- Private. `usedWordCount` as it stood when the scan began. The scan stops there, so
    --- bits set above it while the scan runs are not seen.
    _scanUsed: integer

    --- Create a new bitset with initial capacity for n bits
    ---
    --- @param initialCapacity Bits, not words, and only a starting size: setting a bit past
    ---     it grows rather than failing. Defaults to 64, and one word is always allocated.
    --- @return A set with nothing in it: `count` and `getWordCount` are both 0 whatever
    ---     capacity was asked for, and `wordCount` carries that capacity rounded up to
    ---     whole words.
    new: function(initialCapacity?: integer): Bitset

    --- Set bit at index (0-based)
    ---
    --- Grows the backing array when `index` is past the end. Setting a bit that is already
    --- set changes nothing, so `count` counts distinct bits and not calls.
    ---
    --- @param index A bit position counting from 0. Negative raises rather than being
    ---     ignored, because the word number a negative index produces is far outside the
    ---     array and the store would land there. Past the end it grows, which replaces
    ---     `_data`. An active scan is left running, and reports the new bit only when its
    ---     word is one the scan has yet to reach and is inside the bound the scan
    ---     captured.
    set: function(self, index: integer)

    --- Set all bits in the inclusive range [lo, hi] (0-based).
    --- Equivalent to `for i = lo, hi do set(i) end` but uses word-
    --- aligned OR-mask writes (a range inside one word, else a
    --- head-partial-word + full-middle-words + tail-partial-word),
    --- turning a 1000-bit set from ~1000 bit-level ops into ~32
    --- word-level ops while preserving an exact `count`. Each word
    --- write also pays for one popcount delta, so per-call overhead
    --- remains word-linear.
    ---
    --- @param lo The first bit set, included, counting from 0. Negative raises, for the
    ---     reason `set` gives: the head word this writes would be far outside the array.
    --- @param hi The last bit set, also included. Below `lo` is not an error and sets
    ---     nothing, so an empty range needs no guard at the call site.
    setRange: function(self, lo: integer, hi: integer)

    --- Clear bit at index (0-based)
    ---
    --- Never allocates and never shrinks the backing array; only `usedWordCount` falls.
    --- An index past the end is a no-op rather than an error.
    ---
    --- @param index A bit position counting from 0. Anything in a word at or above
    ---     `getWordCount` is a no-op, a negative index included, since that reads as a word
    ---     far past the end. Clearing the highest set bit lowers `getWordCount`.
    clear: function(self, index: integer)

    --- Check if bit at index is set
    ---
    --- @param index A bit position counting from 0. One in a word at or above
    ---     `getWordCount` is answered from that count alone and never reads the array, so a
    ---     negative index answers false rather than reading out of bounds.
    --- @return False for any index past the end, so a caller need not bound-check first.
    get: function(self, index: integer): boolean

    --- Clear all bits
    ---
    --- Keeps the capacity, so a set reused each frame stops allocating once it has grown
    --- to its peak. Ends any active scan.
    clearAll: function(self)

    --- Clear all bits, then set exactly one bit.
    ---
    --- Ends any active scan, since it clears first.
    ---
    --- @param index The one bit left set, counting from 0 and set exactly as `set` sets it,
    ---     so one past the end grows here too and `count` is 1 either way.
    setOnly: function(self, index: integer)

    --- Returns true when every bit set in `other` is also set in `self`.
    ---
    --- @param other Read and not modified. Only the words it uses are compared, so the two
    ---     need not have the same capacity and a longer `self` costs nothing.
    --- @return True when `other` is a subset of `self`. An empty `other` is contained by
    ---     anything, an empty `self` included.
    containsAll: function(self, other: Bitset): boolean

    --- Returns true when `self` and `other` share at least one set bit.
    ---
    --- @param other Read and not modified, as is `self`. Only the words both use are
    ---     compared.
    --- @return True when at least one bit is set in both, false when either side is empty.
    overlaps: function(self, other: Bitset): boolean

    --- Returns true when `self` and `other` share no set bits.
    ---
    --- @param other Read and not modified, as is `self`.
    --- @return The negation of `overlaps`, so an empty set is disjoint from everything,
    ---     itself included.
    disjoint: function(self, other: Bitset): boolean = macroexp(self: Bitset, other: Bitset): boolean
        return not self:overlaps(other)
    end

    --- Replace `self` with a copy of `other`.
    ---
    --- The bits are copied, not shared, so the two sets are independent afterwards.
    --- `self` keeps its own capacity when that is the larger of the two. An active scan on
    --- `self` is not valid after this.
    ---
    --- @param other Read and not modified. Only the words it uses are copied and the rest of
    ---     `self` is zeroed, so `self` ends with `other`'s exact `count` and
    ---     `getWordCount` whatever either held before.
    copyFrom: function(self, other: Bitset)

    --- In-place set union.
    ---
    --- Grows `self` when `other` reaches further. An active scan on `self` is not valid
    --- after this.
    ---
    --- @param other Read and not modified. An empty `other` returns without touching `self`,
    ---     scan included; anything else is the call that may allocate.
    orWith: function(self, other: Bitset)

    --- In-place set intersection.
    ---
    --- An active scan on `self` is not valid after this.
    ---
    --- @param other Read and not modified. Words of `self` above the ones `other` uses are
    ---     cleared rather than kept, so an empty `other` empties `self`.
    andWith: function(self, other: Bitset)

    --- In-place set difference (`self = self & ~other`).
    ---
    --- An active scan on `self` is not valid after this.
    ---
    --- @param other Read and not modified. Words of `self` beyond it keep their bits, and an
    ---     empty `other` returns leaving `self` and its scan alone.
    andNotWith: function(self, other: Bitset)

    --- Returns true when no bits are set.
    ---
    --- @return True when `count` is zero. It says nothing about capacity: a set that grew
    ---     and was cleared is empty and still holds its words.
    isEmpty: function(self): boolean = macroexp(self: Bitset): boolean
        return self.count == 0
    end

    --- Return the number of words with any possible set bit.
    ---
    --- @return Words, not bits: one past the word holding the highest set bit, and 0 for an
    ---     empty set. Not the allocated capacity, which is `wordCount`.
    getWordCount: function(self): integer = macroexp(self: Bitset): integer
        return self.usedWordCount
    end

    --- Return the raw uint32 word at `index` (0-based).
    ---
    --- Word `w` holds bits `w * 32` to `w * 32 + 31`, lowest bit first.
    ---
    --- @param index A word index counting from 0, not a bit index, and bounded by
    ---     `getWordCount` rather than by `wordCount`.
    --- @return The word as a signed 32-bit value, so a word with the top bit set reads
    ---     negative. Zero for an index outside `getWordCount`, negative ones included.
    getWord: function(self, index: integer): integer

    --- Ensure capacity for at least n bits
    ---
    --- @param n Bits, not words. Only grows: a smaller `n` than the current capacity does
    ---     nothing, and no call here ever frees storage. A growth allocates at least twice
    ---     the current capacity, so repeated calls that each add a little stay amortised,
    ---     and every one of them replaces `_data`.
    ensureCapacity: function(self, n: integer)

    --- Begin a resumable scan at or after `start`.
    --- Only one scan may be active per bitset at a time. Bits set
    --- above the captured used-word bound after `beginScan` starts
    --- are not visible to the active scan.
    ---
    --- @param start The lowest index the scan may return, included.
    --- @return The first set bit at or after `start`, or nil when there is none, which also
    ---     leaves no scan active.
    beginScan: function(self, start: integer): integer

    --- Continue the active resumable scan.
    ---
    --- @return The next set bit, in increasing order, or nil once the scan is exhausted.
    ---     Also nil when no scan is active, so the two cases are not distinguished.
    nextScan: function(self): integer

    --- Return the index of the first set bit >= start, or nil if none.
    ---
    --- This begins a scan, so it replaces any scan already running on this bitset rather
    --- than answering alongside it.
    ---
    --- @param start The lowest index that may be returned, included, as for `beginScan`.
    --- @return The first set bit at or after `start`, or nil when there is none. Walking a
    ---     set by calling this with the last answer plus one re-enters the scan from that
    ---     word each time; `beginScan` with `nextScan` is the walk that carries on.
    nextSetBit: function(self, start: integer): integer
end

local BITSET_MT <const>: metatable<Bitset> = {__index = Bitset}

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
    return POPCOUNT_TABLE[band(word, 0xFF)] + POPCOUNT_TABLE[band(rshift(word, 8), 0xFF)] + POPCOUNT_TABLE[band(
        rshift(word, 16), 0xFF
    )] + POPCOUNT_TABLE[band(rshift(word, 24), 0xFF)]
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
    -- `rshift` is logical, so a negative index becomes a word number near 2^27
    -- while `ensureCapacity` is handed a bit count of zero or less and grows
    -- nothing. The write below then lands far outside the array. One
    -- predictable compare is what that costs to make impossible, and every
    -- other entry point here is safe already: reading, clearing and testing
    -- past the end are defined.
    if index < 0 then
        error("Bitset:set: index must not be negative", 2)
    end
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
    if hi < lo then
        return
    end
    -- The same hazard `set` guards, and here it reaches the head word write
    -- below rather than a single store: `rshift` is logical, so a negative
    -- `lo` names a word near 2^27 while the growth is sized from `hi`.
    if lo < 0 then
        error("Bitset:setRange: lo must not be negative", 2)
    end
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
CTZ_TABLE[0] = 8 -- no bits set in this byte
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
    if otherUsed == 0 then
        return
    end
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
    if selfUsed == 0 then
        return
    end

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
    if limit == 0 then
        return
    end

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

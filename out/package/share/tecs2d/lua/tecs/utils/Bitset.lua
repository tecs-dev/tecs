

local cffi = require("ffi")
local bit = require("bit")

local bnot = bit.bnot
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local tobit = bit.tobit
local max = math.max

local Bitset = {}

































































































local BITSET_MT = { __index = Bitset }





local POPCOUNT_TABLE = cffi.new("uint8_t[256]")
for i = 0, 255 do
   local n = 0
   local v = i
   while v ~= 0 do
      n = n + band(v, 1)
      v = rshift(v, 1)
   end
   POPCOUNT_TABLE[i] = n
end

local function popcount32(word)
   return POPCOUNT_TABLE[band(word, 0xFF)] +
   POPCOUNT_TABLE[band(rshift(word, 8), 0xFF)] +
   POPCOUNT_TABLE[band(rshift(word, 16), 0xFF)] +
   POPCOUNT_TABLE[band(rshift(word, 24), 0xFF)]
end

local function trimUsedWordCount(self)
   local data = self._data
   for w = self.usedWordCount - 1, 0, -1 do
      if data[w] ~= 0 then
         self.usedWordCount = w + 1
         return
      end
   end
   self.usedWordCount = 0
end

function Bitset.new(initialCapacity)
   local capacity = initialCapacity or 64
   local wordCount = max(1, rshift(capacity + 31, 5))
   return setmetatable({
      _data = cffi.new("uint32_t[?]", wordCount),
      wordCount = wordCount,
      usedWordCount = 0,
      count = 0,
      _scanActive = false,
      _scanWordIndex = 0,
      _scanWord = 0,
      _scanUsed = 0,
   }, BITSET_MT)
end

function Bitset:ensureCapacity(n)
   local wordCount = self.wordCount
   local neededWords = rshift(n + 31, 5)
   if neededWords <= wordCount then
      return
   end

   local newWordCount = max(neededWords, wordCount * 2)
   local newData = cffi.new("uint32_t[?]", newWordCount)
   cffi.copy(newData, self._data, wordCount * 4)
   self._data = newData
   self.wordCount = newWordCount
end

function Bitset:set(index)
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

function Bitset:setRange(lo, hi)
   if hi < lo then return end

   local neededWords = rshift(hi + 1 + 31, 5)
   if neededWords > self.wordCount then
      self:ensureCapacity(hi + 1)
   end
   local data = self._data
   local oldUsed = self.usedWordCount
   local firstWord = rshift(lo, 5)
   local lastWord = rshift(hi, 5)
   local loBit = band(lo, 31)
   local hiBit = band(hi, 31)
   local tailMask = hiBit == 31 and -1 or (lshift(1, hiBit + 1) - 1)

   if firstWord == lastWord then

      local highMask = tailMask
      local lowMask = (lshift(1, loBit) - 1)
      local old = tobit(data[firstWord])
      local new = bor(old, band(highMask, bnot(lowMask)))
      data[firstWord] = new
      self.count = self.count + (popcount32(new) - popcount32(old))
   else

      do
         local old = tobit(data[firstWord])
         local new = bor(old, bnot(lshift(1, loBit) - 1))
         data[firstWord] = new
         self.count = self.count + (popcount32(new) - popcount32(old))
      end

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

function Bitset:clear(index)
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

function Bitset:get(index)
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
      cffi.fill(self._data, used * 4, 0)
      self.usedWordCount = 0
   end
   self._scanActive = false
   self._scanWordIndex = 0
   self._scanWord = 0
   self._scanUsed = 0
   self.count = 0
end

function Bitset:setOnly(index)
   self:clearAll()
   self:set(index)
end


local CTZ_TABLE = cffi.new("uint8_t[256]")
CTZ_TABLE[0] = 8
for i = 1, 255 do
   local n = 0
   local v = i
   while band(v, 1) == 0 do
      n = n + 1
      v = rshift(v, 1)
   end
   CTZ_TABLE[i] = n
end

function Bitset:containsAll(other)
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

function Bitset:overlaps(other)
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

function Bitset:disjoint(other)
   return not self:overlaps(other)
end

function Bitset:copyFrom(other)
   local otherUsed = other.usedWordCount
   if otherUsed > self.wordCount then
      self:ensureCapacity(lshift(otherUsed, 5))
   end

   local selfUsed = self.usedWordCount
   if otherUsed > 0 then
      cffi.copy(self._data, other._data, otherUsed * 4)
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

function Bitset:orWith(other)
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

function Bitset:andWith(other)
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

function Bitset:andNotWith(other)
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

function Bitset:isEmpty()
   return self.count == 0
end

function Bitset:getWordCount()
   return self.usedWordCount
end

function Bitset:getWord(index)
   if index < 0 or index >= self.usedWordCount then
      return 0
   end
   return tobit(self._data[index])
end

local function decodeBitPos(word)
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

function Bitset:beginScan(start)
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

function Bitset:nextScan()
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

function Bitset:nextSetBit(start)
   return self:beginScan(start)
end

return Bitset

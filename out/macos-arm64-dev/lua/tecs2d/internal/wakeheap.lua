










local floor = math.floor

local wakeheap = { Heap = {} }

























function wakeheap.new()
   return { keys = {}, seqs = {}, values = {}, size = 0 }
end

function wakeheap.clear(heap)
   local keys, seqs, values = heap.keys, heap.seqs, heap.values
   for i = 1, heap.size do
      keys[i], seqs[i], values[i] = nil, nil, nil
   end
   heap.size = 0
end

function wakeheap.push(heap, key, seq, value)
   local keys, seqs, values = heap.keys, heap.seqs, heap.values
   local i = heap.size + 1
   heap.size = i

   while i > 1 do
      local parent = floor(i / 2)
      local parentKey = keys[parent]
      if key < parentKey or (key == parentKey and seq < seqs[parent]) then
         keys[i], seqs[i], values[i] = parentKey, seqs[parent], values[parent]
         i = parent
      else
         break
      end
   end

   keys[i], seqs[i], values[i] = key, seq, value
end

function wakeheap.peek(heap)
   if heap.size == 0 then return nil end
   return heap.keys[1]
end

function wakeheap.pop(heap)
   local size = heap.size
   if size == 0 then return nil, nil, nil end
   local keys, seqs, values = heap.keys, heap.seqs, heap.values

   local key = keys[1]
   local seq = seqs[1]
   local value = values[1]


   local tailKey, tailSeq, tailValue = keys[size], seqs[size], values[size]
   keys[size], seqs[size], values[size] = nil, nil, nil
   size = size - 1
   heap.size = size

   local i = 1
   while true do
      local left = i * 2
      if left > size then break end
      local child = left
      local right = left + 1
      if right <= size then
         local leftKey, rightKey = keys[left], keys[right]
         if rightKey < leftKey or (rightKey == leftKey and seqs[right] < seqs[left]) then
            child = right
         end
      end
      local childKey = keys[child]
      if childKey < tailKey or (childKey == tailKey and seqs[child] < tailSeq) then
         keys[i], seqs[i], values[i] = childKey, seqs[child], values[child]
         i = child
      else
         break
      end
   end

   if size > 0 then
      keys[i], seqs[i], values[i] = tailKey, tailSeq, tailValue
   end
   return key, seq, value
end

return wakeheap

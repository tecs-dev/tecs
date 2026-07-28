--- A deterministic min-heap for things scheduled at an integer time.
---
--- Entries are ordered by `(key, seq)`: the key is whatever clock the caller
--- counts in, and `seq` breaks ties in insertion order, so two things due at
--- the same moment always run in the order they were queued. The heap does
--- not care whether the key means fixed steps or gameplay frames.
---
--- Held as parallel arrays rather than entry tables, and sifted by moving the
--- hole rather than swapping pairs: scheduling allocates nothing, which
--- matters for a population that reschedules every time it runs.

local floor <const> = math.floor

local record wakeheap
    record Heap
        keys: {integer}
        seqs: {integer}
        values: {any}
        size: integer
    end

    --- An empty heap.
    new: function(): Heap

    --- Discard every entry, keeping the arrays.
    clear: function(heap: Heap)

    --- Add `value`, due at `key`, ordered after anything already queued for
    --- that key with a lower `seq`.
    push: function(heap: Heap, key: integer, seq: integer, value: any)

    --- The earliest key, or nil when the heap is empty. Cheap enough to call
    --- every tick before deciding whether anything is due.
    peek: function(heap: Heap): integer

    --- Remove the earliest entry, returning its key, seq, and value.
    pop: function(heap: Heap): integer, integer, any
end

function wakeheap.new(): wakeheap.Heap
    return {keys = {}, seqs = {}, values = {}, size = 0}
end

function wakeheap.clear(heap: wakeheap.Heap)
    local keys, seqs, values = heap.keys, heap.seqs, heap.values
    for i = 1, heap.size do
        keys[i], seqs[i], values[i] = nil, nil, nil
    end
    heap.size = 0
end

function wakeheap.push(heap: wakeheap.Heap, key: integer, seq: integer, value: any)
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

function wakeheap.peek(heap: wakeheap.Heap): integer
    if heap.size == 0 then
        return nil
    end
    return heap.keys[1]
end

function wakeheap.pop(heap: wakeheap.Heap): integer, integer, any
    local size = heap.size
    if size == 0 then
        return nil, nil, nil
    end
    local keys, seqs, values = heap.keys, heap.seqs, heap.values

    local key <const> = keys[1]
    local seq <const> = seqs[1]
    local value <const> = values[1]

    -- The tail entry sifts down from the root into the hole the top left.
    local tailKey, tailSeq, tailValue = keys[size], seqs[size], values[size]
    keys[size], seqs[size], values[size] = nil, nil, nil
    size = size - 1
    heap.size = size

    local i = 1
    while true do
        local left = i * 2
        if left > size then
            break
        end
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

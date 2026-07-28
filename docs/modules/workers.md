---
description: "Worker threads and serialized channels: spawning a state of its own, what can cross between them, and how a worker is asked to stop"
outline: deep
---

# tecs.workers

`tecs.workers` is the only sanctioned way to run work off the main thread. Raw thread creation is deliberately
not exposed: a LuaJIT FFI callback invoked from a thread the VM did not create is unsafe, and a thread entry
point written in Lua is exactly that mistake. The native side does nothing but start a thread with a fresh
`lua_State` and move opaque byte blocks between queues; it never learns what a message contains, because
serialization stays in Lua.

That boundary is not a style choice. LuaJIT has no shared mutable heap across threads, so a worker cannot see
the spawning state's objects at all. Values cross as serialized bytes, which is what decides what may cross.

[`assets`](/modules/assets) is the engine's own use of this module: one worker decoding images and sounds, with
the addresses of what it decoded coming back across a channel.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.workers`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily
on first field access.

## What can cross

What `string.buffer` can encode: numbers, strings, booleans, and tables of those. Not functions, not userdata,
and not cdata pointers into another state's heap. Table keys have to be scalars too, and a value nesting deeper
than 32 levels is refused.

A send is checked before it is encoded, and the error names the path to the first value that cannot cross:

```
tecs: cannot send to a worker: value.onDone is a function
```

That is partly for the message. It is mostly because the failing path proved unsafe: an encode error raised
while worker threads are running has intermittently terminated the process instead of surfacing. Refusing to
call the encoder with something it will reject keeps that path unreached.

::: tip Addresses cross, and ownership with them
A number is a number, so the address of something that lives in process memory rather than in a Lua heap
crosses fine. That is how a decoded image comes back: the worker sends the address of an `SDL_Surface` rather
than its pixels, which avoids copying a decoded image through a serialized message only to copy it again into
staging. Whoever receives the address owns what it points at.
:::

## Spawning

### spawn

Starts a worker running `options.source` on its own thread and state.

```teal
function workers.spawn(options: SpawnOptions): Worker
```

| Option    | Type     | Default                     | Description                                                                                    |
| --------- | -------- | --------------------------- | ---------------------------------------------------------------------------------------------- |
| `source`  | `string` | required                    | Lua source the worker runs. It reaches its channels through `workers.current()`.               |
| `luaPath` | `string` | this state's `package.path` | `package.path` for the worker's state, so a worker resolves the same modules the spawner does. |

**Returns:** a `Worker`. Omitting `source` raises, and so does a spawn the native side refuses.

```teal
local worker <const> = tecs.workers.spawn({
    source = [[
        local workers = require("tecs.workers")
        local self = workers.current()
        while true do
            local task = self:receive()
            if task == nil then break end
            self:send({ id = task.id, total = task.a + task.b })
        end
    ]],
})

worker:send({ id = 1, a = 2, b = 40 })
-- ... later, on a frame that can afford to look
local result = worker:receive()
```

### Worker

| Member                | Description                                                                    |
| --------------------- | ------------------------------------------------------------------------------ |
| `pending`             | Messages the worker has not taken yet, as of the last `send`.                  |
| `send(value)`         | Queues a value for the worker, and refreshes `pending`.                        |
| `receive(timeoutMs?)` | Takes a result, or nil if none is ready.                                       |
| `available()`         | Results waiting to be taken.                                                   |
| `stop()`              | Closes the worker's inbox, waits for it to finish, and releases both channels. |

`receive` polls by default: `timeoutMs` of zero polls, a negative value waits indefinitely, and any other value
waits that long. A frame polls.

`stop` returns the thread's exit status, or zero when the worker was already stopped. A worker is expected to
leave its loop when `receive` returns nil on a closed channel, so closing is how it is asked to stop.

## Inside a worker

### current

The channels of the worker this code is running inside.

```teal
function workers.current(): Self
```

Only valid in a worker's state, where the native entry point installed the pointers as globals before running
the source. Calling it anywhere else raises.

**Returns:** a value with two methods:

- `receive(timeoutMs?)`: takes the next task, or nil when the inbox closes. Unlike the spawner's `receive`,
  this waits indefinitely when no timeout is given, because a worker with nothing to do should not spin.
- `send(value)`: returns a result to the spawner.

A worker's loop is therefore the shape in the example above: receive, break on nil, answer, repeat.

## Channels

A `Channel` is one direction of a worker's traffic, and `spawn` creates a pair. A game rarely builds one
directly; it is here because the two halves of a worker's protocol are the same object.

```teal
function Channel.create(): Channel
function Channel:send(value: any)
function Channel:receive(timeoutMs?: number): any
function Channel:count(): integer
function Channel:close()
function Channel:destroy()
```

- `send` serializes and queues a value, raising for anything that cannot cross.
- `receive` takes the next value, or nil if none arrived. Zero polls, a negative value waits indefinitely, and
  any other value waits that long. The bytes are copied out before the message is freed, so nothing a decoded
  value holds points into storage the native side is about to release.
- `count` is the messages waiting.
- `close` wakes anything blocked on the channel so it can stop.
- `destroy` releases it, and is safe to call more than once.

## Fields

| Field  | Type     | Description                                 |
| ------ | -------- | ------------------------------------------- |
| `path` | `string` | Absolute path of the loaded native library. |

## When a worker runs slowly

A worker's state has to be given somewhere to compile into. A LuaJIT trace reaches the interpreter with one
immediate branch, so its machine code has to sit within that branch's reach, and there is no way to hand LuaJIT
memory: it asks the kernel for an area near that anchor and rejects whatever lands outside. A state created
after the graphics driver has mapped its own memory can find nowhere at all and then runs entirely interpreted,
with `jit.status()` still answering true.

The host holds a block of that address space open from its first instruction and gives it back once
initialisation returns, which is what makes a worker compile at all. Past what that block covers, a worker
competes for whatever is left, and the only symptom is that it runs slowly.

Setting `TECS_TRACEPROF` makes each worker report its trace aborts when its inbox closes, which is how that is
told apart from a worker that is merely busy: the failure reads as tens of thousands of `failed to allocate
mcode memory`.

## Related

- [`assets`](/modules/assets) decodes images and sounds on a worker of its own.
- [`proc`](/modules/proc) runs a child process, and answers a [`Future`](/modules/future) rather than a raw
  channel.
- [`Future`](/modules/future) is the settle-once value a worker-backed subsystem hands out, and its `Source`
  interface is exactly what a channel offers: take what is ready, or block for up to N milliseconds.

## Design record

- [Workers and assets](https://github.com/tecs-dev/tecs/blob/main/README.md#workers-and-assets)
- [A value that settles once](https://github.com/tecs-dev/tecs/blob/main/README.md#a-value-that-settles-once)
- [Shelling out](https://github.com/tecs-dev/tecs/blob/main/README.md#shelling-out)

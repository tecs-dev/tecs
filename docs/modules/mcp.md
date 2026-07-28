---
description: "The debug server: JSON-RPC over HTTP answered inside the frame, the tools every build exposes, the sandbox and the transport"
outline: deep
---

# tecs.mcp

`tecs.mcp` is the debug server. It speaks JSON-RPC over HTTP POST, and everything an agent can do is a tool
registered on it: a name, a JSON Schema and a function. The tool list is generated from the same table that
dispatches, so there is no second list to keep in step.

Requests are answered inside `update`, on the game's own thread, before the world is stepped. A tool therefore
reads a world that is not mid-update and writes one that has not yet advanced, which is why none of them lock
and none of them queue anything. The cost is that a tool must not block: it runs during a frame someone is
watching.

The server also outlives the game. When a system raises, [`Application`](/modules/Application) records the
traceback here and keeps polling, so an agent that was debugging up to the moment it broke gets the reason
rather than a refused connection.

## Starting a server

Under an application, set `Application.Config.mcpPort`. Omitting it means no server, since a game should not
open a socket nobody asked for. The application binds the renderer and the world to the tools, requires the
two tool modules so their registrations run, and calls `poll` once per frame before the crash guard.

```teal
tecs.newApplication({
    mcpPort = 7100,
    plugin = registerEverything,
})
```

### listen

Starts the server on `port`.

```teal
function mcp.listen(port?: integer): mcp.Server
```

**Parameters:**

- `port`: the TCP port. Defaults to `7100`.

**Returns:** a `Server`, whose `port` field is the port it bound. Binding raises rather than retrying on
another port: a debugger that silently moved would be worse than one that did not start, since whatever
connects to it has only the port it was told.

### Server:poll

Answers at most one request. Call once per frame.

```teal
function mcp.Server:poll(): boolean
```

**Returns:** whether a request was dispatched. Accepting and reading never wait, so a frame with nobody
connected costs a non-blocking accept.

A request that is not a `POST` is answered `405 Method Not Allowed`. A dispatch that raises is logged and
answered `500` with a JSON-RPC internal error, so a broken request cannot take the frame with it.

### Server:destroy

Releases the server and any connection. Safe to call more than once.

```teal
function mcp.Server:destroy()
```

## The protocol

Three methods are answered.

| Method       | Result                                                                                   |
| ------------ | ---------------------------------------------------------------------------------------- |
| `initialize` | `protocolVersion` `2025-06-18`, a `tools` capability, and `serverInfo` naming this build |
| `tools/list` | every registered tool, in registration order, with its schema and annotations            |
| `tools/call` | runs the named tool with `params.arguments` and returns its result                       |

A tool's result comes back as `structuredContent`, the table the handler returned, alongside a `content` array
carrying the same table encoded as text. A tool that raises is reported as a result with `isError` set and the
message as its text content, not as a JSON-RPC error: the agent is told, the frame carries on.

Each tool is listed with three annotations. `readOnlyHint` and `destructiveHint` are MCP's own;
`whenCrashedHint` is this server's, so an agent can tell which tools still answer after a crash without
calling them.

JSON-RPC errors use the specification's codes: `-32700` for a body that is not JSON, `-32600` for a request
with no method, `-32601` for an unknown method or an unknown tool name, and `-32603` for a dispatch that
raised.

### dispatch

Runs one JSON-RPC request and returns the response text.

```teal
function mcp.dispatch(text: string): string
```

Exposed so the protocol can be exercised without a socket, which is most of what there is to get wrong here.

**Example:**

```bash
curl -s localhost:7100 -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### After a crash

While a crash is recorded, every tool that did not declare `whenCrashed` answers with `isError`, `crashed` and
the traceback instead of running. A crashed world cannot answer anything about itself, and a tool that read it
would return nonsense rather than an error.

```teal
function mcp.setCrashed(traceback: string)
function mcp.crashed(): string
```

`crashed` returns `nil` while the game is healthy. The tools that survive a crash are `ping`, `context`,
`get_logs` and `send_event`: reading the log and being able to send a quit are exactly what a stopped process
still needs.

## Tools

The tools below are the ones true of any build. They are registered when their module is required, which the
application does for you: `tecs.mcp.tools` carries the process-facing ones and `tecs.mcp.world` carries the
eight that read and write the world.

The world tools name a game's own components on the same terms as the engine's. They resolve a name through
the ECS's own component registry, so declaring a component is what makes it nameable here and there is no
second registration step to find.

### ping

Confirms the game is running and answering. Reports a crash rather than refusing to answer after one.

Read-only, answers after a crash. No arguments.

**Returns:** `ok`, `crashed` (the traceback or null) and `ticks`.

### context

What this build is, what it can do, and what the world it is running holds.

Read-only, answers after a crash. No arguments.

**Returns:** `world` (entity, archetype, component, declared-component and system counts, or null before a
world is bound), the target and architecture, whether JIT and dynamic libraries are available, whether shaders
are compiled at runtime or packaged, the shader formats, the core count, the asset and writable roots, the log
file path, and every registered logger name.

Both component counts are reported because they answer different questions: `components` counts what an
archetype in this world carries, while `declaredComponents` counts the process-wide registry, and the
difference is what an agent looking for a component it cannot find needs to see.

### get_logs

Reads the log file from a byte offset. Poll with the returned offset to follow it.

Read-only, answers after a crash.

| Argument   | Type      | Description                                   |
| ---------- | --------- | --------------------------------------------- |
| `after`    | `integer` | Byte offset to read from. Omit to start at 0. |
| `contains` | `string`  | Only return lines containing this text.       |

**Returns:** `path`, `offset` and `lines`. A read covers at most 64 KB and stops on a line boundary, so a
cursor never lands mid-record. An `after` past the end of the file restarts at 0, which is what a truncated
file looks like from here. The path is returned so an agent sharing a filesystem with the game can read it
directly instead of pulling it through the protocol. See [`log`](/modules/log#the-log-file) for the record
format.

### screenshot

Captures the last rendered frame to a PNG and returns its path.

Read-only.

| Argument | Type     | Description                                                      |
| -------- | -------- | ---------------------------------------------------------------- |
| `name`   | `string` | File name under the writable root. Defaults to `screenshot.png`. |

**Returns:** `path`, `width` and `height`. A file rather than inline base64, because an agent that shares a
filesystem with the game reads it far more cheaply and it persists for a human to look at afterwards.

### sample_pixels

Reads the color of specific pixels from the last frame.

Read-only.

| Argument | Type    | Description                                    |
| -------- | ------- | ---------------------------------------------- |
| `points` | `array` | Points to sample, as `{x, y}` pairs. Required. |

**Returns:** `width`, `height` and `pixels`, one entry per point carrying `x`, `y` and either `r`, `g`, `b`,
`a` or `outside` for a point off the frame. A screenshot answers what the frame looks like and needs eyes;
this answers whether a pixel is the color it should be, which is the question an agent can check.

### send_event

Pushes an event into the input stream, as if it had come from the platform.

Destructive, answers after a crash. Calling it with no `kind` returns the list of kinds instead of pushing
anything, and an unknown kind is refused rather than pushed and then ignored. The full event model is in
[`events`](/modules/events).

| Argument                     | Type      | Description                                                                            |
| ---------------------------- | --------- | -------------------------------------------------------------------------------------- |
| `kind`                       | `string`  | Event kind. Call with no kind to list them.                                            |
| `scancode`                   | `integer` | For `keyDown`, `keyUp`.                                                                |
| `button`                     | `integer` | For `mouseDown`, `mouseUp`.                                                            |
| `x`, `y`                     | `number`  | Position.                                                                              |
| `clicks`                     | `integer` | Clicks in the run, for `mouseDown` and `mouseUp`. One when omitted.                    |
| `wheelX`, `wheelY`           | `number`  | For `mouseWheel`.                                                                      |
| `wheelTicksX`, `wheelTicksY` | `integer` | Whole notches.                                                                         |
| `flipped`                    | `boolean` | Send the wheel event as a platform with natural scrolling does, which arrives negated. |
| `penState`                   | `integer` | `SDL_PEN_INPUT_*` mask, for the pen kinds.                                             |
| `repeated`                   | `boolean` | For `keyDown`.                                                                         |
| `which`                      | `integer` | Device, window or display the event is about.                                          |
| `data1`, `data2`             | `integer` | Payloads, for the window and display kinds.                                            |
| `scale`                      | `number`  | Zoom factor, for the pinch kinds.                                                      |
| `recording`                  | `boolean` | Whether an audio device records.                                                       |

**Returns:** `pushed`, the kind that was pushed, or `kinds` when called with none.

### audio

Sound output: the clips loaded, the voices sounding, and the gains, mutes and pauses over them.

Read-only. No arguments. Requires an [`Audio`](/modules/audio) installed on the bound world.

**Returns:** `available`, `masterGain`, `muted`, `sounding`, `maxVoices`, `loading`, the `decoders` this build
linked, and four lists: `clips`, `groups`, `keys` and `voices`. Sound is the one subsystem with nothing to look
at, so what an agent can check is what the layer was asked for: which clips loaded, which voices are sounding
and on what, and which of the gains, mutes and pauses over them explains a silence.

### reload_shaders

Re-reads shaders and materials from their files and rebuilds the pipelines. Refuses where a reload would change
what already-drawn entities mean.

Destructive. No arguments.

**Returns:** `materials`, the material names after the reload. It refuses on a build that links no shader
compiler, since such a build has no way to change what it draws with while it is running, and on a process
with no pipeline rebuild registered, since the sources would be re-read and nothing would draw differently.

### reload_image

Re-reads an image file and uploads it over the one already registered under that path. Refuses a file whose
size changed.

Destructive.

| Argument | Type     | Description                                        |
| -------- | -------- | -------------------------------------------------- |
| `path`   | `string` | The path the image was registered under. Required. |

**Returns:** `path`, `layer`, `width` and `height`. An image keeps its layer and its rect, so every sprite
naming it goes on naming the right texels and the next frame draws the new pixels with nothing in the world
touched. A file that changed size cannot do that, so it is refused rather than half applied.

### reload_sound

Re-reads a sound file over the clip already loaded from that path. A streamed clip holds nothing, so it reports
that rather than replacing anything.

Destructive.

| Argument | Type     | Description                                  |
| -------- | -------- | -------------------------------------------- |
| `path`   | `string` | The path the clip was loaded from. Required. |

**Returns:** `path`, `resident` and `replaced`. A clip is its path, so an edited file comes back under the
index every `Sound` row already carries.

### reload_font

Re-reads a font's metrics over the font already loaded from that path, and lays out every text drawing it
again. Refuses metrics that name an atlas of a different size.

Destructive.

| Argument | Type     | Description                                             |
| -------- | -------- | ------------------------------------------------------- |
| `path`   | `string` | The path the font's metrics were loaded from. Required. |

**Returns:** `path`, `font` and `glyphs`. This is the one reload with something in the world to put right
afterwards: a glyph is an instance laid out once from the metrics and left alone until its text changes, so
re-reading the metrics has to lay those glyphs out again.

### watch

Reports, starts, stops or steps the content file watcher, which reloads shaders, images, sounds and fonts when
their files change.

Destructive.

| Argument  | Type      | Description                                                        |
| --------- | --------- | ------------------------------------------------------------------ |
| `enabled` | `boolean` | Starts or stops the watcher. Omit to leave it as it is.            |
| `poll`    | `boolean` | Looks at every watched file now, without waiting for the interval. |

**Returns:** `watching`, the number of `files` and their `paths`, the `unsettled` ones, the `kinds` registered,
`dispatched` and how many reloads `fired` on this call. It refuses on a build that links no shader compiler,
which is a release and has no business polling the filesystem. Polling from here as well as from the loop is
what lets an agent that has just written a file wait for the effect rather than for the interval. See
[`watch`](/modules/filesystem/watch).

`unsettled` names the files that have changed and have not been dispatched yet. A file has to report the same
size and modification time on consecutive polls first, because an editor saving commonly truncates and
rewrites, and handing a half-written file to a reloader is how a watcher takes a process down. So a `fired` of
zero with the path still in `unsettled` means the write is still landing: poll again rather than conclude
nothing happened.

### components_info

Lists the components these tools can name, with the fields each carries and whether the bound world carries
any.

Read-only. No arguments.

**Returns:** `components`, one entry per registered component with its `name`, `id`, whether it is a `tag`, its
`fields`, and whether the bound world has any entity carrying it; plus `bound`. The registry is process-wide
and a world is not, so a component declared here and carried by nothing is an ordinary state rather than a name
that does not exist. Fields are read from a default instance rather than declared again, so this cannot
describe a component incorrectly.

### query

Finds entities carrying every named component. Returns their ids and, unless `values` is false, their component
values.

Read-only.

| Argument  | Type      | Description                                    |
| --------- | --------- | ---------------------------------------------- |
| `include` | `array`   | Component names an entity must have. Required. |
| `limit`   | `integer` | Default 50.                                    |
| `values`  | `boolean` | Include component values. Default true.        |

**Returns:** `matched`, the total number of entities the query covered, `returned`, and `entities`, capped at
`limit`. Each row carries the entity id, its `Name` where it has one, and its component values.

### info

Everything known about one entity.

Read-only.

| Argument | Type      | Description |
| -------- | --------- | ----------- |
| `entity` | `integer` | Required.   |

**Returns:** `entity`, `alive`, `name`, `components` and `count`. An entity that is not alive answers with
`alive` false and nothing else.

Component values cross as plain tables through each component's own `serialize`, so an FFI component arrives as
numbers rather than as cdata JSON cannot carry. A tag has no data, so it reports as `true` rather than as an
empty object a client would have to special-case.

### spawn

Creates an entity carrying the given components.

Destructive.

| Argument     | Type     | Description                                   |
| ------------ | -------- | --------------------------------------------- |
| `components` | `object` | Component name to its field values. Required. |

**Returns:** the new entity, described as [`info`](/modules/mcp#info) describes one.

### set

Replaces a component in full, adding it if absent.

Destructive.

| Argument    | Type      | Description   |
| ----------- | --------- | ------------- |
| `entity`    | `integer` | Required.     |
| `component` | `string`  | Required.     |
| `values`    | `object`  | Field values. |

**Returns:** the entity as `info` describes it, plus `added`. Instances are built through the component's own
constructor, so a field the payload omits takes the component's default. That is what makes this a replacement
rather than a merge; prefer `modify` for changing one value without disturbing the rest.

### modify

Changes only the named fields, leaving the rest alone.

Destructive.

| Argument    | Type      | Description                 |
| ----------- | --------- | --------------------------- |
| `entity`    | `integer` | Required.                   |
| `component` | `string`  | Required.                   |
| `values`    | `object`  | Fields to change. Required. |

**Returns:** the entity as `info` describes it, plus `skipped`. An entity that is not alive or does not carry
the component is skipped rather than gaining one, so a typo cannot silently add a component. The write goes
through `getMut`, so the column is marked dirty and whatever consumes it re-uploads.

### remove

Removes a component from an entity.

Destructive.

| Argument    | Type      | Description |
| ----------- | --------- | ----------- |
| `entity`    | `integer` | Required.   |
| `component` | `string`  | Required.   |

**Returns:** the entity as `info` describes it, plus `skipped`.

### despawn

Destroys an entity.

Destructive.

| Argument | Type      | Description |
| -------- | --------- | ----------- |
| `entity` | `integer` | Required.   |

**Returns:** `entity` and `skipped`.

### run_lua

Runs Lua with `world` in scope. Returns an envelope `{returned, values}`. State persists between calls, so a
handle stashed in a global is there next time. Prefer a structured tool where one covers the operation.

Destructive.

| Argument | Type     | Description                                          |
| -------- | -------- | ---------------------------------------------------- |
| `code`   | `string` | Lua to run. A bare expression is returned. Required. |

**Returns:** `returned`, the number of values the chunk returned, and `values`, each converted into something
JSON can carry. The count is reported separately because returning `nil` has to be distinguishable from
returning nothing. Execution is synchronous, inside the frame, so there is no deferral and no second round
trip.

## Registering your own tools

A game registers what its own world needs. The built-in set is deliberately small: what is true of any build,
and what an agent reaches for before it knows anything else.

### Tool

```teal
record Tool
    name: string
    description: string
    inputSchema: {string: any}
    handler: Handler
    readOnly: boolean
    destructive: boolean
    whenCrashed: boolean
end
```

**Fields:**

- `name`: the tool name, which is what `tools/call` dispatches on.
- `description`: sent in the tool list.
- `inputSchema`: JSON Schema for the arguments, sent verbatim. A tool with no arguments uses
  `{ type = "object", properties = tecs.data.empty_array }`, because an empty Lua table encodes as an object
  and a client parsing the list strictly would reject it.
- `handler`: the function. Arguments arrive decoded; the table it returns is encoded as the structured
  content.
- `readOnly`: declared so an agent can tell what a call will do before making it. False by default.
- `destructive`: the same, for a call that changes something. False by default.
- `whenCrashed`: still callable after the game has crashed. False by default, because a crashed world cannot
  answer anything about itself.

### Handler

```teal
type Handler = function(arguments: {string: any}): {string: any}
```

Raising from a handler is how a tool reports a refusal. Use `error(message, 0)` so the message reaches the
agent without a file and line in front of it.

### register

Registers a tool. Re-registering a name replaces it.

```teal
function mcp.register(tool: mcp.Tool)
```

Raises when the tool has no `name` or no `handler`.

**Example:**

```teal
tecs.mcp.register({
    name = "spawn_wave",
    description = "Spawns a wave of enemies and returns how many were created.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = { count = { type = "integer" } },
        required = { "count" },
    },
    handler = function(args: {string: any}): {string: any}
        local count = math.floor(tonumber(args.count) or 0) as integer
        if count < 1 then error("count must be at least one", 0) end
        for _ = 1, count do spawnEnemy(world) end
        return { spawned = count }
    end,
})
```

### tools

Every registered tool, in registration order.

```teal
function mcp.tools(): {mcp.Tool}
```

## Binding

The tools are bound to a renderer and a world rather than to an application, so a tool reads the same world
whatever a game registered. `Application` calls all three of these; a test or a tool assembling the pieces by
hand calls them itself.

```teal
function tools.bind(renderer: Renderer, world: ecs.World)
function tools.bindReload(rebuild: function())
function world.bind(w: ecs.World)
```

`tools.bind` supplies what the frame-facing tools look at. `tools.bindReload` supplies the device's half of a
shader reload: swapping a pipeline means destroying live GPU handles and creating new ones against the formats
the device claimed, which is knowledge the [`Renderer`](/modules/gfx/) has and nothing in the tools does.
`world.bind` is what the eight world tools act on. A tool called before its binding exists reports why rather
than failing obscurely.

### The reloads

The four reloads are functions first and tools second, because a saved file arriving at the file watcher and an
agent asking have to be refused on identical terms or the two disagree about what the process is drawing. Each
raises with the reason when it refuses.

```teal
function tools.reloadShaders(): {string}
function tools.reloadImage(path: string): integer, integer, integer
function tools.reloadSound(path: string): boolean
function tools.reloadFont(path: string): string, integer
```

`reloadShaders` returns the material names. `reloadImage` returns the layer the image occupies and its width
and height. `reloadSound` returns whether the clip is held in memory, which is what was replaced. `reloadFont`
returns the name the font is loaded under and how many glyphs it carries.

## The sandbox

`tecs.mcp.sandbox` is the environment `run_lua` compiles into. It is kept out of the tool so protocol dispatch
carries no policy, and it holds the environment across calls, so an agent can stash a handle in one call and
read it in the next. That is what makes an exploratory session possible at all.

```teal
function sandbox.compile(code: string): function(any): any..., string
function sandbox.reset()
function sandbox.describe(value: any, depth?: integer): any
```

`compile` wraps the code so `world` is a parameter and both a statement block and a bare expression work: a
chunk that does not compile is retried with `return` in front of it before a syntax error is reported. It
returns `nil` and a diagnostic when neither form compiles. `reset` forgets everything a previous call stashed.
`describe` converts a value into something JSON can carry, because encoding raises on a function, a coroutine
or cdata, and an agent that returned one by accident should get a description of it rather than a failed call;
it walks 6 levels deep and 256 entries per table before summarizing.

The environment carries `assert`, `error`, `ipairs`, `next`, `pairs`, `pcall`, `print`, `select`,
`setmetatable`, `getmetatable`, `rawget`, `rawset`, `rawequal`, `rawlen`, `tonumber`, `tostring`, `type`,
`unpack`, `xpcall`, `require`, `string`, `table`, `math`, `coroutine`, `bit`, `jit` and `ffi`, plus an `os`
holding only `time`, `clock`, `date`, `difftime` and `getenv`. Absent on purpose: `io`, `dofile`, `loadfile`,
`load`, and `os.execute`, `remove`, `rename` and `exit`. Anything not on the list is absent, so a new global in
the host does not silently become reachable.

::: warning A guard rail, not a security boundary
`run_lua` exists to do what no structured tool covers, so anything reachable from the engine is reachable from
it. What is removed are the operations that damage the machine rather than the game.
:::

## The transport

`tecs.mcp.transport` is HTTP framing over SDL3_net, polled rather than blocking, because the thing being
debugged is a game loop and a transport that blocked on accept would stall the frame it exists to observe.

```teal
record Request
    method: string
    path: string
    body: string
end

function transport.listen(port: integer): transport.Server
function transport.Server:poll(now: number, handler: function(transport.Request)): boolean
function transport.Server:respond(status: integer, reason: string, body: string, contentType?: string)
function transport.Server:close()
function transport.Server:destroy()
```

`poll` accepts and reads without waiting and calls `handler` only with a whole request; `now` is the engine
clock and is used only to time a connection out. `respond` writes the status line, a `Content-Type` that
defaults to `application/json`, a `Content-Length` and the body, drains the socket and closes, since each
request gets its own connection.

Only `Content-Length` framing is handled, because MCP posts a JSON body and always declares its length. One
connection is served at a time: a debugger is one client, and a queue of pending sockets would be state to
reason about for no benefit. A request arrives over as many reads as it takes, 16 KB at a time, and a
connection that stops mid-request is dropped after 10 seconds so a half-open peer cannot hold the single client
slot forever.
<!-- @generated by docs/scripts/reference.py from src/tecs/mcp/init.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/mcp/init.tl`.

<a id="tecs.mcp.Handler"></a>

### tecs.mcp.Handler

<pre><code v-pre>type <a href="#tecs.mcp.Handler">tecs.mcp.Handler</a> = function({string : &lt;any type&gt;}): {string : &lt;any type&gt;}
</code></pre>

What a tool receives and returns. Arguments arrive decoded; the result
is encoded as the tool's structured content.
<a id="tecs.mcp.Server"></a>

### tecs.mcp.Server

<pre><code v-pre>record <a href="#tecs.mcp.Server">tecs.mcp.Server</a>
</code></pre>

A listening MCP endpoint. Answers only while something calls `poll`.
<a id="tecs.mcp.Server.port"></a>

### tecs.mcp.Server.port

<pre><code v-pre><a href="#tecs.mcp.Server.port">tecs.mcp.Server.port</a>: integer
</code></pre>

The TCP port bound, which is 7100 when `listen` was given none.
<a id="tecs.mcp.Server.poll"></a>

### tecs.mcp.Server.poll

<pre><code v-pre>function <a href="#tecs.mcp.Server.poll">tecs.mcp.Server.poll</a>(self: <a href="#tecs.mcp.Server">Server</a>): boolean
</code></pre>

Answers at most one request. Call once per frame.

Reads the clock itself, so no time is passed in. Only POST is accepted;
anything else is answered 405 without reaching `dispatch`.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.mcp.Server">Server</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>boolean</code> | True when a request was answered, which includes one answered with a 405 or a JSON-RPC error. False when nothing was waiting, when a request is still arriving, or when the server has been destroyed. |

<a id="tecs.mcp.Server.destroy"></a>

### tecs.mcp.Server.destroy

<pre><code v-pre>function <a href="#tecs.mcp.Server.destroy">tecs.mcp.Server.destroy</a>(self: <a href="#tecs.mcp.Server">Server</a>)
</code></pre>

Releases the server. Safe to call more than once.

One way: the port is given up and the server cannot be made to listen
again. The tool registry is module-wide and is left untouched, so a later
`listen` answers the same tools.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.mcp.Server">Server</a></code> | <code v-pre>self</code> |             |

<a id="tecs.mcp.Tool"></a>

### tecs.mcp.Tool

<pre><code v-pre>record <a href="#tecs.mcp.Tool">tecs.mcp.Tool</a>
</code></pre>

One registered tool: what it is called, how it is described to an
agent, and what runs when the agent calls it.
<a id="tecs.mcp.Tool.name"></a>

### tecs.mcp.Tool.name

<pre><code v-pre><a href="#tecs.mcp.Tool.name">tecs.mcp.Tool.name</a>: string
</code></pre>

The name an agent calls, and the registry key. Established MCP
tool names are spelled the way the protocol's ecosystem spells
them, `run_lua` and `send_event` among them, so they are
snake_case where the rest of this tree is camelCase; that is
deliberate and is not to be renamed. Required.
<a id="tecs.mcp.Tool.description"></a>

### tecs.mcp.Tool.description

<pre><code v-pre><a href="#tecs.mcp.Tool.description">tecs.mcp.Tool.description</a>: string
</code></pre>

One line shown to the agent alongside the name. Optional: nil is
sent as an empty string rather than omitted.
<a id="tecs.mcp.Tool.inputSchema"></a>

### tecs.mcp.Tool.inputSchema

<pre><code v-pre><a href="#tecs.mcp.Tool.inputSchema">tecs.mcp.Tool.inputSchema</a>: {string : &lt;any type&gt;}
</code></pre>

JSON Schema for the arguments, sent verbatim in the tool list.
<a id="tecs.mcp.Tool.handler"></a>

### tecs.mcp.Tool.handler

<pre><code v-pre><a href="#tecs.mcp.Tool.handler">tecs.mcp.Tool.handler</a>: <a href="#tecs.mcp.Handler">Handler</a>
</code></pre>

Runs on the game thread when the tool is called. Required, and its
absence raises at registration rather than at call time.
<a id="tecs.mcp.Tool.readOnly"></a>

### tecs.mcp.Tool.readOnly

<pre><code v-pre><a href="#tecs.mcp.Tool.readOnly">tecs.mcp.Tool.readOnly</a>: boolean
</code></pre>

Declared so an agent can tell what a call will do before making it.
<a id="tecs.mcp.Tool.destructive"></a>

### tecs.mcp.Tool.destructive

<pre><code v-pre><a href="#tecs.mcp.Tool.destructive">tecs.mcp.Tool.destructive</a>: boolean
</code></pre>

Whether a call changes state that a caller would not want changed
without asking. Optional, false when nil. Advisory, like
`readOnly`: both are reported to the agent and neither is checked
here, so a tool declared read-only is still free to write.
<a id="tecs.mcp.Tool.whenCrashed"></a>

### tecs.mcp.Tool.whenCrashed

<pre><code v-pre><a href="#tecs.mcp.Tool.whenCrashed">tecs.mcp.Tool.whenCrashed</a>: boolean
</code></pre>

Still callable after the game has crashed. False by default,
because a crashed world cannot answer anything about itself, and a
tool that read it would return nonsense rather than an error.
<a id="tecs.mcp.crashed"></a>

### tecs.mcp.crashed

<pre><code v-pre>function <a href="#tecs.mcp.crashed">tecs.mcp.crashed</a>(): string
</code></pre>

The crash traceback, or nil while the game is healthy.

#### Returns

| Type                      | Description                                                                                                                         |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | nil means no crash has been recorded, which is the only sense in which the game is known to be healthy: nothing here polls for one. |

<a id="tecs.mcp.dispatch"></a>

### tecs.mcp.dispatch

<pre><code v-pre>function <a href="#tecs.mcp.dispatch">tecs.mcp.dispatch</a>(text: string): string
</code></pre>

Runs one JSON-RPC request and returns the response text.

Exposed so the protocol can be tested without a socket, which is most of
what there is to get wrong here.

The three methods answered, `initialize`, `tools/list` and `tools/call`,
are spelled as the MCP specification spells them and are not this tree's to
rename. Anything else is a method-not-found error.

A handler that raises is caught: the agent is told through `isError` and
the server carries on. A handler that returns nil is not an error, and
comes back as an empty `structuredContent`.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                                         |
| ------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>text</code> | One JSON-RPC request object. A batch, that is a JSON array, is not supported; it decodes, has no `method`, and comes back as an invalid-request error rather than being fanned out. |

#### Returns

| Type                      | Description                                                                                                                                                                                        |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | Always a response as JSON text, never nil, and never a raise, since bad input is reported in-band. A request that carried no `id` is still answered, with the `id` field absent from the response. |

<a id="tecs.mcp.listen"></a>

### tecs.mcp.listen

<pre><code v-pre>function <a href="#tecs.mcp.listen">tecs.mcp.listen</a>(port: integer): mcp.Server
</code></pre>

Starts the server on `port`.

#### Parameters

| Type                       | Name                    | Description                                                                                                                     |
| -------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>port</code> | Defaults to 7100. A port already in use raises rather than being worked around, since a debugger that moved could not be found. |

#### Returns

| Type                          | Description                                                    |
| ----------------------------- | -------------------------------------------------------------- |
| <code v-pre>mcp.Server</code> | Listening, but answering nothing until something calls `poll`. |

<a id="tecs.mcp.register"></a>

### tecs.mcp.register

<pre><code v-pre>function <a href="#tecs.mcp.register">tecs.mcp.register</a>(tool: mcp.Tool)
</code></pre>

Registers a tool. Re-registering a name replaces it.

Replacing keeps the name's original position in the list, so the order a
client sees is first-registration order rather than last.

#### Parameters

| Type                        | Name                    | Description                                                                                                                                                                                             |
| --------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>mcp.Tool</code> | <code v-pre>tool</code> | Stored by reference and never copied, so mutating the table afterwards changes what the server dispatches and reports. `name` and `handler` are required and their absence raises; the rest may be nil. |

<a id="tecs.mcp.setCrashed"></a>

### tecs.mcp.setCrashed

<pre><code v-pre>function <a href="#tecs.mcp.setCrashed">tecs.mcp.setCrashed</a>(traceback: string)
</code></pre>

Records a crash. Every subsequent world-touching call reports it.

#### Parameters

| Type                      | Name                         | Description                                                                                                                                                                                     |
| ------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>traceback</code> | Stored as given and handed back verbatim by `crashed`, and sent as the whole body of the error a blocked tool answers with. Passing nil clears the crashed state and lets every tool run again. |

<a id="tecs.mcp.tools"></a>

### tecs.mcp.tools

<pre><code v-pre>function <a href="#tecs.mcp.tools">tecs.mcp.tools</a>(): {mcp.Tool}
</code></pre>

Every registered tool, in registration order.

#### Returns

| Type                          | Description                                                                                                                                                                   |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{mcp.Tool}</code> | A fresh list each call, so the caller may keep it. The `Tool` values in it are the registered tables themselves rather than copies, so writing to one writes to the registry. |

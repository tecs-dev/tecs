--- Deterministic, snapshot-safe gameplay sequencing.
---
--- A sequence is a compiled program of scheduled steps that advances on the
--- fixed step. Cutscenes, ability chains, spawn waves, and tutorials are
--- normally written as coroutines, whose suspended state lives in the Lua
--- stack and cannot be serialized. A sequence keeps its position as data, so
--- it survives snapshots, rewind, and hot reload.
---
--- Usage:
---   local sequence = require("tecs2d.sequence")
---
---   sequence.registerAction(world, "game.lockControls", function(_w, _ctx)
---       controlsLocked = true
---   end)
---
---   local intro = sequence.define("game.bossIntro", {
---       sequence.call("game.lockControls"),
---       sequence.wait(1.5),
---       sequence.emit("boss.ready"),
---   })
---
---   sequence.play(world, intro, {owner = encounter, bindings = {boss = bossId}})
---
--- This module currently declares its public contract. The runtime lands in
--- the following phase; every entry point raises until then.

local tecs <const> = require("tecs")

local type World = tecs.World

local NOT_IMPLEMENTED <const> =
    "tecs2d.sequence: the runtime is not implemented yet"

--- Why a cursor stopped running.
local enum FaultReason
    --- A `call` named an action that is not registered on this world.
    "unregisteredAction"
    --- A registered action raised.
    "actionError"
    --- The cursor exceeded its per-step instruction budget.
    "budgetExceeded"
    --- A `call` needed a binding that is absent or no longer alive.
    "missingBinding"
end

--- The lifecycle state of one playback.
local enum PlaybackState
    "running"
    "paused"
    "completed"
    "cancelled"
    "faulted"
end

local record sequence
    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------

    --- Why a cursor stopped running.
    type FaultReason = FaultReason

    --- The lifecycle state of one playback.
    type PlaybackState = PlaybackState

    --- A compiled, immutable program. Produced by `define`, shared by every
    --- playback of it, and reference counted.
    ---
    --- Redefining a name compiles a new version. Playbacks already running
    --- keep the version they started with, so a hot reload continues rather
    --- than resuming against changed instructions. Later `play` calls use the
    --- newest version, and a superseded version is released once its last
    --- playback finishes.
    interface Program
        --- The name passed to `define`.
        name: string

        --- Monotonic version, starting at 1. Incremented per redefinition.
        version: integer
    end

    --- One authored step. Produced by the node constructors below; treat the
    --- returned value as opaque and do not reuse a node across programs.
    interface Node end

    --- A reference to an entity supplied at `play` time. Resolved when the
    --- instruction that uses it runs, not when the program is defined.
    interface EntityRef end

    --- A generation-checked reference to one playback. Remains meaningful
    --- across a snapshot load: a handle saved before the snapshot refers to
    --- the same playback after it is restored, and reports `cancelled` if
    --- that playback did not survive.
    interface Handle end

    --- Constants a `call` passes to its action. Numbers, strings, booleans,
    --- and arrays or maps composed of those. Entities are passed as bindings
    --- rather than arguments, so a saved program never embeds an entity id.
    type Argument = number | string | boolean | {any}

    --- Options for `play`.
    record PlayOptions
        --- Entity whose lifetime governs the playback. When it despawns, the
        --- playback is cancelled. Omit for a world-scoped sequence.
        owner: integer

        --- Entities the program acts on, addressed by `sequence.bind(name)`.
        bindings: {string: integer}

        --- Per-step instruction budget for this playback. Defaults to the
        --- world's configured budget. See `setInstructionBudget`.
        budget: integer
    end

    --- What a registered action receives.
    record ActionContext
        --- The world this playback belongs to.
        world: World

        --- The playback, for `status` or `cancel` from inside an action.
        handle: Handle

        --- The `owner` supplied at `play`, or 0 for a world-scoped sequence.
        owner: integer

        --- Constants supplied by the `call` node.
        args: {Argument}

        --- Resolve a named binding. Returns nil when the binding was not
        --- supplied or its entity is no longer alive.
        entity: function(self: ActionContext, name: string): integer
    end

    --- A registered effect. Runs synchronously and must return before the
    --- cursor advances; it may not yield.
    ---
    --- Raising faults the playback with `actionError`. Mutations the action
    --- already made are kept: the sequencer does not roll them back.
    type Action = function(world: World, ctx: ActionContext)

    --- A playback's current state.
    record Status
        state: PlaybackState

        --- Program name and version this playback is running.
        program: string
        version: integer

        --- Instruction index, for disassembly and debugging.
        pc: integer

        --- Fixed step this playback next runs on. Nil when it is not waiting.
        wakeAt: integer

        --- Set when `state` is `"faulted"`.
        fault: FaultReason
        faultMessage: string
    end

    ---------------------------------------------------------------------------
    -- Authoring
    ---------------------------------------------------------------------------

    --- Compile a program under a stable symbolic name.
    ---
    --- The name is what snapshots and replays store, so it must be stable
    --- across builds. Redefining a name produces a new version rather than
    --- mutating the existing one; see `Program`.
    ---
    --- @param name Stable program name, conventionally dotted ("game.bossIntro").
    --- @param nodes Steps to run in order.
    --- @return The compiled program.
    define: function(name: string, nodes: {Node}): Program

    --- Look up the newest version of a defined program.
    --- @return The program, or nil when the name was never defined.
    program: function(name: string): Program

    --- Reference an entity supplied through `PlayOptions.bindings`.
    bind: function(name: string): EntityRef

    --- Run a registered action.
    ---
    --- Arguments are constants stored in the program. Pass entities through
    --- bindings instead, so the program stays independent of any one world.
    call: function(action: string, ...: Argument): Node

    --- Wait for a duration in seconds.
    ---
    --- Converted to whole fixed steps at compile time, rounded to nearest,
    --- with any non-zero duration waiting at least one step. Use `waitSteps`
    --- when the exact step count matters more than the wall-clock duration.
    wait: function(seconds: number): Node

    --- Wait for a whole number of fixed steps.
    ---
    --- `waitSteps(0)` yields: the cursor resumes on the next fixed step
    --- rather than continuing within the current one. This bounds a loop body
    --- that would otherwise have to consume instruction budget to make
    --- progress.
    waitSteps: function(steps: integer): Node

    --- Emit an ECS event at address 0.
    emit: function(event: string, ...: Argument): Node

    --- Repeat a block.
    --- @param count Iterations, or nil to repeat until cancelled.
    --- @param nodes Steps to repeat.
    loop: function(count: integer, nodes: {Node}): Node

    ---------------------------------------------------------------------------
    -- Actions
    ---------------------------------------------------------------------------

    --- Register an effect a `call` node can name.
    ---
    --- Registration is per world and by stable name, so a snapshot load or a
    --- hot reload rebinds a saved program to the freshly registered function.
    ---
    --- Actions must obey the deterministic-action contract to keep replay and
    --- rewind meaningful: no wall-clock reads, no file or network access, and
    --- randomness only through `love.math`, whose state travels with
    --- snapshots. The sequencer guarantees deterministic control flow and
    --- scheduling; it cannot make an arbitrary action deterministic.
    registerAction: function(world: World, name: string, action: Action)

    --- Whether an action name is registered on this world.
    hasAction: function(world: World, name: string): boolean

    ---------------------------------------------------------------------------
    -- Playback
    ---------------------------------------------------------------------------

    --- Start a program. The first instruction runs on the next fixed step.
    play: function(world: World, program: Program, options?: PlayOptions): Handle

    --- Stop a playback and release its cursor. Safe on a finished handle.
    --- @return true when a running playback was stopped.
    cancel: function(world: World, handle: Handle): boolean

    --- Suspend a playback. Its wait, if any, resumes from where it paused.
    pause: function(world: World, handle: Handle): boolean

    --- Resume a paused playback.
    resume: function(world: World, handle: Handle): boolean

    --- Inspect a playback. Returns nil for a handle this world never issued.
    status: function(world: World, handle: Handle): Status

    --- Cancel every playback owned by an entity. Called automatically when
    --- the owner despawns; exposed for explicit teardown.
    cancelOwnedBy: function(world: World, owner: integer): integer

    ---------------------------------------------------------------------------
    -- Configuration and tooling
    ---------------------------------------------------------------------------

    --- Per-step instruction budget for playbacks that do not set their own.
    ---
    --- A program that loops without waiting would otherwise never yield. When
    --- a cursor exceeds its budget in one step it faults with
    --- `budgetExceeded`, reporting the program name, version, and pc.
    setInstructionBudget: function(world: World, instructions: integer)

    --- Render a program as readable instructions, for debugging and the
    --- runtime debugger's inspection commands.
    disassemble: function(program: Program): string

    --- Install the sequencer. Auto-installed by `tecs2d.run`.
    plugin: function(world: World)
end

function sequence.define(_name: string, _nodes: {sequence.Node}): sequence.Program
    error(NOT_IMPLEMENTED)
end

function sequence.program(_name: string): sequence.Program
    error(NOT_IMPLEMENTED)
end

function sequence.bind(_name: string): sequence.EntityRef
    error(NOT_IMPLEMENTED)
end

function sequence.call(_action: string, ...: sequence.Argument): sequence.Node
    local _argCount <const> = select("#", ...)
    error(NOT_IMPLEMENTED)
end

function sequence.wait(_seconds: number): sequence.Node
    error(NOT_IMPLEMENTED)
end

function sequence.waitSteps(_steps: integer): sequence.Node
    error(NOT_IMPLEMENTED)
end

function sequence.emit(_event: string, ...: sequence.Argument): sequence.Node
    local _argCount <const> = select("#", ...)
    error(NOT_IMPLEMENTED)
end

function sequence.loop(_count: integer, _nodes: {sequence.Node}): sequence.Node
    error(NOT_IMPLEMENTED)
end

function sequence.registerAction(_world: World, _name: string, _action: sequence.Action)
    error(NOT_IMPLEMENTED)
end

function sequence.hasAction(_world: World, _name: string): boolean
    error(NOT_IMPLEMENTED)
end

function sequence.play(
    _world: World,
    _program: sequence.Program,
    _options?: sequence.PlayOptions
): sequence.Handle
    error(NOT_IMPLEMENTED)
end

function sequence.cancel(_world: World, _handle: sequence.Handle): boolean
    error(NOT_IMPLEMENTED)
end

function sequence.pause(_world: World, _handle: sequence.Handle): boolean
    error(NOT_IMPLEMENTED)
end

function sequence.resume(_world: World, _handle: sequence.Handle): boolean
    error(NOT_IMPLEMENTED)
end

function sequence.status(_world: World, _handle: sequence.Handle): sequence.Status
    error(NOT_IMPLEMENTED)
end

function sequence.cancelOwnedBy(_world: World, _owner: integer): integer
    error(NOT_IMPLEMENTED)
end

function sequence.setInstructionBudget(_world: World, _instructions: integer)
    error(NOT_IMPLEMENTED)
end

function sequence.disassemble(_program: sequence.Program): string
    error(NOT_IMPLEMENTED)
end

function sequence.plugin(_world: World)
    error(NOT_IMPLEMENTED)
end

return sequence

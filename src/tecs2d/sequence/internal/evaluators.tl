--- Things a program can evaluate continuously.
---
--- Most instructions run once and hand the tick back. An `eval` step does
--- not: the cursor joins its clock's active set and is stepped every tick
--- until the evaluator says it is done. That is what interpolation needs --
--- a value that has to move on every frame, not a decision made once.
---
--- Registered by name, like actions, so a program names what it evaluates
--- and a snapshot carries that name rather than a function. Global rather
--- than per world, because an evaluator is code.

local seqtypes <const> = require("tecs2d.sequence.internal.types")

local record evaluators
    --- Register an evaluator under a stable name. Registering a name twice
    --- replaces it, which is what a hot reload wants.
    register: function(name: string, evaluator: seqtypes.Evaluator)

    --- Look one up, or nil.
    get: function(name: string): seqtypes.Evaluator
end

local byName: {string: seqtypes.Evaluator} = {}

function evaluators.register(name: string, evaluator: seqtypes.Evaluator)
    if type(name) ~= "string" or name == "" then
        error("sequence: an evaluator needs a non-empty name", 2)
    end
    if type(evaluator) ~= "table" or evaluator.step == nil then
        error("sequence: an evaluator needs a step function", 2)
    end
    byName[name] = evaluator
end

function evaluators.get(name: string): seqtypes.Evaluator
    return byName[name]
end

return evaluators

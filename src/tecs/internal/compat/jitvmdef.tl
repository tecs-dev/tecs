-- love2d doesn't bundle the jit/*.lua stdlib files in its release packages
-- (see https://github.com/love2d/love/issues/1752), so require("jit.vmdef") fails inside a love game and trace abort
-- reports lose their human-readable reasons (e.g. "error 5" instead of "blacklisted") and bytecode names
-- (e.g. "op51" instead of "FNEW"). This registers a fallback on package.preload exposing only the fields tecs uses
-- (`traceerr`, `bcnames`); on systems that ship the real file, Lua's loader still resolves to it first
-- (package.loaded is checked before preload, and if a user has already required jit.vmdef, their version is kept).
--
-- The tables below are baked from LuaJIT 2.1's jit/vmdef.lua. Regenerate with:
--   luajit -e 'local v=require"jit.vmdef".traceerr; local i=0; while v[i] do io.write(string.format("[%d] = %q,\n",i,v[i])); i=i+1 end'
--   luajit -e 'print(require("jit.vmdef").bcnames)'

local loaded = package.loaded as {string: any}
local preload = package.preload as {string: function(): any}

if not loaded["jit.vmdef"] and not preload["jit.vmdef"] then
    preload["jit.vmdef"] = function(): any
        local traceerr: {integer: string} = {
            [0] = "error thrown or hook called during recording",
            [1] = "trace too short",
            [2] = "trace too long",
            [3] = "trace too deep",
            [4] = "too many snapshots",
            [5] = "blacklisted",
            [6] = "retry recording",
            [7] = "NYI: bytecode %s",
            [8] = "leaving loop in root trace",
            [9] = "inner loop in root trace",
            [10] = "loop unroll limit reached",
            [11] = "bad argument type",
            [12] = "JIT compilation disabled for function",
            [13] = "call unroll limit reached",
            [14] = "down-recursion, restarting",
            [15] = "NYI: unsupported variant of FastFunc %s",
            [16] = "NYI: return to lower frame",
            [17] = "store with nil or NaN key",
            [18] = "missing metamethod",
            [19] = "looping index lookup",
            [20] = "NYI: mixed sparse/dense table",
            [21] = "symbol not in cache",
            [22] = "NYI: unsupported C type conversion",
            [23] = "NYI: unsupported C function type",
            [24] = "guard would always fail",
            [25] = "too many PHIs",
            [26] = "persistent type instability",
            [27] = "failed to allocate mcode memory",
            [28] = "machine code too long",
            [29] = "hit mcode limit (retrying)",
            [30] = "too many spill slots",
            [31] = "inconsistent register allocation",
            [32] = "NYI: cannot assemble IR instruction %d",
            [33] = "NYI: PHI shuffling too complex",
            [34] = "NYI: register coalescing too complex",
        }

        -- LuaJIT packs bytecode opcode names into a single fixed-width string,
        -- 6 chars per entry; consumers look up op N at byte N*6+1.
        local bcnames =
            "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP " ..
            "ISTC  ISFC  IST   ISF   ISTYPEISNUM MOV   NOT   UNM   LEN   " ..
            "ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV " ..
            "ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   " ..
            "KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  " ..
            "UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  " ..
            "TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR " ..
            "CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXT" ..
            "RETM  RET   RET0  RET1  " ..
            "FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERL" ..
            "LOOP  ILOOP JLOOP JMP   " ..
            "FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"

        return {
            traceerr = traceerr,
            bcnames = bcnames,
        }
    end
end

return true

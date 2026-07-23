require("busted")

local luassert <const> = require("luassert")
local cmdharness <const> = require("spec.tecs2d.debug.cmdharness")

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local makeRegistry <const> = cmdharness.makeRegistry
local SpecPos <const> = cmdharness.SpecPos
local SpecTag <const> = cmdharness.SpecTag

describe("tecs2d.debug.internal.cmd.capture", function()
    describe("artifact info verbs", function()
        it("snapshot, screenshot, and record info report entry details", function()
            local reg, _, ctx = makeRegistry()
            local fsAny = love.filesystem as {string: any}
            local oldSaveDir = fsAny.getSaveDirectory
            fsAny.getSaveDirectory = function(): string return "/save" end
            ctx.snapshots[1] = {number = 7, path = "s.snapshot", size = 2048, time = 0, entities = 123}
            ctx.screenshots[1] = {path = "shot.png", size = 1024, time = 0}
            ctx.recordings[1] = {path = "rec/clip.mp4", size = 4096, time = 0,
                duration = 2.5, stopReason = "manual"}

            local snap = reg:execute("snapshot info")
            luassert.is_true(snap.ok, tostring(snap.message))
            luassert.equals(7, snap.data.number)
            luassert.equals(123, snap.data.entities)
            luassert.is_true((reg:execute("snapshot info 7")).ok)

            local shot = reg:execute("screenshot info")
            luassert.is_true(shot.ok, tostring(shot.message))
            luassert.equals("shot.png", shot.popupImagePath)

            local recInfo = reg:execute("record info")
            luassert.is_true(recInfo.ok, tostring(recInfo.message))
            luassert.equals("manual", recInfo.data.stopReason)
            luassert.equals(2.5, recInfo.data.duration)

            luassert.is_false((reg:execute("snapshot info nope")).ok)
            fsAny.getSaveDirectory = oldSaveDir
        end)

        it("profile info regenerates the summary from the capture file", function()
            local reg, _, ctx = makeRegistry()
            local tmp = os.tmpname()
            local f = io.open(tmp, "w")
            f:write("beforeFixed;Update:spec.Sys;foo 5\nbeforeFixed;Update:spec.Sys;bar 3\n")
            f:close()
            ctx.profiles[1] = {path = tmp, size = 10, time = 0}

            local r = reg:execute("profile info")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.matches("samples: 8", table.concat(r.popup, "\n"))
            os.remove(tmp)
        end)

        it("profile open copies the capture path and opens speedscope", function()
            local reg, _, ctx = makeRegistry()
            ctx.profiles[1] = {path = "cap.collapsed", size = 1, time = 0}

            local oldSystem = love.system
            local clip, opened = "", ""
            love.system = {
                setClipboardText = function(text: string) clip = text end,
                openURL = function(url: string): boolean
                    opened = url
                    return true
                end,
            } as any
            local fsAny = love.filesystem as {string: any}
            local oldWd = fsAny.getWorkingDirectory
            fsAny.getWorkingDirectory = function(): string return "/work" end

            local r = reg:execute("profile open")

            love.system = oldSystem
            fsAny.getWorkingDirectory = oldWd
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals("/work/cap.collapsed", clip)
            luassert.matches("speedscope", opened)
        end)
    end)

    describe("capture commands", function()
        it("screenshot delay schedules a pending capture", function()
            local reg = makeRegistry()
            local r = reg:execute("screenshot late.png delay=2 panel=true")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.equals(1, #reg.pendingShots)
            luassert.equals(true, r.data.panel)
            luassert.matches("in 2%.0s", r.message)
        end)

        it("rewind rings, evicts, loads the past, and keeps evidence", function()
            local reg, w, ctx = makeRegistry()
            local rewind = require("tecs2d.debug.internal.rewind")

            -- In-memory filesystem so writes, reads, and eviction are
            -- observable; restored even when an assertion throws.
            local files: {string: string} = {}
            local fs = love.filesystem as {string: any}
            local oldWrite, oldRead, oldRemove = fs.write, fs.read, fs.remove
            local oldInfo, oldDir = fs.getInfo, fs.getDirectoryItems
            fs.write = function(path: string, contents: string): boolean, string
                files[path] = contents
                return true, nil
            end
            fs.read = function(path: string): string return files[path] end
            fs.remove = function(path: string): boolean, string
                if files[path] == nil then return false, "missing" end
                files[path] = nil
                return true, nil
            end
            fs.getInfo = function(path: string): any
                if files[path] == nil then return nil end
                return {size = #files[path]}
            end
            fs.getDirectoryItems = function(prefix: string): {string}
                local out: {string} = {}
                local lead = prefix .. "/"
                for k in pairs(files) do
                    if k:sub(1, #lead) == lead then
                        out[#out + 1] = k:sub(#lead + 1)
                    end
                end
                return out
            end
            finally(function()
                fs.write, fs.read, fs.remove = oldWrite, oldRead, oldRemove
                fs.getInfo, fs.getDirectoryItems = oldInfo, oldDir
            end)

            w:spawn(SpecPos(1, 1))
            w:commit()

            -- A stale file from a "crashed session" is swept by start.
            files["debug-rewind/rewind-99.snapshot"] = "stale"
            luassert.is_true((reg:execute("rewind start 5 3")).ok)
            luassert.equals("running", ctx.rewind.status)
            luassert.is_nil(files["debug-rewind/rewind-99.snapshot"], "stale file survived start")
            luassert.is_false((reg:execute("rewind start")).ok, "double start must refuse")

            -- Captures happen on the tick clock, never while frozen.
            rewind.tick(ctx, w, 0, true)
            luassert.equals(0, #ctx.rewind.entries, "captured while frozen")
            rewind.tick(ctx, w, 0, false)
            luassert.equals(1, #ctx.rewind.entries)
            rewind.tick(ctx, w, 1, false)
            luassert.equals(1, #ctx.rewind.entries, "captured before due")
            rewind.tick(ctx, w, 5, false)

            -- Mutate after the second capture, then push past the cap: the
            -- first (pre-mutation) capture is evicted from memory and disk.
            local marker = w:spawn(SpecPos(9, 9))
            w:commit()
            rewind.tick(ctx, w, 10, false)
            rewind.tick(ctx, w, 15, false)
            luassert.equals(3, #ctx.rewind.entries)
            luassert.is_nil(files["debug-rewind/rewind-1.snapshot"], "oldest not evicted from disk")

            local listed = reg:execute("rewind list")
            local rows = listed.data.entries as {any}
            luassert.equals(3, #rows)
            luassert.equals(1, (rows[1] as {string: any}).index, "list must be newest first")

            -- Loading the oldest kept entry restores the pre-marker world and
            -- pauses capture until an explicit resume.
            local loaded = reg:execute("rewind load 3")
            luassert.is_true(loaded.ok, tostring(loaded.message))
            luassert.is_false(w:isAlive(marker), "load did not rewind the world")
            luassert.equals("paused", ctx.rewind.status)
            luassert.equals("loaded", ctx.rewind.pauseReason)

            -- Mashed Enter cannot stack world loads: a second load inside the
            -- cooldown is refused, and allowed once the clock moves on.
            local timer = love.timer as {string: any}
            luassert.equals("busy", (reg:execute("rewind load 3")).code)
            luassert.equals("busy", (reg:execute("snapshot load")).code, "cooldown must be shared")
            timer.currentTime = (timer.currentTime as number) + 1
            luassert.is_true((reg:execute("rewind load 3")).ok, "cooldown never released")

            -- ago=N selects by age (entry times are steerable directly).
            ctx.rewind.entries[1].time = os.time() - 60
            local byAge = rewind.findEntry(ctx, nil, 30)
            luassert.equals(ctx.rewind.entries[1].path, byAge.path)
            local none, _, ageErr = rewind.findEntry(ctx, nil, 999)
            luassert.is_nil(none)
            luassert.matches("no entry that old", ageErr)
            -- "30s" is shorthand for ago=30.
            local shorthand = rewind.findEntry(ctx, "30s", nil)
            luassert.equals(ctx.rewind.entries[1].path, shorthand.path)

            -- keep promotes into the normal snapshot history with a number
            -- and the capture-time timestamp.
            local kept = reg:execute("rewind keep latest before-bug.snapshot")
            luassert.is_true(kept.ok, tostring(kept.message))
            luassert.equals(1, #ctx.snapshots)
            luassert.equals(kept.data.number, ctx.snapshots[1].number)
            luassert.equals(ctx.rewind.entries[#ctx.rewind.entries].time, ctx.snapshots[1].time)
            luassert.is_not_nil(files["before-bug.snapshot"])

            luassert.is_true((reg:execute("rewind resume")).ok)
            luassert.equals("running", ctx.rewind.status)
            luassert.is_true((reg:execute("rewind stop")).ok)
            luassert.is_false((reg:execute("rewind start")).ok,
                "start must refuse over a stopped ring")

            -- Separation both ways: snapshot clear leaves the ring, rewind
            -- clear leaves the snapshot history (already emptied here).
            reg:execute("snapshot clear")
            luassert.equals(3, #ctx.rewind.entries)
            luassert.is_true((reg:execute("rewind clear")).ok)
            luassert.equals("idle", ctx.rewind.status)
            luassert.equals(0, #ctx.rewind.entries)
            for k in pairs(files) do
                luassert.is_nil(k:match("^debug%-rewind/"), "ring file survived clear: " .. k)
            end
        end)

        it("snapshot save inline json round-trips through snapshot load payload", function()
            local reg, w, ctx = makeRegistry()
            local json = require("tecs.utils.json")
            local eid = w:spawn(SpecPos(3, 4))
            w:commit()

            local saved = reg:execute("snapshot save inline=true format=json")
            luassert.is_true(saved.ok, tostring(saved.message))
            luassert.equals("json", saved.data.format)
            luassert.is_not_nil(saved.data.snapshot)
            luassert.equals(1, saved.data.entities)
            luassert.is_true((saved.data.archetypes as integer) >= 1)
            luassert.is_true((saved.data.bytes as integer) > 0)
            luassert.equals(0, reg.saveCounter, "inline must not mint a snapshot number")
            luassert.equals(0, #ctx.snapshots, "inline must not register an artifact")

            -- Mutate the world, then restore the inline payload.
            local pos = w:getMut(eid, SpecPos) as {string: number}
            pos.x = 99
            local extra = w:spawn(SpecPos(8, 8))
            w:commit()

            local payload = json.serialize(saved.data.snapshot as {string: any})
            local loaded = reg:invokeMcp("cmd_snapshot_load",
                {payload = payload, format = "json"})
            luassert.is_true(loaded.ok, tostring(loaded.message))
            luassert.equals("inline-payload", loaded.data.source)
            luassert.equals("json", loaded.data.format)
            luassert.equals(1, loaded.data.entities)
            luassert.equals(3, (w:get(eid, SpecPos) as {string: number}).x,
                "load must restore the saved field value")
            luassert.is_false(w:isAlive(extra), "load must drop entities born after the save")

            -- Layer validation matches the snapshot_save builtin.
            luassert.equals("invalid_arguments",
                (reg:execute("snapshot save inline=true format=json layers=99")).code)
            luassert.equals("invalid_arguments",
                (reg:execute("snapshot save inline=true layers=a,b")).code)
        end)

        it("diff sees JSON kind changes and honors sentinel values", function()
            local snapdiff = require("tecs2d.debug.internal.diff")
            local json = require("tecs.utils.json")
            local from: {integer: {string: any}} = {[1] = {C = json.NULL, D = {}}}
            local to: {integer: {string: any}} = {[1] = {C = json.EMPTY_OBJECT, D = json.EMPTY_OBJECT}}
            local r = snapdiff.compare(from, {}, to, {}, {limit = 10})
            luassert.equals(1, r.totalChanges, "null vs empty object must be one change")
            local ch = (r.changes as {any})[1] as {string: any}
            luassert.equals("C", ch.component)
            luassert.equals("replace", ch.operation)
        end)

        it("failed writes fail loudly and never mint history entries", function()
            local reg, w, ctx = makeRegistry()
            local rewindMod = require("tecs2d.debug.internal.rewind")
            local files: {string: string} = {}
            local failWrites = false
            local fs = love.filesystem as {string: any}
            local oldWrite, oldRead, oldInfo, oldDir = fs.write, fs.read, fs.getInfo, fs.getDirectoryItems
            fs.write = function(path: string, contents: string): boolean, string
                if failWrites then return false, "disk full" end
                files[path] = contents
                return true, nil
            end
            fs.read = function(path: string): string return files[path] end
            fs.getInfo = function(path: string): any
                if files[path] == nil then return nil end
                return {size = #files[path]}
            end
            fs.getDirectoryItems = function(_p: string): {string} return {} end
            finally(function()
                fs.write, fs.read, fs.getInfo, fs.getDirectoryItems = oldWrite, oldRead, oldInfo, oldDir
            end)

            w:spawn(SpecPos(1, 1))
            w:commit()

            -- Snapshot save reports the failure and records nothing.
            failWrites = true
            local saved = reg:execute("snapshot save doomed.snapshot")
            luassert.is_false(saved.ok)
            luassert.equals("save_failed", saved.code)
            luassert.matches("disk full", saved.message)
            luassert.equals(0, #ctx.snapshots)

            -- Rewind capture parks the session on error instead of recording
            -- a phantom entry.
            failWrites = false
            luassert.is_true((reg:execute("rewind start 5 3")).ok)
            failWrites = true
            rewindMod.tick(ctx, w, 1e9, false)
            luassert.equals(0, #ctx.rewind.entries)
            luassert.equals("paused", ctx.rewind.status)
            luassert.equals("error", ctx.rewind.pauseReason)
            luassert.matches("disk full", ctx.rewind.lastError)

            -- The diff still answers when only its artifact write fails.
            failWrites = false
            luassert.is_true((reg:execute("snapshot save one.snapshot")).ok)
            luassert.is_true((reg:execute("snapshot save two.snapshot")).ok)
            failWrites = true
            local d = reg:execute("diff 1 2")
            luassert.is_true(d.ok, tostring(d.message))
            luassert.matches("disk full", d.data.artifactError as string)
            luassert.equals(0, #ctx.diffs)
        end)

        it("diff compares snapshots, rewind entries, and the live world", function()
            local reg, w, ctx = makeRegistry()

            local files: {string: string} = {}
            local fs = love.filesystem as {string: any}
            local oldWrite, oldRead, oldRemove = fs.write, fs.read, fs.remove
            local oldInfo, oldDir = fs.getInfo, fs.getDirectoryItems
            fs.write = function(path: string, contents: string): boolean, string
                files[path] = contents
                return true, nil
            end
            fs.read = function(path: string): string return files[path] end
            fs.remove = function(path: string): boolean, string
                files[path] = nil
                return true, nil
            end
            fs.getInfo = function(path: string): any
                if files[path] == nil then return nil end
                return {size = #files[path]}
            end
            fs.getDirectoryItems = function(_prefix: string): {string} return {} end
            finally(function()
                fs.write, fs.read, fs.remove = oldWrite, oldRead, oldRemove
                fs.getInfo, fs.getDirectoryItems = oldInfo, oldDir
            end)

            -- Timeline: a moves, b gains a tag, dead despawns, born spawns,
            -- and a pushed state pops (snapshot one carries a state stack).
            -- Entities spawn before the push so the pop cannot despawn them
            -- as state-scoped.
            local a = w:spawn(SpecPos(1, 2))
            local b = w:spawn(SpecPos(0, 0))
            local dead = w:spawn(SpecPos(9, 9))
            w:commit()
            w:createState("DiffSpecState")
            w:pushState("DiffSpecState")
            luassert.is_true((reg:execute("snapshot save one.snapshot")).ok)

            local aPos = w:getMut(a, SpecPos) as {string: number}
            aPos.x = 5
            w:set(b, SpecTag)
            w:despawn(dead)
            w:popState()
            local born = w:spawn(SpecPos(7, 7))
            w:commit()
            luassert.is_true((reg:execute("snapshot save two.snapshot")).ok)

            local r = reg:execute("diff 1 2")
            luassert.is_true(r.ok, tostring(r.message))
            luassert.is_true((r.data.summary as {string: any}).stateStackChanges as integer >= 1,
                "state stack pop must diff")
            luassert.is_not_nil(r.data.skipped, "binary refs must carry the custom-data note")
            local summary = r.data.summary as {string: any}
            luassert.equals(1, summary.entitiesAdded)
            luassert.equals(1, summary.entitiesRemoved)
            local byComp = summary.byComponent as {string: {string: integer}}
            luassert.equals(1, byComp.DbgCmdPos.changed)
            luassert.equals(1, byComp.DbgCmdTag.added)
            -- The x change appears with a proper pointer and values.
            local foundMove = false
            for _, ch in ipairs(r.data.changes as {any}) do
                local c = ch as {string: any}
                if c.entity == a and c.component == "DbgCmdPos" and c.path == "/x" then
                    foundMove = true
                    luassert.equals("replace", c.operation)
                    luassert.equals(1, c.before)
                    luassert.equals(5, c.after)
                end
            end
            luassert.is_true(foundMove, "missing the /x replace change")
            -- Entity add carries the canonical component object.
            local addCh: {string: any} = nil
            for _, ch in ipairs(r.data.changes as {any}) do
                local c = ch as {string: any}
                if c.entity == born and c.operation == "add" then addCh = c end
            end
            luassert.equals(7, ((addCh.after as {string: any}).DbgCmdPos as {string: number}).x)

            -- The artifact was written and is listed.
            luassert.is_not_nil(files["debug-diff-1.json"], "diff artifact missing")
            luassert.equals(1, #((reg:execute("diff list")).data.diffs as {any}))

            -- to defaults to current; the world equals snapshot 2 right now.
            local toCurrent = reg:execute("diff 1")
            luassert.equals(r.data.totalChanges, toCurrent.data.totalChanges)
            luassert.equals(0, (reg:execute("diff 2 2")).data.totalChanges)
            luassert.equals(0, (reg:execute("diff 2")).data.totalChanges)
            luassert.equals(0, (reg:execute("diff latest")).data.totalChanges,
                "`latest` must resolve to the newest save")

            -- Filters.
            local only = reg:execute("diff 1 2 entity=" .. tostring(a))
            luassert.equals(1, only.data.totalChanges)
            local viaArray = reg:invokeMcp("cmd_diff",
                {from = "1", to = "2", ignore = {"DbgCmdPos"}})
            luassert.is_nil(((viaArray.data.summary as {string: any}).byComponent
                as {string: any}).DbgCmdPos, "JSON array ignore= must apply")
            local ignored = reg:execute("diff 1 2 ignore=DbgCmdPos")
            luassert.is_nil((ignored.data.summary as {string: any}).byComponent
                and ((ignored.data.summary as {string: any}).byComponent as {string: any}).DbgCmdPos)
            for _, ch in ipairs(ignored.data.changes as {any}) do
                local c = ch as {string: any}
                if c.entity == born and c.operation == "add" then
                    luassert.is_nil((c.after as {string: any}).DbgCmdPos,
                        "ignore= must strip entity-add payloads too")
                end
            end
            local summaryOnly = reg:execute("diff 1 2 limit=0")
            luassert.equals(0, #(summaryOnly.data.changes as {any}))
            luassert.is_true(summaryOnly.data.truncated as boolean)
            luassert.equals(r.data.totalChanges, summaryOnly.data.totalChanges,
                "summary must cover the complete diff when truncated")
            luassert.equals("invalid_filter", (reg:execute("diff 1 2 component=Nope")).code)
            luassert.equals("read_failed", (reg:execute("diff nope")).code,
                "unknown names pass through as filenames")
            luassert.equals("invalid_ref", (reg:execute("diff rewind:nope")).code)

            -- Rewind refs decode too, and a fresh capture diffs empty against
            -- the live world (the round-trip fidelity check).
            local rewindMod = require("tecs2d.debug.internal.rewind")
            luassert.is_true((reg:execute("rewind start 5 3")).ok)
            rewindMod.tick(ctx, w, 1e9, false)
            local fidelity = reg:execute("diff rewind:latest current")
            luassert.is_true(fidelity.ok, tostring(fidelity.message))
            luassert.equals(0, fidelity.data.totalChanges,
                "capture -> decode -> compare against live must be empty")

            -- A cleared ring reuses filenames; the decode cache must not
            -- serve the old timeline.
            w:spawn(SpecPos(42, 42))
            w:commit()
            luassert.is_true((reg:execute("rewind stop")).ok)
            luassert.is_true((reg:execute("rewind clear")).ok)
            luassert.is_true((reg:execute("rewind start 5 3")).ok)
            rewindMod.tick(ctx, w, 2e9, false)
            local fresh = reg:execute("diff rewind:latest current")
            luassert.equals(0, fresh.data.totalChanges,
                "stale decode served after the ring was cleared and reused")

            -- `latest` with no snapshot history is a clean error, not a
            -- literal filename read.
            local reg2 = makeRegistry()
            luassert.equals("invalid_ref", (reg2:execute("diff latest")).code)

            -- Read-only: the diff never touched selection or the world.
            luassert.equals(0, #ctx.selected)
            luassert.is_true(w:isAlive(a))
        end)

    end)
end)

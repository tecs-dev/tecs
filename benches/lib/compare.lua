#!/usr/bin/env luajit
-- compare.lua - Diff two labeled runs from benches/results/bench-log.csv.
--
-- Usage:
--   luajit compare.lua <label-a> <label-b> [log-path]
--   luajit compare.lua <label-a>                       (compares <label-a> vs latest other label)
--   luajit compare.lua                                  (compares the two most recent distinct labels)
--
-- Labels default to short git SHAs (see bench.lua's BENCH_LOG emission); pass
-- LABEL=<name> when running a suite to tag runs with something memorable.
-- Matching rows across the two labels are joined by (suite, case_name, variant)
-- and the newest timestamp per (label, key) wins — so re-running a label
-- overwrites its prior entry for this comparison.

local function parseCsvLine(line)
    -- RFC 4180-ish: quoted fields may contain commas; "" inside a quoted field
    -- escapes a literal quote. Handles the format emitted by bench.suite.
    local fields = {}
    local i = 1
    local len = #line
    while i <= len do
        local c = line:sub(i, i)
        if c == '"' then
            local buf = {}
            i = i + 1
            while i <= len do
                local ch = line:sub(i, i)
                if ch == '"' then
                    if line:sub(i + 1, i + 1) == '"' then
                        buf[#buf + 1] = '"'
                        i = i + 2
                    else
                        i = i + 1
                        break
                    end
                else
                    buf[#buf + 1] = ch
                    i = i + 1
                end
            end
            fields[#fields + 1] = table.concat(buf)
            if line:sub(i, i) == "," then i = i + 1 end
        else
            local commaAt = line:find(",", i, true)
            if commaAt then
                fields[#fields + 1] = line:sub(i, commaAt - 1)
                i = commaAt + 1
            else
                fields[#fields + 1] = line:sub(i)
                i = len + 1
            end
        end
    end
    return fields
end

local function loadLog(path)
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("compare: could not open " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    local headerLine = f:read("*l")
    if not headerLine then
        io.stderr:write("compare: empty log at " .. path .. "\n")
        os.exit(1)
    end
    local header = parseCsvLine(headerLine)
    local colIdx = {}
    for i, name in ipairs(header) do colIdx[name] = i end

    local required = {"iso", "label", "suite", "case_name", "variant", "p50_us", "ci95_us", "min_us", "p99_us", "iterations"}
    for _, col in ipairs(required) do
        if not colIdx[col] then
            io.stderr:write("compare: log is missing required column '" .. col .. "'\n")
            os.exit(1)
        end
    end

    local rows = {}
    for line in f:lines() do
        if line ~= "" then
            local fields = parseCsvLine(line)
            local row = {
                iso = fields[colIdx.iso],
                label = fields[colIdx.label],
                sha = colIdx.sha and fields[colIdx.sha] or "",
                suite = fields[colIdx.suite],
                caseName = fields[colIdx.case_name],
                variant = fields[colIdx.variant],
                min = tonumber(fields[colIdx.min_us]) or 0,
                p50 = tonumber(fields[colIdx.p50_us]) or 0,
                p99 = tonumber(fields[colIdx.p99_us]) or 0,
                ci95 = tonumber(fields[colIdx.ci95_us]) or 0,
                iterations = tonumber(fields[colIdx.iterations]) or 0,
            }
            rows[#rows + 1] = row
        end
    end
    f:close()
    return rows
end

-- Collapse multiple entries for the same (label, suite, case, variant) down to
-- the newest by iso timestamp. Returns map[key] = row where key encodes
-- suite|case|variant. Runs of the same label are deduped so a re-run replaces
-- the earlier result instead of getting merged/averaged.
local function indexByLabel(rows, label)
    local index = {}
    for _, row in ipairs(rows) do
        if row.label == label then
            local key = row.suite .. "\0" .. row.caseName .. "\0" .. row.variant
            local prior = index[key]
            if not prior or row.iso > prior.iso then
                index[key] = row
            end
        end
    end
    return index
end

-- Walk the log newest-first, returning distinct labels in order of appearance.
local function distinctLabels(rows)
    local seen = {}
    local ordered = {}
    for i = #rows, 1, -1 do
        local label = rows[i].label
        if not seen[label] then
            seen[label] = true
            ordered[#ordered + 1] = label
        end
    end
    return ordered
end

local function formatTimeUs(us)
    if us < 1 then return string.format("%.3f", us)
    elseif us < 1000 then return string.format("%.1f", us)
    else return string.format("%.0f", us) end
end

local function padRight(s, w) return s .. string.rep(" ", math.max(0, w - #s)) end
local function padLeft(s, w) return string.rep(" ", math.max(0, w - #s)) .. s end

-- Argument handling.
local labelA = arg[1]
local labelB = arg[2]
local logPath = arg[3]

if not logPath or logPath == "" then
    local scriptDir = arg[0]:match("^(.*)/[^/]+$") or "."
    logPath = scriptDir .. "/../results/bench-log.csv"
end

local rows = loadLog(logPath)
if #rows == 0 then
    io.stderr:write("compare: no rows in " .. logPath .. "\n")
    os.exit(1)
end

local labels = distinctLabels(rows)
if #labels < 2 and (not labelA or not labelB) then
    io.stderr:write("compare: need at least two distinct labels in the log (found " .. #labels .. ")\n")
    os.exit(1)
end

-- Auto-fill missing labels: if neither given, take the two most recent. If
-- only A is given, pair it with the most recent label that differs from A.
if not labelA and not labelB then
    labelB = labels[1]
    labelA = labels[2]
elseif labelA and not labelB then
    for _, l in ipairs(labels) do
        if l ~= labelA then labelB = l; break end
    end
    if not labelB then
        io.stderr:write("compare: no other label to compare against '" .. labelA .. "'\n")
        os.exit(1)
    end
end

local indexA = indexByLabel(rows, labelA)
local indexB = indexByLabel(rows, labelB)
if next(indexA) == nil then
    io.stderr:write("compare: no rows for label '" .. labelA .. "'\n")
    os.exit(1)
end
if next(indexB) == nil then
    io.stderr:write("compare: no rows for label '" .. labelB .. "'\n")
    os.exit(1)
end

-- Build union of keys present in either side, preserving the case_idx order
-- they first appear in the log so output matches the source suite's layout.
local keyOrder = {}
local keySeen = {}
for _, row in ipairs(rows) do
    if row.label == labelA or row.label == labelB then
        local key = row.suite .. "\0" .. row.caseName .. "\0" .. row.variant
        if not keySeen[key] then
            keySeen[key] = true
            keyOrder[#keyOrder + 1] = {
                key = key, suite = row.suite, caseName = row.caseName, variant = row.variant,
            }
        end
    end
end

print(string.format("\nComparing A=%s  vs  B=%s   (log: %s)\n", labelA, labelB, logPath))

-- Build data rows first so we can size columns consistently.
local dataRows = {}
local currentSuite = nil
local improvements, regressions, significantImprovements, significantRegressions = 0, 0, 0, 0

for _, k in ipairs(keyOrder) do
    local a = indexA[k.key]
    local b = indexB[k.key]
    if a and b then
        if k.suite ~= currentSuite then
            dataRows[#dataRows + 1] = {sectionHeader = k.suite}
            currentSuite = k.suite
        end
        local delta = b.p50 - a.p50
        local pct = a.p50 > 0 and (delta / a.p50 * 100) or 0
        -- Significance test: treat the change as real when |Δ| exceeds the sum
        -- of both CI95 half-widths. Loose but cheap — proper answer would be a
        -- Mann-Whitney U or bootstrapped CI on the difference, which we don't
        -- have the raw samples for here.
        local significant = math.abs(delta) > (a.ci95 + b.ci95)
        if delta < 0 then
            improvements = improvements + 1
            if significant then significantImprovements = significantImprovements + 1 end
        elseif delta > 0 then
            regressions = regressions + 1
            if significant then significantRegressions = significantRegressions + 1 end
        end
        dataRows[#dataRows + 1] = {
            caseName = k.caseName,
            variant = k.variant,
            aStr = formatTimeUs(a.p50) .. " ±" .. formatTimeUs(a.ci95),
            bStr = formatTimeUs(b.p50) .. " ±" .. formatTimeUs(b.ci95),
            deltaStr = string.format("%+.1f%%", pct),
            marker = significant and (delta < 0 and "▼" or "▲") or " ",
        }
    elseif a and not b then
        dataRows[#dataRows + 1] = {
            caseName = k.caseName, variant = k.variant,
            aStr = formatTimeUs(a.p50), bStr = "—",
            deltaStr = "B missing", marker = " ",
        }
    else
        dataRows[#dataRows + 1] = {
            caseName = k.caseName, variant = k.variant,
            aStr = "—", bStr = formatTimeUs(b.p50),
            deltaStr = "A missing", marker = " ",
        }
    end
end

-- Column widths.
local wCase, wVariant, wA, wB, wDelta = #"case", #"variant", #("A: " .. labelA), #("B: " .. labelB), #"Δ p50"
for _, r in ipairs(dataRows) do
    if not r.sectionHeader then
        if #r.caseName > wCase then wCase = #r.caseName end
        if #r.variant > wVariant then wVariant = #r.variant end
        if #r.aStr > wA then wA = #r.aStr end
        if #r.bStr > wB then wB = #r.bStr end
        if #r.deltaStr > wDelta then wDelta = #r.deltaStr end
    end
end

local function printRow(case, variant, a, b, delta, marker)
    print(string.format("%s  %s  %s  %s  %s %s",
        padRight(case, wCase),
        padRight(variant, wVariant),
        padLeft(a, wA),
        padLeft(b, wB),
        padLeft(delta, wDelta),
        marker))
end

printRow("case", "variant", "A: " .. labelA, "B: " .. labelB, "Δ p50", " ")
printRow(string.rep("-", wCase), string.rep("-", wVariant), string.rep("-", wA), string.rep("-", wB), string.rep("-", wDelta), " ")

for _, r in ipairs(dataRows) do
    if r.sectionHeader then
        print("\n# " .. r.sectionHeader)
    else
        printRow(r.caseName, r.variant, r.aStr, r.bStr, r.deltaStr, r.marker)
    end
end

-- Geomean across matched cases: same formula the suite uses, giving one
-- headline number. Ratio = b.p50 / a.p50 per case, then geometric mean, so
-- >1.0 means B is slower overall.
local product, matched = 1.0, 0
for _, k in ipairs(keyOrder) do
    local a, b = indexA[k.key], indexB[k.key]
    if a and b and a.p50 > 0 and b.p50 > 0 then
        product = product * (b.p50 / a.p50)
        matched = matched + 1
    end
end
if matched > 0 then
    local geomean = product ^ (1.0 / matched)
    local verdict
    if geomean > 1.0 then verdict = string.format("%.2fx slower overall", geomean)
    elseif geomean < 1.0 then verdict = string.format("%.2fx faster overall", 1 / geomean)
    else verdict = "same overall" end
    print(string.format("\nGeomean B/A across %d matched rows: %.3f  (B is %s)",
        matched, geomean, verdict))
end

print(string.format("\n%d improvements (%d significant), %d regressions (%d significant)",
    improvements, significantImprovements, regressions, significantRegressions))
print("Markers: ▼ B faster than A (significant)   ▲ B slower than A (significant)")

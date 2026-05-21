#!/usr/bin/env lua
-- tools/parse_debuglog.lua — turn debug.log into a per-frame timeline.
--
-- Usage (from a terminal with Lua 5.1+ available):
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --hero=Sniper
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --grep=layer1_dispatch
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --since=120 --until=180
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --summary
--
-- Output: one event per line, formatted as a compact timeline. Events with
-- a `_t` or `t=` field are sorted by that timestamp; lines without are kept
-- in source order.
--
-- This is a READ-ONLY tool — no game-state mutation. Safe to run while
-- a match is in progress (file is read-locked briefly).

local function usage()
    io.stderr:write([[
parse_debuglog.lua <path-to-debug.log> [options]

Options:
  --hero=Name            Filter to one hero's events (default: all)
  --grep=substring       Filter to events whose name matches
  --since=N              Skip events before relative-time N seconds
  --until=N              Skip events after relative-time N seconds
  --summary              Print event-name → count summary instead of timeline
  --modseen              Print modseen_summary + first 50 unique modifiers
  --postmortem           Print death_postmortem lines + surrounding context
  --aggression-report    Parse cast_outcome → R-kill rate, damage-per-R, false-positive commits
  --defense-report       Parse save_outcome → survival rate per threat, HP nadir, save latency

]])
end

-- Brain log format from `tlog()`:
--   [LEVEL] [Hero] event_name | k=v k2=v2 k3=v3
-- LEVEL is one of [INFO] [WARN] [ERROR]. Hero is the brain name. Parse with
-- a permissive regex so future hero names just work.
local function parse_line(line)
    local level, hero, body = line:match("^%[(%w+)%]%s*%[([^%]]+)%]%s*(.+)$")
    if not level or not hero then return nil end
    local event, kvs = body:match("^(%S+)%s*|?%s*(.*)$")
    if not event then return nil end
    local kv = {}
    for k, v in kvs:gmatch("(%S+)=(%S+)") do
        kv[k] = v
    end
    return { level = level, hero = hero, event = event, kv = kv, raw = line }
end

-- ---- arg parsing ----
local path
local opt_hero, opt_grep, opt_since, opt_until = nil, nil, nil, nil
local mode = "timeline"  -- timeline | summary | modseen | postmortem
local mode_count = 0     -- v6.15.2 M7: warn on multiple mode flags
for i = 1, #arg do
    local a = arg[i]
    if not path and not a:match("^%-%-") then
        path = a
    elseif a:match("^%-%-hero=") then opt_hero = a:sub(8)
    elseif a:match("^%-%-grep=") then opt_grep = a:sub(8)
    elseif a:match("^%-%-since=") then opt_since = tonumber(a:sub(9))
    elseif a:match("^%-%-until=") then opt_until = tonumber(a:sub(9))
    elseif a == "--summary" then mode = "summary"; mode_count = mode_count + 1
    elseif a == "--modseen" then mode = "modseen"; mode_count = mode_count + 1
    elseif a == "--postmortem" then mode = "postmortem"; mode_count = mode_count + 1
    elseif a == "--aggression-report" then mode = "aggression_report"; mode_count = mode_count + 1
    elseif a == "--defense-report" then mode = "defense_report"; mode_count = mode_count + 1
    elseif a == "--help" or a == "-h" then usage(); os.exit(0)
    end
end
if not path then usage(); os.exit(1) end
if mode_count > 1 then
    io.stderr:write("warning: multiple mode flags passed; using --" .. mode .. "\n")
end

-- ---- read ----
local f = io.open(path, "r")
if not f then io.stderr:write("cannot open " .. path .. "\n"); os.exit(2) end

-- v6.15.2 H7: --since / --until previously dead options. Wire them in.
-- Events expose a relative timestamp via `t=` or `_t=` kv field set by tlog().
-- Filter inclusively: keep if (no since OR ts >= since) AND (no until OR ts <= until).
local events = {}
local summary_counts = {}
for line in f:lines() do
    local e = parse_line(line)
    if e then
        local ts = tonumber(e.kv.t or e.kv._t)
        local time_ok = (not opt_since or (ts and ts >= opt_since))
                    and (not opt_until or (ts and ts <= opt_until))
        if (not opt_hero or e.hero == opt_hero)
           and (not opt_grep or e.event:find(opt_grep, 1, true))
           and time_ok then
            events[#events + 1] = e
            summary_counts[e.event] = (summary_counts[e.event] or 0) + 1
        end
    end
end
f:close()

-- ---- render ----
if mode == "summary" then
    -- sort by count desc
    local pairs_arr = {}
    for k, v in pairs(summary_counts) do pairs_arr[#pairs_arr + 1] = { k, v } end
    table.sort(pairs_arr, function(a, b) return a[2] > b[2] end)
    print("event\tcount")
    for i = 1, #pairs_arr do
        print(pairs_arr[i][1] .. "\t" .. pairs_arr[i][2])
    end
    os.exit(0)
elseif mode == "modseen" then
    print("--- modseen_summary (unique modifier names observed) ---")
    local seen = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "modseen" or e.event == "modseen_entry" then
            local key = (e.kv.unit or "?") .. ":" .. (e.kv.mod or e.kv.key or "?")
            if not seen[key] then
                seen[key] = e.kv.caster or "-"
                print(key .. "\tcaster=" .. (e.kv.caster or "-"))
            end
        end
    end
    os.exit(0)
elseif mode == "postmortem" then
    print("--- death_postmortem entries ---")
    for i = 1, #events do
        local e = events[i]
        if e.event == "death_postmortem" then
            print(e.raw)
            -- context: previous 5 events
            for j = math.max(1, i - 5), i - 1 do
                print("  ctx -" .. (i - j) .. ": " .. events[j].raw)
            end
        end
    end
    os.exit(0)
elseif mode == "aggression_report" then
    -- v6.15.58 (G15): aggression report.
    -- v6.15.86 (CRITICAL fix — user feedback): the prior report counted
    -- cast_outcome events as "R casts" — that's WRONG. cast_outcome tracks
    -- target HP delta in a 5s window after `issued`, but doesn't verify
    -- R actually fired. In the v6.15.85 log, EVERY R cast_verify showed
    -- fired=n (engine cancelled R via native interference) — yet the
    -- report claimed 75% kill rate because the cast_outcome window caught
    -- damage from autos/Q that landed independently. Ground truth must be
    -- cast_verify fired=y. Now:
    --   1. First pass: build per-intent map of LATEST cast_verify fired status
    --   2. Second pass: cast_outcome only counts when verified fired=y
    --   3. Report shows BOTH verified count and raw count so the user can
    --      see the gap if cast cancellation is happening.
    print("--- aggression report ---")
    local last_verify = {}        -- intent → latest fired status ("y"/"n")
    local fire_count_per_intent = {}  -- intent → count of fired=y verifies
    local double_fail_per_intent = {} -- intent → count of double_fail events
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            local intent = e.kv.intent or "?"
            last_verify[intent] = e.kv.fired
            if e.kv.fired == "y" then
                fire_count_per_intent[intent] = (fire_count_per_intent[intent] or 0) + 1
            end
        elseif e.event == "cast_verify_double_fail" then
            local intent = e.kv.intent or "?"
            double_fail_per_intent[intent] = (double_fail_per_intent[intent] or 0) + 1
            last_verify[intent] = "n"  -- explicit fail
        end
    end
    local n_total, n_kill, n_alive, n_respawn = 0, 0, 0, 0
    local n_raw_outcome, n_bogus_outcome = 0, 0
    local sum_hp_delta_pct = 0
    local per_intent = {}        -- intent → {casts, kills}
    local per_target = {}        -- target → {casts, kills}
    local hp_delta_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    -- Track per-intent last verify dynamically as we iterate (events are
    -- in source order; cast_verify precedes cast_outcome for any one issue).
    local rolling_verify = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            rolling_verify[e.kv.intent or "?"] = e.kv.fired
        elseif e.event == "cast_verify_double_fail" then
            rolling_verify[e.kv.intent or "?"] = "n"
        elseif e.event == "cast_outcome" then
            n_raw_outcome = n_raw_outcome + 1
            local intent = e.kv.intent or "?"
            -- v6.15.86: REJECT if the most recent cast_verify for this
            -- intent shows R didn't actually fire. The cast_outcome HP
            -- delta is then attributable to autos/Q/headshot, not R.
            if rolling_verify[intent] ~= "y" then
                n_bogus_outcome = n_bogus_outcome + 1
                goto continue
            end
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local respawn = e.kv.respawn == "y"
            local target = e.kv.target or "?"
            local hp_dp = tonumber(e.kv.hp_delta_pct) or 0
            sum_hp_delta_pct = sum_hp_delta_pct + (hp_dp > 0 and hp_dp or 0)
            per_intent[intent] = per_intent[intent] or { casts = 0, kills = 0 }
            per_intent[intent].casts = per_intent[intent].casts + 1
            per_target[target] = per_target[target] or { casts = 0, kills = 0 }
            per_target[target].casts = per_target[target].casts + 1
            if respawn then
                n_respawn = n_respawn + 1
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            elseif not alive then
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            else
                n_alive = n_alive + 1
            end
            -- HP delta bucket
            local b = 0
            if hp_dp >= 100 then b = 100
            elseif hp_dp >= 75 then b = 75
            elseif hp_dp >= 50 then b = 50
            elseif hp_dp >= 25 then b = 25 end
            hp_delta_buckets[b] = hp_delta_buckets[b] + 1
            ::continue::
        end
    end
    -- v6.15.86: surface verified R fires and double-fails specifically for
    -- R steps (intent ending in "_r" — snipe_e_r_r, snipe_q_r_r, etc.).
    -- Counts Q/E/D fires don't help diagnose "did R actually go off".
    local verified_R = 0
    local double_fail_R = 0
    for intent, n in pairs(fire_count_per_intent) do
        if intent:sub(-2) == "_r" then verified_R = verified_R + n end
    end
    for intent, n in pairs(double_fail_per_intent) do
        if intent:sub(-2) == "_r" then double_fail_R = double_fail_R + n end
    end
    print(string.format("  cast_outcome events (raw):       %d", n_raw_outcome))
    print(string.format("  bogus outcomes (R never fired):  %d  ← cast_verify fired=n",
                        n_bogus_outcome))
    print(string.format("  verified R fires (fired=y on _r intents):  %d", verified_R))
    print(string.format("  R double-fails (engine cancelled cast):    %d", double_fail_R))
    if verified_R == 0 and n_raw_outcome > 0 then
        print("")
        print("  ** WARNING: R never actually fired in this session.")
        print("  ** All cast_outcome 'kills' are autos/Q/headshot — bogus attribution.")
        print("  ** Investigate cast_verify_double_fail events + r_cast_protect_veto.")
    end
    print("")
    if n_total == 0 then
        print("  (no verified R fires — see above warning)")
        os.exit(0)
    end
    local kill_rate = (n_kill / n_total) * 100
    local avg_dmg = sum_hp_delta_pct / n_total
    print(string.format("  verified R casts:   %d", n_total))
    print(string.format("  kills:              %d (%.1f%%)", n_kill, kill_rate))
    print(string.format("  alive after (FP):   %d", n_alive))
    print(string.format("  respawn-attributed: %d", n_respawn))
    print(string.format("  avg damage per R:   %.1f%% of target max HP", avg_dmg))
    print("")
    print("  hp_delta_pct distribution:")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24%" end
        print(string.format("    %-9s %d", label, hp_delta_buckets[b] or 0))
    end
    print("")
    print("  per-intent kill rates:")
    local intent_keys = {}
    for k in pairs(per_intent) do intent_keys[#intent_keys + 1] = k end
    table.sort(intent_keys)
    for _, k in ipairs(intent_keys) do
        local v = per_intent[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-30s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    print("")
    print("  per-target kill rates:")
    local target_keys = {}
    for k in pairs(per_target) do target_keys[#target_keys + 1] = k end
    table.sort(target_keys)
    for _, k in ipairs(target_keys) do
        local v = per_target[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-20s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    os.exit(0)
elseif mode == "defense_report" then
    -- v6.15.58 (G15): defense report. Parse save_outcome events into
    -- survival rate per threat, HP nadir distribution, save latency.
    print("--- defense report ---")
    local n_total, n_alive, n_no_save = 0, 0, 0
    local per_threat = {}        -- threat → {events, alive, no_save, sum_hp_pct_min, sum_latency}
    local per_save = {}          -- save → count
    local latency_buckets = { [0]=0, [100]=0, [250]=0, [500]=0, [1000]=0 }
    local hp_nadir_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    for i = 1, #events do
        local e = events[i]
        if e.event == "save_outcome" then
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local save_fired = e.kv.save and e.kv.save ~= "-"
            local threat = e.kv.threat or "?"
            local lat = tonumber(e.kv.latency_ms) or -1
            local hp_pct = tonumber(e.kv.hp_pct_min) or 100
            if alive then n_alive = n_alive + 1 end
            if not save_fired then n_no_save = n_no_save + 1 end
            per_threat[threat] = per_threat[threat] or {
                events = 0, alive = 0, no_save = 0,
                sum_hp_pct_min = 0, sum_latency = 0, lat_count = 0,
            }
            local t = per_threat[threat]
            t.events = t.events + 1
            if alive then t.alive = t.alive + 1 end
            if not save_fired then t.no_save = t.no_save + 1 end
            t.sum_hp_pct_min = t.sum_hp_pct_min + hp_pct
            if lat >= 0 then
                t.sum_latency = t.sum_latency + lat
                t.lat_count = t.lat_count + 1
            end
            if save_fired then
                per_save[e.kv.save] = (per_save[e.kv.save] or 0) + 1
            end
            -- Latency bucket (only if save fired)
            if lat >= 0 then
                local b = 0
                if lat >= 1000 then b = 1000
                elseif lat >= 500 then b = 500
                elseif lat >= 250 then b = 250
                elseif lat >= 100 then b = 100 end
                latency_buckets[b] = latency_buckets[b] + 1
            end
            -- HP nadir bucket
            local hb = 0
            if hp_pct >= 100 then hb = 100
            elseif hp_pct >= 75 then hb = 75
            elseif hp_pct >= 50 then hb = 50
            elseif hp_pct >= 25 then hb = 25 end
            hp_nadir_buckets[hb] = hp_nadir_buckets[hb] + 1
        end
    end
    if n_total == 0 then
        print("  (no save_outcome events found)")
        os.exit(0)
    end
    local survive = (n_alive / n_total) * 100
    print(string.format("  total threats:      %d", n_total))
    print(string.format("  survived:           %d (%.1f%%)", n_alive, survive))
    print(string.format("  no save fired:      %d", n_no_save))
    print("")
    print("  per-threat outcomes:")
    local threat_keys = {}
    for k in pairs(per_threat) do threat_keys[#threat_keys + 1] = k end
    table.sort(threat_keys)
    for _, k in ipairs(threat_keys) do
        local t = per_threat[k]
        local s = t.events > 0 and (t.alive / t.events * 100) or 0
        local avg_hp = t.events > 0 and (t.sum_hp_pct_min / t.events) or 100
        local avg_lat = t.lat_count > 0 and (t.sum_latency / t.lat_count) or -1
        print(string.format(
            "    %-50s %d events, %d alive (%.0f%%), %d no-save, avg hp_min %.0f%%, avg lat %d ms",
            k, t.events, t.alive, s, t.no_save, avg_hp, avg_lat))
    end
    print("")
    print("  per-save usage:")
    local save_keys = {}
    for k in pairs(per_save) do save_keys[#save_keys + 1] = k end
    table.sort(save_keys)
    for _, k in ipairs(save_keys) do
        print(string.format("    %-25s %d", k, per_save[k]))
    end
    print("")
    print("  save latency distribution (ms, only fired saves):")
    local lat_labels = {
        [0]    = "0-99ms",
        [100]  = "100-249ms",
        [250]  = "250-499ms",
        [500]  = "500-999ms",
        [1000] = ">=1000ms",
    }
    for _, b in ipairs({0, 100, 250, 500, 1000}) do
        print(string.format("    %-12s %d", lat_labels[b], latency_buckets[b] or 0))
    end
    print("")
    print("  HP nadir distribution (% of max HP at lowest point during threat):")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24% (NEAR DEATH)" end
        print(string.format("    %-22s %d", label, hp_nadir_buckets[b] or 0))
    end
    os.exit(0)
else
    -- timeline mode. v6.15.2 low: sort kv keys deterministically per-line
    -- so diff-tooling output is stable between runs.
    for i = 1, #events do
        local e = events[i]
        local s_t = e.kv.t or e.kv._t or "-"
        local keys = {}
        for k in pairs(e.kv) do
            if k ~= "t" and k ~= "_t" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        local parts = {}
        for j = 1, #keys do
            parts[#parts + 1] = keys[j] .. "=" .. tostring(e.kv[keys[j]])
        end
        print(string.format("[%s] %s.%-25s %s", s_t, e.hero, e.event,
            table.concat(parts, " ")))
    end
end

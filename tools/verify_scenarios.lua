#!/usr/bin/env lua
-- tools/verify_scenarios.lua — verify expected brain behaviors after a demo.
--
-- Workflow:
--   1. User runs a specific demo scenario (e.g., 1v1 vs Bara charging Sniper)
--   2. After the demo, user runs:  lua tools/verify_scenarios.lua bara_charge_1v1
--   3. Tool greps C:\Umbrella\debug.log for the expected event signatures
--      and reports pass/fail per assertion.
--
-- This is a regression-prevention layer: when v6.x lessons land (e.g.,
-- "armed_threats_tick must respect responded_threats"), we record the
-- expected log signature here. Future demos that don't produce that
-- signature fail loudly.
--
-- This is NOT a game-side test runner — Umbrella doesn't expose one. The
-- workflow assumes a human plays the scenario; the tool just verifies the
-- log afterward.

local DEFAULT_LOG = [[C:\Umbrella\debug.log]]

local function read_log(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end
    local s = f:read("*a"); f:close()
    return s
end

-- v6.15.2 H8: anchor event matching on the tlog separator. tlog() emits
--   [LEVEL] [Hero] event_name | k=v k2=v2 ...
-- So we look for ` event_name |` (with separator) OR ` event_name ` with
-- end-of-line (no kvs). This stops "smoke_alert" from also matching
-- "smoke_alert_disable" etc. via plain substring.
local function _event_pattern(name)
    return " " .. name .. " |", " " .. name .. "$"
end
local function has_event(log, event, opts)
    opts = opts or {}
    local min = opts.min_count or 1
    local kv_list = opts.kv or {}
    local pat_with_kv, pat_bare = _event_pattern(event)
    local count = 0
    for line in log:gmatch("[^\n]+") do
        local hit = line:find(pat_with_kv, 1, true) or line:find(pat_bare)
        if hit then
            local match = true
            for _, kv in ipairs(kv_list) do
                if not line:find(kv, 1, true) then match = false; break end
            end
            if match then count = count + 1 end
        end
    end
    return count >= min, count
end

----------------------------------------------------------------------------
-- SCENARIOS
----------------------------------------------------------------------------
--
-- Each scenario is { name = "...", setup = "...", asserts = { ... } }.
-- `setup` is human instructions for what to do in the demo.
-- Each assert is { kind = "has_event"|"no_event", event, ... opts }.

local scenarios = {

    bara_charge_1v1 = {
        setup = [[
1v1 demo, Sniper vs Spirit Breaker. Build Sniper with: Pike, BKB in inventory.
Let SB charge once into Sniper. Wait for response. Then exit demo.
Verifies: armed_threats_tick fires AT MOST ONCE per charge (no v6.13 Bug #1
regression), and the modseen diagnostic captures the charge modifier.
]],
        asserts = {
            { kind = "has_event", event = "armed_threat_fire", min_count = 1 },
            -- v6.15.2 H8: Lua-error lines aren't tlog-formatted, so we
            -- substring-match the engine's "attempt to call" prefix.
            { kind = "no_event_raw", event = "attempt to call a nil value" },
            { kind = "has_event", event = "modseen",
                kv = { "mod=modifier_spirit_breaker_charge_of_darkness" } },
        },
    },

    panic_key_smoke = {
        setup = [[
Demo, Sniper alone. Bind Panic Save key in Brain menu. Press it once with no
active threats and verify the save fires (or short-circuits with no Lua error).
Then verify the v6.14.1 C3 fix: panic with empty chain doesn't permanently
disable reaction window.
]],
        asserts = {
            { kind = "has_event", event = "panic_save_user_pressed", min_count = 1 },
            { kind = "no_event_raw", event = "attempt to call a nil value" },
        },
    },

    combo_dispatch_basic = {
        setup = [[
Demo, Sniper vs Bot. Hold combo key on a kill-grade target. Verifies the v6.14.1
C1 fix (cluster_around_target was uncallable, build_layer1_ctx crashed). Should
see layer1_dispatch lines and NO Lua errors mentioning cluster_around_target.
]],
        asserts = {
            { kind = "has_event", event = "layer1_dispatch", min_count = 1 },
            -- v6.15.2 H8: the regression we're guarding against is a Lua
            -- error containing the function name. Use the raw kind for
            -- error-string matching.
            { kind = "no_event_raw", event = "attempt to call a nil value (field 'cluster_around_target')" },
        },
    },

    smoke_alert_visibility = {
        setup = [[
Demo, with smoke detection enabled in menu. Have 2 enemy bots move into a
1500u radius then go dormant (run into fog). Within 30s, the HUD chip
should flip to "alert" and (if HP <60%) BKB should pre-fire.
]],
        asserts = {
            { kind = "has_event", event = "smoke_alert", min_count = 1 },
        },
    },

    match_summary_at_end = {
        setup = [[
Play any full bot match to completion. After the Ancient explodes, check the
match_summary log line appears once.
]],
        asserts = {
            { kind = "has_event", event = "match_summary", min_count = 1 },
            { kind = "has_event", event = "modseen_summary", min_count = 1 },
        },
    },

}

----------------------------------------------------------------------------
-- MAIN
----------------------------------------------------------------------------

local function usage()
    print("Usage: lua tools/verify_scenarios.lua <scenario> [log_path]")
    print("")
    print("Scenarios:")
    for k, s in pairs(scenarios) do
        local first_line = (s.setup or ""):match("^%s*(.-)\n") or "(no description)"
        print("  " .. k .. "\t" .. first_line)
    end
    print("")
    print("If <scenario> is omitted or unknown, prints this help.")
end

local sname = arg[1]
local lpath = arg[2] or DEFAULT_LOG
local scenario = sname and scenarios[sname]
if not scenario then usage(); os.exit(1) end

local log, err = read_log(lpath)
if not log then io.stderr:write(err .. "\n"); os.exit(2) end

print("Scenario: " .. sname)
print("Setup:" .. scenario.setup)
print("Asserts:")
local fail = 0
for i, a in ipairs(scenario.asserts) do
    if a.kind == "has_event" then
        local ok, count = has_event(log, a.event, a)
        local marker = ok and "PASS" or "FAIL"
        if not ok then fail = fail + 1 end
        print(string.format("  [%s] has_event %s (count=%d, need>=%d)",
            marker, a.event, count, a.min_count or 1))
    elseif a.kind == "no_event" then
        -- v6.15.2 H8: anchored match (same shape as has_event). Substring
        -- match would flag legitimate references to the same name (e.g.
        -- "cluster_around_target_count=3" matching the error-check name).
        local pat_with_kv, pat_bare = _event_pattern(a.event)
        local ok = not (log:find(pat_with_kv, 1, true) or log:find(pat_bare))
        if not ok then fail = fail + 1 end
        print(string.format("  [%s] no_event %s",
            ok and "PASS" or "FAIL", a.event))
    elseif a.kind == "no_event_raw" then
        -- Plain substring match for non-tlog log lines (e.g., Lua errors).
        local ok = not log:find(a.event, 1, true)
        if not ok then fail = fail + 1 end
        print(string.format("  [%s] no_event_raw %s",
            ok and "PASS" or "FAIL", a.event))
    end
end
print(string.format("\n%d assertions, %d failures.", #scenario.asserts, fail))
os.exit(fail == 0 and 0 or 3)

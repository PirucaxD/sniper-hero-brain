#!/usr/bin/env lua
-- tools/run_tests.lua — pure-Lua test runner for hero-brain lib helpers.
--
-- Runs unit tests on the lib/ modules that are pure (no game state):
--   - lib/threat_data.lua's SaveCounters / SeverityOf / CategoryOf / etc.
--   - lib/target.lua's NotClone (with stub NPC)
--   - lib/timing.lua's EscapeReadiness (with stub APIs)
--
-- Game-side APIs are stubbed at the top so the libs load without errors.
-- Run with:  lua tools/run_tests.lua

----------------------------------------------------------------------------
-- API STUBS (so the libs can be required without a running game)
----------------------------------------------------------------------------

-- Most lib code reads game globals (Entity, NPC, Ability, etc.). For pure
-- helpers we provide no-op stubs; for predicate-helpers we provide minimal
-- behavior. Tests that need real game state are not runnable here.

NPC = NPC or {}
NPC.IsIllusion       = function() return false end
NPC.IsMeepoClone     = function() return false end
NPC.HasModifier      = function() return false end
NPC.HasState         = function() return false end
NPC.GetItem          = function() return nil end
NPC.GetMana          = function() return 100 end
NPC.GetStatesDuration= function() return 0 end
NPC.IsRunning        = function() return false end
NPC.IsAttacking      = function() return false end
NPC.GetAttackRange   = function() return 550 end
NPC.FindRotationAngle= function() return 0 end

Entity = Entity or {}
Entity.IsNPC         = function() return true end
Entity.IsAlive       = function() return true end
Entity.IsSameTeam    = function(a, b) return false end
Entity.GetIndex      = function(e) return e and e.idx or 0 end
Entity.GetAbsOrigin  = function(e) return e and e.pos or { x = 0, y = 0, z = 0 } end
Entity.GetHealth     = function() return 1000 end
Entity.GetMaxHealth  = function() return 1000 end

Ability = Ability or {}
Ability.IsReady      = function() return false end
Ability.GetCooldown  = function() return 999 end
Ability.GetManaCost  = function() return 0 end
Ability.GetLevel     = function() return 0 end

Hero = Hero or {}
Hero.GetLastVisibleTime = function() return nil end

GlobalVars = GlobalVars or {}
GlobalVars.GetCurTime = function() return 0 end

Enum = Enum or {}
Enum.ModifierState = setmetatable({}, { __index = function(_, k) return k end })

-- Patch package.path so requires from lib/ resolve.
package.path = "./?.lua;./?/init.lua;" .. package.path

----------------------------------------------------------------------------
-- TEST FRAMEWORK
----------------------------------------------------------------------------

local pass, fail = 0, 0
local fails = {}
local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("  pass  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name); fails[#fails + 1] = { name = name, err = err }
    end
end
local function describe(group, fn)
    print("[" .. group .. "]")
    fn()
end
local function assert_eq(a, b, msg)
    if a ~= b then error((msg or "expected eq") .. ": got " .. tostring(a)
        .. ", want " .. tostring(b), 2) end
end
local function assert_true(v, msg) if not v then error(msg or "expected true", 2) end end
local function assert_false(v, msg) if v then error(msg or "expected false", 2) end end

----------------------------------------------------------------------------
-- TESTS
----------------------------------------------------------------------------

local TD = require("lib.threat_data")

describe("lib/threat_data — SAVE_KIND data integrity", function()
    it("SAVE_KIND populated", function()
        local n = 0
        for _ in pairs(TD.SAVE_KIND) do n = n + 1 end
        assert_true(n > 10, "fewer than 10 SAVE_KIND entries")
    end)
    it("ESCAPE_ITEM_NAMES derived at load", function()
        assert_true(type(TD.ESCAPE_ITEM_NAMES) == "table", "ESCAPE_ITEM_NAMES not table")
        assert_true(#TD.ESCAPE_ITEM_NAMES > 0, "empty escape list")
    end)
    it("ESCAPE_ITEM_NAMES includes BKB", function()
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_black_king_bar" then found = true; break end
        end
        assert_true(found, "BKB missing from ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES excludes non-item saves", function()
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            local s = TD.ESCAPE_ITEM_NAMES[i]
            assert_true(s:sub(1, 5) == "item_", "non-item in escape list: " .. s)
        end
    end)
end)

describe("lib/threat_data — SaveCounters", function()
    it("BKB counters Bane Nightmare (magic_immune)", function()
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_bane_nightmare"))
    end)
    it("Force Staff does NOT counter Doom (no displacement_perp on Doom)", function()
        -- modifier_doom_bringer_doom has counter {invuln, magic_immune, reflect_target}
        assert_false(TD.SaveCounters("item_force_staff", "modifier_doom_bringer_doom"))
    end)
    it("Pike DOES counter Pudge hook (displacement_perp)", function()
        assert_true(TD.SaveCounters("item_hurricane_pike", "modifier_pudge_meat_hook"))
    end)
    it("Cyclone does NOT counter Pudge hook in-flight (v6.14.1 M3 fix)", function()
        -- modifier_pudge_meat_hook should NOT have `invuln` in THREAT_COUNTER.
        assert_false(TD.SaveCounters("item_cyclone", "modifier_pudge_meat_hook"))
    end)
end)

describe("lib/threat_data — SeverityOf / CategoryOf", function()
    it("SeverityOf returns low/medium/high for known threats", function()
        local sev = TD.SeverityOf("modifier_bane_nightmare")
        assert_true(sev == "low" or sev == "medium" or sev == "high",
            "got severity=" .. tostring(sev))
    end)
    it("Axe Call severity is medium post-v6.14.1 M4", function()
        assert_eq(TD.SeverityOf("modifier_axe_berserkers_call"), "medium")
    end)
end)

describe("lib/threat_data — ENEMY_BUFF_THREATS", function()
    it("contains expected entries", function()
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_sven_gods_strength"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_ursa_enrage"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_troll_warlord_battle_trance"] ~= nil)
    end)
end)

local Target = require("lib.target")

describe("lib/target — pure predicates", function()
    it("NotClone is true for nil-safe", function() assert_false(Target.NotClone(nil)) end)
    -- More target.lua tests need richer NPC stubs (per-entity behavior) — defer.
end)

local Timing = require("lib.timing")

describe("lib/timing — EscapeReadiness", function()
    it("returns 0 for entity without items", function()
        local r = Timing.EscapeReadiness({ idx = 1 }, 2.0)
        assert_eq(r, 0)
    end)
end)

----------------------------------------------------------------------------
-- REPORT
----------------------------------------------------------------------------

print()
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
    print()
    for i = 1, #fails do
        print("FAIL: " .. fails[i].name)
        print("  " .. tostring(fails[i].err))
    end
    os.exit(1)
end
os.exit(0)

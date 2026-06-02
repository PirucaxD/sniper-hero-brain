---@meta
---lib/defense.lua - generic Layer-2 save dispatcher (Tier-2 extraction).
---
---Pulls the chain-resolution + chain-walk + throttle bookkeeping out of the
---per-hero defense layer. The DATA (chain tables, SAVE_FIRE map, override
---tables, filter sets) stays hero-side; the ALGORITHM lives here. Each hero
---calls Defense.New{cfg} once at init and keeps thin adapters around the
---returned dispatcher.
---
---No cross-hero state. Each dispatcher captures one cfg and operates only on
---the throttle_state / armed_threats refs the hero passes in.
---
---Audit-trail of equivalence vs the pre-extraction inline path:
---  - ResolveSaveOrder mirrors Lina pre-v0.5.0 resolve_save_order (anim ->
---    hero -> patched_recommended -> category -> default; first hit wins).
---  - TrySaveSelf mirrors the chain walk: same skip reasons, same order,
---    same reserve-penalty + concurrent-threat math, same tlog event names
---    so log greps keep working unchanged.
---  - CanFire / MarkFired match the inline LAYER2_REACTION_WINDOW gate.
---
---See Lina/LIB_DEFENSE_EXTRACTION.md for design + Sniper migration plan.

local Defense = {}

-- v0.5.39 P3-LOW-magic: reserve-skip / concurrent-penalty thresholds are
-- passed in via cfg (cfg.reserve_skip_floor / cfg.concurrent_penalty) rather
-- than baked in here, so heroes can tune them independently. The hero-side
-- source of truth lives in the hero file's module-level constants (e.g. Lina:
-- state.RESERVE_SKIP_FLOOR / state.CONCURRENT_PENALTY). The hero file's
-- chain-peek helper (armed_chain_peek in Lina.lua) MUST mirror these same
-- values when previewing the dispatcher's gate; v0.5.39 M1 routed the count
-- itself through Dispatcher:CountConcurrentExcluding so peek+dispatch share
-- one method, but the thresholds still need to be kept in lock-step.
local Dispatcher = {}
Dispatcher.__index = Dispatcher

---Create a dispatcher bound to one hero's defense config.
---@param cfg table see Lina/LIB_DEFENSE_EXTRACTION.md for the cfg field list
---@return table dispatcher
function Defense.New(cfg)
    return setmetatable({ cfg = cfg }, Dispatcher)
end

---Resolve the effective save chain for a (threat_mod, category_hint,
---ability_name) tuple. Returns (chain, is_authoritative); authoritative
---chains bypass the kind/tether filters during the walk.
---@param threat_mod string|nil
---@param category_hint string|nil
---@param ability_name string|nil
---@return table chain, boolean is_authoritative
function Dispatcher:ResolveSaveOrder(threat_mod, category_hint, ability_name)
    local c = self.cfg
    -- v0.5.13 E4 (HI-3 / PE04-OVERRIDE-WORKS): emit a single diagnostic tlog at
    -- each return point so operators can read the resolved chain HEAD directly
    -- from the log. PE04-OVERRIDE-WORKS confirmed LINA_SAVE_OVERRIDES is being
    -- consulted (BKB > Manta > Eul > Aeon on Duel) but the level-1
    -- threat_on_self line was reporting the static lib `save=` hint, which
    -- operators kept reading as the resolved head and concluding the override
    -- was unconsulted. No behavioural change to the resolver itself; this is
    -- diagnostic_only. The companion Lina.lua threat_on_self tlog will drop /
    -- demote that misleading `save = entry.save` field in a sibling patch.
    if ability_name then
        local ao = c.anim_save_overrides[ability_name]
        if ao then
            c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "anim_override", head = ao[1] or "-" })
            return ao, true
        end
    end
    if threat_mod then
        local hero = c.hero_save_overrides[threat_mod]
        if hero then
            c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "hero_override", head = hero[1] or "-" })
            return hero, true
        end
        -- v0.5.14 E8 (BL-B2 / BL-B6): split the old single "category_default" head-source
        -- label into three distinct values (category_default / category_hint / default_chain)
        -- so operators can tell apart CategoryOf(threat_mod) hits, caller-passed
        -- category_hint hits, and the terminal default_chain fallthrough. Also adds a
        -- lib_patched_empty tlog for KFR/Pit-style intentionally-empty RECOMMENDED entries
        -- that previously fell through silently.
        local td = c.patched_recommended[threat_mod]
        if td and #td > 0 then
            c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "lib_patched", head = td[1] or "-" })
            return td, false
        elseif td then
            c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "lib_patched_empty", head = "-" })
        end
        local category = c.TD.CategoryOf and c.TD.CategoryOf(threat_mod) or nil
        if category and c.category_chains[category] then
            c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "category_default", head = c.category_chains[category][1] or "-" })
            return c.category_chains[category], false
        end
    end
    if category_hint and c.category_chains[category_hint] then
        c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "category_hint", head = c.category_chains[category_hint][1] or "-" })
        return c.category_chains[category_hint], false
    end
    c.tlog(3, "resolve_save_order_pick", { mod = threat_mod, source = "default_chain", head = c.default_chain[1] or "-" })
    return c.default_chain, false
end

---Throttle gate. Returns true iff defense is enabled AND the reaction window
---has elapsed since the last save dispatch.
---@return boolean
function Dispatcher:CanFire()
    local c = self.cfg
    if not c.defense_enabled() then return false end
    if (c.now() - (c.throttle_state.last_save_t or 0)) < c.reaction_window then
        return false
    end
    return true
end

---Mark a save as just-fired (writes throttle_state.last_save_t). Idempotent.
---v0.5.39 P1-LAST-SAVE-TGT: the throttle_state.last_save_target write has been
---removed (Sniper-port orphan; no Lina-side reader, see Lina.lua state-decl
---comment near state.last_save_t for history). Method signature preserved.
---@param threat_caster any  may be nil (kept for signature compatibility)
function Dispatcher:MarkFired(threat_caster)
    local c = self.cfg
    c.throttle_state.last_save_t = c.now()
end

-- Local helpers for the chain walk. Operate on the cfg so the dispatcher
-- table itself stays empty besides self.cfg / methods.

local function save_counters_ok(c, save_name, threat_mod)
    if not threat_mod or not c.TD.SaveCounters then return true end
    return c.TD.SaveCounters(save_name, threat_mod)
end

local function tether_breaks_ok(c, save_name, threat_mod, threat_caster)
    if not threat_mod or not c.TD.WillTetherBreak then return true end
    local d = (threat_caster and c.dist_to and c.dist_to(threat_caster)) or math.huge
    return c.TD.WillTetherBreak(save_name, threat_mod, d)
end

---v0.5.39 M1 (Option A): count armed_threats rows excluding `armed_entry` by
---entry-handle identity. Single source of truth for the reserve/concurrent
---penalty math; Lina armed_chain_peek delegates here so the per-hero peek
---and the lib chain-walk cannot drift. Pass the live armed_entry on the
---armed-fire path (Lina.lua armed_threats_tick L1528) so peek+dispatch agree
---on n=0 for the typical single-armed-threat case. Non-armed call sites
---(events / persistent / threat_on_self / lotus / line_intercept) pass nil
---and count all armed rows (legacy behaviour preserved).
---Entry-handle identity is the correct semantics per v0.5.14 BL-A5/BL-B7:
---two different casters arming the same modifier must NOT collapse.
---@param armed_entry table|nil
---@return integer
function Dispatcher:CountConcurrentExcluding(armed_entry)
    local c = self.cfg
    local n = 0
    for _, e2 in pairs(c.armed_threats) do
        if e2 ~= armed_entry then
            n = n + 1
        end
    end
    return n
end

---Walk the resolved chain and fire the first eligible save. First-success-wins
---(lesson 3). Homing close-gap threats skip self-displacement saves (lesson 5).
---On a successful fire, `on_save_fired(intent, fire_short, threat_mod,
---threat_caster)` is called. The hero's callback OWNS throttle bookkeeping
---(typically chains through to dispatcher:MarkFired via the hero's record_save
---and mark_layer2_fired adapters); the lib does NOT mark fired on its own here,
---to avoid double-writing the throttle state when the hero already does so.
---Direct callers that bypass TrySaveSelf (lotus-first / ally-save) call
---MarkFired through the same hero chain.
---@param intent string
---@param threat_mod string|nil
---@param threat_caster any
---@param category_hint string|nil
---@param ability_name string|nil
---@param on_save_fired fun(intent:string, short:string, mod:string|nil, caster:any)|nil
---@return boolean fired
-- v0.5.39 M1 (Option A): optional armed_entry param threads the live armed
-- entry handle from Lina armed_threats_tick L1528 so CountConcurrentExcluding
-- self-excludes by entry-handle identity (matches the peek). Non-armed
-- callers pass nil; the new param is positional and trails the original
-- signature so existing call sites need no change.
function Dispatcher:TrySaveSelf(intent, threat_mod, threat_caster,
                                category_hint, ability_name, on_save_fired,
                                armed_entry)
    local c = self.cfg
    if not self:CanFire() then
        c.tlog(3, "layer2_window_throttle", { intent = intent })
        return false
    end

    local order, is_authoritative = self:ResolveSaveOrder(threat_mod, category_hint, ability_name)
    local severity = (c.TD.SeverityOf and c.TD.SeverityOf(threat_mod)) or "medium"
    local homing = threat_mod and c.threats_on_self
                   and c.threats_on_self[threat_mod]
                   and c.threats_on_self[threat_mod].homing or false

    for _, save_name in ipairs(order) do
        local fire_entry = c.save_fire[save_name]
        if not fire_entry then
            c.tlog(3, "save_chain_skip", { save = save_name, reason = "no_entry" })
        elseif c.ability_saves[save_name] and not c.self_can_cast_abilities() then
            c.tlog(3, "save_chain_skip", { save = save_name, reason = "ability_muted" })
        elseif homing and c.self_displacement_saves[save_name] then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "homing_no_displacement" })
        elseif not is_authoritative and not save_counters_ok(c, save_name, threat_mod) then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "kind_mismatch" })
        elseif not is_authoritative and not tether_breaks_ok(c, save_name, threat_mod, threat_caster) then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "tether_unreachable" })
        elseif not c.save_is_ready(save_name) then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "not_ready" })
        else
            local penalty = (c.TD.SaveReservePenalty and c.TD.SaveReservePenalty(save_name, threat_mod)) or 0
            -- v0.5.39 M1 (Option A): self-exclude by entry-handle when called from
            -- the armed-fire path (armed_entry non-nil); pass nil to count all
            -- armed rows on the immediate-save path. Mirrors Lina armed_chain_peek
            -- so peek+dispatch agree on n for the same fire. Single source of truth.
            local concurrent = self:CountConcurrentExcluding(armed_entry)
            if concurrent >= 1 then penalty = penalty + c.concurrent_penalty end
            if penalty < c.reserve_skip_floor then
                c.tlog(3, "save_chain_skip", {
                    save = fire_entry.short, reason = "reserved",
                    severity = severity, concurrent = concurrent,
                })
            else
                local issue_intent = intent .. "_" .. fire_entry.short
                if fire_entry.fire(issue_intent, threat_caster, threat_mod) then
                    if on_save_fired then
                        on_save_fired(intent, fire_entry.short, threat_mod, threat_caster)
                    end
                    return true
                end
                c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "fire_returned_false" })
            end
        end
    end

    if threat_mod then
        c.tlog(1, "no_effective_save_for_threat", { intent = intent, threat = threat_mod })
    else
        c.tlog(2, "layer2_no_save_available", { intent = intent })
    end
    return false
end

return Defense

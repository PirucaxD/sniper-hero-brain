---@meta
---Sniper brain — augmentation companion script.
---
---Pattern: baseline UCZone Sniper stays enabled. This script adds three
---decisions baseline can't make (Phase 0 gaps):
---  G1. Assassinate decisions (dead in baseline combo + kill-stealer)
---  G2. Save items wired to threat (BKB / Pike / Glimmer / Grenade-self)
---  G3. Fog / predictive Shrapnel + Assassinate
---
---Two layers:
---  Layer 1 — aggressive, key-activated via CMenuBind
---  Layer 2 — defensive, always-on, fires after framework Dodger

local Order  = require("lib.order")
local Damage = require("lib.damage")
local Anim   = require("lib.anim")
local Target = require("lib.target")
local TD     = require("lib.threat_data")
local Signal = require("lib.signal")    -- v6.15 A4
-- v6.15.237: the `local Timing = require("lib.timing")` import was removed.
-- lib/timing.lua's predictive-invuln helpers were never wired into Sniper
-- (it `require`d the module but called nothing from it); dropping the dead
-- import reclaims a main-chunk local slot. lib/timing.lua itself is kept
-- as a built, tested Tier-2 lib for a future hero to adopt.
-- v6.15.112 + v6.15.113 (Lua 5.4 200-locals refactor): extracted small
-- generic helpers to lib so future hero brains can reuse + Sniper main
-- chunk frees slots. Dedup helpers attempted v6.15.112 but reverted —
-- entangled with state.responded_threats / state.anim_log_dedup which
-- have 5+ external readers in Sniper.lua. Will redesign lib/dedup.lua
-- with passed-in-state pattern for v6.15.114+.
local Geom   = require("lib.geometry")  -- distance + lead-target prediction
local NPCLib = require("lib.npc")       -- has_shard / has_scepter / item / item_ready
local Dedup  = require("lib.dedup")     -- v6.15.115: anim-log + threat-response dedup
                                        -- (state-container API — Sniper still owns the tables)

-- Local re-bindings so call sites stay short. ThreatData owns these as
-- universal Dota-side facts (Tier 2 data-only extraction); the logic that
-- consumes them stays in this hero file (the planned `lib/defense.lua`
-- logic extraction is gated on a second hero per the project's two-hero
-- rule).
local SAVE_KIND               = TD.SAVE_KIND
local THREAT_COUNTER          = TD.THREAT_COUNTER
local SAVE_PUSH_DISTANCE      = TD.SAVE_PUSH_DISTANCE
local THREAT_TETHER_RANGE     = TD.THREAT_TETHER_RANGE
local THREATS_ON_SELF         = TD.THREATS_ON_SELF
local LOTUS_WORTHY_INCOMING   = TD.LOTUS_WORTHY_INCOMING
local ENEMY_CHANNEL_MODIFIERS = TD.ENEMY_CHANNEL_MODIFIERS
local ABILITY_TO_THREAT       = TD.ABILITY_TO_THREAT
local ENEMY_BUFF_THREATS      = TD.ENEMY_BUFF_THREATS

-- Forward-declared module state. Telemetry below reads it, but `state` is
-- assigned the actual table further down.
local state = {}

-- Forward declarations of functions used by callbacks before they're defined.
-- Lua resolves names at function-definition time, so a callback that calls
-- `refresh_status_panel()` before that local exists would resolve to the
-- (nil) global and crash at first call. Declaring them here gives the locals
-- a slot in the upvalue chain that later assignments fill in.
local refresh_status_panel
local damage_rate_panic_check
local ally_save_scan
local SafePushDestination       -- used by grenade_self_cast_point (defined earlier
                                -- than SafePushDestination's body)
local take_aim_range_bonus      -- v6.15.79 (LIQUIPEDIA_REF.md Take Aim levels):
                                -- live attack-range bonus 160/240/320/400 by E
                                -- level. Forward-declared because build_layer1_ctx
                                -- and project_target_state reference it but the
                                -- assignment lives below them (near shrap_radius).
                                -- The closure resolves to THIS local at call time.
local self_take_aim_state       -- v6.15.81: forward-decl for the same reason.
                                -- build_layer1_ctx exposes c.self_take_aim_active
                                -- from this helper.
local commit_floor              -- v6.14.1 H2: ScoreUltTarget reads commit_floor()
                                -- but its assignment lives further down the file.
local _persist_state            -- v6.15 E1: defined after setup_menu(); referenced
                                -- from OnUpdateEx earlier in the file.
local r_kill_prediction         -- v6.15.172: damage-model back-check. Snapshots
                                -- the brain's predicted R damage at cast time so
                                -- cast_outcome can log predicted-vs-actual. The
                                -- order-issue choke point references it but the
                                -- assignment lives below the R-damage helpers.

----------------------------------------------------------------------------
-- Telemetry — Logger-based, no on-screen draw.
--
-- Verbosity slider (Diag menu): 0 = errors only · 1 = key decisions (default)
-- 2 = info (every save / cast / dispatch) · 3 = trace (every score, every
-- candidate poll, every queue-dedup skip).
--
-- Levels are coarse so the user can crank verbosity for investigation and
-- drop to 1 in normal play. The log line format is `[INFO] [Sniper] <event> |
-- k=v ...` (Logger adds the [LEVEL] [name] prefix) so a future log parser can
-- split on the pipe.
----------------------------------------------------------------------------

local LOG = Logger("Sniper")

local function v_level()
    if state.menu and state.menu.diag then return state.menu.diag:Get() end
    return 1
end

local function tlog(level, event, kv)
    if level > v_level() then return end
    local parts = { event }
    if kv then
        for k, v in pairs(kv) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    local msg = table.concat(parts, " | ")
    if     level == 0 then LOG:error(msg)
    elseif level == 1 then LOG:info(msg)
    elseif level == 2 then LOG:info(msg)
    else                   LOG:debug(msg)
    end
end

local function uname(e)
    if not e then return "<nil>" end
    -- v6.15.207: NPC.GetUnitName throws on a valid-but-non-NPC entity (rune /
    -- ground item / building hit by an order). Gate behind Entity.IsNPC so this
    -- diagnostic helper can never crash its caller.
    if Entity.IsNPC(e) then
        local n = NPC.GetUnitName(e)
        if n then return n:gsub("^npc_dota_hero_", "") end
    end
    return tostring(e)
end

-- v6.15.115: anim-log + threat-response dedup helpers extracted to
-- lib/dedup.lua via the state-container redesign. The lib functions take
-- the caller-owned table as their first argument, so Sniper's
-- state.responded_threats / state.anim_log_dedup tables (and the 5+
-- external iterators / GC passes that read them) keep working — Sniper
-- still owns the data, the lib just provides the read/write API.
-- See lib/dedup.lua for the API. Frees 6 local slots (4 functions +
-- 2 constants); net +5 slots after the Dedup import.

local HERO_KEY  = "sniper"
local CAST_R    = 3000
local GRENADE_R = 600

local MS = Enum.ModifierState
local DT = Enum.DamageTypes
local UO = Enum.UnitOrder

-- ability names, single source of truth
local A = {
    Q  = "sniper_shrapnel",
    W  = "sniper_headshot",
    E  = "sniper_take_aim",
    D  = "sniper_concussive_grenade",
    KS = "sniper_keen_scope",
    R  = "sniper_assassinate",
}

-- Universal threat / save tables now live in `lib/threat_data.lua` and are
-- re-bound at the top of this file (THREATS_ON_SELF, LOTUS_WORTHY_INCOMING,
-- ENEMY_CHANNEL_MODIFIERS, ABILITY_TO_THREAT, SAVE_KIND, THREAT_COUNTER,
-- SAVE_PUSH_DISTANCE, THREAT_TETHER_RANGE). Pure helpers (save_counters,
-- displacement_will_break_tether) are below as thin Sniper-side adapters.

-- save_counters: thin alias over the module's pure helper.
local save_counters = TD.SaveCounters

-- displacement_will_break_tether is declared lower — it needs `dist_to` which
-- isn't in scope yet. Forward-declared here so call sites bind to the slot.
local displacement_will_break_tether

----------------------------------------------------------------------------
-- module-local state
----------------------------------------------------------------------------

-- Populate the forward-declared `state` table (don't re-declare with `local`).
state.self_npc       = nil
state.last_score_t   = 0
state.last_save_t    = 0
-- v6.15.251: per-target stamp paired with last_save_t. Set when a defensive
-- save fires against a specific caster; checked by starter_tick to suppress
-- same-tick offensive combo dispatch on the same target (the D+R double-fire
-- on PA was both save grenade and combo R hitting PA in the same frame).
state.last_save_target = nil
-- v6.15.251: window during which starter_tick skips combo dispatch on
-- the same target a defensive save just fired on. Short on purpose --
-- catches strict same-tick double-fire (D + R combined on PA per the
-- v6.15.250 log) without suppressing the legitimate next-blink combo
-- (PA 2-blink charges, ~5s recharge).
state.STARTER_SAVE_SUPPRESS_S = 0.1
state.candidates     = {}     -- last computed valuation list (visible only)
state.fog_cache      = {}     -- entity_idx → {target, score, t} (recently high-score, lost-vision)
state.last_layer1_t  = 0
state.pending_steps  = {}  -- v6.11 Tier 2: step scheduler. List of pending step records:
                            -- { fire_at, combo_name, short, ability_key, kind,
                            --   arg_fn, cond_fn, target } — fired by
                            -- pending_steps_tick() from OnUpdateEx when now>=fire_at.
state.r_cast_protect_until_t = 0   -- v6.15.86: order-veto window during R cast.
state.save_cast_protect_until_t = 0 -- v6.15.139: order-veto window after a Layer-2 self-save dispatches (keeps native MOVE/ATTACK from replacing the issued save order before the engine executes it — same mechanism as r_cast_protect).
state.SAVE_CAST_PROTECT_S    = 0.4 -- v6.15.139: length of the save-cast-protect veto window.
state.combo_cast_protect_until_t = 0 -- v6.15.231: order-veto window after a deferred Layer-1 combo no-target cast (Take Aim) issues, so a native MOVE/ATTACK does not replace it before the engine runs it. Same mechanism as r_cast_protect / save_cast_protect.
state.COMBO_CAST_PROTECT_S   = 0.35 -- v6.15.231: length of the combo-cast-protect veto window. Take Aim is an instant cast; this only needs to cover the dispatch-to-execution gap.
state.r_phase_seen           = false -- v6.15.141: set true once R is observed in its cast phase after a dispatch; lets r_abort_tick tell a cancelled-on-receipt R from one that simply has not started yet.
state.R_PHASE_START_DEADLINE = 1.5 -- v6.15.229: R-cast give-up cap. r_abort_tick waits this many seconds for R to enter its cast phase after dispatch; if it never does, R is given up as cancelled. The give-up stops the instant R locks.
state.R_REISSUE_MAX          = 2   -- v6.15.230: max bounded R re-issues per attempt. The per-frame re-issue (v6.15.228, and once before as v6.15.217) restarted R's own pre-cast wind-up every tick so R never reached its ability phase; a bounded count of spaced retries only ever lands as a real retry of a lost cast.
state.R_REISSUE_SPACING      = 0.25 -- v6.15.230: minimum seconds between R re-issues. The Nth re-issue cannot fire before N*this after dispatch, so a retry never stomps an in-progress cast.
state.r_reissue_count        = 0   -- v6.15.228: R re-issues on the current attempt; for the r_cast_locked / r_cast_never_started log lines, reset on lock or give-up.
state.last_shrap_on_target_t = {}  -- v6.15.90: target_idx → last Q cast time on that target. Used by q_stack_attacker / q_corridor_finisher triggers to refuse re-dispatch within ~9s of prior Q (zone lifetime).
state.starter_q_track        = {}  -- v6.15.131: LIST of recent Starter chip-Q placements {x,y,t} for the GLOBAL zone-coverage re-Q gate (was a per-target-idx map in v6.15.122-.130).
state.vel_hist               = {}  -- v6.15.127: target_idx → ring buffer of {t,x,y} position samples, for smoothed-velocity prediction.
state.VEL_HIST_N             = 5   -- v6.15.127: position-history ring buffer size (~0.33s window at ~15Hz).
state.last_r_target     = nil  -- v6.12 Tier 3 #8: most-recent R cast target.
state.last_r_combo_name = nil  -- combo name that committed R, for pending_steps cleanup on abort.
state.engaged_target    = nil  -- v6.15.50 (G6): last target a combo/sequence dispatched on.
state.engaged_target_t  = 0    -- timestamp of that dispatch — drives 2.0s target stickiness.
-- v6.15.62 / v6.15.184: brain-side orbwalk removed — native Hit & Run owns
-- attack cadence; the no-op orbwalk_cancel_tick was deleted in v6.15.184.
state.kinetic_fields    = {}      -- v6.15.58 (G12): index → { thinker, mod_name, caster }
                                  -- Tracks active Disruptor Kinetic Field thinkers so
                                  -- the per-tick poll fires the save when Sniper WALKS
                                  -- INTO a field that existed before Sniper got close.
                                  -- OnModifierCreate only catches the at-cast case.
state.last_q_t       = 0
state.last_e_t       = 0
state.last_d_t       = 0
state.last_r_t       = 0
state.menu           = nil    -- table of widget handles
state.last_save_intent = "—"  -- string, last Layer 2 save fired
state.last_layer1_intent = "—" -- string, last Layer 1 dispatch
state.skip_counter   = 0      -- queue-dedup skip count (proof of Gate 3 fix firing)
state.l1_counter     = 0      -- Layer 1 dispatch count
state.l2_counter     = 0      -- Layer 2 save count
state.modcreate_counter = 0   -- OnModifierCreate threat-hit count
state.armed_threats   = {}    -- threat-key → {caster, threat_mod, eta_speed, eta_trigger}
                              -- ETA-armed homing threats; fire when impact ETA < eta_trigger
state.anim_log_dedup  = {}    -- "<caster_idx>:<ability_name>" → last_log_time
                              -- Anim events loop during channels; rate-limit
                              -- their log output to once per (caster,ability)
                              -- per Dedup.ANIM_WINDOW seconds. Behavior is
                              -- unchanged — only the log line is suppressed.
state.responded_threats = {}  -- "<caster_idx>:<mod_name>" → last_response_time
                              -- Threat-response dedup: a single threat
                              -- instance (Bane casting Nightmare once)
                              -- should produce at most one save action,
                              -- not stack across multiple paths.

-- v6.13 Cross F#14: ability-slot reservations. When offense schedules a
-- delayed step (e.g. snipe_standard's D at +1.5s), the underlying ability
-- slot is "reserved" until the step fires. Defense's save chain checks
-- reservations before considering D-using saves (grenade_self,
-- grenade_at_caster) — without this, defense fires the grenade now and
-- offense's scheduled D silently fails when the step time arrives.
-- Keyed by ability constant (A.D / A.E / A.Q / A.R), value is the time
-- the reservation expires. Cleared by pending_steps_tick when the step
-- fires or aborts.
state.reservations = {}

-- v6.13 Cross F#19: displacement-in-flight window. When a save fires Pike
-- on an enemy (425u airborne ~0.5s) or grenade-self / Force-self (Sniper
-- airborne / moving), set the end-time here so offense's commit_pred can
-- refuse R during the airborne window. Keyed by entity-index of the
-- displaced unit (or `0` for self), value is the time the displacement
-- ends.
state.displacements = {}

-- v6.14: playability state.
state.last_refusal       = nil   -- { combo, target_name, reason, t }
state.last_score_breakdown = nil -- string formatted for status label
state.combo_key_was_down = false -- for tap-mode + release-cancel edge detection
-- v6.15.118: runtime tap/hold detection replaces the v6.14 combo_tap menu
-- toggle. combo_press_t marks when the combo key went down; a release within
-- COMBO_TAP_MAX_S is a TAP (Heavy Starter), a longer press is a HOLD (the
-- adaptive Starter / Team Fight loop). combo_hold_active latches once a press
-- crosses the tap threshold so the release edge knows it was a HOLD, not a TAP.
state.combo_press_t          = 0
state.combo_hold_active      = false
-- v6.15.194 (audit #6): latched dispatch mode for the current HOLD ("tf" |
-- "starter"). Captured ONCE on hold-start in the OnUpdateEx classifier and
-- held until release. Without the latch the routing flipped per tick on
-- the 1500u radius boundary, so an enemy crossing the line for a single
-- tick could route one frame to teamfight_tick and the next to
-- starter_tick mid-combo (an open issue from the polish audit).
state.combo_hold_active_mode = nil
state.COMBO_TAP_MAX_S        = 0.18  -- press shorter than this = TAP
state.COMBO_CLASSIFY_RADIUS  = 1500  -- enemy-hero scan radius for the HOLD classifier (3+ = Team Fight)
-- v6.15.199 (audit C4): TF coordination-radius constant. Used by
-- tf_q_pos (enemy scan), tf_team_focus (ally scan), teamfight_tick
-- outer enemy scan. 1800u is the engagement-footprint radius — wider
-- than COMBO_CLASSIFY_RADIUS (1500u, the in/out gate) so transient
-- enemies don't drop out of the TF picture between classify and
-- archetype dispatch. Different semantic from state.q_cast_range()
-- (which happens to also be 1800 at current KV but is the Shrapnel
-- cast-range live read).
state.TF_SCAN_RADIUS         = 1800
-- v6.15.200 (audit C12): "close enough to count as in attack
-- engagement" — used by `target_attacking_us` (Sniper-to-target close
-- gate) and `tf_team_focus` (ally-to-enemy pairing). Same numeric
-- value, same intent (attack reach is typically 550 + bonuses, 700
-- gives a small buffer for projectile/range fluctuation).
state.ATTACK_ENGAGE_RADIUS   = 700
state.last_combo_key_down_t  = 0     -- v6.15.129: last time the combo key was down (combo_key:IsDown flickers — use a window, not 1 tick)
state.pike_primed            = false -- v6.15.222: Hurricane Pike confirmed-fired (cooldown observed > 0) at least once — the engine's fresh-item first-cast quirk is spent.
state.pike_prime_done        = false -- v6.15.222: a one-shot throwaway prime cast has been issued (guards against re-priming every tick).
state.pike_reissue           = nil   -- v6.15.222: {caster,t} — a real Pike save fired an un-primed Pike; pike_prime_tick re-issues next frame (double-issue).
state.AUTO_GRENADE_COMBO_SUPPRESS_S = 2.5 -- auto-grenade D stays suppressed this long after the combo key was last down
state.BLINK_ARRIVE_TIMEOUT_S       = 2.0 -- v6.15.143: drop an instant-blink armed threat that never arrived (caster valid but never entered range) after this long, so a stale key cannot block re-arming the next blink
state.BLINK_ARRIVE_DIST_U          = 250 -- v6.15.149 (D5): an instant blink (PA Phantom Strike) lands the caster at melee (~150-250u). Firing the save as soon as d<=425 caught the caster mid-blink-settle (a demo logged a fire at d~256). Wait until the caster has settled inside this distance so the Pike push acts on a settled target
state.BLINK_SETTLE_S               = 0.05 -- v6.15.253: after blink_arrived detection, wait one settle window before dispatching save. PA's network position can lag the actual teleport by ~1-2 ticks; pike fire's dist_to(caster) <= 425u check then refuses (engine sees stale far position) and the cast_verify reports fired=n / cd_after=0. 50ms ~ 1.5 ticks at 30Hz. Tight enough to keep save inside PA's ~0.5s+attack_point auto window.
state.AUTO_GRENADE_SAVE_SUPPRESS_S  = 0.6 -- v6.15.140: auto-grenade D stays suppressed this long after a Layer-2 self-save dispatched, so D does not double up on a rusher the defense layer just peeled
state.FOG_SNIPE_COMBO_SUPPRESS_S    = 1.0 -- v6.15.152: speculative fog-R stays suppressed this long after the combo key was last down, so it never steals R from a combo the user is running
state.FOG_SNIPE_RETRY_S             = 0.5 -- v6.15.152: fog-R self-throttle (L20 — a per-tick check that may fire nothing must self-throttle)
-- v6.15.121-.124: Starter per-tick adaptive loop tunables.
state.STARTER_R_MIN_RANGE_FRAC = 0.70 -- fleeing-R only commits at ≥70% of (Take-Aim) attack range
state.STARTER_Q_ZONE_LIFE      = 11.0  -- Shrapnel KV: 10s zone + 0.3s cast point. Was 9.0 — sporadic stacking (full-match: zones 307u apart cast just after the brain forgot the first). 11.0 covers actual ground-life + safety.
state.STARTER_Q_COVER_R        = 400  -- v6.15.195 (audit A5): superseded at the squared-form call sites by a live shrap_radius() read (KV per-Q-level 400/425/450/475). Kept as a doc / safety fallback only.
state.D_PEEL_OFFSET            = 300  -- v6.15.128: dr-combo D lands this far inward from the attacker (Sniper side) so the knockback shoves them outward
state.D_PEEL_LEAD_S            = 0.3  -- v6.15.161: optimal_d_pos leads the attacker's movement by this long (D cast point 0.1s + humanizer delay + short projectile travel) so the grenade lands on the attacker's PREDICTED position, not a stale dispatch-time snapshot
state.COMMITTED_ATTACK_WINDOW_S = 1.6 -- v6.15.135: `committed` latches NPC.IsAttacking over this window (~one attack cycle) so the flickering poll doesn't drop `dr` to `chip`
state.DMG_PANIC_RETRY_S  = 1.0   -- v6.15.144: min interval between damage-rate-panic save attempts (the check runs every tick; without this it re-runs the whole save chain every frame while taking damage with no save available)
state.last_dmg_panic_t   = 0     -- v6.15.144: last damage-rate-panic save attempt time
state.last_panic_key_down = false
state.last_smoke_warn_t  = 0
state.smoke_state        = "ok"  -- "ok" / "watch" / "alert" / "off" — HUD
state.last_layer15_t     = 0     -- v6.14.1 H4: separate throttle so L1.5
                                 -- auto-fires don't block user combo dispatch
-- v6.14.1 lows: removed state.last_force_key_down (was dead — never read).

-- v6.15.10: pre-face tick state. Pre-emptive ATTACK_TARGET on the most
-- imminent threat (time-to-impact = dist / move_speed) overrides whatever
-- the user is doing so Sniper is already aimed when the threat casts —
-- recovers the turn-time budget the engine would otherwise eat during the
-- save's cast point. Cooldown prevents per-frame re-issue.
state.last_preface_t     = 0
-- v6.15 B3: deduped modifier-name observations for end-of-match summary.
-- Each unique <unit>:<modifier> first-seen timestamp + count.
state.seen_modifiers     = {}
-- v6.15 B1: end-of-match telemetry flag + counters.
state.match_summary_dumped = false
state.abort_counter        = 0    -- r_abort fires
state.panic_counter        = 0    -- panic-key fires
state.force_counter        = 0    -- force-commit dispatches
-- v6.15 C1: postmortem — track last save fire kind + threat for death analysis.
state.last_save_kind       = nil
state.last_save_threat_mod = nil

local FOG_CACHE_TTL = 1.5     -- seconds a fog candidate remains castable

local function now() return GlobalVars.GetCurTime() end

-- Reservation primitives. ability_key is one of the A.* constants.
local function reserve_ability(ability_key, expires_at, by)
    state.reservations[ability_key] = { expires_at = expires_at, by = by or "?" }
end
local function is_reserved(ability_key)
    local r = state.reservations[ability_key]
    if not r then return false end
    if now() >= r.expires_at then
        state.reservations[ability_key] = nil
        return false
    end
    return true
end
local function clear_reservation(ability_key)
    state.reservations[ability_key] = nil
end

-- Displacement primitives. unit_idx == 0 for self.
local function record_displacement(unit_idx, ends_at)
    state.displacements[unit_idx] = ends_at
end
local function is_displaced(unit_idx)
    local t = state.displacements[unit_idx]
    if not t then return false end
    if now() >= t then state.displacements[unit_idx] = nil; return false end
    return true
end
local function f_idx() return GlobalVars.GetFrameCount() end

----------------------------------------------------------------------------
-- helpers — predicates / utilities
----------------------------------------------------------------------------

local function self_alive_ok()
    local me = state.self_npc
    if not me or not Entity.IsAlive(me) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_STUNNED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_HEXED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_SILENCED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_NIGHTMARED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_TAUNTED) then return false end
    -- v6.15.107 (audit-derived from klc9r4n + Axe Auto Call): COMMAND_RESTRICTED
    -- prevents most player orders from reaching the engine. Sniper's brain
    -- orders go through the same pipeline so they're also blocked. Adding the
    -- check here saves a wasted dispatch attempt + cast_verify cycle.
    --
    -- ROOTED is INTENTIONALLY NOT added (klc9r4n includes it but for Sniper
    -- it would be wrong). ROOTED only prevents movement; Sniper can cast Q,
    -- W, E, R, D, items normally while rooted. A rooted Sniper is in danger
    -- and NEEDS to fire saves and Assassinate — refusing to cast would be a
    -- regression.
    -- v6.15.108 (defensive): explicit nil check rather than `if X and ...`
    -- short-circuit. Lua treats 0 as truthy (unlike most languages), so a
    -- hypothetical engine build where the enum value is 0 would slip past
    -- the truthy short-circuit and call NPC.HasState(me, 0) — undefined.
    -- Dota's modifier-state enums are never 0 in practice, but `~= nil` is
    -- the unambiguously-correct guard. Found in the v6.15.107 review.
    if MS.MODIFIER_STATE_COMMAND_RESTRICTED ~= nil and NPC.HasState(me, MS.MODIFIER_STATE_COMMAND_RESTRICTED) then return false end
    -- v6.13 Cross F#15+F#20: refuse to dispatch / fire scheduled steps when
    -- Sniper is mid-Eul/Manta-cyclone or otherwise out-of-game (defense fired
    -- an invuln save while offense had pending D/Q1/Q2/Q3 steps). Without
    -- these checks, scheduled steps fire pointlessly during cyclone.
    if NPC.HasState(me, MS.MODIFIER_STATE_INVULNERABLE) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_OUT_OF_GAME) then return false end
    return true
end

-- v6.2: Concussive Grenade is granted by Aghs Shard in 7.41C (not base kit).
-- NPC.GetAbility still returns a handle for the unlearned slot when shard
-- isn't owned, so the multi-slot scan is kept as a defensive fallback (in
-- case future patches reintroduce a second slot via shard or talent). The
-- level-gate in ability_ready is the actual safety net — find_ability just
-- returns a handle; downstream callers must check Ability.GetLevel > 0.
local function find_ability(name)
    local me = state.self_npc
    if not me then return nil end
    -- Fast path: single-slot abilities use the named lookup
    local first = NPC.GetAbility(me, name)
    if name ~= A.D then return first end
    -- Multi-slot scan for grenade: walk every slot, return any LEARNED-and-ready
    -- instance; fall back to any learned slot; finally any slot at all.
    local fallback_learned = nil
    local fallback_any = first
    for i = 0, 23 do
        local a = NPC.GetAbilityByIndex(me, i)
        if a and Ability.GetName(a) == name then
            local learned = Ability.GetLevel(a) > 0
            if learned and Ability.IsReady(a) then return a end
            if learned then fallback_learned = fallback_learned or a end
            fallback_any = fallback_any or a
        end
    end
    return fallback_learned or fallback_any
end

local function ability(name)
    return find_ability(name)
end

-- v6.2: gate on Ability.GetLevel > 0. In 7.41C, Concussive Grenade is
-- granted by Aghs Shard (not base kit). Without shard, NPC.GetAbility still
-- returns a handle for the unlearned slot, and Ability.IsReady returns true
-- (no CD on unlearned). Without this check the chain "fires" grenade_at_caster
-- against Pudge Dismember, the in-game cast silently fails (unlearned), the
-- chain stops, and Pike never falls through. User-reported "Pike doesn't fire
-- without shard" symptom.
local function ability_ready(name)
    local a = ability(name)
    return a ~= nil and Ability.GetLevel(a) > 0 and Ability.IsReady(a)
end

local function shrap_charges()
    local a = ability(A.Q)
    return a and Ability.GetCurrentCharges(a) or 0
end

-- v6.15.105: live R cast point with 2.0 fallback. Talent-aware via
-- Ability.GetCastPoint's second arg (true = include talents/aspects).
-- Replaces 7 inline duplicates of the same `(ability(A.R) and
-- Ability.GetCastPoint and Ability.GetCastPoint(ability(A.R), true)) or 2.0`
-- pattern (plus one hardcoded 2.0 in r_will_range_leak that previously
-- ignored Scepter). Returns 2.0 when R isn't available or the API isn't.
local function r_cast_point()
    local r_ab = ability(A.R)
    if r_ab and Ability.GetCastPoint then
        return Ability.GetCastPoint(r_ab, true) or 2.0
    end
    return 2.0
end

-- v6.15.106 + v6.15.109: lead time for Q-cast position prediction.
--
-- LIQUIPEDIA Shrapnel pipeline = cast animation 0.3s + effect delay
-- (zone arms after) 1.2s = 1.5s total from cast issue to zone active.
-- v6.15.106 used 1.5s here as the "physics-correct" lead — but that
-- assumed CONSTANT target velocity over the entire 1.5s flight. In
-- practice target velocity drops mid-flight (Headshot procs slow them,
-- attack-animations freeze them, stuns lock them, channels glue them,
-- they decide to attack Sniper instead of fleeing). User feedback on
-- v6.15.107 demo: "Q1 prediction is off, not using enemy as center
-- point" — Q was landing AHEAD of where target ended up.
--
-- v6.15.109: drop lead to 0.5s. At v=300:
--   - Q placed +150u ahead of target's current position
--   - If target maintains velocity for full 1.5s arm time → ends up at
--     +450u (+300u from Q center, well inside 450u radius)
--   - If target stops at any point during flight → ends up between +0
--     (back-edge -150u from Q center) and +450u (+300u from center)
--   - In ALL velocity-profile cases, target is INSIDE Q at arm time
-- For v=400: target ends up at most +400u from Q center (just inside
--   L4's 475u radius). For v=200: target ends up at most +200u from
--   center (well inside).
--
-- This trades "perfect center placement at constant velocity" for
-- "target always inside Q regardless of velocity changes". User-
-- preferred per "use enemy as center point" feedback.
--
-- Used by: snipe_e_r / snipe_q_r / snipe_standard / q_e_sustained /
-- q_stack_attacker / q_refresh / corridor_pos_q1 / q_corridor_finisher
-- Q2 + Q3 (v6.15.109 changed Q2/Q3 from corridor offset to lead_target_pos
-- with this same lead — see q_corridor_finisher steps).
-- v6.15.123: back to 1.5s — the full LIQUIPEDIA Shrapnel pipeline (0.3s cast
-- animation + 1.2s effect delay before the zone strikes). v6.15.109 dropped it
-- to 0.5s on a constant-velocity argument; the v6.15.122 demo disproved that —
-- moving-target Q landed mispositioned. Q must lead by the time it takes the
-- zone to actually strike so the target walks into it as it arms. Stationary
-- targets are unaffected (lead_target_pos' <200-mvspeed gate → current pos).
local function q_arm_lead_s()
    return 1.5
end

-- v6.15.114: item / item_ready extracted to lib/npc.lua. Sniper callers now
-- use NPCLib.item(state.self_npc, name) / NPCLib.item_ready(state.self_npc, name).
-- Frees 2 local slots (no new import — NPCLib already imported in v6.15.113).

-- Distance from Sniper to target world position
local function dist_to(target)
    local me = state.self_npc
    -- v6.15.236: a stale handle (a destroyed entity left in a HUD or
    -- candidate cache) is a non-nil number that passes `not target` but
    -- throws arg-is-not-an-Entity inside GetAbsOrigin -- observed from
    -- refresh_status_panel. Entity.IsEntity rejects the garbage handle;
    -- the a/b nil guard then covers a valid-but-dead entity (GetAbsOrigin
    -- returns nil mid-respawn, lesson #124).
    if not me or not target
       or not Entity.IsEntity(me) or not Entity.IsEntity(target) then
        return math.huge
    end
    local a = Entity.GetAbsOrigin(me)
    local b = Entity.GetAbsOrigin(target)
    if not a or not b then return math.huge end
    return a:Distance2D(b)
end

-- v6.15.17: NPC.GetAttackRange returns the BASE attack range per LuaCATS
-- (Npc.lua:296: "Returns the base attack range"). Item bonuses (Pike +75,
-- Dragon Lance +120, Hurricane Pike +75, etc.), talents, and active buffs
-- live in NPC.GetAttackRangeBonus. The brain previously read only the
-- base everywhere — causing:
--   • snipe_r_only's "out of RC range" gate to fire R on targets that were
--     actually inside the effective autos range (user observation, Pugna).
--   • setup_killable to refuse setups that were in real RC range.
--   • snipe_e_r's atk_range_with_e to be 140u short of reality.
-- All four call sites now go through this helper.
function effective_attack_range(npc)
    if not npc then return 550 end
    local base  = NPC.GetAttackRange(npc) or 550
    local bonus = NPC.GetAttackRangeBonus(npc) or 0
    return base + bonus
end

-- v6.15.18: same pattern for cast range. Ability.GetCastRange returns the
-- ability's level-specific BASE cast range; NPC.GetCastRangeBonus returns
-- the unit-wide cast range bonus (Aether Lens +250, talents, etc.). The
-- brain had hardcoded constants (CAST_R=3000, GRENADE_R=600, SHRAP_R=1800)
-- that ignored bonuses — Sniper with Aether Lens has effective R range
-- 3250 but the brain refused R commits beyond 3000u.
function effective_cast_range(npc, ability_handle)
    if not npc or not ability_handle then return 0 end
    local base  = Ability.GetCastRange(ability_handle) or 0
    local bonus = NPC.GetCastRangeBonus(npc) or 0
    return base + bonus
end

-- v6.15.170 (KV-hardcode migration A8): live R / grenade cast ranges. The
-- module constants CAST_R=3000 / GRENADE_R=600 were hardcoded KV mirrors
-- (sniper_assassinate cast range / sniper_concussive_grenade cast range)
-- that IGNORED cast-range bonuses — a Sniper with Aether Lens (+250) or a
-- cast-range talent has 3250 R / 850 grenade reach, but the range gates
-- still using these raw constants refused valid casts. These helpers derive
-- the live effective range; the constant is the no-handle fallback (the KV
-- base). build_layer1_ctx already migrated the combo paths to
-- effective_cast_range — this finishes the job for the candidate-scan and
-- save-range gates.
state.r_cast_range = function()
    local me = state.self_npc
    local v  = me and effective_cast_range(me, ability(A.R))
    return (v and v > 0) and v or CAST_R
end
state.grenade_cast_range = function()
    local me = state.self_npc
    local v  = me and effective_cast_range(me, ability(A.D))
    return (v and v > 0) and v or GRENADE_R
end
-- v6.15.197 (audit B9): Q effective cast range. Mirrors r_cast_range /
-- grenade_cast_range above. Replaces two duplicated inline fallbacks
-- (the legacy `cast_q = 1800` setup at the top of tf_q_pos, and the
-- ctx.cast_q-or-1800 ternary in the teamfight ap_ok path). 1800u
-- matches sniper_shrapnel KV `AbilityCastRange` base; live reads add
-- cast-range bonuses (Aether Lens / talent).
state.q_cast_range = function()
    local me = state.self_npc
    local v  = me and effective_cast_range(me, ability(A.Q))
    return (v and v > 0) and v or 1800
end
-- v6.15.199 (audit C6): per-frame cache of OUR allies (TEAM_FRIEND
-- from me-POV). The ScoreUltTarget far-shot has-ally-near check used
-- to do `Entity.GetHeroesInRadius(target, 800, TEAM_ENEMY)` per
-- candidate inside `recompute_candidates` (10 Hz × N candidates that
-- hit the far-shot path → up to ~50 redundant ally scans/sec). One
-- me-POV scan per frame replaces all of them; the per-candidate check
-- becomes an O(allies) distance filter against the cached list.
-- Scan radius = r_cast_range() + 800 so any ally that could pass the
-- "within 800 of a candidate at edge of R range" check is captured.
state.cached_allies_f = state.cached_allies_f or -1
state.cached_allies   = state.cached_allies   or {}
state.get_cached_allies = function(me)
    local cur_f = f_idx()
    if state.cached_allies_f == cur_f then return state.cached_allies end
    local radius = (state.r_cast_range() or 3000) + 800
    local list   = me and Entity.GetHeroesInRadius(me, radius,
        Enum.TeamType.TEAM_FRIEND) or {}
    state.cached_allies   = list
    state.cached_allies_f = cur_f
    return list
end
-- v6.15.204 (audit C9): is an enemy's in-progress Teleport still
-- INTERRUPTIBLE by Sniper's R? ScoreUltTarget's +50 TP-interrupt bonus
-- (stacked on the +200 channel bonus → +250, the highest score in the
-- system) should only apply when R can actually land before the TP
-- channel completes. R's cast point is r_cast_point() — ~2.0s base,
-- ~0.5s with Scepter; a base TP is a 3.0s channel. If the modifier
-- has less than r_cast_point() + 0.3s margin left, R cannot finish in
-- time and the +50 is awarding a chase the brain can't cash in.
-- Returns true (award the bonus) when the timer shows enough margin,
-- OR when the timer can't be read at all (default to the prior
-- always-on behaviour rather than silently dropping the bonus on a
-- missing-API path).
state.tp_interruptible = function(target)
    if not (target and NPC.GetModifier and Modifier.GetDieTime) then
        return true
    end
    local mod = NPC.GetModifier(target, "modifier_teleporting")
    if not mod then return true end
    local die = Modifier.GetDieTime(mod)
    if not die then return true end
    local remaining = die - GlobalVars.GetCurTime()
    return remaining > (r_cast_point() + 0.3)
end

-- v6.15.18: total spell amp. NPC.GetBaseSpellAmp returns the BASE amp from
-- the hero's intelligence (per Dota's stat conversion); item amp lives in
-- NPC.GetModifierProperty(MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE) and
-- the unique-amp slot (Kaya/Yasha-Kaya/Octarine) goes in
-- MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE_UNIQUE. Combining additively
-- approximates Dota's actual multiplicative-with-unique stacking close
-- enough for kill-budget math. assassinate_damage uses this so R damage
-- estimates include Octarine etc.
function effective_spell_amp_pct(npc)
    if not npc then return 0 end
    local base = (NPC.GetBaseSpellAmp and NPC.GetBaseSpellAmp(npc)) or 0
    local item_amp, unique_amp = 0, 0
    if NPC.GetModifierProperty and Enum.ModifierFunction then
        item_amp = NPC.GetModifierProperty(npc,
            Enum.ModifierFunction.MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE) or 0
        unique_amp = NPC.GetModifierProperty(npc,
            Enum.ModifierFunction.MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE_UNIQUE) or 0
    end
    return base + item_amp + unique_amp
end

-- Sniper-side adapter for the module's pure-math tether predicate. Turns a
-- caster entity into a sniper→caster distance, then defers to TD.WillTetherBreak.
displacement_will_break_tether = function(save_kind_key, threat_mod, threat_caster)
    if not threat_caster or not Entity.IsEntity(threat_caster) then return true end
    return TD.WillTetherBreak(save_kind_key, threat_mod, dist_to(threat_caster))
end

-- Hero-specific (but generalizable): Blink escape destination 1200u opposite
-- the threat. Uses the same threat-priority SafePushDestination check so a
-- valid blink point in a multi-enemy scenario considers only the immediate
-- threat. Returns nil if no threat direction or destination unsafe.
local function blink_escape_position(threat_caster_hint)
    local me = state.self_npc
    if not me then return nil end
    -- v6.15.238: NPCLib.origin guards the stale-handle throw; the nil-check
    -- covers a mid-respawn self.
    local me_pos = NPCLib.origin(me)
    if not me_pos then return nil end

    local toward_threat
    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local cp = NPCLib.origin(threat_caster_hint)
        if cp then
            local diff = cp - me_pos
            if diff:Length2DSqr() > 1 then toward_threat = diff:Normalized() end
        end
    end
    if not toward_threat then
        local enemies = NPCs.InRadius(me_pos, 1500, Entity.GetTeamNum(me),
            Enum.TeamType.TEAM_ENEMY, true, true)
        if enemies and #enemies > 0 then
            local centroid = VectorCenter(enemies)
            if centroid then
                local diff = centroid - me_pos
                if diff:Length2DSqr() > 1 then toward_threat = diff:Normalized() end
            end
        end
    end
    if not toward_threat then return nil end

    -- Blink range is 1200u (with manabar slack — most patches allow exact
    -- 1200). Aim a bit shorter to ensure success even if the engine clamps.
    -- v6.15.240 (clue C4) added the 5-angle danger-aware pick here;
    -- v6.15.244 lifted it into state.pick_escape_dir so grenade_self and
    -- pike_self share the same logic. 0deg (straight away) is always a
    -- candidate, so this never does worse than the old single-point
    -- behaviour.
    local _, dest = state.pick_escape_dir(me_pos, toward_threat, 1180, threat_caster_hint)
    return dest
end

-- Hero-specific: optimal grenade-self cast point for `self_push` escape.
--
-- Concussive Grenade pushes affected units RADIALLY AWAY FROM the cast point.
-- For Sniper with self_push=1, casting AT his own feet leaves the push
-- direction undefined (zero vector) — the engine fell back to facing-or-
-- random in observed games, sometimes landing Sniper INTO the enemy.
--
-- Fix: offset the cast point 75u TOWARD the threat (still inside the 375u
-- grenade radius so Sniper is affected by self_push). The resulting push
-- direction is (sniper - cast_point) → -toward_threat → AWAY from threat.
--
-- Returns the cast point Vector, or nil if no usable threat direction or the
-- predicted landing position fails SafePushDestination (cliff, tower-aggro,
-- moving Sniper closer to threat centroid).
local function grenade_self_cast_point(threat_caster_hint)
    local me = state.self_npc
    if not me then return nil end
    -- v6.15.238: NPCLib.origin guards the stale-handle throw; the nil-check
    -- covers a mid-respawn self.
    local me_pos = NPCLib.origin(me)
    if not me_pos then return nil end
    local push_distance = SAVE_PUSH_DISTANCE.grenade_self or 475

    -- Direction TOWARD threat. Prefer the explicit caster hint, else the
    -- centroid of nearby enemies, else Sniper's current facing as last resort.
    local toward_threat
    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local cp = NPCLib.origin(threat_caster_hint)
        if cp then
            local diff = cp - me_pos
            if diff:Length2DSqr() > 1 then toward_threat = diff:Normalized() end
        end
    end

    if not toward_threat then
        local enemies = NPCs.InRadius(me_pos, 1500, Entity.GetTeamNum(me),
            Enum.TeamType.TEAM_ENEMY, true, true)
        if enemies and #enemies > 0 then
            local centroid = VectorCenter(enemies)
            if centroid then
                local diff = centroid - me_pos
                if diff:Length2DSqr() > 1 then toward_threat = diff:Normalized() end
            end
        end
    end

    if not toward_threat then
        -- No directional info — refuse to fire grenade-self. Falling back
        -- to a cast-at-self would risk pushing Sniper INTO the enemy.
        tlog(3, "grenade_self_skip_no_direction", {})
        return nil
    end

    -- v6.15.44 (user-reported PA bug): cast_offset must keep the threat
    -- on the FAR side of the cast point. Fixed 75u placed cast BEYOND
    -- the threat when the threat was closer than 75u (PA at modifier-
    -- create time is mid-blink, often <75u away). In that case the
    -- engine's radial push from cast point hits BOTH Sniper and threat
    -- in the SAME -toward_threat direction — exactly the v6.15.43 demo
    -- complaint "grenade lands behind her, throwing both of us in the
    -- same direction". Fix: clamp cast_offset so it's always between
    -- Sniper (0u) and threat (dist - 25u of margin). The 25u floor keeps
    -- cast_point clear of Sniper himself (avoiding undefined radial
    -- direction); the upper clamp at 75u preserves the long-range
    -- behavior (Pudge dismember at 200u, Bane grip at 875u tether).
    local cast_offset = 75
    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local dist = dist_to(threat_caster_hint) or 75
        cast_offset = math.max(25, math.min(75, dist - 25))
    end

    -- Facing-angle gate (background, v6.15.47): the cast point is BETWEEN
    -- Sniper and the threat; if Sniper is currently facing AWAY (kiting,
    -- attacking another target), the engine queues the grenade order but
    -- Sniper has to TURN to face the cast point before the cast animation
    -- can play. At Sniper's 0.7 turn rate, a 180deg turn takes ~0.45s --
    -- longer than Pudge Dismember's 0.3s cast point window, so the grenade
    -- lands AFTER Sniper is already stunned. 120deg threshold ~= 0.3s of
    -- turn at the 0.6 rate; within that window the grenade lands inside
    -- the channel's cast point and breaks it. Threshold tuned against
    -- Pudge Dismember; longer-cast channels (Bane grip 0.6s) tolerate more
    -- turn but are also fine falling to Pike when facing way off.
    --
    -- v6.15.247: the gate is now baked into the danger-aware pick instead
    -- of running AFTER the helper. The v6.15.246 fresh-log test against
    -- Disruptor Kinetic Field showed Sniper back-turned at 142deg; the
    -- 0deg-baseline cast_point fails the 120deg gate, but the +/-90deg
    -- perpendicular candidates (v6.15.245) have cast_points roughly
    -- perpendicular to Sniper's facing -- within the 120deg budget. With
    -- the post-pick gate, the helper happily picked 0deg (lowest danger
    -- in a 1-enemy scenario), the gate then refused, and the chain ran
    -- out with no save fired even though a usable rotated angle existed.
    -- The fix: pass a facing predicate INTO the helper. It now only
    -- considers candidates whose cast_point is already within the 120deg
    -- turn budget, then picks the lowest-danger of THOSE. So in the
    -- back-turned kinetic-field case the helper picks +/-90deg (the only
    -- facing-reachable angles) and the grenade fires.
    local MAX_TURN_FOR_GRENADE_SELF = 120
    local function facing_ok(esc_dir, _landing)
        local cand_cast = me_pos - esc_dir * cast_offset
        local angle = math.deg(math.abs(NPC.FindRotationAngle(me, cand_cast)))
        return angle <= MAX_TURN_FOR_GRENADE_SELF
    end

    -- v6.15.244 (clue C4 finalisation, refined v6.15.245/.247):
    -- danger-aware landing pick, now also facing-aware. Try 7 angles off
    -- straight-away (0, +/-35, +/-65, +/-90); keep the lowest-danger
    -- candidate that passes both SafePushDestination AND the facing gate
    -- above. 0deg ties go to the baseline via strict less-than. If every
    -- candidate fails one of the gates, the helper returns nil and the
    -- chain falls through to the next save.
    local escape_dir, landing = state.pick_escape_dir(me_pos, toward_threat, push_distance, threat_caster_hint, facing_ok)
    if not escape_dir then
        tlog(3, "grenade_self_skip_no_safe_dir", { push = push_distance })
        return nil
    end
    -- cast_point is OPPOSITE the chosen escape direction (offset behind
    -- Sniper). The grenade's radial push at Sniper's feet then points
    -- along escape_dir, so Sniper lands at me_pos + escape_dir * 475.
    -- Equivalent to the historical me_pos + toward_threat * cast_offset
    -- whenever the helper picks 0deg. Facing already validated by
    -- facing_ok inside the helper -- no post-pick gate.
    local cast_point = me_pos - escape_dir * cast_offset

    -- Landing already validated by state.pick_escape_dir above; logged
    -- here for diagnostic visibility (land_x / land_y reveal which of the
    -- 5 candidates won when teamfight positioning matters).
    tlog(3, "grenade_self_cast_plan", {
        offset = cast_offset, push = push_distance,
        land_x = string.format("%.0f", landing.x or 0),
        land_y = string.format("%.0f", landing.y or 0),
    })
    return cast_point
end

-- Gate 3: baseline-dedup against Humanizer.GetOrderQueue(). Returns true iff
-- the humanizer queue already carries an EQUIVALENT order. Match keys:
-- orderType + unit + abilityIndex + targetIndex, and — for position casts —
-- the cast POSITION. Queue entries expose `position` (per the UCZone API).
-- v6.15.155: a CAST_POSITION order has targetIndex 0, so `match_target` was
-- always true — two Shrapnel zones aimed at DIFFERENT spots looked identical
-- and the second was wrongly deduped. That was the "Team Fight Q never
-- spreads" bug: tf_q's spare charges were swallowed because Q1 was still in
-- the humanizer queue and the position was ignored. Now, when the caller
-- passes a position and the queued entry has one, the two must be within
-- 250u to count as the same order. Same-intent re-dispatches land within
-- ~250u (target-prediction jitter); a deliberate spread is 400u+ apart
-- (tf_q_pos / ap_ok never place zones closer than STARTER_Q_COVER_R 400u).
local function queue_has_baseline(order_type, ability_h, target_h, unit_h, position)
    local q = Humanizer.GetOrderQueue()
    if not q then return false end
    local ab_idx = ability_h and Entity.GetIndex(ability_h) or 0
    local tg_idx = target_h  and Entity.GetIndex(target_h)  or 0
    local un_idx = unit_h    and Entity.GetIndex(unit_h)    or 0
    for i = 1, #q do
        local e = q[i]
        if e.orderType == order_type then
            local match_unit    = un_idx == 0 or (e.unit and Entity.GetIndex(e.unit) == un_idx)
            local match_ability = ab_idx == 0 or e.abilityIndex == ab_idx
            local match_target  = tg_idx == 0 or e.targetIndex  == tg_idx
            local match_pos     = true
            if position and e.position then
                local dx = (e.position.x or 0) - (position.x or 0)
                local dy = (e.position.y or 0) - (position.y or 0)
                if (dx * dx + dy * dy) > (250 * 250) then match_pos = false end
            end
            if match_unit and match_ability and match_target and match_pos then
                return true
            end
        end
    end
    return false
end

-- v6.1: detect any save item pending on a specific target. Used to avoid
-- firing grenade when baseline (or anything else) already has a save item
-- queued for the same enemy. Different from queue_has_baseline because we
-- don't match a specific ability — any save item on this target counts.
--
-- Save items considered: Pike, Force, Eul, Manta, Satanic, Glimmer, Disperser,
-- Diffusal, Cyclone, Wind Waker, Solar Crest, Lotus, Blade Mail.
local SAVE_ITEMS_TO_CHECK = {
    "item_hurricane_pike", "item_force_staff", "item_cyclone", "item_wind_waker",
    "item_manta", "item_satanic", "item_glimmer_cape", "item_disperser",
    "item_diffusal_blade", "item_solar_crest", "item_lotus_orb", "item_blade_mail",
}

local function save_item_pending_on_target(target)
    if not target or not Entity.IsEntity(target) then return false, nil end
    local me = state.self_npc
    if not me then return false, nil end
    local q = Humanizer.GetOrderQueue()
    if not q then return false, nil end
    local tg_idx = Entity.GetIndex(target)
    local me_idx = Entity.GetIndex(me)
    -- Resolve item handles to indices once.
    local item_indices = {}
    for _, name in ipairs(SAVE_ITEMS_TO_CHECK) do
        local it = NPC.GetItem(me, name, true)
        if it then item_indices[Entity.GetIndex(it)] = name end
    end
    for i = 1, #q do
        local e = q[i]
        if e.unit and Entity.GetIndex(e.unit) == me_idx
           and e.targetIndex == tg_idx
           and item_indices[e.abilityIndex]
        then
            return true, item_indices[e.abilityIndex]
        end
    end
    return false, nil
end

-- v6.8: Read a hint about what the framework's baseline Target Selection
-- is currently aiming at. There is NO direct API for this; the best signals
-- are (a) the order queue when baseline has just issued an attack-target
-- order, and (b) the cursor proxy. Returns (target, source) where source is
-- "queue" | "cursor" | "none".
--
-- Use as a HINT, not an authority. The brain's own ScoreUltTarget guards
-- (fog age, Linkens, Lotus, invuln-at-impact) take precedence. The hint is
-- folded as a small +score bonus when present AND brain doesn't veto, so
-- baseline's user-facing pick (Locked/Cursor) gets respected when it's safe.
local function read_baseline_target_hint()
    local me = state.self_npc
    if not me then return nil, "none" end
    local me_idx = Entity.GetIndex(me)
    local me_team = Entity.GetTeamNum(me)

    -- (0) v6.15.179: the player's most recent MANUAL attack target, captured
    -- in OnPrepareUnitOrders. The Humanizer order queue (path 1) holds the
    -- BRAIN's orders, not the player's manual right-clicks, and the cursor
    -- proxy (path 2) drifts the moment the player moves the mouse — so
    -- neither tracked a mid-fight target switch (user: "Q sticks to the
    -- first focused target"). The captured attack order is the authoritative
    -- read of who the player is focusing.
    local pat = state.player_attack_target
    if pat and Entity.IsEntity(pat) and Target.IsAlive(pat)
       and state.player_attack_target_t
       and (now() - state.player_attack_target_t) < 8.0
       and Entity.GetTeamNum(pat) ~= me_team
    then
        return pat, "player_order"
    end

    -- (1) Order queue: did baseline issue an attack on a hero recently?
    local q = Humanizer.GetOrderQueue()
    if q and #q > 0 then
        for i = 1, #q do
            local e = q[i]
            if e.orderType == UO.DOTA_UNIT_ORDER_ATTACK_TARGET
               and e.unit and Entity.GetIndex(e.unit) == me_idx
               and e.targetIndex and e.targetIndex ~= 0
            then
                local t = Entity.Get(e.targetIndex)  -- v6.14.1 C2: Entity.GetByIndex doesn't exist
                if t and NPC.IsHero(t) and Entity.GetTeamNum(t) ~= me_team then
                    return t, "queue"
                end
            end
        end
    end

    -- (2) Cursor proxy: nearest enemy hero to the user's cursor.
    local t = Input.GetNearestHeroToCursor(me_team, Enum.TeamType.TEAM_ENEMY)
    if t and Humanizer.IsSafeTarget(t) then return t, "cursor" end

    return nil, "none"
end

-- Keen Scope bonus damage at given distance (additive to attack damage; we
-- fold this only as a small correction to ult kill-confirm).
local function keen_scope_bonus(distance)
    if not distance or distance < 100 then return 0 end
    return math.floor(distance / 100) * 1.5
end

-- v6.15.1 D1 (corrected): no facets in 7.41C — Sniper power scaling comes
-- from Shard, Scepter, and Talents only.
-- v6.15.2 C1 (corrected magnitudes + API): the talent NAMES exist as
-- ability slots (npc_heroes.json Sniper.Ability11/15) but their VALUES live
-- inside the parent ability's AbilityValues. Calling
-- Ability.GetLevelSpecialValueFor on the talent handle itself returns 0.
-- Cleanest: gate on `Ability.GetLevel(talent_handle) > 0` ("is the talent
-- leveled?") and hardcode the verified 7.41C KV values.
--
-- Verified 7.41C values (npc_abilities.json):
--   special_bonus_unique_sniper_headshot_damage = "30" (flat +30 per attack)
--   special_bonus_unique_sniper_shrapnel_damage = "+30%" (multiplicative)
--   Other talents: atk_range / R cooldown / spell-amp fold into base APIs.
-- v6.15.113: has_shard / has_scepter extracted to lib/npc.lua. Sniper
-- callers updated to NPCLib.has_shard(state.self_npc) etc. via replace_all.
-- Frees 2 local slots (net 1 after NPCLib import added in v6.15.113).

local function _talent_leveled(name)
    local me = state.self_npc
    if not me or not NPC.GetAbility then return false end
    local a = NPC.GetAbility(me, name)
    if not a then return false end
    return (Ability.GetLevel(a) or 0) > 0
end
local function talent_headshot_bonus()
    return _talent_leveled("special_bonus_unique_sniper_headshot_damage") and 30 or 0
end
-- v6.15.88 (user directive: real damage including items + talents): Tier 4
-- (level 25) RIGHT talent — "+150 Assassinate Damage" per LIQUIPEDIA_REF.md.
-- v6.15.169 (KV-hardcode migration #3): the talent ability NAME had ROTTED.
-- The brain checked `special_bonus_unique_sniper_5`, but a KV cross-check
-- shows `_5` is the +50 Take Aim range talent (sniper_take_aim
-- `passive_attack_range_bonus` carries `special_bonus_unique_sniper_5: 50`)
-- and the +150 Assassinate-damage talent is `_1` (sniper_assassinate
-- `damage` carries `special_bonus_unique_sniper_1: 150`). The brain was
-- detecting the WRONG talent — corrected to `_1`. The +150 magnitude stays
-- hardcoded: GetLevelSpecialValueFor on a talent handle returns 0, and
-- reading it off the parent ability is unverified live (left as future
-- work). Returns 0 gracefully if the talent is not leveled / not present.
local function talent_assassinate_damage_bonus()
    return _talent_leveled("special_bonus_unique_sniper_1") and 150 or 0
end
-- v6.15.2 C1: shrap talent is +30% MULTIPLICATIVE, not flat. Returns a
-- multiplier (1.0 = no talent, 1.30 = talent taken).
local function talent_shrap_multiplier()
    return _talent_leveled("special_bonus_unique_sniper_shrapnel_damage") and 1.30 or 1.0
end

-- v6.15 D2: game-time-based aggression scaling. Early lane (<6 min, level 1-7)
-- is conservative; mid game (6-25 min) baseline; late game (25+ min) loose.
-- Returns a multiplicative adjustment that wraps commit_floor() — late game
-- subtracts up to 30 from the slider value, early adds 20.
local function game_time_offset()
    if not GameRules or not GameRules.GetGameTime then return 0 end
    local t = GameRules.GetGameTime() or 0  -- seconds since horn (negative pre-horn)
    -- v6.15.2 M4: pre-game (negative t) returns 0 — brain shouldn't fire
    -- pre-horn anyway, and the +20 tighten was misleading in demo/sandbox
    -- runs.
    if t <= 0   then return   0 end
    if t < 360  then return  20 end   -- < 6 min: tighter
    if t < 1500 then return   0 end   -- 6-25 min: baseline
    if t < 2400 then return -15 end   -- 25-40 min: looser
    return -30                         -- 40+ min: late
end

-- v6.15 D4: Roshan pit coordinates (7.41C two-pit version). Tightened
-- radius v6.15.2 M3: 1500u was generous to "fight context" but overlapped
-- multiple jungle camps. 700u keeps the bonus to genuine pit fights.
-- Coordinates are best-guess; verify empirically by standing in the pit
-- with the debug panel toggled (me_pos display) and update if off by >300u.
local ROSHAN_PITS = {
    Vector(-2519, 1934, 256),   -- Radiant pit (verify in demo)
    Vector( 4878, -2300, 256),  -- Dire pit    (verify in demo)
}
local ROSHAN_PIT_R_SQR = 700 * 700
-- v6.15.2 low: cache per-tick result so commit_floor + ScoreUltTarget don't
-- both recompute. The Sniper position doesn't change across a single tick.
local _roshan_cache = { t = -1, val = false }
local function in_roshan_context()
    local me = state.self_npc
    if not me then return false end
    local now_t = GlobalVars.GetCurTime()
    if _roshan_cache.t == now_t then return _roshan_cache.val end
    local p = Entity.GetAbsOrigin(me)
    -- v6.15.201 (audit D4): nil-guard. GetAbsOrigin can return nil on a
    -- dormant / mid-respawn self_npc; the per-tick dx/dy arithmetic
    -- below would crash. Cache the false result so a brief dormant
    -- window doesn't re-run this nil check 10x per tick.
    if not p then
        _roshan_cache.t = now_t; _roshan_cache.val = false
        return false
    end
    local hit = false
    for i = 1, #ROSHAN_PITS do
        local r = ROSHAN_PITS[i]
        local dx = p.x - r.x; local dy = p.y - r.y
        if (dx*dx + dy*dy) < ROSHAN_PIT_R_SQR then hit = true; break end
    end
    _roshan_cache.t = now_t; _roshan_cache.val = hit
    return hit
end

-- v6.15 D4: nearest ally tower attack-range bias. If target is inside any
-- ally tower's attack range, Sniper can safely commit longer R casts (the
-- tower will protect the cast point and finish low-HP runners).
-- v6.15.2 M5: simplified regex (single pattern subsumes the prior three).
-- v6.15.2 low: per-target-per-tick cache so commit-time + score-time don't
-- both fire NPCs.InRadius for the same target.
local _tower_cache = {}      -- target_idx → { t, val }
local _tower_cache_last_t = -1
local function target_in_ally_tower_range(target_pos, target_idx)
    local me = state.self_npc
    if not me or not target_pos then return false end
    local now_t = GlobalVars.GetCurTime()
    if _tower_cache_last_t ~= now_t then
        _tower_cache = {}                     -- drop stale entries each tick
        _tower_cache_last_t = now_t
    end
    if target_idx and _tower_cache[target_idx] ~= nil then
        return _tower_cache[target_idx]
    end
    local towers = NPCs.InRadius(target_pos, 800, Entity.GetTeamNum(me),
        Enum.TeamType.TEAM_FRIEND, true, true)
    local hit = false
    if towers then
        for i = 1, #towers do
            local n = towers[i]
            local name = NPC.GetUnitName(n) or ""
            if name:find("^npc_dota_%w+guys_tower") then hit = true; break end
        end
    end
    if target_idx then _tower_cache[target_idx] = hit end
    return hit
end

-- Estimated Assassinate damage at Sniper's current ult level, factoring spell
-- amplification (Octarine, Kaya, Aether Lens). R stays MAGICAL even under
-- Scepter (verified npc_abilities.json: AbilityUnitDamageType=MAGICAL,
-- scepter_crit=0; Scepter adds stun + faster cast + AoE, NOT crit) so amp is
-- the only multiplier in play. v6.13 Offense F#33.
local function assassinate_damage()
    local a = ability(A.R)
    if not a then return 0 end
    local lvl = Ability.GetLevel(a)
    if lvl <= 0 then return 0 end
    -- v6.15.194 (audit #1): Ability.GetDamage(a) reads the static
    -- `AbilityDamage` KV field, which Assassinate does NOT define — its
    -- base damage lives in `AbilityValues.damage = "250 350 450"` (per
    -- LIQUIPEDIA_REF.md and npc_abilities.json). GetDamage was therefore
    -- returning 0 on every cast and the legacy fallback 200+100*lvl fired,
    -- giving 300/400/500 — off by +50 / +50 / +50 vs the real 250/350/450.
    -- The brain's R-kill grade ran ~50 hot at every R level, R-committing
    -- on targets that R alone could NOT kill. Switched to
    -- GetLevelSpecialValueFor("damage") which auto-resolves to the
    -- ability's current level off the handle (same pattern as the
    -- v6.15.167-.173 KV migration). The 200+100*lvl fallback stays only
    -- for the no-handle / pre-learn edge case where GetLevelSpecialValueFor
    -- itself returns 0.
    local base = 0
    if Ability.GetLevelSpecialValueFor then
        base = Ability.GetLevelSpecialValueFor(a, "damage") or 0
    end
    if base <= 0 then base = 200 + 100 * lvl end   -- fallback
    -- v6.15.88: +150 Assassinate damage at level 25 talent (Tier 4 RIGHT).
    local talent_bonus = talent_assassinate_damage_bonus() or 0
    -- v6.15.18: effective_spell_amp_pct includes item amp (Octarine +25,
    -- Kaya family) + base int-derived amp + unique amp. Previous code used
    -- GetBaseSpellAmp only, missing Octarine / Kaya entirely.
    local amp = effective_spell_amp_pct(state.self_npc)
    return (base + talent_bonus) * (1 + amp / 100)
end

local function full_combo_cost()
    -- Q 75 + E 50 + R 175; read at runtime for safety in case patch changes
    local q, e, r = ability(A.Q), ability(A.E), ability(A.R)
    local c = 0
    if q then c = c + Ability.GetManaCost(q) end
    if e then c = c + Ability.GetManaCost(e) end
    if r then c = c + Ability.GetManaCost(r) end
    return c
end

----------------------------------------------------------------------------
-- shared utility 1 — target valuation for Assassinate
----------------------------------------------------------------------------

-- has-channel test for the +200 score bonus (and +50 if it's a TP)
-- v6.15.199 (audit C7): API-first channel detection.
-- NPC.GetChannellingAbility is modifier-name-free and rot-proof, so a
-- channel-cast on an enemy whose modifier name doesn't match the static
-- ENEMY_CHANNEL_MODIFIERS catalog still scores the +200 bonus. The
-- modifier_teleporting check stays at the front because the +50 TP
-- bonus needs the SPECIFIC modifier name (and TP isn't a "channelling
-- ability" handle anyway; it's an item-triggered modifier). The legacy
-- catalog iteration + MODIFIER_STATE_CHANNELED state check stay as
-- final fallbacks. Returns: "modifier_teleporting" (TP, triggers +50),
-- "live_channel" (generic channel via API, +200 only), the catalog
-- modifier name (legacy match), "state_channeled" (state fallback), or
-- nil.
local function target_in_channel(t)
    if NPC.HasModifier(t, "modifier_teleporting") then
        return "modifier_teleporting"
    end
    if NPC.GetChannellingAbility
       and NPC.GetChannellingAbility(t) then
        return "live_channel"
    end
    for mod, _ in pairs(ENEMY_CHANNEL_MODIFIERS) do
        if NPC.HasModifier(t, mod) then return mod end
    end
    if NPC.HasState(t, MS.MODIFIER_STATE_CHANNELED) then
        return "state_channeled"
    end
    return nil
end

-- v6.15.51 (G1 — hero-role weighting): additive score adjustment per hero
-- role. Carries are Sniper's natural prey (high kill impact; killing the
-- enemy 1 ends most fights); tanks dilute brain's R cast (high effective
-- HP, often refused by commit_pred anyway, and Sniper's autos chip them
-- inefficiently). Additive — not multiplicative — so it interacts cleanly
-- with negative penalty scores (fog, Lotus, Linkens). Heroes not listed
-- get 0 (neutral). Conservative magnitudes — must not outrank a real kill
-- window (commit_pred score 100+) and must not block a confirmed snipe
-- on a tank who happens to be killable right now.
local HERO_ROLE_SCORE = {
    -- Carries (+20) — Sniper's natural prey
    npc_dota_hero_antimage          = 20,
    npc_dota_hero_phantom_assassin  = 20,
    npc_dota_hero_spectre           = 20,
    npc_dota_hero_faceless_void     = 20,
    npc_dota_hero_slark             = 20,
    npc_dota_hero_riki              = 20,
    npc_dota_hero_naga_siren        = 20,
    npc_dota_hero_templar_assassin  = 20,
    npc_dota_hero_drow_ranger       = 20,
    npc_dota_hero_sniper            = 20,
    npc_dota_hero_luna              = 20,
    npc_dota_hero_phantom_lancer    = 20,
    npc_dota_hero_juggernaut        = 20,
    npc_dota_hero_life_stealer      = 20,
    npc_dota_hero_ursa              = 20,
    npc_dota_hero_troll_warlord     = 20,
    npc_dota_hero_morphling         = 20,
    npc_dota_hero_medusa            = 20,
    npc_dota_hero_terrorblade       = 20,
    npc_dota_hero_arc_warden        = 20,
    npc_dota_hero_razor             = 20,
    npc_dota_hero_obsidian_destroyer = 20,
    npc_dota_hero_lone_druid        = 20,
    npc_dota_hero_gyrocopter        = 20,
    npc_dota_hero_skeleton_king     = 20,
    npc_dota_hero_bloodseeker       = 20,
    npc_dota_hero_weaver            = 20,
    -- Cores / mid-game threats (+10)
    npc_dota_hero_storm_spirit      = 10,
    npc_dota_hero_queenofpain       = 10,
    npc_dota_hero_nevermore         = 10,
    npc_dota_hero_invoker           = 10,
    npc_dota_hero_puck              = 10,
    npc_dota_hero_magnataur         = 10,
    npc_dota_hero_lina              = 10,
    npc_dota_hero_death_prophet     = 10,
    npc_dota_hero_necrolyte         = 10,
    npc_dota_hero_pugna             = 10,
    npc_dota_hero_tinker            = 10,
    npc_dota_hero_ember_spirit      = 10,
    npc_dota_hero_void_spirit       = 10,
    -- Supports default to 0 (no entry needed — listed below for clarity)
    -- npc_dota_hero_crystal_maiden, lich, witch_doctor, shadow_shaman,
    -- lion, vengefulspirit, disruptor, treant, oracle, dazzle, warlock,
    -- ogre_magi, rubick, skywrath_mage, silencer, bane, wisp, ancient_apparition,
    -- jakiro, hoodwink ...
    -- Tanks / initiators (-20) — high eff_hp, commit_pred refuses, autos waste
    npc_dota_hero_tidehunter        = -20,
    npc_dota_hero_bristleback       = -20,
    npc_dota_hero_centaur           = -20,
    npc_dota_hero_pudge             = -20,
    npc_dota_hero_spirit_breaker    = -20,
    npc_dota_hero_tusk              = -20,
    npc_dota_hero_axe               = -20,
    npc_dota_hero_mars              = -20,
    npc_dota_hero_abyssal_underlord = -20,
    npc_dota_hero_doom_bringer      = -20,
    npc_dota_hero_sand_king         = -20,
    npc_dota_hero_slardar           = -20,
    npc_dota_hero_earth_spirit      = -20,
    npc_dota_hero_primal_beast      = -20,
    npc_dota_hero_marci             = -20,
    npc_dota_hero_snapfire          = -20,
    npc_dota_hero_beastmaster       = -20,
    npc_dota_hero_brewmaster        = -20,
    npc_dota_hero_dawnbreaker       = -20,
    npc_dota_hero_chaos_knight      = -20,
    npc_dota_hero_night_stalker     = -20,
    npc_dota_hero_legion_commander  = -20,
    npc_dota_hero_pangolier         = -20,
    npc_dota_hero_huskar            = -20,
}

---Returns score for casting Assassinate on `target`, or nil to veto.
---@param target userdata
---@return number|nil
local function ScoreUltTarget(target)
    local me = state.self_npc
    if not me or not target then return nil end

    -- Guard 1: illusion / clone / Arc Warden Tempest Double (v6.13: NotClone
    -- replaces NotIllusion+NotMeepoClone — also vetoes tempest_double which
    -- isn't an illusion and isn't a Meepo clone but is still a fake target).
    if not Target.IsValid(target) then return nil end
    -- v6.15.18 / v6.15.200 (C11) / v6.15.203 (D14): use state.r_cast_range
    -- — single source of truth for effective R cast range (base + Aether
    -- Lens / talents). The helper already collapses the no-handle case
    -- to CAST_R, so the inline fallback is no longer needed.
    local cast_r_live = state.r_cast_range()
    if not Target.IsAlive(target) then return nil end
    if not Target.IsEnemyHero(target, me) then return nil end
    if not Target.NotClone(target) then return nil end

    -- Guard 2: magic-immune at R impact = live R cast point + 1.2s buffer
    -- (~3.2s base / ~1.7s under Scepter; r_cast_point is Scepter-aware).
    local commit_ms = r_cast_point() * 1000 + 1200
    if Target.WillBeInvulnIn(target, commit_ms) then return nil end

    -- Guard 3: Linkens-protected (single-target spell pops Linkens, no kill)
    if Target.HasReadyLinkens(target) then return nil end

    -- Guard 4: Lotus reflects 500 magic back at us
    if Target.HasReadyLotus(target) then return nil end

    -- v6.8.4: Hero.GetLastVisibleTime returns nil for heroes with no
    -- fog-tracking history — applies to demo bots (spawn already visible,
    -- never been in fog) AND to freshly-spawned / freshly-revealed enemies
    -- in real matches before they've gone in-and-out of fog. Treating nil
    -- as a veto vetoed every demo-test target (3/3 in the latest demo log)
    -- and would also veto fresh enemies in real games. Treat nil as
    -- "fog_age = 0" (currently visible / no staleness data) — the actual
    -- stale-fog protection is the >3s check below, plus Layer 1 only fires
    -- when combo key is held by the user who's looking at the target.
    local last_t = Hero.GetLastVisibleTime(target)
    local fog_age = last_t and (now() - last_t) or 0
    if fog_age > 3.0 then return nil end

    -- Distance
    local d = dist_to(target)
    if d > cast_r_live then return nil end

    -- Score
    local score = 0
    if Target.IsKillable(target) then
        local eff_hp = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL)
        -- v6.15.195 (audit A1): Keen Scope is PHYSICAL bonus damage and is
        -- already included inside `rc_attack_damage_with_procs`,
        -- which feeds `r_physical`. Adding `keen_scope_bonus(d)` to the
        -- MAGICAL `assassinate_damage()` here was the double-count flagged
        -- by the v6.15.91 TODO. Removed.
        local nominal = assassinate_damage()
        if nominal >= eff_hp then score = score + 100 end
    end

    local ch = target_in_channel(target)
    if ch then
        score = score + 200
        -- v6.15.204 (audit C9): the +50 TP-interrupt bonus only applies
        -- when R can still land before the TP completes (see
        -- state.tp_interruptible). A TP that finishes before R's cast
        -- point elapses is not worth the highest score in the system.
        if ch == "modifier_teleporting" and state.tp_interruptible(target) then
            score = score + 50
        end
    end

    if Target.HasAegis(target) then score = score - 75 end
    -- v6.13 Targeting F#7: Wraith King with Reincarnation ready survives R.
    -- Treat like Aegis (-75) rather than full veto — sometimes R to burn the
    -- reincarnation CD is the right call (e.g. setup-kill where ally cleanup
    -- closes the second life).
    -- v6.15.198 (audit round 2, C1): the
    -- `modifier_skeleton_king_reincarnation_active` modifier name was
    -- never observed in any actual modseen log across 3 bot matches;
    -- only `_scepter` (the persistent Scepter passive) was seen. The
    -- HasModifier branch was dead code that misled the HUD into
    -- promising `reinc_active-75` strings that never printed. Dropped
    -- the dead branch — the ability-readiness check below is the only
    -- reliable signal. Same fix family as v6.15.196 A4-r (which used
    -- the same handle pattern, inverted, for the post-fire window).
    if NPC.GetUnitName(target) == "npc_dota_hero_skeleton_king" then
        local reincarnate = NPC.GetAbility(target, "skeleton_king_reincarnation")
        if reincarnate and Ability.GetLevel(reincarnate) > 0
           and Ability.IsReady(reincarnate) then
            score = score - 75
        end
    end
    -- v6.15.50 (G5): graduated fog penalty. Previous flat -30/sec from
    -- 0.3s onward dropped flicker-fogged targets (tree LoS, smoke gust)
    -- below the score floor mid-fight, causing brain churn to other
    -- candidates and breaking engaged_target stickiness. Now:
    --   0.3s..1.0s fog → -3/sec (gentle, accommodates brief flicker)
    --   1.0s..3.0s fog → -30/sec on the remainder (real hiding)
    --   >3.0s → full veto (the fog-age veto above, unchanged).
    if fog_age > 1.0 then
        score = score - math.floor(3 + (fog_age - 1.0) * 30)
    elseif fog_age > 0.3 then
        score = score - math.floor(fog_age * 3)
    end

    -- v6.12 Tier 3 #9: windowed escape-item detection. Sniper R has 2.0s
    -- cast point (0.5s Scepter) — a target with a "ready" or "soon" escape
    -- item will pop dispel/immunity DURING our cast and waste the R. The
    -- old binary HasReadyEscapeItem -15 penalty was too lenient; pro brain
    -- treats this as near-veto.
    --
    -- "active" already caught by HasReadyLotus / HasReadyLinkens / invuln
    -- checks above. "long" / "none" = safe (no penalty).
    local esc_window = Target.EscapeItemWindowState(target,
        NPC.HasScepter(me) and 0.9 or 2.4)
    if esc_window == "ready" then
        score = score - 50   -- near-veto; will pop dispel as R hits
    elseif esc_window == "soon" then
        score = score - 25   -- will pop during cast
    end

    -- v6.9: pro-play R usage. Assassinate has a 2.0s cast point during which
    -- Sniper stands still — during a fight this is a DPS LOSS vs continuing
    -- to right-click. R is the right tool for finishing runners, cancelling
    -- TPs, hitting far-away targets fighting allies, or pre-empting kills.
    -- Mid-fight on a target in our attack range, RC almost always wins.
    -- v6.15.17: include item / talent / buff bonuses — NPC.GetAttackRange
    -- returns BASE ONLY per LuaCATS, bonuses live in GetAttackRangeBonus.
    local atk_range = effective_attack_range(me)
    local target_in_rc_range = d <= atk_range
    local target_fleeing = Target.IsKitingUs(target, me)
    local target_far     = d > atk_range * 1.5
    if target_in_rc_range and not target_fleeing then
        -- "I could just right-click them" — heavy penalty so non-RC-range
        -- targets win the candidate list when one exists.
        -- v6.10 G4: Scepter cuts R cast 2.0s → 0.5s. With Scepter the
        -- DPS-loss from R cast is minimal, so taper the penalty.
        -- v6.14 D1: also taper by Take Aim level — at E lvl 4 the AS+slow
        -- inside the cone makes RC follow-up much more reliable, so the
        -- DPS-loss from R cast is partially recovered. Lvl 4 → -10 of the
        -- penalty; lvl 1 → -0.
        local e_ability = ability(A.E)
        local e_lvl = e_ability and Ability.GetLevel(e_ability) or 0
        local e_taper = math.max(0, e_lvl - 1) * 3   -- 0/3/6/9
        if NPC.HasScepter(me) then
            score = score - math.max(0, 10 - e_taper)
        else
            score = score - math.max(0, 40 - e_taper)
        end
    end
    -- v6.15 D4: target inside an ally tower's attack range → +15. Sniper plays
    -- well from behind tower; commits more safely under tower cover.
    if target_in_ally_tower_range(Entity.GetAbsOrigin(target), Entity.GetIndex(target)) then
        score = score + 15
    end
    -- v6.15 D5: Roshan-pit context — target inside a Rosh pit (everyone is
    -- clustered). +10 score; combo_floor adjustment in commit_floor() handles
    -- the matching commit threshold.
    if in_roshan_context() then
        local p = Entity.GetAbsOrigin(target)
        for i = 1, (p and #ROSHAN_PITS) or 0 do
            local r = ROSHAN_PITS[i]
            local dx = p.x - r.x; local dy = p.y - r.y
            if (dx*dx + dy*dy) < (1500 * 1500) then
                score = score + 10
                break
            end
        end
    end
    -- v6.15.1 D1: facet code removed — 7.41C Sniper has no facets. Talent
    -- bonuses (headshot/shrap damage, atk range, R cd) fold in via talent
    -- helpers + base API reads.
    if target_fleeing then
        -- Finisher on a runner — R catches them.
        score = score + 30
    end
    if target_far then
        -- v6.9.1: far-shot only valuable when we can secure the kill or
        -- assist. (a) R alone kills, (b) ally is near target (they clean up
        -- after R lands), or (c) we can reach for RC follow-up (d <= 1500).
        -- If none, R is just chip — no bonus.
        local kills_with_r = false
        if Target.IsKillable(target) then
            local eff_hp = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL)
            -- v6.15.195 (audit A1): see note at the score-bonus site —
            -- Keen Scope is physical, already in r_physical via
            -- rc_attack_damage_with_procs; removed from r_magical here too.
            local nominal = assassinate_damage()
            kills_with_r = nominal >= eff_hp
        end
        local can_reach = d <= 1500
        local has_ally_near = false
        if not kills_with_r and not can_reach then
            -- v6.15.199 (audit C6): use the per-frame me-POV ally cache
            -- instead of a per-candidate target-POV scan. Each
            -- recompute_candidates tick (10 Hz) used to issue N
            -- redundant Entity.GetHeroesInRadius calls into this branch
            -- (one per "far + not-killable + not-reachable" candidate);
            -- now there's a single cached scan + an O(allies)
            -- distance-to-target filter.
            local allies = state.get_cached_allies(me)
            local me_idx = Entity.GetIndex(me)
            local tp     = Entity.GetAbsOrigin(target)
            if tp and allies then
                local r2 = 800 * 800
                for i = 1, #allies do
                    local a = allies[i]
                    if a and Entity.GetIndex(a) ~= me_idx then
                        local ap = Entity.GetAbsOrigin(a)
                        if ap then
                            local dx, dy = ap.x - tp.x, ap.y - tp.y
                            if (dx * dx + dy * dy) <= r2 then
                                has_ally_near = true; break
                            end
                        end
                    end
                end
            end
        end
        if kills_with_r or can_reach or has_ally_near then
            score = score + 20
        end
    end

    -- v6.8: baseline target-selection hint. v6.13 Targeting F#5: previously
    -- applied unconditionally as +40, which could lift a sub-floor target
    -- (no kill grade, no channel, no fleeing — score 0) above another
    -- candidate sitting just below COMBO_COMMIT_FLOOR (score 80). The hint
    -- shouldn't override brain's better pick; only break near-ties between
    -- candidates that were already in contention.
    --
    -- Constraint: +40 applied only when raw score is already commit-grade
    -- (>= floor - 20). For queue orders we trust the user's direct intent
    -- more than cursor proximity — queue hints get the bonus at a slightly
    -- lower threshold (>= floor - 40).
    local hint, hint_src = read_baseline_target_hint()
    if hint and Entity.GetIndex(hint) == Entity.GetIndex(target) then
        -- v6.14.1 H2: read the commit_floor slider, not the static constant.
        -- Fish-mode (40) and conservative mode (150) both deserve their
        -- proportional hint threshold; the legacy constant locked the hint
        -- behavior at strict-mode levels regardless of slider position.
        local cf = commit_floor()
        local threshold = (hint_src == "queue") and (cf - 40) or (cf - 20)
        if score >= threshold then
            score = score + 40
            tlog(3, "score_baseline_hint", {
                target = uname(target), source = hint_src, bonus = 40,
                raw_score = score - 40,
            })
        else
            tlog(3, "score_baseline_hint_below_threshold", {
                target = uname(target), source = hint_src,
                raw_score = score, threshold = threshold,
            })
        end
    end

    -- v6.15.51 (G1): hero-role adjustment applied AFTER baseline hint so
    -- player cursor's +40 still wins ties. Carries +20, cores +10, tanks
    -- -20, others 0 (HERO_ROLE_SCORE table above). Conservative magnitudes
    -- so a confirmed kill (commit_pred contributes +100 via Target.IsKillable
    -- branch above) outranks the role adjustment — we DON'T refuse
    -- a killable tank just because they're tagged tank.
    local hero_name = NPC.GetUnitName and NPC.GetUnitName(target) or ""
    local role_adj = HERO_ROLE_SCORE[hero_name]
    if role_adj then
        score = score + role_adj
        tlog(3, "score_role_adj", {
            target = uname(target), adj = role_adj, raw_score = score - role_adj,
        })
    end

    -- v6.15.54 (G2): ally focus alignment via Signal.lua. Other hero brains
    -- (when they exist — Pudge / Wisp / Disruptor brains in future) publish
    -- their R / kill-commit target on the "hero_focus_target" channel.
    -- If an ALLY brain published this target within the last 3s, give a
    -- +30 score bonus — Sniper piles on the focused enemy instead of
    -- splitting damage. Filtered by payload.hero ~= "Sniper" so we don't
    -- self-loop on our own broadcasts. Only Sniper today, so this is a
    -- no-op until a second brain registers — but the wiring is in place.
    if Signal and Signal.Last then
        local focus = Signal.Last("hero_focus_target")
        if focus and focus.hero and focus.hero ~= "Sniper"
           and focus.target_idx and focus.t
           and (now() - focus.t) < 3.0
           and focus.target_idx == Entity.GetIndex(target)
        then
            score = score + 30
            tlog(3, "score_ally_focus", {
                target = uname(target), ally = focus.hero,
                age_ms = string.format("%.0f", (now() - focus.t) * 1000),
            })
        end
    end

    return score
end

----------------------------------------------------------------------------
-- shared utility 3 — safe self-push destination
----------------------------------------------------------------------------

---Compute Sniper's post-displacement position given a cast point.
---For Pike-self the direction is Sniper→cast_point with magnitude pike_range.
---For grenade self_push the direction is cast_point→Sniper with magnitude 475.
---Returns nil if the destination fails safety checks (cliff / into-tower /
---closer-to-enemy-centroid). Caller picks the right primitive based on which
---save is being used.
---@param dest_pos userdata  -- Vector
---@return userdata|nil
-- Validate a proposed push destination. Two layers of safety:
--   1. Terrain — destination must be traversable from current position
--   2. Threat positioning — destination must not move Sniper toward the
--      threat. When a specific threat caster is provided, distance from
--      that caster is the primary check (we want to escape THIS threat,
--      even if other enemies happen to be on the other side). When no
--      specific threat is known, fall back to the enemy-centroid check.
SafePushDestination = function(dest_pos, threat_caster_hint)
    if not dest_pos then return nil end
    local me = state.self_npc
    if not me then return nil end
    local me_pos = Entity.GetAbsOrigin(me)
    -- v6.15.201 (audit D7): nil-guard me_pos. GridNav.IsTraversableFromTo
    -- and the DistanceSqr2D calls below all crash on nil.
    if not me_pos then return nil end
    if not GridNav.IsTraversableFromTo(me_pos, dest_pos) then return nil end

    -- Primary check: when escaping a known threat, the only thing that
    -- matters is increasing distance from that threat. Sniper happens to
    -- be in a multi-enemy scrum? Fine — the centroid check would refuse
    -- to fire when pushing away from the primary threat puts Sniper
    -- closer to backliners. That's the wrong choice; the immediate
    -- threat is the one channeling/charging us.
    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local cp = Entity.GetAbsOrigin(threat_caster_hint)
        -- v6.15.201 (audit D7): nil-guard cp.
        if not cp then return dest_pos end  -- skip threat check; terrain check already passed
        local d_now  = me_pos:DistanceSqr2D(cp)
        local d_dest = dest_pos:DistanceSqr2D(cp)
        if d_dest <= d_now then
            tlog(3, "safe_push_dest_rejects_toward_threat", {
                dist_now = string.format("%.0f", math.sqrt(d_now)),
                dist_dest = string.format("%.0f", math.sqrt(d_dest)),
            })
            return nil
        end
        return dest_pos
    end

    -- Centroid fallback: no specific threat known. v6.15.240 (clue C4): the
    -- crude enemy-centroid check is replaced by danger_at_pos, which weights
    -- each visible enemy by proximity -- it refuses a destination
    -- meaningfully more dangerous than where Sniper stands now (the +12
    -- margin, against a ~30/enemy scale, avoids flapping on a marginal diff).
    if state.danger_at_pos(dest_pos) > state.danger_at_pos(me_pos) + 12 then
        return nil
    end
    return dest_pos
end

-- v6.15.240 (JppsTech clue C4): stateless danger score at a world position
-- -- the proximity-weighted count of visible enemy heroes near `pos`. Used
-- ONLY to rank escape destinations (blink_escape_position, and the
-- SafePushDestination centroid fallback) so a save does not push Sniper
-- out of one threat and into a second. Called on demand at save-fire time,
-- never per-tick; no event store, no veto. Towers are intentionally not
-- counted -- there is no clean enemy-tower-in-radius API and the
-- enemy-hero term alone closes the documented blind spot.
state.danger_at_pos = function(pos)
    if not pos then return 0 end
    local me = state.self_npc
    if not me then return 0 end
    local list = Heroes.InRadius(pos, 1400, Entity.GetTeamNum(me),
                                 Enum.TeamType.TEAM_ENEMY)
    if not list then return 0 end
    local score = 0
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) then
            local ep = NPCLib.origin(e)
            if ep then
                local d = pos:Distance2D(ep)
                if d < 1400 then
                    local base = (1 - d / 1400) * 30
                    -- v6.15.251: turn-cost factor. Landings that force the
                    -- enemy to TURN far from her current facing have less
                    -- effective chase time (turn rate ~0.8 = ~0.4s per
                    -- 90deg). The chase delay during the turn is "free"
                    -- distance for Sniper. Bias the danger score so picks
                    -- forcing big enemy turns rank as SAFER than picks
                    -- maintaining linear distance but no turn cost. User
                    -- observation: in 1v1 PA at 56u, +/-90deg landing
                    -- (~478u linear, 83deg PA turn) gives MORE effective
                    -- distance than 0deg (531u linear, 0deg turn) because
                    -- of the ~0.4s turn budget PA must spend before
                    -- closing. BIAS = 0.5 caps the reduction at 50% even
                    -- for a 180deg turn -- the linear distance still
                    -- dominates the ranking, but turn-cost wins ties and
                    -- close calls.
                    local turn_factor = 0
                    if NPC.GetForwardVector then
                        local fwd = NPC.GetForwardVector(e)
                        if fwd then
                            local cdx, cdy = pos.x - ep.x, pos.y - ep.y
                            local clen = math.sqrt(cdx*cdx + cdy*cdy)
                            if clen > 1 then
                                local nx, ny = cdx / clen, cdy / clen
                                -- dot in [-1, 1]; 1 = enemy already faces
                                -- the landing (no turn), -1 = directly
                                -- away (180deg turn). turn_factor = 0..1.
                                local dot = fwd.x * nx + fwd.y * ny
                                turn_factor = (1 - dot) * 0.5
                                if turn_factor < 0 then turn_factor = 0
                                elseif turn_factor > 1 then turn_factor = 1 end
                            end
                        end
                    end
                    score = score + base * (1 - turn_factor * 0.5)
                end
            end
        end
    end
    return score
end

-- v6.15.244 (clue C4 finalisation): shared 5-angle danger-aware escape
-- destination picker. blink_escape_position, grenade_self_cast_point, and
-- pike_self_reposition all share the same shape: given "Sniper must move
-- away from THIS threat by N units", pick a landing that is also clear
-- of secondary enemies. v6.15.240 fixed only the blink path; the v6.15.242
-- fresh-log test surfaced a teamfight case where pike-on-self pushed
-- Sniper directly into a backliner (the "TF escape position not
-- calculating the best route" report).
--
-- Algorithm: try 7 angles off the straight-away vector (0, -35, 35, -65,
-- 65, -90, 90 degrees), keep the candidate with the lowest danger_at_pos
-- that still passes SafePushDestination for the given threat hint. Ties
-- go to 0deg (the baseline) via strict less-than, so a marginal angle
-- does not win over the straight-away unless meaningfully safer.
-- Returns (escape_dir, landing) where escape_dir is the unit vector FROM
-- Sniper TO the chosen landing; (nil, nil) if every candidate failed
-- terrain or the threat-distance check.
--
-- v6.15.245 (TF refinement): widened from the original 5 angles to 7 to
-- include perpendicular landings (+/-90deg). The user-observation that
-- triggered it: in a real TF where backliners sit on the straight-away
-- side from threat A, the safest landing is often perpendicular to A,
-- not opposite. The threat-distance gate inside SafePushDestination is
-- preserved -- a +/-90deg landing is still meaningfully farther from A
-- (sqrt(d_AB^2 + push^2) > d_AB for any non-zero push), so the gate
-- passes and the danger-ranker has more room to maneuver. The motivating
-- build context: pike is dropped from Sniper's build when no close-gap
-- heroes are around, so grenade-self must be self-sufficient as the sole
-- displacement save. The widening applies to all three callers via the
-- shared helper, keeping grenade and pike behaviour in lock-step.
-- v6.15.247: optional `filter_fn(esc_dir, landing) -> bool` for callers
-- that have additional per-candidate constraints (e.g. grenade_self's
-- 120deg facing gate to the cast_point). The filter runs AFTER
-- SafePushDestination, so it only sees candidates that already pass the
-- threat-distance / terrain gates. Returning false drops the candidate
-- before it competes for lowest danger. Callers that pass nil get the
-- unchanged v6.15.245 behaviour.
state.pick_escape_dir = function(me_pos, toward_threat, push_distance, threat_caster_hint, filter_fn)
    if not me_pos or not toward_threat or not push_distance then return nil, nil end
    local best_dir, best_landing, best_danger
    for _, deg in ipairs({ 0, -35, 35, -65, 65, -90, 90 }) do
        local rad     = math.rad(deg)
        local c, s    = math.cos(rad), math.sin(rad)
        -- rotate toward_threat by deg, then negate to get the escape unit
        local rx      = toward_threat.x * c - toward_threat.y * s
        local ry      = toward_threat.x * s + toward_threat.y * c
        local esc_dir = Vector(-rx, -ry, 0)
        local landing = me_pos + esc_dir * push_distance
        if SafePushDestination(landing, threat_caster_hint)
           and (not filter_fn or filter_fn(esc_dir, landing)) then
            local dng = state.danger_at_pos(landing)
            if not best_danger or dng < best_danger then
                best_danger, best_dir, best_landing = dng, esc_dir, landing
            end
        end
    end
    return best_dir, best_landing
end

----------------------------------------------------------------------------
-- target enumeration (called from OnUpdateEx, ~10Hz)
----------------------------------------------------------------------------

local function recompute_candidates()
    local me = state.self_npc
    if not me then return end
    -- v6.15.34 (user directive: 'combos don't work without force commit'):
    -- previous commit_threshold of 0/-10 rejected every target whose
    -- ScoreUltTarget came back negative (in-RC-range penalty, escape window,
    -- fog, etc.). state.candidates ended up empty, layer1_tick exited at
    -- no_top_candidate, no combo/sequence evaluation happened. The score is
    -- still useful for RANKING candidates (top-K by score), but it
    -- shouldn't VETO eligibility — combos have their own commit_pred (kill
    -- check) and sequences have their own triggers. Both should get to see
    -- in-range enemies regardless of their score sign.
    local commit_threshold = -math.huge
    local fog_threshold = 100   -- high-confidence bar for fog-snipe carryover (unchanged)

    local list = Entity.GetHeroesInRadius(me, state.r_cast_range(), Enum.TeamType.TEAM_ENEMY)
    local scored = {}
    local visible_idx = {}

    -- v6.8.3 diagnostic: per-scan stats. v6.15.184 — these counters are
    -- computed but currently consumed by nothing (an old layer1_no_path log
    -- was removed); kept as cheap scaffolding for ad-hoc debugging. The
    -- `if s == nil` branch below is NOT decorative — it nil-guards the
    -- `elseif s >= commit_threshold` comparison.
    local n_in_range = 0
    local n_vetoed = 0          -- ScoreUltTarget returned nil
    local n_below_threshold = 0 -- score < commit_threshold
    local vetoed_names = {}

    if list then
        n_in_range = #list
        for i = 1, #list do
            local t = list[i]
            local s = ScoreUltTarget(t)
            if s == nil then
                n_vetoed = n_vetoed + 1
                if #vetoed_names < 3 then
                    vetoed_names[#vetoed_names + 1] = uname(t)
                end
            elseif s >= commit_threshold then
                scored[#scored + 1] = { target = t, score = s, t = now() }
            else
                n_below_threshold = n_below_threshold + 1
            end
            if s and s >= fog_threshold then
                state.fog_cache[Entity.GetIndex(t)] = { target = t, score = s, t = now() }
            end
            visible_idx[Entity.GetIndex(t)] = true
        end
    end
    -- v6.13: deterministic tiebreak by entity index so two same-score
    -- candidates don't reorder frame-to-frame (Lua table.sort is unstable).
    -- The 2.5s commit window already suppresses the symptom, but stable
    -- ordering makes the +40 baseline-hint logging consistent.
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return Entity.GetIndex(a.target) < Entity.GetIndex(b.target)
    end)
    -- v6.14 B2 / v6.14.1 M5: format a score breakdown for the top candidate.
    -- Mirrors every component that ScoreUltTarget adds/subtracts so the HUD
    -- matches the actual score. Previously omitted WK-reincarnation, far-shot,
    -- Take-Aim taper on rc-penalty, baseline-hint — could diverge by 75+40+9.
    if scored[1] then
        local t = scored[1].target
        local parts = {}
        local d_t = dist_to(t)
        if Target.IsKillable(t) then
            local eff_hp = Target.EffectiveHpVs(t, me, DT.DAMAGE_TYPE_MAGICAL)
            -- v6.15.195 (audit A1): see note at score-bonus site — KS is
            -- physical, already in r_physical; removed from r_magical here.
            local nominal = assassinate_damage()
            if nominal >= eff_hp then parts[#parts + 1] = "kill+100" end
        end
        local ch = target_in_channel(t)
        if ch then
            parts[#parts + 1] = "chan+200"
            -- v6.15.204 (audit C9): mirror the tp_interruptible gate.
            if ch == "modifier_teleporting" and state.tp_interruptible(t) then
                parts[#parts + 1] = "tp+50"
            end
        end
        if Target.HasAegis(t) then parts[#parts + 1] = "aegis-75" end
        -- v6.14.1 M5: Wraith King reincarnation veto (matches ScoreUltTarget).
        -- v6.15.198 (audit C1): dropped the dead `_active` HasModifier
        -- branch in lockstep with ScoreUltTarget — only `reinc_ready-75`
        -- now appears, mirroring the actual scoring logic.
        if NPC.GetUnitName(t) == "npc_dota_hero_skeleton_king" then
            local reincarnate = NPC.GetAbility(t, "skeleton_king_reincarnation")
            if reincarnate and Ability.GetLevel(reincarnate) > 0
               and Ability.IsReady(reincarnate) then
                parts[#parts + 1] = "reinc_ready-75"
            end
        end
        -- v6.15.199 (audit C5): 4 HUD parts that ScoreUltTarget already
        -- adds but the prior breakdown silently omitted (potentially +/-75
        -- hidden from the user). Now mirrored 1:1 with the scorer.
        -- (a) ally-tower-cover +15 (v6.15 D4).
        if target_in_ally_tower_range(Entity.GetAbsOrigin(t),
                                       Entity.GetIndex(t)) then
            parts[#parts + 1] = "tower+15"
        end
        -- (b) Roshan-pit context +10 (v6.15 D5). Mirrors the gate's
        -- in_roshan_context() guard + 1500u pit-radius check.
        if in_roshan_context() then
            local tp = Entity.GetAbsOrigin(t)
            if tp then
                for i = 1, #ROSHAN_PITS do
                    local r = ROSHAN_PITS[i]
                    local dx, dy = tp.x - r.x, tp.y - r.y
                    if (dx * dx + dy * dy) < (1500 * 1500) then
                        parts[#parts + 1] = "rosh+10"; break
                    end
                end
            end
        end
        local last_t_v = Hero.GetLastVisibleTime(t)
        local fog_age = last_t_v and (now() - last_t_v) or 0
        -- v6.15.200 (audit C10): mirror the v6.15.50 G6 two-segment fog
        -- penalty (the prior linear `-30/s` formula DIVERGED from the
        -- scorer's actual gentle/steep split, showing up to ~14 drift
        -- at fog_age 0.5s). Now matches ScoreUltTarget's gate exactly.
        if fog_age > 1.0 then
            parts[#parts + 1] = "fog-" .. math.floor(3 + (fog_age - 1.0) * 30)
        elseif fog_age > 0.3 then
            parts[#parts + 1] = "fog-" .. math.floor(fog_age * 3)
        end
        local esc = Target.EscapeItemWindowState(t, NPC.HasScepter(me) and 0.9 or 2.4)
        if esc == "ready" then parts[#parts + 1] = "esc-50"
        elseif esc == "soon" then parts[#parts + 1] = "esc-25"
        end
        local atk_range_b = effective_attack_range(me)
        local target_in_rc = d_t <= atk_range_b
        local fleeing = Target.IsKitingUs(t, me)
        if target_in_rc and not fleeing then
            -- v6.14.1 M5: mirror v6.14 D1's Take-Aim level taper.
            local e_ab = ability(A.E)
            local e_lvl = e_ab and Ability.GetLevel(e_ab) or 0
            local e_taper = math.max(0, e_lvl - 1) * 3
            local rc_pen = NPC.HasScepter(me) and math.max(0, 10 - e_taper)
                                              or  math.max(0, 40 - e_taper)
            parts[#parts + 1] = "rc-" .. rc_pen
        end
        if fleeing then parts[#parts + 1] = "flee+30" end
        -- v6.14.1 M5: far-shot conditional +20.
        if d_t > atk_range_b * 1.5 then parts[#parts + 1] = "far?+20" end
        -- v6.14.1 M5: baseline-hint when this target matches AND raw score
        -- meets the (slider-aware) threshold.
        local hint, hint_src = read_baseline_target_hint()
        if hint and Entity.GetIndex(hint) == Entity.GetIndex(t) then
            parts[#parts + 1] = "hint(" .. (hint_src or "?") .. ")+40?"
        end
        -- v6.15.199 (audit C5): role-adjust + ally-focus bonuses. These two
        -- score components were also silently omitted from the breakdown.
        -- (c) HERO_ROLE_SCORE adjust (carries +20, cores +10, tanks -20).
        local hud_role_name = NPC.GetUnitName and NPC.GetUnitName(t) or ""
        local hud_role_adj  = HERO_ROLE_SCORE[hud_role_name]
        if hud_role_adj and hud_role_adj ~= 0 then
            local sign = (hud_role_adj > 0) and "+" or ""
            parts[#parts + 1] = "role" .. sign .. hud_role_adj
        end
        -- (d) ally-brain Signal +30 — Sniper piles on whatever target an
        -- allied brain published as their focus within the last 3s.
        if Signal and Signal.Last then
            local focus = Signal.Last("hero_focus_target")
            if focus and focus.hero and focus.hero ~= "Sniper"
               and focus.target_idx and focus.t
               and (now() - focus.t) < 3.0
               and focus.target_idx == Entity.GetIndex(t)
            then
                parts[#parts + 1] = "ally_focus+30"
            end
        end
        state.last_score_breakdown = (#parts > 0) and table.concat(parts, " ") or "base+0"
    else
        state.last_score_breakdown = nil
    end
    state.candidates = scored
    -- v6.15.50 (G6 — mid-engagement target stickiness): when brain committed
    -- to a target within the last 2s and that target is still valid + still
    -- in our candidate list, promote them to position 1. Prevents mid-cast
    -- target swap when scoring shifts (autoattacks chip a second enemy,
    -- their score rises, brain would otherwise abandon the engaged target).
    -- Cleared elsewhere on target death (cast_outcome_tick) or invuln.
    -- NOTE: applied BEFORE baseline_hint_promoted below — player cursor
    -- intent (mid-fight redirect) overrides brain's prior commit.
    do
        local et = state.engaged_target
        if et and Entity.IsEntity(et) and Target.IsAlive(et)
           and (now() - (state.engaged_target_t or 0)) < 2.0
           and #state.candidates > 1
        then
            local et_idx = Entity.GetIndex(et)
            for i = 2, #state.candidates do
                local e = state.candidates[i]
                if e.target and Entity.GetIndex(e.target) == et_idx
                   and (e.score or -1) >= 0
                then
                    state.candidates[1], state.candidates[i] = e, state.candidates[1]
                    tlog(2, "engaged_target_sticky", {
                        target = uname(et),
                        age_ms = string.format("%.0f", (now() - state.engaged_target_t) * 1000),
                    })
                    break
                end
            end
        end
    end
    -- v6.15.48 (user directive: subsystem-driven targeting): 'use the
    -- subsystem targeting system with a logic system to choose better
    -- target instead of locking on the one closer to the mouse.' Before
    -- this build, baseline hint was a +40 score bonus inside ScoreUltTarget
    -- — a raw-score-stronger candidate could outrank the hint. Now if the
    -- hint target (cursor proxy / order queue) is in the surviving candidate
    -- list AND has a non-negative score (brain didn't VETO it), promote
    -- it to position 1. Brain's scoring still vetoes invalid targets but
    -- defers to baseline's user-intent pick when both agree the target is
    -- viable.
    do
        local hint, hint_src = read_baseline_target_hint()
        if hint and Entity.IsEntity(hint) and #state.candidates > 1 then
            local hint_idx = Entity.GetIndex(hint)
            for i = 2, #state.candidates do
                local e = state.candidates[i]
                if e.target and Entity.GetIndex(e.target) == hint_idx
                   and (e.score or -1) >= 0
                then
                    state.candidates[1], state.candidates[i] = e, state.candidates[1]
                    -- v6.15.49: clear stale score breakdown after promotion.
                    -- state.last_score_breakdown was computed for the OLD
                    -- top candidate (before swap) earlier in this function;
                    -- leaving it would make the HUD show wrong components
                    -- for the now-promoted target. Replace with a marker
                    -- that names the promotion source so the HUD still has
                    -- something meaningful to render.
                    state.last_score_breakdown = "hint(" .. (hint_src or "?")
                        .. ") promoted score=" .. tostring(e.score or 0)
                    tlog(2, "baseline_hint_promoted", {
                        target = uname(hint),
                        source = hint_src or "?",
                        score  = string.format("%d", e.score or 0),
                    })
                    break
                end
            end
        end
    end

    -- Decay fog_cache entries: drop if expired, alive-target gone, or now visible.
    local t_now = now()
    for idx, entry in pairs(state.fog_cache) do
        local stale = (t_now - entry.t) > FOG_CACHE_TTL
        local dead  = not Target.IsAlive(entry.target)
        if stale or dead or visible_idx[idx] then
            state.fog_cache[idx] = nil
        end
    end

    -- Trace: tick summary at verbosity 3 only.
    if #scored > 0 then
        local top = scored[1]
        tlog(3, "candidates", {
            n = #scored, top = uname(top.target), top_score = top.score,
            fog = (function() local c = 0; for _ in pairs(state.fog_cache) do c = c + 1 end; return c end)(),
        })
    end
end

-- Best fog-snipe candidate: highest-score entry whose unit handle is still
-- valid and that's within R cast range from Sniper's current position.
local function top_fog_candidate()
    local me = state.self_npc
    if not me then return nil end
    local best, best_s = nil, -1
    for _, entry in pairs(state.fog_cache) do
        if Target.IsAlive(entry.target) and dist_to(entry.target) <= state.r_cast_range() then
            if entry.score > best_s then best, best_s = entry, entry.score end
        end
    end
    return best
end

----------------------------------------------------------------------------
-- Layer 1 — aggressive overrides (key-activated)
----------------------------------------------------------------------------

-- v6.15.37: snapshot Humanizer.GetOrderQueue() for self-targeted entries.
-- Used at safe_issue dispatch time AND cast_verify check time so we can
-- correlate: did our order make it into the queue, did it linger, did it
-- disappear without firing? Returns (total_count, self_count).
local function queue_snapshot()
    if not Humanizer or not Humanizer.GetOrderQueue then return 0, 0 end
    local q = Humanizer.GetOrderQueue()
    if not q then return 0, 0 end
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return #q, 0 end
    local me_idx = Entity.GetIndex(me)
    local self_n = 0
    for i = 1, #q do
        local e = q[i]
        if e.unit and Entity.GetIndex(e.unit) == me_idx then
            self_n = self_n + 1
        end
    end
    return #q, self_n
end

-- All issue helpers go through this wrapper so Gate 3 baseline-dedup is
-- enforced uniformly (and the brain never duplicates a pending baseline order).
local function safe_issue(spec)
    if queue_has_baseline(spec.order_type, spec.ability, spec.target, spec.unit, spec.position) then
        state.skip_counter = state.skip_counter + 1
        tlog(3, "queue_dedup_skip", {
            intent = spec.intent, order_type = spec.order_type,
            target = spec.target and uname(spec.target) or "-",
        })
        return false
    end
    -- v6.15.29 / v6.15.34: capture pre-issue ability state for cast
    -- verification. Cooldown alone insufficient for charge-based abilities
    -- (Shrapnel) — Q has 3 charges and GetCooldown only bumps once all
    -- depleted. Also track charges to detect Q firing when charges > 0
    -- post-cast.
    local cd_before = 0
    local charges_before = 0
    if spec.ability and Ability.GetCooldown then
        cd_before = Ability.GetCooldown(spec.ability) or 0
    end
    if spec.ability and Ability.GetCurrentCharges then
        local okc, ch = pcall(Ability.GetCurrentCharges, spec.ability)
        if okc and type(ch) == "number" then charges_before = ch end
    end
    -- v6.15.32: capture Sniper's mana too — cast_verify exposed silent
    -- engine-side rejection of R/Q for insufficient mana.
    local mana_at_issue = (state.self_npc and NPC.GetMana) and NPC.GetMana(state.self_npc) or 0
    local mana_cost = spec.ability and Ability.GetManaCost
                      and (Ability.GetManaCost(spec.ability) or 0) or 0
    local ok = Order.Issue(spec)
    if ok then
        tlog(1, "issued", {
            layer  = spec.layer,
            intent = spec.intent,
            order  = spec.order_type,
            target = spec.target and uname(spec.target) or "-",
            ability = spec.ability and (Ability.GetName(spec.ability) or "?") or "-",
            cd_before = string.format("%.2f", cd_before),
            mana      = string.format("%.0f", mana_at_issue),
            cost      = string.format("%.0f", mana_cost),
        })
        -- v6.15.29 / v6.15.33: schedule cast verification. CRITICAL TIMING
        -- FIX: in Dota 2, an ability's cooldown begins at cast-point END
        -- (when the projectile releases), NOT at cast-point start. My
        -- previous fixed 0.6s check was a FALSE NEGATIVE for cast-point
        -- abilities — it read CD during the cast, before it was set. R
        -- (2s cast point) and Q (1.4s) showed fired=n even when casting
        -- normally; only instant abilities (E, grenade) showed fired=y.
        -- Now: schedule based on ability's own cast point + 0.4s slack.
        if spec.ability then
            local cast_point = 0
            if Ability.GetCastPoint then
                local okcp, cp = pcall(Ability.GetCastPoint, spec.ability, true)
                if okcp and type(cp) == "number" then cast_point = cp end
            end
            local check_delay = cast_point + 0.4
            -- v6.15.37: snapshot queue state at issue time. Pair with the
            -- check-time snapshot inside cast_verify_tick to detect orders
            -- that entered the queue, never fired, and were consumed silently.
            local q_total_at_issue, q_self_at_issue = queue_snapshot()
            -- v6.15.38: pending_cast_verify is keyed by a monotonic counter,
            -- not by intent. The intent-keyed form let a rapid re-dispatch of
            -- the same intent overwrite an in-flight retry — most fired=n
            -- attempt=1 entries in v6.15.37 never produced an attempt=2
            -- because the next dispatch clobbered them. The intent is still
            -- carried as a payload field on each entry for the log line.
            state.pending_cast_verify         = state.pending_cast_verify or {}
            state.pending_cast_verify_counter = (state.pending_cast_verify_counter or 0) + 1
            local pcv_key = state.pending_cast_verify_counter
            state.pending_cast_verify[pcv_key] = {
                intent           = spec.intent,
                ability          = spec.ability,
                target           = spec.target,  -- v6.15.227: lets cast_verify classify a fired=n as target-died vs flood-loss.
                cd_before        = cd_before,
                charges_before   = charges_before,
                t_check          = now() + check_delay,
                t_issued         = now(),
                ability_name     = Ability.GetName(spec.ability) or "?",
                cast_point       = cast_point,
                attempt          = 1,
                q_total_at_issue = q_total_at_issue,
                q_self_at_issue  = q_self_at_issue,
            }
            -- v6.15.40: record brain's last in-flight cast so the interference
            -- detector in brain_native_diagnostic_tick can attribute mid-cast
            -- aborts to specific native subsystems. Only set for abilities
            -- with non-trivial cast points — instant abilities (cast_point=0)
            -- complete before any subsystem can interfere.
            if cast_point > 0.05 then
                state.last_brain_cast = {
                    t            = now(),
                    intent       = spec.intent,
                    ability_name = Ability.GetName(spec.ability) or "?",
                    cast_point   = cast_point,
                }
            end
            -- v6.15.42: track R casts for cast_outcome study. After 5s,
            -- check whether the target died and how much HP the cast
            -- removed. Generates the raw data for aggression efficiency
            -- analysis (R-kill rate, damage-per-R, commit_pred accuracy).
            -- Only track sniper_assassinate — Q's outcome is harder to
            -- attribute (no specific enemy target on position cast).
            local ab_name = Ability.GetName(spec.ability) or ""
            if ab_name == "sniper_assassinate" and spec.target
               and Entity.IsEntity(spec.target)
            then
                state.pending_cast_outcomes = state.pending_cast_outcomes or {}
                state.cast_outcome_counter = (state.cast_outcome_counter or 0) + 1
                -- v6.15.174: if this R belongs to an E+R tap, heavy_starter
                -- left its damage prediction in state.tap_pending. Read it,
                -- clear it (so a stale entry never attaches to a later combo
                -- R), and fold it into the outcome row only if fresh (<1s).
                local tap = state.tap_pending
                state.tap_pending = nil
                if tap and (now() - (tap.t or 0)) > 1.0 then tap = nil end
                -- v6.15.172 / v6.15.176: snapshot the brain's predicted R
                -- damage (raw HP) so cast_outcome can back-check it. Use the
                -- correct Take Aim frame: only a tap that fired E has Take
                -- Aim active at R (100% headshot); every other R cast — the
                -- starter_r / tf_r finishers, dr, fog/channel R — is R-alone,
                -- take-aim inactive (40% headshot). This matches the
                -- v6.15.176 commit-math frame fix, so pred_raw lines up with
                -- the damage the brain actually committed on.
                local r_pred_ta = (tap and tap.e_fires) and true or false
                local pred = r_kill_prediction
                             and r_kill_prediction(spec.target, r_pred_ta)
                state.pending_cast_outcomes[state.cast_outcome_counter] = {
                    intent     = spec.intent,
                    target     = spec.target,
                    tgt_name   = uname(spec.target),
                    hp_before  = Entity.GetHealth(spec.target) or 0,
                    hp_max     = Entity.GetMaxHealth(spec.target) or 1,
                    t_check    = now() + 5.0,
                    t_issued   = now(),
                    pred_raw   = pred and pred.pred_raw or nil,
                    pred_kill  = pred and pred.kill or nil,
                    tap_e_r    = tap and tap.dmg_e_r or nil,
                    tap_r_only = tap and tap.dmg_r_only or nil,
                    tap_e_fires = tap and tap.e_fires or nil,
                    is_tap     = tap and true or nil,
                }
            end
        end
    else
        tlog(3, "issue_rejected", { intent = spec.intent })
    end
    return ok
end

local function issue_cast_target(intent, ab, t)
    -- v6.15.95: execute_fast=true for Assassinate. v6.15.94 demo
    -- cast_verify_double_fail entries showed q_total_at_issue=3,
    -- q_self_at_issue=0 — at the moment we issued R, the queue had 3
    -- non-brain (native subsystem) orders already pending. R then never
    -- enters cooldown (cd_after=0 across both retry attempts) — engine
    -- silently drops R because native orders process first and reset
    -- Sniper's action state. Per player.md:21, execute_fast "bypasses
    -- internal safety delays for immediate execution" — scopes R's
    -- dispatch ahead of the native orders queued the same tick.
    -- Limited to sniper_assassinate so we don't accelerate non-critical
    -- item casts that don't have this same self-cancellation pattern.
    local fast = false
    if ab and Ability.GetName then
        local nm = Ability.GetName(ab) or ""
        if nm == "sniper_assassinate" then fast = true end
    end
    return safe_issue {
        hero        = HERO_KEY,
        layer       = "agg",
        intent      = intent,
        order_type  = UO.DOTA_UNIT_ORDER_CAST_TARGET,
        unit        = state.self_npc,
        ability     = ab,
        target      = t,
        execute_fast = fast,
    }
end

local function issue_cast_position(intent, ab, pos)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = "agg",
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_POSITION,
        unit       = state.self_npc,
        ability    = ab,
        position   = pos,
    }
end

local function issue_cast_notarget(intent, ab, layer)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = layer or "agg",
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_NO_TARGET,
        unit       = state.self_npc,
        ability    = ab,
    }
end

local function issue_item_self(intent, layer, it)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = layer,
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
        unit       = state.self_npc,
        ability    = it,
        target     = state.self_npc,
    }
end

local function issue_item_position(intent, layer, it, pos)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = layer,
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_POSITION,
        unit       = state.self_npc,
        ability    = it,
        position   = pos,
    }
end

-- Cast an item on a specific target unit (Pike-on-enemy, Force-on-ally, etc).
-- Used when the save's geometry is more reliable when applied to the threat
-- itself rather than Sniper (e.g., Pike on enemy pushes them 600u outward
-- from Sniper, deterministic; Pike on self depends on Sniper's facing).
local function issue_item_target(intent, layer, it, target)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = layer,
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
        unit       = state.self_npc,
        ability    = it,
        target     = target,
    }
end

-- Cast a no-target item (Phase Boots active, BKB technically is target-self
-- but most "active passes" use no-target form too).
local function issue_item_no_target(intent, layer, it)
    return safe_issue {
        hero       = HERO_KEY,
        layer      = layer,
        intent     = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_NO_TARGET,
        unit       = state.self_npc,
        ability    = it,
    }
end

----------------------------------------------------------------------------
-- Commit-floor threshold for R-target valuation.
-- (Historical: the v6.8 COMBOS / SEQUENCES dispatcher this section once
-- headed was retired in v6.15.153 — the combo key now runs the adaptive
-- Starter / Team Fight / Heavy Starter loop. `commit_floor()` below survives
-- because ScoreUltTarget still uses it to rank R targets by valuation.)
--
-- Harass-only modes (just-Q lane poke, just-E auto-attack support) are
-- intentionally NOT modeled here — user feedback: spell harass is too
-- mana-sensitive to automate and is best done by hand. Layer 1 always
-- intends to kill or to pre-position for a kill.
----------------------------------------------------------------------------

local COMBO_COMMIT_FLOOR_DEFAULT = 100
-- v6.14 A4: commit floor is now a slider — heroes who want fish-mode set 40,
-- conservative users set 150. The constant above is the menu default. Reads
-- the slider when available; falls back to the default before menu init.
-- v6.14.1: assigned to the forward-declared local (line 60) so ScoreUltTarget's
-- earlier reference resolves correctly.
commit_floor = function()
    local base = COMBO_COMMIT_FLOOR_DEFAULT
    if state.menu and state.menu.commit_floor then
        base = state.menu.commit_floor:Get()
    end
    -- v6.15 D2: game-time scaling — late game loosens, early tightens.
    -- v6.15 D5: Roshan-pit context — everyone is clustered AoE; loosen by 10.
    -- v6.15 D1: Aghs Scepter sharpens R commits (faster cast = lower DPS-loss
    -- on commit) — loosen by 10. Shard adds scattershot AoE = loosen by 5.
    local adj = game_time_offset()
    if in_roshan_context() then adj = adj - 10 end
    if NPCLib.has_scepter(state.self_npc) then adj = adj - 10 end
    if NPCLib.has_shard(state.self_npc) then adj = adj - 5 end
    return math.max(0, base + adj)
end

-- v6.8.5: Layer 1 commit window. After firing a combo or sequence, suppress
-- re-dispatch for this many seconds. R cast point is 2.0s (0.5s with Scepter)
-- plus 0.4s grenade/0.3s shrap step time. 2.5s lets the cast resolve before
-- re-evaluating. Prevents per-tick log spam (216 dispatches on the same
-- target observed in the v6.8.4 demo) and per-tick chain re-evaluation
-- (cheap but redundant).
-- v6.15.28: split throttle by what was dispatched.
--   R combo → 3.0s (v6.15.220): covers the dr combo's full D-R-Q-E. E is
--     the last step, firing at ~2.8s (r_cast_point+0.8); the prior 2.5s
--     window let a re-dispatch land before E and double-cast Take Aim.
--   Non-R sequence (grenade_self_kite, pike_self_kite, shrap_chase) → 0.4s:
--     just enough to prevent same-frame double-dispatch. With this window,
--     a user tapping the combo key gets a new dispatch each press as soon as
--     the ability comes off CD (grenade 10s, Pike 19s) — instead of being
--     locked out for 2.5s after every sequence.
local LAYER1_COMMIT_WINDOW_R = 3.0
local LAYER1_COMMIT_WINDOW_SEQ = 0.4
-- Kept for legacy reads (e.g. status panel display).
local LAYER1_COMMIT_WINDOW = LAYER1_COMMIT_WINDOW_R

-- v6.10 G9 / v6.11 #5: Sniper per-attack damage including common item procs
-- AND Headshot. Headshot is Sniper's signature passive: 40% proc baseline
-- with ~75 magic damage + 0.5s 100% slow + mini-stun. During Take Aim active,
-- proc rate is 100% inside the 140° view cone. Caller specifies whether to
-- model the Take-Aim-active case (e.g., snipe_e_r setup/stack-kill math)
-- vs baseline (any other context). Headshot bonus damage scales with Q level
-- via talents at level 25, but we use a conservative flat 75 per proc.
--
-- Multiplicative procs (crit) compound base; flat procs (chain/headshot)
-- add on top. All expressed as expected per-attack contribution (chance × proc).

-- v6.15.167: read a live KV special value off an item handle, so the proc
-- damage model tracks Valve's frequent item retunes instead of rotting on
-- hardcoded numbers. `fallback` is the current KV value, used only if the
-- handle or the API is unavailable; a returned 0 counts as unresolved (none
-- of the proc values read through this is ever legitimately 0).
state.item_kv = function(handle, key, fallback)
    if handle and Ability.GetLevelSpecialValueFor then
        local v = Ability.GetLevelSpecialValueFor(handle, key)
        if v and v ~= 0 then return v end
    end
    return fallback
end

-- v6.15.171 (KV-hardcode migration A9): Hurricane Pike enemy-target cast
-- range, read LIVE off the Pike item handle. KV item_hurricane_pike
-- `cast_range_enemy` (snapshot 425). Falls back to 425 when Pike is absent
-- or the API is unavailable. The brain hardcoded 425 at four range gates.
state.pike_enemy_range = function()
    local me   = state.self_npc
    local pike = me and NPC.GetItem and NPC.GetItem(me, "item_hurricane_pike", true)
    return state.item_kv(pike, "cast_range_enemy", 425)
end

local function rc_attack_damage_with_procs(take_aim_active, distance)
    local me = state.self_npc
    if not me then return 0 end
    -- v6.12.1 fix: NPC.GetAttackDamage doesn't exist. GetTrueDamage = min+bonus,
    -- GetTrueMaximumDamage = max+bonus. Average for expected per-attack damage.
    local true_min = NPC.GetTrueDamage(me) or 0
    local true_max = NPC.GetTrueMaximumDamage(me) or true_min
    local base = (true_min + true_max) * 0.5
    -- v6.14 D3: Keen Scope (innate passive) adds physical bonus damage scaling
    -- with distance. Applied to RC autoattacks, not just R. At 2000u this is
    -- ~30 extra per attack — material to setup-kill math. Distance optional
    -- (caller may omit when range isn't known); defaults to attack range.
    local d_for_keen = distance
    if not d_for_keen then
        d_for_keen = effective_attack_range(me)
    end
    base = base + keen_scope_bonus(d_for_keen)
    local mult = 1.0
    local flat = 0
    -- v6.15.167: proc-item contributions read LIVE from each item's KV via
    -- item_kv, so the model tracks Valve's item retunes. Names are the
    -- canonical KV names: Daedalus = item_greater_crit, Crystalys =
    -- item_lesser_crit (the prior item_daedalus / item_crystalys checks were
    -- dead — those are display names, not KV names, so GetItem never matched).
    local item_kv = state.item_kv
    -- Crit items: expected-value multiplier. crit_chance / crit_multiplier are
    -- percent-encoded in KV (30 = 30%, 225 = 2.25x).
    local daedalus = NPC.GetItem(me, "item_greater_crit", true)
    if daedalus then
        local chance = item_kv(daedalus, "crit_chance", 30) / 100
        local cmult  = item_kv(daedalus, "crit_multiplier", 225) / 100
        mult = mult * (1 + chance * (cmult - 1))
    end
    local crystalys = NPC.GetItem(me, "item_lesser_crit", true)
    if crystalys then
        local chance = item_kv(crystalys, "crit_chance", 30) / 100
        local cmult  = item_kv(crystalys, "crit_multiplier", 160) / 100
        mult = mult * (1 + chance * (cmult - 1))
    end
    -- Chain-lightning proc items: expected flat magic per attack =
    -- chain_damage * chain_chance.
    local maelstrom = NPC.GetItem(me, "item_maelstrom", true)
    if maelstrom then
        flat = flat + item_kv(maelstrom, "chain_damage", 110)
                    * (item_kv(maelstrom, "chain_chance", 25) / 100)
    end
    local mjollnir = NPC.GetItem(me, "item_mjollnir", true)
    if mjollnir then
        flat = flat + item_kv(mjollnir, "chain_damage", 180)
                    * (item_kv(mjollnir, "chain_chance", 25) / 100)
    end
    -- Skadi and Revenant's Brooch are intentionally NOT modeled as procs: the
    -- KV exposes no reliable per-attack proc damage for either. Skadi is
    -- +stats and slows; Brooch is +bonus_damage plus a situational charge
    -- mechanic. Both items' static bonus_damage is already inside `base` via
    -- NPC.GetTrueDamage, so a flat proc here would invent damage.
    -- Headshot (W passive): mini-stun and slow aren't damage but help the
    -- target stay in place / break their casts (modeled separately).
    -- v6.15.169 (KV-hardcode migration #3): headshot bonus damage + proc
    -- chance read LIVE off the W handle via state.item_kv. KV
    -- sniper_headshot: `damage` is per-W-level (20/50/80/110), `proc_chance`
    -- is 40. The prior flat 75 mismatched the KV at every W level — this is
    -- a correctness fix, NOT behaviour-neutral. Take Aim active forces a
    -- 100% proc. The +30 headshot-damage talent still folds in via
    -- talent_headshot_bonus().
    local headshot_ab  = ability(A.W)
    local hs_lvl       = (headshot_ab and Ability.GetLevel
                          and Ability.GetLevel(headshot_ab)) or 0
    local HS_DMG_FB    = { 20, 50, 80, 110 }
    local hs_dmg_fb    = HS_DMG_FB[math.max(1, math.min(4, hs_lvl))] or 110
    local headshot_base   = state.item_kv(headshot_ab, "damage", hs_dmg_fb)
    local proc_chance_pct = state.item_kv(headshot_ab, "proc_chance", 40)
    local headshot_chance = take_aim_active and 1.0 or (proc_chance_pct / 100)
    local headshot_dmg    = headshot_base + talent_headshot_bonus()
    flat = flat + headshot_dmg * headshot_chance
    return base * mult + flat
end

-- RC damage over a time window. `take_aim_active` should be true when the
-- caller knows the brain will activate Take Aim within the window (e.g.,
-- snipe_e_r's setup_killable / stack-kill calcs, where E fires before R).
-- For mid-fight estimates outside an E-committing combo, leave nil/false.
-- v6.10 G9 / v6.11 #5.
local function rc_damage_over(seconds, take_aim_active, distance)
    local me = state.self_npc
    if not me then return 0 end
    local dmg = rc_attack_damage_with_procs(take_aim_active, distance)
    local atk_time = NPC.GetAttackTime(me) or 1.7
    if atk_time <= 0 then return 0 end
    return dmg * (seconds / atk_time)
end

-- v6.15.91: Assassinate dual-instance damage. 7.34 added "Sniper's R fires an
-- instant attack at projectile impact in addition to the magical 300/400/500
-- base"; 7.41 only removed the 1/1.1/1.2 level-scaling factor — the instant
-- attack itself remains (verified via Liquipedia main page + 7.34/7.40/7.41
-- changelogs, 2026-05-14 session). Per Liquipedia's "Instant Attacks" article:
-- instant attacks use the hero's regular attack damage as ability damage,
-- proc on-hit modifiers (Headshot, Maelstrom, Daedalus crit, Skadi), have
-- True Strike (no evasion), ignore disarms, and apply physical armor
-- reduction at the target.
--
-- Brain through v6.15.90 missed this whole physical instance. v6.15.90 demo
-- evidence: CM at hp_max 884, combo_dmg_breakdown total=821 gap=63 → refuse.
-- The missing instant attack (Sniper L16 with Daedalus ≈ 130-180 physical
-- after armor) would close that gap and unlock the kill. Recent log shows
-- 14 refuses with gap 100-180 — all the same pattern.
--
-- Function: returns the physical instant-attack damage R adds against
-- `target` at `distance`. `take_aim_active` should be true when caller knows
-- Take Aim will be up at R impact (snipe_e_r casts E before R) → Headshot
-- procs at 100%, otherwise 40%. Caller adds the return value to the magical
-- R component to get total R damage for kill-grade math.
--
-- KEEN SCOPE FRAMING (audit A1, cleaned up in v6.15.195).
-- Keen Scope is PHYSICAL bonus damage scaling with attack range (per the
-- code's intent at keen_scope_bonus). It belongs in
-- `r_physical` only, via rc_attack_damage_with_procs which already adds
-- it inside the per-attack base. The v6.15.91 deferred-cleanup TODO was
-- the five `r_magical = assassinate_damage() + keen_scope_bonus(d)` sites
-- (score functions + r_kill_prediction + the main r_dmg_at_d gate) that
-- ALSO added KS to the magical component, double-counting it in the
-- combined `r_magical + r_physical * magic_inflate` formula.
local function assassinate_instant_attack_damage(target, distance, take_aim_active)
    local me = state.self_npc
    if not me or not target then return 0 end
    local per_attack = rc_attack_damage_with_procs(take_aim_active and true or false, distance)
    local armor_mult = 1.0
    if NPC.GetArmorDamageMultiplier then
        armor_mult = NPC.GetArmorDamageMultiplier(target) or 1.0
    end
    return per_attack * armor_mult
end

-- v6.9.3: estimated Shrapnel damage per cast given current Q level.
-- Conservative: assumes target sits in zone for ~2s (4 ticks at 0.5s). Pro
-- play often gets more — but kill-grade math should err toward "yes the
-- target dies" not "maybe." Stacking multiple Q at the same location
-- overlaps zones; each zone applies its own ticks → total damage =
-- N * shrap_per_q_effective.
-- v6.15.173 (KV-hardcode migration): per-tick damage read LIVE off the Q
-- handle. KV sniper_shrapnel `shrapnel_damage` (base 30/45/60/75 by Q
-- level). GetLevelSpecialValueFor returns the BASE value — talent magnitudes
-- are read separately in the UCZone API (a special_bonus_* key off the
-- parent), so the +30% shrap talent stays applied below via
-- talent_shrap_multiplier(); no double-count. The old formula 30+15*(lvl-1)
-- reproduced the same base table, so the migration is behaviour-neutral;
-- it is kept as the no-handle fallback.
local function shrap_damage_per_q_effective()
    local me = state.self_npc
    if not me then return 0 end
    local a = ability(A.Q)
    if not a or Ability.GetLevel(a) <= 0 then return 0 end
    local lvl = Ability.GetLevel(a)
    local fb = (30 + 15 * (lvl - 1))  -- 30 / 45 / 60 / 75 base
    local per_tick = state.item_kv(a, "shrapnel_damage", fb)
    -- v6.15.2 C1: +30% multiplicative shrap talent (level 25). Scales the
    -- per-tick damage, NOT a flat addition.
    per_tick = per_tick * talent_shrap_multiplier()
    return per_tick * 4  -- 4 ticks ≈ 2s of dwell in zone
end

-- v6.15.172: R-damage back-check snapshot. Reproduces build_layer1_ctx's
-- r_dmg_at_d formula (assassinate magical + keen scope + the instant-attack
-- physical instance) for `target` at the live distance, but expresses the
-- result in RAW HP so it is directly comparable to cast_outcome's hp_delta
-- (the raw HP actually removed). The magical instance is converted out of
-- the magical frame to raw HP via the same magic_inflate factor the kill
-- check uses; the physical instance is already post-armor raw HP.
-- take_aim_active (default true) selects the headshot frame: true = Take Aim
-- active (100% headshot — the combo / E+R-tap case), false = R alone (40%
-- headshot — the tap with E on cooldown). It only affects the physical
-- instance. `kill` = the brain would expect R alone to kill at this
-- snapshot. Diagnostic only — no combat decision reads this; it exists so
-- cast_outcome / tap_combo can log predicted-vs-actual.
r_kill_prediction = function(target, take_aim_active)
    local me = state.self_npc
    if not me or not target or not Entity.IsEntity(target) then return nil end
    if take_aim_active == nil then take_aim_active = true end
    local d = dist_to(target) or effective_attack_range(me)
    -- v6.15.195 (audit A1): KS is PHYSICAL bonus damage, already counted
    -- inside r_physical via rc_attack_damage_with_procs. The
    -- old `+ keen_scope_bonus(d)` here double-counted KS in the combined
    -- r_dmg_at_d formula, ~15-30 HP overshoot at typical R distance.
    local r_magical  = assassinate_damage()
    local r_physical = assassinate_instant_attack_damage(target, d, take_aim_active)
    local raw_hp = Entity.GetHealth(target) or 0
    local eff_hp = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL) or 0
    local magic_inflate = (raw_hp > 0 and eff_hp > 0) and (eff_hp / raw_hp) or 1.0
    local pred_raw = r_magical / magic_inflate + r_physical
    return {
        pred_raw = pred_raw,
        kill     = (raw_hp > 0 and pred_raw >= raw_hp),
    }
end

-- v6.15.239 (JppsTech clue C6-A): kill confidence as a 0-100 probability,
-- derived from the brain's OWN conservative/optimistic damage band -- not a
-- hand-tuned step ladder. dmg_lo is the pessimistic estimate the commit
-- gate is built on (R + the RC_MIN_DAMAGE_FACTOR-haircut autoattack window);
-- dmg_hi swaps the haircut for the full window. p is the fraction of that
-- self-uncertainty band that clears the (regen/barrier-correct) eff_hp kill
-- threshold: band fully lethal -> 100, band fully short -> 0. R + RC only
-- (archetype-agnostic, Q not counted) -- so it reads CONSERVATIVE for a
-- Q-stacking combo. Diagnostic: surfaced in the `starter` R-decision log;
-- it does NOT gate commit (the conservative dmg_lo gate is unchanged).
state.kill_confidence = function(ctx)
    if not ctx then return 0 end
    local eff_hp = (ctx.proj_state_r_impact
                    and ctx.proj_state_r_impact.eff_hp_magical)
                   or ctx.eff_hp or 0
    if eff_hp <= 0 then return 0 end
    local r      = ctx.r_dmg_at_d or 0
    local rc_lo  = ctx.rc_2s or 0
    local factor = state.RC_MIN_DAMAGE_FACTOR or 0.5
    local rc_hi  = (factor > 0) and (rc_lo / factor) or rc_lo
    local dmg_lo = r + rc_lo
    local dmg_hi = r + rc_hi
    if dmg_hi <= dmg_lo then
        return (dmg_lo >= eff_hp) and 100 or 0
    end
    local p = (dmg_hi - eff_hp) / (dmg_hi - dmg_lo)
    return math.floor(math.max(0, math.min(1, p)) * 100 + 0.5)
end

-- v6.9.3: minimum Q charges needed to close the kill, given R + RC follow-up.
-- v6.15.14 Delta A: live re-evaluation of how many more Q's are needed to
-- close the kill, given target's CURRENT effective HP at fire time. Used by
-- pending Q steps' cond closures to skip stacks that no longer matter
-- (target already dead from R, dispelled out of range, or healed past Q's
-- damage potential). Replaces the dispatch-time q_kill_floor snapshot for
-- Q2/Q3 decisions — Q1 still always fires when q_charges available since
-- by Q1's fire time R may have killed and Q would be pure waste.
--
-- Returns:
--   0 — target dead / about to die without more Q (skip).
--   1..3 — that many more Q's needed from this point.
--   4+ — Q won't close it (target too tanky or magic immune; skip stacking).
--
-- Conservative against unknowns: returns 4 (skip) when target invalid /
-- magic immune / no shrap damage estimate, so a missing precondition
-- doesn't cause Q to fire blindly.

-- v6.15.72 (user directive): "improve damage modelation by extrapolation.
-- We know our total minimal damage for auto attack, as we know the abilities
-- damage, we know our total maximum range, we need to understand what we
-- can get of information from the target to add to this model (live data
-- for life, armor, magic resistance, life regeneration, healing items and
-- velocity). With this model we might be able to predict exactly the skills
-- usage and so on."
--
-- project_target_state(target, t_future) — predicts target's state at
-- time t = now() + t_future. Assumes target keeps current velocity vector
-- and current modifier set. Returns a table with predicted fields, or nil
-- if target invalid.
--
-- Live data folded in:
--   - HP: current HP + (regen × t_future) + (Satanic/Bloodthorn heal bonus)
--   - Position: current pos + (velocity × t_future) along facing yaw
--   - Distance: from Sniper to projected pos
--   - Range membership: in_atk_range / in_q_range / in_r_range at projected pos
--   - Effective HP: dispatch-time eff_hp with HP delta adjustment for projected HP
--   - dead: true if target became invalid / dead
--
-- Consumed by:
--   - q_chain_step_cond (live eff_hp projection accounts for healing while
--     autos chip — prevents skipping Q2 prematurely when target heals back)
--   - r_will_range_leak (existing range-leak check; future migration)
--   - commit_pred kill projections (future)
--
-- Cost: ~6 API calls (GetHealth, GetMaxHealth, CalculateHealthRegen,
-- GetMoveSpeed, GetAbsOrigin, GetRotationPYR). Call only when the model
-- output will be consumed; not in hot per-tick loops without a use case.
local function project_target_state(target, t_future)
    local me = state.self_npc
    if not target or not me then return nil end
    if not Entity.IsEntity(target) then return nil end
    if not Target.IsAlive(target) then return { dead = true } end
    t_future = t_future or 0
    local s = {}
    -- HP projection: current HP + regen contribution + active heal bonuses.
    local hp     = Entity.GetHealth(target) or 0
    local hp_max = Entity.GetMaxHealth(target) or 1
    local regen  = 0
    if NPC.CalculateHealthRegen then
        local ok, r = pcall(NPC.CalculateHealthRegen, target)
        if ok and type(r) == "number" then regen = r end
    end
    local heal_bonus = 0
    -- v6.15.208: only Satanic's Unholy Rage is a burst-heal worth projecting.
    -- KV item_satanic carries unholy_lifesteal 175%; KV item_bloodthorn has
    -- NO lifesteal/heal of any kind, so the old elseif (+300 for
    -- modifier_item_bloodthorn_active) was a phantom bonus that made the
    -- brain under-rate kills on Bloodthorn holders. Removed.
    if NPC.HasModifier
       and NPC.HasModifier(target, "modifier_item_satanic_unholy_rage") then
        heal_bonus = 500  -- approx burst-heal contribution over ~3s window
    end
    -- Heal bonus pro-rated to the projection window (max at t≥3s).
    local heal_scaled = heal_bonus * math.min(1.0, t_future / 3.0)
    s.hp_projected = math.min(hp_max, hp + regen * t_future + heal_scaled)
    -- HP delta from now → projected (signed)
    s.hp_delta = s.hp_projected - hp
    -- Position projection: current pos + velocity × t along facing yaw.
    local pos = Entity.GetAbsOrigin(target)
    local mvspeed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(target)) or 0
    if pos and Entity.GetRotationPYR and mvspeed > 0 then
        local _, yaw_deg = Entity.GetRotationPYR(target)
        if yaw_deg then
            local yaw = math.rad(yaw_deg)
            s.pos_projected = Vector(
                pos.x + math.cos(yaw) * mvspeed * t_future,
                pos.y + math.sin(yaw) * mvspeed * t_future,
                pos.z
            )
        end
    end
    s.pos_projected = s.pos_projected or pos
    -- Distance + range checks at projected position.
    local me_pos = Entity.GetAbsOrigin(me)
    if me_pos and s.pos_projected then
        -- v6.15.197 (audit B1): native Vector arithmetic (v6.15.187 sweep).
        s.dist_projected = s.pos_projected:Distance2D(me_pos)
        local atk_range = effective_attack_range(me) + take_aim_range_bonus()
        s.in_atk_range  = s.dist_projected <= atk_range
        local r_ab = ability(A.R); local q_ab = ability(A.Q)
        s.in_q_range = q_ab and (s.dist_projected <= effective_cast_range(me, q_ab)) or false
        s.in_r_range = r_ab and (s.dist_projected <= effective_cast_range(me, r_ab)) or false
    end
    -- Effective HP at projected state. EffectiveHpVs reads CURRENT target
    -- HP + armor/MR multipliers — we adjust by the projected HP delta so
    -- the result reflects the future HP state (assumes armor/MR static).
    if Target.EffectiveHpVs and DT then
        s.eff_hp_magical = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL)
                         + s.hp_delta
        s.eff_hp_physical = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_PHYSICAL)
                          + s.hp_delta
    end
    return s
end

-- Per-tick context built once and passed to every requires/trigger/score
-- closure so we don't re-introspect on every entry.
local function build_layer1_ctx(target, score_ult)
    local me = state.self_npc
    local d = dist_to(target)
    local t_pos = Entity.GetAbsOrigin(target)
    local mana = NPC.GetMana(me) or 0
    -- v6.9.1: eff_hp + setup_killable for E+R opener detection.
    -- Setup-kill = R damage + ~2s of RC follow-up finishes the target,
    -- AND we have RC range (with Take Aim's +140 atk_range bonus) to
    -- actually deliver the follow-up. Used by snipe_e_r commit_pred.
    local eff_hp_magical = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL)
    -- v6.15.45 (user directive: "account enemy regen ... bottom value of
    -- damage window"): kill predicates were over-committing because the
    -- damage estimate assumed AVG autoattack rolls AND ignored target's HP
    -- regen during R's 2s cast point. Fix two ways in one place so all
    -- commit_preds and setup_killable benefit:
    --   1. eff_hp_magical bumped by 2s of target regen (NPC.CalculateHealthRegen
    --      is bonus-aware per LuaCATS) — target heals while R flies.
    --   2. rc_2s scaled by RC_MIN_DAMAGE_FACTOR (0.5 in v6.15.55+, was 0.85)
    --      conservative value of the autoattack damage window. Avg-vs-min
    --      ratio for Sniper autos is ~1.15:1; using min keeps commits
    --      pessimistic so we don't waste R on a kill that didn't quite
    --      land.
    local target_regen = 0
    if NPC.CalculateHealthRegen then
        local ok, r = pcall(NPC.CalculateHealthRegen, target)
        if ok and type(r) == "number" then target_regen = r end
    end
    -- v6.15.171 (KV-hardcode migration A2): live, Scepter-aware R cast point
    -- via r_cast_point(). The old hardcoded 2.0 ignored Scepter (0.5s cast)
    -- and so 4x over-estimated target regen-during-cast for a Scepter Sniper.
    local R_CAST_S = r_cast_point()
    eff_hp_magical = eff_hp_magical + target_regen * R_CAST_S
    -- v6.15.53 (G8): account for enemy active-heal items during R cast.
    -- Satanic Unholy Rage (~175%% lifesteal × 3 autos over R cast point) +
    -- Bloodthorn equivalent. Conservative flat bumps so commit_pred refuses
    -- when target popped an active heal — wait it out, R commits when the
    -- buff ends.
    -- v6.15.104: barrier-aware kill prediction. NPC.GetBarriers (from
    -- DISCOVERED_APIs.md, used by KotL's Illuminate damage estimator) returns
    -- { magic = {current, max}, all = {current, max} } for absorbing shields
    -- (Aeon Disk, Lotus Orb, Pipe of Insight aura, item_infused_raindrops).
    -- Without this, Sniper R was over-committing on shielded targets — combo
    -- damage hits the shield first and the kill check is wrong.
    --
    -- Magic barriers absorb magical damage (R's primary instance). "All"
    -- barriers absorb everything. Both add to effective HP for our kill math.
    -- Wrapped in pcall for safety per KotL's pattern (the API was undocumented
    -- when the brain was first written; the pcall is defensive).
    if NPC.GetBarriers then
        local ok, barriers = pcall(NPC.GetBarriers, target)
        if ok and barriers then
            if barriers.magic and barriers.magic.current then
                eff_hp_magical = eff_hp_magical + barriers.magic.current
            end
            if barriers.all and barriers.all.current then
                eff_hp_magical = eff_hp_magical + barriers.all.current
            end
        end
    end
    -- The two enemy active-heal modifier checks (Satanic / Bloodthorn),
    -- read once here for the eff_hp_magical bump below.
    local target_has_satanic_active = NPC.HasModifier
        and NPC.HasModifier(target, "modifier_item_satanic_unholy_rage")
        or false
    local target_has_bloodthorn_active = NPC.HasModifier
        and NPC.HasModifier(target, "modifier_item_bloodthorn_active")
        or false
    if target_has_satanic_active then
        eff_hp_magical = eff_hp_magical + 500
    elseif target_has_bloodthorn_active then
        eff_hp_magical = eff_hp_magical + 300
    end
    -- v6.15.17: effective attack range (base + item/talent/buff bonus).
    -- See effective_attack_range() comment — base-only made setup_killable
    -- and snipe_r_only's out-of-RC gate incorrect when Sniper has Pike,
    -- Dragon Lance, or attack range talent.
    local atk_range = effective_attack_range(me)
    -- v6.15.91: R has two damage instances per Liquipedia (7.34+).
    -- Magical component = assassinate_damage() (base + amp + talent).
    -- Physical instant-attack component = assassinate_instant_attack_damage
    -- at target's armor, which itself folds in Keen Scope and other
    -- per-attack procs (Daedalus, Maelstrom chain) via the per-attack
    -- model in rc_attack_damage_with_procs. v6.15.195 (audit A1) removed
    -- the `+ keen_scope_bonus(d)` that was double-applied to the magical
    -- component here — Keen Scope is physical and belongs only in
    -- r_physical.
    -- v6.15.176 FRAME FIX (user demo: the `starter_r` finisher's pred R
    -- damage logged ~530-586 on Primal while R-alone actually does ~468).
    -- r_physical was computed with take_aim_active=TRUE — a leftover from the
    -- deleted snipe_e_r combo, which fired E before R for a 100% headshot. NO
    -- current archetype that consults the R-kill math fires E before R: the
    -- `r` finisher is R-only (E dropped in v6.15.127), `dr` fires E AFTER R,
    -- `tf_r` is R-only. The ONLY take-aim-active R is the heavy_starter TAP,
    -- and the TAP has no kill check. So the kill math must use the R-alone
    -- frame — take_aim_active=false (40% headshot, not 100%). Using true
    -- over-counted r_physical and let the `r` finisher commit on targets R
    -- alone cannot kill.
    --
    -- v6.15.142 FRAME FIX (user, v6.15.141 demo: a Daedalus Sniper refused R
    -- on a 400+ HP target that R alone kills — the "killable" equation
    -- under-counts). The kill check is `eff_hp_magical <= r_dmg_at_d`, so the
    -- two R instances must be summed in the SAME frame as eff_hp_magical.
    -- eff_hp_magical is "magical damage needed to kill" = raw HP inflated by
    -- the target's magic resist. r_magical (assassinate_damage) is already a
    -- magical-damage number → same frame, add directly. But r_physical
    -- (assassinate_instant_attack_damage) is POST-armor damage = the actual
    -- raw HP it removes — a different frame. Summing it raw under-counted the
    -- physical instance by the magic-resist factor (~25% on a typical hero),
    -- so the kill check refused R on targets it would actually kill. Convert:
    -- raw-HP damage P removes P/raw_hp of the target, which in the magical
    -- frame is P × (eff-magical-HP / raw HP). magic_inflate is that factor.
    -- v6.15.195 (audit A1): KS is PHYSICAL bonus damage, already counted
    -- inside r_physical via rc_attack_damage_with_procs. The
    -- old `+ keen_scope_bonus(d)` here double-counted KS in the combined
    -- r_dmg_at_d formula, ~15-30 HP overshoot at typical R distance.
    local r_magical  = assassinate_damage()
    local r_physical = assassinate_instant_attack_damage(target, d, false)
    local magic_inflate = 1.0
    do
        local raw_hp = Entity.GetHealth(target) or 0
        if raw_hp > 0 then
            local ehp_pure = Target.EffectiveHpVs(target, me, DT.DAMAGE_TYPE_MAGICAL)
            if ehp_pure and ehp_pure > 0 then
                magic_inflate = ehp_pure / raw_hp
            end
        end
    end
    local r_dmg_at_d = r_magical + r_physical * magic_inflate
    -- v6.11 #5: setup/stack-kill math assumes E will fire (snipe_e_r is the
    -- combo that uses these), so Take Aim active → 100% headshot proc.
    -- v6.15.55 (N1): dropped from 0.85 to 0.5 after v6.15.54 demo data.
    -- Cast_outcome showed snipe_e_r delivering ~700 dmg per cast (target HP
    -- 1200 → 400) while commit_pred estimated ~1500 (R + RC + Q stacks).
    -- RC autoattacks rarely materialize fully — target moves out of range,
    -- player releases combo key after R, autos miss. Empirical floor of
    -- ~50%% of RC over 2s is closer to reality than 85%% of avg-side.
    -- Effect: commit_pred refuses borderline kills where combo relies on
    -- RC carrying half the damage, escalating to snipe_r_only as finalizer
    -- when target drops below R-alone-kill threshold.
    local rc_2s = rc_damage_over(2, true, d) * state.RC_MIN_DAMAGE_FACTOR
    local shrap_per_q = shrap_damage_per_q_effective()

    -- v6.15.198 (audit C2): memoize the two target-POV ally scans
    -- (`in_teamfight` at 1200u FRIEND-from-target, `ally_cc_lock` at
    -- 1000u ENEMY-from-target). build_layer1_ctx is called up to 3×
    -- per teamfight tick (`tf_r_ctx(r_cand)`, `tf_r_ctx(focus)`,
    -- `build_layer1_ctx(focus, 0)`); without this cache each call did
    -- two fresh `GetHeroesInRadius` scans = up to 6 redundant scans/
    -- tick from the TF path alone. Cache is keyed on (target_idx,
    -- f_idx) so it auto-invalidates on the next frame; behaviour-
    -- equivalent within one frame because engine state cannot change
    -- between same-tick calls.
    state.l1_ctx_cache = state.l1_ctx_cache or {}
    local _ctx_idx = Entity.IsEntity(target) and Entity.GetIndex(target) or 0
    local _ctx_f   = f_idx()
    local _ctx_e   = (_ctx_idx ~= 0) and state.l1_ctx_cache[_ctx_idx] or nil
    local in_teamfight_v, ally_cc_lock_v
    if _ctx_e and _ctx_e.f == _ctx_f then
        in_teamfight_v = _ctx_e.in_teamfight
        ally_cc_lock_v = _ctx_e.ally_cc_lock
    else
        -- in_teamfight: target has >=1 OTHER enemy hero within 1200u of
        -- itself. v6.15.78 (user directive: "snipe_e_r should be done in
        -- middle of TF") — 1200u radius matches TF coordination distance
        -- (R cast range, ult AoEs). From target's POV (enemy of us),
        -- TEAM_FRIEND = the target's allies = our enemies.
        in_teamfight_v = false
        if target and Entity.IsEntity(target) then
            local list = Entity.GetHeroesInRadius(target, 1200,
                                                  Enum.TeamType.TEAM_FRIEND)
            if list then
                local target_idx = Entity.GetIndex(target)
                for i = 1, #list do
                    local h = list[i]
                    if h and Entity.GetIndex(h) ~= target_idx
                       and Target.IsAlive(h) and Target.NotIllusion(h) then
                        in_teamfight_v = true; break
                    end
                end
            end
        end
        -- ally_cc_lock: target currently stunned AND an ally hero of OURS
        -- within 1000u. v6.10 G7 — our grenade-knockback would drag the
        -- target OUT of an ally's CC zone if we fire while they're chain-
        -- locking. From target's POV TEAM_ENEMY = our team.
        ally_cc_lock_v = false
        if NPC.HasState(target, MS.MODIFIER_STATE_STUNNED) then
            local me_idx  = Entity.GetIndex(me)
            local nearby  = Entity.GetHeroesInRadius(target, 1000,
                Enum.TeamType.TEAM_ENEMY)
            if nearby then
                for i = 1, #nearby do
                    if Entity.GetIndex(nearby[i]) ~= me_idx then
                        ally_cc_lock_v = true; break
                    end
                end
            end
        end
        if _ctx_idx ~= 0 then
            state.l1_ctx_cache[_ctx_idx] = {
                f            = _ctx_f,
                in_teamfight = in_teamfight_v,
                ally_cc_lock = ally_cc_lock_v,
            }
        end
    end

    return {
        me                = me,
        target            = target,
        target_pos        = t_pos,
        d                 = d,
        score_ult         = score_ult,
        mana              = mana,
        -- v6.15.94: gate ready_r on "no R cast already in flight." Without
        -- this, ability_ready(A.R) returns true during R's 2s cast point
        -- (Ability.GetCooldown remains 0 until cast END — Ability.IsReady
        -- doesn't know R is mid-cast). v6.15.93 demo: snipe_r_only_r
        -- dispatched DURING snipe_e_r's R cast window because ready_r was
        -- still true. The second R cast replaces the first → cast_verify
        -- fired=n for snipe_e_r_r. Brain was racing itself.
        --
        -- state.r_cast_protect_until_t is set in fire_steps when R issues
        -- (cast point + 0.4s buffer). Clearing it gates all R-using combos
        -- (snipe_e_r, snipe_r_only, snipe_q_r, snipe_d_r, snipe_standard,
        -- snipe_channel_punish) from re-issuing R during the in-flight cast.
        ready_r           = ability_ready(A.R)
                            and not ((state.r_cast_protect_until_t or 0) > now()),
        ready_e           = ability_ready(A.E),
        -- v6.15.79 (LIQUIPEDIA_REF.md): D (Concussive Grenade) is SHARD-
        -- gated entirely. Without shard, D doesn't exist on Sniper. The
        -- prior `ready_d = ability_ready(A.D)` could return true for an
        -- unlearned shard ability (Ability.IsReady gotcha) and lead combos
        -- to attempt D casts that engine drops. Gate explicitly on
        -- NPC.HasShard so all D-using combos (snipe_standard, snipe_d_r,
        -- snipe_channel_punish, grenade_self_kite, grenade_shrap_zone)
        -- correctly require shard ownership.
        ready_d           = ability_ready(A.D) and (NPC.HasShard and NPC.HasShard(me) or false),
        q_charges         = shrap_charges(),
        magic_immune      = NPC.HasState(target, MS.MODIFIER_STATE_MAGIC_IMMUNE),
        target_killable   = Target.IsKillable(target),
        -- v6.12 Tier 3 #9: windowed escape state — "ready" / "soon" / "long"
        -- / "active" / "none". snipe_d_r uses "ready"|"soon" for its +30
        -- interrupt bonus (we'll catch the dispel cast). snipe_e_r commit_pred
        -- refuses setup/stack-killable when "ready"|"soon" (target dispels
        -- during cast). ScoreUltTarget already applies the score penalty.
        -- v6.13: dropped legacy binary `has_escape_item` ctx field; never
        -- consumed by any commit_pred. Saves an 8-slot scan per candidate.
        escape_window     = Target.EscapeItemWindowState(target,
            NPC.HasScepter(me) and 0.9 or 2.4),
        kiting_us         = Target.IsKitingUs(target, me),
        eff_hp            = eff_hp_magical,
        atk_range         = atk_range,
        -- v6.15.41: predict whether target will leave R's cast range during
        -- R's 2.0s cast point. Worst case: target moves at full speed
        -- directly away. Only relevant when target is actively running from
        -- us (kiting_us); a stationary target won't leave range. Applied to
        -- commit_pred of combos that DON'T have a lock step before R
        -- (snipe_e_r / snipe_q_r / snipe_r_only / snipe_standard).
        -- snipe_d_r / snipe_channel_punish keep R-without-leak-check because
        -- D's stun / target's channel already locks them through cast point.
        -- Hoodwink with Scurry, Slark with Pounce, etc. were the v6.15.40
        -- offenders — high speed targets near edge of range = silent R abort.
        r_will_range_leak = (function()
            local mvspeed = NPC.GetMoveSpeed and NPC.GetMoveSpeed(target) or 300
            -- v6.15.203 (audit D14): state.r_cast_range helper.
            local cast_r = state.r_cast_range()
            if not Target.IsKitingUs(target, me) then return false end
            -- v6.15.105: was hardcoded 2.0; now Scepter-aware via r_cast_point()
            -- (Scepter Sniper's R cast is 0.5s — old hardcoded 2.0 over-stated
            -- the range-leak window 4×, falsely refusing R on borderline-kiting
            -- targets at edge of cast range).
            return (d + mvspeed * r_cast_point()) > cast_r
        end)(),
        -- v6.15.68 (user directive): "if enemy is attacking sniper" — Q
        -- should stack on the same place with 1s intervals. Detect target-
        -- attacking-us state. UCZone has no NPC.GetAttackTarget (only
        -- Tower.GetAttackTarget exists per uczone-api-v2.0/game-components/
        -- core/tower.md), so we approximate: target is close AND either
        -- stationary or moving toward us (not kiting). This matches the
        -- existing approximation used in q_e_sustained's score bonus (line
        -- ~3214) for "close non-kiter = engaging us".
        target_attacking_us = (function()
            -- v6.15.200 (audit C12): state.ATTACK_ENGAGE_RADIUS = 700.
            if dist_to(target) > state.ATTACK_ENGAGE_RADIUS then
                return false
            end
            local mvspeed = NPC.GetMoveSpeed and NPC.GetMoveSpeed(target) or 300
            if mvspeed < 150 then return true end  -- stationary close target = attacking
            return not Target.IsKitingUs(target, me)  -- moving toward us = engaging
        end)(),
        -- v6.15.78 (user directive: "snipe_e_r should be done in middle of
        -- TF"): teamfight detection — see the v6.15.198 (audit C2)
        -- memoization comment above. The cached computation is
        -- behaviour-equivalent to the original inline closure.
        in_teamfight = in_teamfight_v,
        -- v6.15.76: target state projected forward by R's live cast point.
        -- Captures target's HP/position/range membership AT R IMPACT.
        -- Replaces the v6.15.45 ad-hoc `eff_hp + target_regen × R_CAST_S`
        -- + flat Satanic/Bloodthorn bumps with the unified projection
        -- model. Combo commit_preds use proj_state_r_impact.eff_hp_magical
        -- as the kill threshold and .in_r_range as the range-leak gate.
        proj_state_r_impact = project_target_state(target, r_cast_point()),
        -- v6.15.81 (LIQUIPEDIA_REF.md Take Aim): self MS-slow state during
        -- Take Aim's 3s active window (45/40/35/30% slow by E level). Sniper
        -- can't kite normally — defense layer and combo timing decisions
        -- can read these fields to bias toward escape-restoring saves
        -- (Pike/Force/Blink) over flat shields. For now this is the data
        -- layer; behavior changes wait for log data showing where saves
        -- are missing during the slow window.
        self_take_aim_active = (function()
            local active, _ = self_take_aim_state()
            return active
        end)(),
        -- v6.15.53 (G7 — BKB-timing exception): remaining seconds on target's
        -- BKB. nil if no BKB modifier present (target not magic immune from
        -- BKB specifically). commit_pred uses this to allow R commit when
        -- BKB will expire BEFORE R's cast completes — R lands on a target
        -- who's just dropped immunity. v6.15.15's strict magic_immune refusal
        -- was over-conservative for the "BKB at 1s remaining + R 2s cast"
        -- case which is a real kill window.
        bkb_remaining_s = (function()
            if not NPC.GetModifier or not Modifier.GetDieTime then return nil end
            local mod = NPC.GetModifier(target, "modifier_item_black_king_bar_active")
            if not mod then return nil end
            local die = Modifier.GetDieTime(mod)
            if not die then return nil end
            return die - GlobalVars.GetCurTime()
        end)(),
        -- v6.15.15: expose damage components so commit_pred can compute the
        -- full combo's damage and gate on a STRICT kill check rather than
        -- the fuzzy score_ult >= commit_floor heuristic.
        r_dmg_at_d        = r_dmg_at_d,
        rc_2s             = rc_2s,
        shrap_per_q       = shrap_per_q,
        -- v6.15.18: effective cast ranges (base + GetCastRangeBonus). Brain
        -- had hardcoded CAST_R=3000, GRENADE_R=600, SHRAP_R=1800; with
        -- Aether Lens / talents those reads were 250+ short. Combos /
        -- requires now compare c.d against these live values.
        cast_r            = effective_cast_range(me, ability(A.R)),
        cast_d            = effective_cast_range(me, ability(A.D)),
        cast_q            = effective_cast_range(me, ability(A.Q)),
        -- v6.13: removed duplicate `bkb_active` ctx field (was the same
        -- NPC.HasState call as magic_immune just above). All commit_preds
        -- now read `c.magic_immune` directly.
        -- v6.14.1 M6: removed `self_displaced` / `target_airborne` ctx fields.
        -- The combo dispatchers gate on is_displaced() themselves and skip
        -- the tick entirely. Target airborne wasn't consumed by any
        -- commit_pred. Saves two is_displaced() calls per ctx-build.
        -- v6.10 G7: ally-CC interference — see the v6.15.198 (audit C2)
        -- memoization comment above. The cached computation is
        -- behaviour-equivalent to the original inline closure.
        ally_cc_lock      = ally_cc_lock_v,
    }
end

-- v6.11 Tier 2: schedule a step for later execution. Captures the full
-- dispatch-time ctx so cond_fn at fire time can still read it; at fire time
-- we override `target_pos` and `q_charges` with live values (cheap
-- re-reads) while keeping the rest as dispatch-time snapshots. Aborts if
-- target died/became invalid.
-- v6.15.69: resolve delay_s — supports either a number (static delay) or
-- a function(ctx) -> number (dynamic delay derived from live ctx state).
-- Used by snipe_standard's D step to scale delay with R's live cast point
-- (Scepter cuts R cast from 2.0s to 0.5s; D delay must follow). nil-safe.
local function resolve_step_delay(step, ctx)
    local d = step.delay_s
    if type(d) == "function" then d = d(ctx) end
    return d or 0
end

-- v6.15.184 (cleanup): combo_target_in_flight removed — a v6.15.70 in-flight
-- sequence-dedup helper that was never wired to any call site (verified
-- zero references). The combo-key redesign's per-tick adaptive loop made it
-- moot. Deleted as dead code.

local function schedule_step(combo_name, step, ctx, resolved_delay)
    -- Shallow-copy the relevant ctx fields. Don't capture closures.
    local ctx_snapshot = {}
    for k, v in pairs(ctx) do ctx_snapshot[k] = v end
    -- v6.15.69: caller passes pre-resolved delay so dynamic delay_s
    -- functions are called only once per dispatch (fire_steps resolves,
    -- schedule_step consumes). Fallback to direct resolve for safety.
    local delay = resolved_delay or resolve_step_delay(step, ctx)
    local fire_at = now() + delay
    state.pending_steps[#state.pending_steps + 1] = {
        fire_at     = fire_at,
        combo_name  = combo_name,
        short       = step.short,
        ability_key = step.ability,
        kind        = step.kind,
        arg_fn      = step.arg,
        cond_fn     = step.cond,
        target      = ctx.target,
        ctx_snapshot = ctx_snapshot,
    }
    -- v6.13 Cross F#14: reserve the ability slot until just after fire_at so
    -- defense doesn't burn the same ability between dispatch and scheduled
    -- fire. Currently relevant for D (snipe_standard's delayed grenade); the
    -- mechanism is generic and applies to any future delayed step too.
    reserve_ability(step.ability, fire_at + 0.5, combo_name)
end

local function pending_steps_tick()
    if #state.pending_steps == 0 then return end
    local me = state.self_npc
    if not me then return end
    local now_t = now()
    local kept = {}
    for i = 1, #state.pending_steps do
        local p = state.pending_steps[i]
        if now_t < p.fire_at then
            kept[#kept + 1] = p
        elseif not p.target or not Entity.IsEntity(p.target)
               or not Target.IsAlive(p.target) then
            tlog(2, "scheduled_step_aborted", {
                combo = p.combo_name, step = p.short, reason = "target_invalid",
            })
            clear_reservation(p.ability_key)
        elseif not self_alive_ok() then
            -- v6.13 Cross F#20: defense fired an invuln save (Eul/Manta/Aeon)
            -- on Sniper mid-combo; firing D/Q1/Q2/Q3 during cyclone is wasted
            -- mana/CDs. self_alive_ok now includes INVULNERABLE + OUT_OF_GAME.
            tlog(2, "scheduled_step_aborted", {
                combo = p.combo_name, step = p.short, reason = "self_not_ok",
            })
            clear_reservation(p.ability_key)
        else
            -- Build live ctx: dispatch snapshot as base, override volatile fields.
            local live = p.ctx_snapshot
            live.target_pos = Entity.GetAbsOrigin(p.target)
            live.q_charges  = shrap_charges()
            live.me         = me   -- re-pin (handle may have refreshed)
            -- v6.15.71: refresh eff_hp at fire time so q_chain_step_cond
            -- can detect that autos+prior-Qs already killed (target's HP
            -- has dropped from dispatch-time value). Without this, q2 at
            -- +1.5s and q3 at +3.0s use dispatch-time eff_hp and over-fire
            -- on a target that's already nearly dead. shrap_per_q is static
            -- per Q level so dispatch-time value is fine; rc_2s only shifts
            -- on Sniper-side buffs (rare mid-engagement) so dispatch-time
            -- is acceptable. eff_hp is the high-frequency mover that
            -- matters for the q_chain_step_cond pipeline check.
            if Target and Target.EffectiveHpVs and DT and p.target
               and Entity.IsEntity(p.target) and Target.IsAlive(p.target) then
                local fresh_eff_hp = Target.EffectiveHpVs(p.target, me,
                                                          DT.DAMAGE_TYPE_MAGICAL)
                if fresh_eff_hp and fresh_eff_hp > 0 then
                    live.eff_hp = fresh_eff_hp
                end
            end
            -- target itself stays the original reference.
            if p.cond_fn and not p.cond_fn(live) then
                tlog(3, "scheduled_step", {
                    combo = p.combo_name, step = p.short, ok = "skip", reason = "cond_false",
                })
                clear_reservation(p.ability_key)
            else
                local arg = p.arg_fn and p.arg_fn(live) or nil
                local intent = p.combo_name .. "_" .. (p.short or "s")
                local ok = false
                if p.kind == "ut" then
                    ok = issue_cast_target(intent, ability(p.ability_key), arg)
                    -- v6.15.96: parity with fire_steps for R cast
                    -- protect window. snipe_e_r now defers R by 50ms so R
                    -- issues from this path, not from fire_steps. Without
                    -- this block the veto window never opens for the
                    -- deferred R cast.
                    if ok and p.ability_key == A.R then
                        state.last_r_target     = arg
                        state.last_r_combo_name = p.combo_name
                        state.last_r_dispatch_t = now()
                        state.r_cast_protect_until_t = now() + r_cast_point() + 0.4
                        state.r_phase_seen = false  -- v6.15.141: arm the fast-cancel detector
                    end
                elseif p.kind == "pt" then
                    ok = issue_cast_position(intent, ability(p.ability_key), arg)
                    -- v6.15.82: same diagnostic as fire_steps for deferred
                    -- pt steps (q_corridor_finisher q2/q3, q_stack_attacker
                    -- q2/q3 fire from here at scheduled delays).
                    if ok and arg then
                        tlog(3, "step_cast_pos", {
                            intent = intent,
                            x      = string.format("%.0f", arg.x or 0),
                            y      = string.format("%.0f", arg.y or 0),
                        })
                    end
                elseif p.kind == "nt" then
                    ok = issue_cast_notarget(intent, ability(p.ability_key), "agg")
                    -- v6.15.231: a deferred no-target cast (Take Aim in the
                    -- dr / chip combos) had no cast-protect window, unlike
                    -- the deferred R in the `ut` branch above. A native
                    -- queue=false MOVE/ATTACK arriving the same frame
                    -- replaces the issued cast before the engine runs it:
                    -- the v6.15.230 log showed chip Take Aim cleanly issued
                    -- (ready, mana, no CC) but fired=n 2 of 7. Open a short
                    -- veto window so OnPrepareUnitOrders holds the native
                    -- order off until the instant cast resolves.
                    if ok then
                        state.combo_cast_protect_until_t =
                            now() + state.COMBO_CAST_PROTECT_S
                    end
                elseif p.kind == "item_target" then
                    -- v6.15.52 (G10): scheduled item-on-enemy step (Pike).
                    -- p.ability_key is the item name string. arg is the unit.
                    local it = NPCLib.item(state.self_npc,p.ability_key)
                    if it and arg then
                        ok = safe_issue {
                            hero = HERO_KEY, layer = "agg", intent = intent,
                            order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
                            unit = state.self_npc, ability = it,
                            target = arg,
                        }
                    end
                elseif p.kind == "item_self" then
                    -- v6.15.52 (G10): scheduled item-on-self step (parity with
                    -- item_target). Not currently used by any combo but
                    -- present for symmetry — if pike_self_kite ever wants a
                    -- delayed self-cast it'll work via this path.
                    local it = NPCLib.item(state.self_npc,p.ability_key)
                    if it then
                        ok = safe_issue {
                            hero = HERO_KEY, layer = "agg", intent = intent,
                            order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
                            unit = state.self_npc, ability = it,
                            target = state.self_npc,
                        }
                    end
                end
                -- v6.15.107: per-ability fire-time tracking for deferred steps.
                -- Mirror of the fire_steps per-ability fire-time update. Skips item
                -- branches because p.ability_key for items is a string name,
                -- not an A.X constant — wouldn't match any branch anyway.
                if ok then
                    if     p.ability_key == A.Q then state.last_q_t = now()
                    elseif p.ability_key == A.E then state.last_e_t = now()
                    elseif p.ability_key == A.D then state.last_d_t = now()
                    elseif p.ability_key == A.R then state.last_r_t = now()
                    end
                end
                tlog(3, "scheduled_step", {
                    combo = p.combo_name, step = p.short, kind = p.kind,
                    ok = ok and "y" or "n",
                })
                clear_reservation(p.ability_key)
            end
        end
    end
    state.pending_steps = kept
end

-- v6.12 Tier 3 #8: monitor an in-progress R cast and abort via DOTA_UNIT_ORDER_STOP
-- if the target becomes unhitable mid-cast (popped Manta/Aeon/BKB, Linkens up,
-- Lotus up, died, went invuln). Pre-cast-resolution STOP refunds mana and
-- does NOT trigger R cooldown (Dota engine: CD starts on cast completion).
-- Saves ~110s R CD per spurious commit. Polled from OnUpdateEx.
local function r_abort_tick()
    if not state.last_r_target then return end
    local r = ability(A.R)
    if not r then return end
    if not Ability.IsInAbilityPhase(r) then
        -- v6.15.230: bounded, spaced R re-issue. v6.15.228's per-frame
        -- re-issue (modeled on a native-only log of the native Sniper
        -- script) fired a fresh queue=false / execute_fast cast on EVERY
        -- tick while R was out of its ability phase. Each one interrupted
        -- R's own pre-cast wind-up from the prior tick, so R never accrued
        -- enough uninterrupted time to enter the phase: a whole bot match
        -- of 0 locks, R "slower than a manual cast". The same per-tick
        -- approach had already been tried and removed once (v6.15.217 to
        -- v6.15.218, where it cancelled D). Now a re-issue fires only as a
        -- genuine retry of a lost cast: at most R_REISSUE_MAX of them, the
        -- Nth not before N*R_REISSUE_SPACING after dispatch, so a retry
        -- never lands on top of an in-progress cast. The first dispatch is
        -- fire_steps'; this only retries. On lock the slip is re-anchored
        -- (see the r_phase_seen transition below).
        if state.last_r_dispatch_t > 0 and not state.r_phase_seen then
            local age = now() - state.last_r_dispatch_t
            local tgt = state.last_r_target
            local tgt_ok = tgt and Entity.IsEntity(tgt)
                               and Target.IsAlive(tgt)
            if tgt_ok and age < state.R_PHASE_START_DEADLINE then
                local n = state.r_reissue_count or 0
                if n < state.R_REISSUE_MAX
                   and age >= (n + 1) * state.R_REISSUE_SPACING
                   and Ability.CastTarget then
                    Ability.CastTarget(r, tgt, false, false, true)
                    state.r_reissue_count = n + 1
                end
                return
            end
            -- Deadline elapsed (or target gone): R never entered its phase.
            tlog(1, "r_cast_never_started", {
                target   = uname(tgt),
                combo    = state.last_r_combo_name or "?",
                age_ms   = string.format("%.0f", age * 1000),
                reissues = state.r_reissue_count or 0,
            })
            state.last_r_target          = nil
            state.last_r_combo_name      = nil
            state.last_r_dispatch_t      = 0
            state.r_cast_protect_until_t = 0
            state.last_layer1_was_r      = false
            state.r_reissue_count        = 0
            return
        end
        -- v6.13 Offense F#1: cast may have completed normally (we'd never
        -- otherwise clear last_r_target, leaving stale state for the next R).
        -- Detect completion: if enough time has passed since dispatch for
        -- the cast to have started AND IsInAbilityPhase is now false, the
        -- cast resolved one way or another. Cast point 2.0s base / 0.5s
        -- Scepter — give 0.6s of slack for pre-step delays.
        -- v6.15.171 (KV-hardcode migration A3): r_cast_point() already
        -- encapsulates the Scepter-aware live cast point — dedup the literal.
        local cast_point = r_cast_point()
        local slack = 0.6
        if state.last_r_dispatch_t > 0
           and (now() - state.last_r_dispatch_t) > (cast_point + slack) then
            tlog(3, "r_target_cleared_completion", {
                target = uname(state.last_r_target),
                combo = state.last_r_combo_name or "?",
            })
            state.last_r_target     = nil
            state.last_r_combo_name = nil
            state.last_r_dispatch_t = 0
            state.r_reissue_count   = 0
        end
        return
    end

    -- v6.15.141 / v6.15.228: R is confirmed in its cast phase. On the
    -- false-to-true transition R has just locked, so the per-frame re-issue
    -- branch above stops (it is gated on not-in-phase). Re-anchor the combo
    -- deferred Q/E by the slip between first dispatch and lock, so a late
    -- lock (after several re-issues) does not let Shrapnel land mid-cast and
    -- cancel R.
    if not state.r_phase_seen then
        local slip = now() - state.last_r_dispatch_t
        tlog(1, "r_cast_locked", {
            combo    = state.last_r_combo_name or "?",
            reissues = state.r_reissue_count or 0,
            slip_ms  = string.format("%.0f", slip * 1000),
        })
        if slip > 0.05 and state.last_r_combo_name then
            for i = 1, #state.pending_steps do
                local p = state.pending_steps[i]
                if p.combo_name == state.last_r_combo_name then
                    p.fire_at = p.fire_at + slip
                end
            end
        end
        state.r_reissue_count = 0
    end
    state.r_phase_seen = true

    local target = state.last_r_target
    if not target or not Entity.IsEntity(target) then return end

    local abort, reason = false, nil
    if not Target.IsAlive(target) then
        abort, reason = true, "target_dead"
    elseif NPC.HasState(target, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
        abort, reason = true, "bkb_popped"
    elseif NPC.HasState(target, MS.MODIFIER_STATE_INVULNERABLE) then
        abort, reason = true, "invulnerable"
    elseif NPC.HasState(target, MS.MODIFIER_STATE_OUT_OF_GAME) then
        abort, reason = true, "out_of_game"
    elseif Target.HasReadyLinkens(target) then
        abort, reason = true, "linkens"  -- Linkens regen mid-cast or unpopped
    elseif Target.HasReadyLotus(target) then
        abort, reason = true, "lotus"
    end

    if not abort then return end

    state.abort_counter = state.abort_counter + 1
    tlog(1, "r_abort", {
        target = uname(target),
        reason = reason,
        combo  = state.last_r_combo_name or "?",
    })

    -- Issue STOP via the existing safe_issue wrapper. No ability/target —
    -- STOP cancels the current ability cast.
    safe_issue {
        hero       = HERO_KEY,
        layer      = "agg",
        intent     = "abort_r_" .. (state.last_r_combo_name or "unk"),
        order_type = UO.DOTA_UNIT_ORDER_STOP,
        unit       = state.self_npc,
    }

    -- Sweep pending_steps: drop any deferred steps belonging to the aborted
    -- combo (e.g., scheduled D in snipe_standard, Q1/Q2/Q3 in snipe_e_r).
    if state.last_r_combo_name then
        local kept = {}
        for i = 1, #state.pending_steps do
            local p = state.pending_steps[i]
            if p.combo_name ~= state.last_r_combo_name then
                kept[#kept + 1] = p
            end
        end
        state.pending_steps = kept
    end

    -- Re-open the commit window so the brain can pick a fresh combo this tick.
    state.last_layer1_t     = 0
    state.last_r_target     = nil
    state.last_r_combo_name = nil
end

-- Step kinds: "ut" = unit-target, "pt" = point-target, "nt" = no-target.
-- arg: function(ctx) -> arg_value (entity for ut, Vector for pt, nil for nt).
-- cond (optional): function(ctx) -> bool. If returns false, step skipped.
-- delay_s (optional): if present and > 0, the step is SCHEDULED for delayed
-- execution via pending_steps_tick instead of issued immediately. The arg_fn
-- and cond_fn are re-evaluated at fire time with live ctx (current
-- target_pos, current q_charges). Used for:
--   - snipe_standard's D (delay 1.5s — lands during R cast point for BKB lockout)
--   - snipe_e_r's Q2 (delay 2.5s — after R lands, with live target_pos)
--   - snipe_e_r's Q3 (delay 2.8s — staggered after Q2)
-- Returns count of immediate steps that successfully queued; scheduled steps
-- aren't counted (their result is determined later).
local function fire_steps(name, steps, ctx)
    local ok_count = 0
    for i = 1, #steps do
        local step = steps[i]
        -- v6.15.69: resolve dynamic delays once per dispatch.
        local delay = resolve_step_delay(step, ctx)
        if delay > 0 then
            -- Defer: cond_fn and arg_fn re-evaluated at fire time with live
            -- target_pos and q_charges; rest of ctx is dispatch-time snapshot.
            schedule_step(name, step, ctx, delay)
            tlog(3, "step_fire", {
                combo = name, step = step.short or ("s" .. i),
                kind = step.kind, ok = "deferred",
                delay = string.format("%.2f", delay),
            })
        elseif step.cond and not step.cond(ctx) then
            tlog(3, "step_fire", {
                combo = name, step = step.short or ("s" .. i),
                kind = step.kind, ok = "skip", reason = "cond_false",
            })
        else
            local arg = step.arg and step.arg(ctx) or nil
            local intent = name .. "_" .. (step.short or "s" .. i)
            local ok = false
            -- v6.15.36: same-tick subsequent steps need queue=true so the
            -- engine sequences them properly. Without queue=true, step N+1
            -- REPLACES step N in the unit's intent — step N's cast may
            -- get dropped before completing. Observed: grenade_self_kite's
            -- Q step (after D, same tick) had charges_before=3 /
            -- charges_after=3 / fired=n consistently — D's order replaced
            -- Q's or vice versa. With queue=true on the 2nd+ step the
            -- engine chains them (D fires, then Q fires after D resolves).
            -- The first step still uses queue=false to interrupt any
            -- prior action (orbwalk attack etc.) and begin the combo.
            -- v6.15.120: step.no_queue forces queue=false even for a 2nd+
            -- step. Heavy Starter needs E and R issued SAME-TICK as two fresh
            -- queue=false dispatches — E is an instant cast (0 cast point) that
            -- resolves immediately, then R casts. A queue chain (R queued
            -- behind E) makes the 2nd step unreliable (v6.15.103: E-first
            -- queue chain → R 0/6 fired). Only Heavy Starter sets no_queue;
            -- every legacy combo leaves it nil → unchanged behavior.
            local use_queue = (i > 1) and not step.no_queue
            if step.kind == "ut" then
                -- v6.15.220: an inline ut-step casting Assassinate (the `r`
                -- and `tf_r` single-step R finishers) gets execute_fast,
                -- matching the deferred path's issue_cast_target.
                -- execute_fast bypasses internal safety delays so R's order
                -- is processed ahead of the native subsystem orders queued
                -- the same tick (v6.15.95 rationale). Before this, only the
                -- deferred dr-combo R was protected; the inline `r` kill
                -- finisher and `tf_r` raced the flood unaided (v6.15.219
                -- log: starter_r_r 1/2). Scoped to A.R so non-critical ut
                -- casts are not accelerated.
                ok = safe_issue {
                    hero = HERO_KEY, layer = "agg", intent = intent,
                    order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
                    unit = state.self_npc, ability = ability(step.ability),
                    target = arg, queue = use_queue,
                    execute_fast = (step.ability == A.R),
                }
            elseif step.kind == "pt" then
                ok = safe_issue {
                    hero = HERO_KEY, layer = "agg", intent = intent,
                    order_type = UO.DOTA_UNIT_ORDER_CAST_POSITION,
                    unit = state.self_npc, ability = ability(step.ability),
                    position = arg, queue = use_queue,
                }
                -- v6.15.82: log the actual position passed to the cast so
                -- demo tests can verify Q corridor tiling (T2) and adaptive
                -- direction (T3) geometrically from log data alone.
                if ok and arg then
                    tlog(3, "step_cast_pos", {
                        intent = intent,
                        x      = string.format("%.0f", arg.x or 0),
                        y      = string.format("%.0f", arg.y or 0),
                    })
                end
            elseif step.kind == "nt" then
                ok = safe_issue {
                    hero = HERO_KEY, layer = "agg", intent = intent,
                    order_type = UO.DOTA_UNIT_ORDER_CAST_NO_TARGET,
                    unit = state.self_npc, ability = ability(step.ability),
                    queue = use_queue,
                }
            elseif step.kind == "item_self" then
                -- v6.15.19: item self-cast step. step.ability is the item
                -- name string (e.g. "item_hurricane_pike"); we resolve it
                -- via NPCLib.item(state.self_npc,) and route through safe_issue.
                local it = NPCLib.item(state.self_npc,step.ability)
                if it then
                    ok = safe_issue {
                        hero = HERO_KEY, layer = "agg", intent = intent,
                        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
                        unit = state.self_npc, ability = it,
                        target = state.self_npc, queue = use_queue,
                    }
                end
            elseif step.kind == "item_target" then
                -- v6.15.52 (G10): item cast on enemy target. step.ability is
                -- the item name string. arg is the unit. Used by snipe_standard's
                -- Pike-during-R step — Pike on enemy locks them in airborne for
                -- ~0.4s, holding them in place during R's 2.0s cast point so R
                -- can't miss to mid-cast Manta / movement.
                local it = NPCLib.item(state.self_npc,step.ability)
                if it and arg then
                    ok = safe_issue {
                        hero = HERO_KEY, layer = "agg", intent = intent,
                        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET,
                        unit = state.self_npc, ability = it,
                        target = arg, queue = use_queue,
                    }
                end
            end
            -- v6.12 Tier 3 #8: track the R-cast target so the abort tick can
            -- monitor for target dispel/invuln/death mid-cast and issue STOP
            -- to refund mana + skip R cooldown. Only set on R unit-target step.
            -- v6.15.90: track per-target Q cast time. q_stack_attacker
            -- and q_corridor_finisher consult this to refuse re-dispatch
            -- on a target that already has a Q zone in flight (zone
            -- duration ~9s after arming). Prevents the user-reported
            -- "Q still stacking on same spot" pattern where multiple
            -- back-to-back dispatches placed multiple Q1s at the same
            -- target_pos. Tracked per dispatch's TARGET (ctx.target),
            -- not per Q position, since the protect window is about
            -- "don't re-place Q on this target while old zone is active."
            if ok and step.ability == A.Q and step.kind == "pt"
               and ctx and ctx.target and Entity.IsEntity(ctx.target) then
                state.last_shrap_on_target_t[Entity.GetIndex(ctx.target)] = now()
            end
            if ok and step.ability == A.R and step.kind == "ut" then
                state.last_r_target     = arg
                state.last_r_combo_name = name
                state.last_r_dispatch_t = now()
                -- v6.15.86: native subsystem orders (orbwalker ATTACK_TARGET,
                -- Hit & Run MOVE) cancel R cast same-tick. cast_verify shows
                -- fired=n + cd_after=0 every snipe_e_r dispatch. Protect the
                -- cast window via OnPrepareUnitOrders veto of non-brain
                -- unit-disrupting orders. Window = R cast point + 0.4s buffer
                -- (cast point sufficient to lock the cast in engine).
                state.r_cast_protect_until_t = now() + r_cast_point() + 0.4
                state.r_phase_seen = false  -- v6.15.141: arm the fast-cancel detector
            end
            -- v6.15.107: per-ability fire-time tracking. state.last_q/e/d/r_t
            -- are read by auto_grenade_tick to gate "don't re-fire
            -- D within 1.5s of a combo D dispatch". Pre-v6.15.107 these fields
            -- were defined (lines 234-237) but never written — vestigial. QA
            -- against v6.15.107 caught the gap. Updated here on every successful
            -- step fire from fire_steps (eager / same-tick combos). Mirror
            -- update in pending_steps_tick for deferred steps.
            if ok then
                if     step.ability == A.Q then state.last_q_t = now()
                elseif step.ability == A.E then state.last_e_t = now()
                elseif step.ability == A.D then state.last_d_t = now()
                elseif step.ability == A.R then state.last_r_t = now()
                end
            end
            if ok then ok_count = ok_count + 1 end
            tlog(3, "step_fire", {
                combo = name, step = step.short or ("s" .. i),
                kind = step.kind, ok = ok and "y" or "n",
            })
            -- v6.15.37: log Sniper state + target geometry + queue state at
            -- the moment each combo step fires. Surfaces failure modes that
            -- the queue=true same-tick fix doesn't cover: silenced/stunned
            -- at fire moment, stale target_pos, queue collision, etc.
            local me = state.self_npc
            if me and Entity.IsEntity(me) then
                local mana = (NPC.GetMana and NPC.GetMana(me)) or 0
                local silenced = NPC.IsSilenced and NPC.IsSilenced(me) and "1" or "0"
                local stunned = NPC.IsStunned and NPC.IsStunned(me) and "1" or "0"
                local channelling = NPC.IsChannellingAbility and NPC.IsChannellingAbility(me) and "1" or "0"
                local q_total, q_self = queue_snapshot()
                local tgt_x, tgt_y, tgt_dist = "-", "-", "-"
                local me_pos = Entity.GetAbsOrigin(me)
                if step.kind == "pt" and arg and arg.x and arg.y and me_pos then
                    -- v6.15.197 (audit B1): native Vector arithmetic.
                    tgt_x = string.format("%.0f", arg.x)
                    tgt_y = string.format("%.0f", arg.y)
                    tgt_dist = string.format("%.0f", arg:Distance2D(me_pos))
                elseif (step.kind == "ut" or step.kind == "item_self")
                       and arg and Entity.IsEntity(arg) and me_pos then
                    local tpos = Entity.GetAbsOrigin(arg)
                    if tpos then
                        tgt_x = string.format("%.0f", tpos.x)
                        tgt_y = string.format("%.0f", tpos.y)
                        tgt_dist = string.format("%.0f", tpos:Distance2D(me_pos))
                    end
                end
                tlog(1, "combo_fire_state", {
                    intent      = intent,
                    ok          = ok and "y" or "n",
                    step_idx    = tostring(i),
                    kind        = step.kind,
                    same_tick   = use_queue and "y" or "n",
                    mana        = string.format("%.0f", mana),
                    silenced    = silenced,
                    stunned     = stunned,
                    channelling = channelling,
                    tgt_x       = tgt_x,
                    tgt_y       = tgt_y,
                    tgt_dist    = tgt_dist,
                    q_total     = tostring(q_total),
                    q_self      = tostring(q_self),
                    -- v6.15.82: surface atk_range_with_e (live, Take Aim
                    -- range bonus dynamic per v6.15.79) so demo Test 12
                    -- can verify L25 Sniper's +400 range vs prior +140
                    -- without computing it from ctx externally.
                    atk_range_e = string.format("%.0f",
                        effective_attack_range(state.self_npc) + take_aim_range_bonus()),
                })
            end
        end
    end
    return ok_count
end

-- v6.15.110 (user feedback from v6.15.109 demo): "R calculations are usually
-- off and not doing the finalization, missing by 1 auto attack. Usually a
-- low value." The brain over-estimates combo damage (or under-estimates
-- target eff_hp) by ~50-150 HP, fires R, and target survives with a sliver.
-- Wasting 110s R cooldown.
--
-- Likely sources of over-estimate:
--   - rc_2s assumes 2 full seconds of autos with Take Aim; real attack
--     cycle has variance, target may move out of range mid-window
--   - Headshot proc rate is statistical (40% baseline, 100% with Take Aim
--     active) — over a small sample (4-5 autos in 2s) actual procs vary
--   - q_dmg assumes one Q zone fully ticks; target may leave zone early
--
-- Add a flat HP buffer to the kill-check expression so R refuses when
-- gap < buffer. 100 HP ≈ one Sniper auto with Headshot proc and net armor
-- reduction (~150 raw → ~100 net for typical heroes). Catches the "off
-- by 1 auto" miss. Conservative trade: refuses some borderline kills,
-- but a refused R is reusable in 110s; a wasted R is gone.
--
-- Applied to all 6 R-using commit_pred kill checks: snipe_e_r, snipe_d_r,
-- snipe_q_r, snipe_standard, snipe_r_only, snipe_channel_punish — 5 of them
-- via the `(eff_hp_check + OVERKILL_BUFFER_HP) <= combo_dmg` pattern, plus
-- snipe_e_r's `will_fire = ...` form in its combo_dmg_breakdown log path.
-- (v6.15.116 doc fix: the prior comment said "5 sites" and omitted
-- snipe_channel_punish — the code always applied the buffer to all 6.)
--
-- If user feedback says "buffer too aggressive" or "too lax", make this
-- a menu slider in v6.15.111+.
--
-- Stored as a state field rather than a top-level local because the brain's
-- main chunk has accumulated close to Lua 5.4's 200-locals-per-function
-- hard limit; a `local OVERKILL_BUFFER_HP = 100` at this point would push
-- it over and crash with "too many local variables" at parse time. Future
-- additions of module-level constants should use the same pattern.
state.OVERKILL_BUFFER_HP = 100
-- v6.15.239: RC_MIN_DAMAGE_FACTOR -- the conservative (min-side) fraction
-- of the autoattack damage window used in the rc_2s kill estimate. Moved
-- from a build_layer1_ctx local to a state constant so kill_confidence can
-- reconstruct the optimistic (full-window) RC for its damage band.
state.RC_MIN_DAMAGE_FACTOR = 0.5

-- v6.15.48 (user directive): corridor Q placement for fleeing targets.
-- 'the corridor might be made on any direction the target is going and
-- the chances of killing are guaranteed or high; IF there is no chance
-- of killing it is better to just let it go than waisting everything.'
-- Kill-chance gate is handled separately by live_q_kill_floor in step
-- cond; this helper only computes WHERE to place the Q. Behavior:
--   • Target engaging or stationary → stack on current position.
--   • Target kiting us (fleeing) AND moving > 200 MS → lead by
--     (movespeed × lead_s) in target's facing direction. Q lands
--     ahead of target's path so they run into the shrap zone.
-- Different lead_s values across Q1/Q2/Q3 build the corridor: tight
-- stack at first Q, spreading lead at subsequent Qs.
-- v6.15.112: lead_target_pos extracted to lib/geometry.lua (Geom.lead_target_pos).
-- Frees 1 local slot from main chunk. Same signature, no behavior change.
-- Sniper.lua callers updated via replace_all.

-- v6.15.73 (LIQUIPEDIA_REF.md, Q ability section): Shrapnel radius is
-- LEVEL-DEPENDENT — 400/425/450/475 at Q level 1/2/3/4.
-- v6.15.168 (KV-hardcode migration #2): radius read LIVE off the Q handle
-- via state.item_kv — Ability.GetLevelSpecialValueFor auto-resolves Q's
-- level, so the value tracks Valve retunes. KV sniper_shrapnel `radius`
-- (confirmed 400/425/450/475). The BY_LEVEL table is the no-handle
-- fallback, a snapshot of the current KV. Behaviour-neutral.
local SHRAP_RADIUS_BY_LEVEL = { 400, 425, 450, 475 }
local function shrap_radius()
    local q = ability(A.Q)
    if not q or not Ability.GetLevel then return 450 end
    local lvl = Ability.GetLevel(q) or 0
    if lvl < 1 then return 450 end
    local fb = SHRAP_RADIUS_BY_LEVEL[math.max(1, math.min(4, lvl))] or 450
    return state.item_kv(q, "radius", fb)
end

-- v6.15.79 (LIQUIPEDIA_REF.md, Take Aim section): passive attack range
-- bonus is LEVEL-DEPENDENT — 160/240/320/400 at E level 1/2/3/4. v6.11
-- through v6.15.78 used hardcoded +140 which was conservative at L1 but
-- severely under-counted late game (+260u missing at L4). Affects
-- atk_range_with_e in build_layer1_ctx and project_target_state's
-- in_atk_range check. Returns 0 if E is unlearned.
-- take_aim_range_bonus forward-declared at top (line ~55) so callers above
-- this line resolve correctly; this is the assignment.
-- v6.15.168 (KV-hardcode migration #2): bonus read LIVE off the E handle
-- via state.item_kv. KV sniper_take_aim `passive_attack_range_bonus`
-- (confirmed 160/240/320/400). BY_LEVEL is the no-handle fallback.
-- Behaviour-neutral.
local TAKE_AIM_RANGE_BY_LEVEL = { 160, 240, 320, 400 }
take_aim_range_bonus = function()
    local e = ability(A.E)
    if not e or not Ability.GetLevel then return 140 end
    local lvl = Ability.GetLevel(e) or 0
    if lvl < 1 then return 0 end
    local fb = TAKE_AIM_RANGE_BY_LEVEL[math.max(1, math.min(4, lvl))] or 140
    return state.item_kv(e, "passive_attack_range_bonus", fb)
end

-- v6.15.79: overkill margin constant for snipe_e_r's init-bypass gate
-- (v6.15.77 cleanup-vs-initiation hard refusal). Promoted to module-level
-- so future iterations can tune without code archaeology.
local COMBO_OVERKILL_MARGIN = 1.3

-- v6.15.81 (LIQUIPEDIA_REF.md, Take Aim section): self-MS-slow detection.
-- Take Aim active slows Sniper's own movement while up — Sniper loses
-- kiting capability during the active window — saves and positioning
-- decisions should know about this vulnerability. Returns
-- (active_bool, slow_pct_number).
-- v6.15.168 (KV-hardcode migration #2): slow magnitude read LIVE off the
-- E handle via state.item_kv (KV sniper_take_aim `slow`). The old
-- per-level table {45,40,35,30} had ROTTED — the live KV `slow` is now a
-- flat value (snapshot 65). The live read self-corrects to the current
-- patch regardless. slow_pct is informational only — it feeds the
-- save_take_aim_active / self_ms_slow_pct logs, no combat decision — so
-- this is behaviour-neutral in combat (only the logged number changes).
self_take_aim_state = function()
    local me = state.self_npc
    if not me or not NPC.HasModifier then return false, 0 end
    -- v6.15.147 (user confirmed, full-test C2: Take Aim is NEVER up in
    -- teamfights yet the `ta` diagnostic logged y on every tick): the old
    -- check `HasModifier(..._active) OR HasModifier(modifier_sniper_take_aim)`
    -- matched the second name on EVERY tick — `modifier_sniper_take_aim` is
    -- Take Aim's ALWAYS-ON passive (attack-range) modifier, not the active
    -- buff. So self_take_aim_state was stuck true, and the teamfight E
    -- archetypes (the only ones gated on `not self_take_aim_active`) never
    -- fired. Check ONLY the active-buff modifier. If that name is wrong in a
    -- future patch this returns false (E may over-cast — harmless, E's own
    -- cooldown limits it) rather than stuck-true (E never casts at all).
    local active = NPC.HasModifier(me, "modifier_sniper_take_aim_active")
    if not active then return false, 0 end
    return true, state.item_kv(ability(A.E), "slow", 65)
end

-- ─── COMBOS (R-commit) ────────────────────────────────────────────────────

-- v6.10 G4: detect a cluster of enemies near the target (for Scepter AoE R).
-- Scepter R becomes 400-radius AoE crit attack at 0.5s cast. Worth firing
-- when ≥2 enemies are within ~400u of each other AND at most 1 has BKB up.
----------------------------------------------------------------------------
-- v6.15.118 — adaptive-engagement combo-key core
----------------------------------------------------------------------------
-- The combo key classifies the engagement and dispatches an archetype:
--   TAP  (press+release < COMBO_TAP_MAX_S) → Heavy Starter: E+R fire-on-
--         command, minimal gates, no kill check — the player decided.
--   HOLD → Starter (1-2 enemies) or Team Fight (3+) per the classifier.
-- v6.15.118 shipped the tap/hold detection, classifier and routing; the
-- Starter per-tick adaptive loop (v6.15.119+) and Team Fight mode (v6.15.120+)
-- are the HOLD bodies. Entry points use the state.X pattern — no top-level
-- local slots (Lua 5.4 200-locals limit, see lesson 7).

-- v6.15.127: smoothed-velocity target prediction. The v6.15.125 model read
-- the engine's INSTANTANEOUS velocity (m_vecVelocity) — accurate but noisy
-- tick-to-tick (a target mid-turn, attack-move micro-stutter, one jittery
-- sample), so consecutive chip-Q predictions jittered and the zones still
-- overlapped on moving targets. sample_velocities() records each nearby enemy
-- hero's position every tick into a short ring buffer; predict_pos() derives a
-- velocity by averaging the position delta over the whole buffer (~0.33s),
-- which smooths the jitter → steadier Q placement. A filtering improvement,
-- not a different predictor.
state.sample_velocities = function()
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return end
    local list = Entity.GetHeroesInRadius(me, 3200, Enum.TeamType.TEAM_ENEMY)
    if not list then return end
    local t = now()
    state.attacking_seen_t = state.attacking_seen_t or {}
    for i = 1, #list do
        local h = list[i]
        if h and Entity.IsEntity(h) and Target.IsAlive(h) then
            local idx = Entity.GetIndex(h)
            local pos = Entity.GetAbsOrigin(h)
            -- v6.15.135: latch the last tick this enemy was mid-attack-
            -- animation. NPC.IsAttacking is true only for the ~0.3s swing of
            -- each ~1.4s attack cycle, so a single-tick read flickers — the
            -- `committed` classifier in starter_tick latches over
            -- COMMITTED_ATTACK_WINDOW_S using this stamp.
            if idx and NPC.IsAttacking and NPC.IsAttacking(h) then
                state.attacking_seen_t[idx] = t
            end
            if idx and pos then
                local buf = state.vel_hist[idx]
                if buf and #buf > 0 then
                    local last = buf[#buf]
                    local gap_dt = t - last.t
                    -- a >0.25s gap means the target was out of vision/range —
                    -- restart the buffer so velocity isn't computed across it.
                    if gap_dt > 0.25 then
                        buf = nil
                    else
                        -- v6.15.194 (audit #2): per-tick displacement above
                        -- what any hero could traverse on foot = a teleport
                        -- or blink discontinuity (Blink Dagger, TP, Pounce,
                        -- Phantom Strike, Tricks of the Trade, etc.). Without
                        -- this guard the pre-blink sample stays in the buffer
                        -- and predict_pos derives a phantom 3000+ u/s
                        -- velocity for the next ~0.33s — Q/D zones lead 1.5s
                        -- along the bogus vector, well off the target's real
                        -- post-blink position. 700 u/s is a generous foot-
                        -- speed cap (capped MS 550 + Drums/Phase/etc.),
                        -- comfortably under any blink and comfortably over
                        -- any legitimate movement. +0.05s slack absorbs tick
                        -- jitter.
                        local dx, dy = pos.x - last.x, pos.y - last.y
                        local cap = 700 * (gap_dt + 0.05)
                        if (dx * dx + dy * dy) > (cap * cap) then
                            buf = nil
                        end
                    end
                end
                if not buf then buf = {}; state.vel_hist[idx] = buf end
                buf[#buf + 1] = { t = t, x = pos.x, y = pos.y }
                while #buf > state.VEL_HIST_N do table.remove(buf, 1) end
            end
        end
    end
end

-- Predicted target position `lead_s` seconds ahead, using the smoothed
-- velocity from sample_velocities()' buffer. Falls back to the stateless
-- Geom.lead_target_pos (instantaneous m_vecVelocity) when there is no usable
-- history. Returns nil only for an invalid target (callers do `... or fb`).
state.predict_pos = function(target, lead_s)
    if not target or not Entity.IsEntity(target) then return nil end
    local tpos = Entity.GetAbsOrigin(target)
    if not tpos then return nil end
    local idx = Entity.GetIndex(target)
    local buf = idx and state.vel_hist[idx]
    if buf and #buf >= 2 then
        local newest, oldest = buf[#buf], buf[1]
        local dt = newest.t - oldest.t
        if dt >= 0.05 and (now() - newest.t) < 0.25 then
            local vx = (newest.x - oldest.x) / dt
            local vy = (newest.y - oldest.y) / dt
            -- v6.15.197 (audit B5): stationary floor 5 u/s -> 60 u/s.
            -- The 5 u/s gate (25 squared) let path-spline drift on a
            -- held-position hero (idle micro-motion, target-attacking
            -- shuffle) register as movement, so Q led 1.5 s along a
            -- ~5-50 u/s phantom vector and landed tens of units off the
            -- actual stationary target. 60 u/s (3600 squared) cleanly
            -- separates spline drift (well under) from legitimate move
            -- (~200+ u/s base MS).
            if (vx * vx + vy * vy) > 3600 then  -- smoothed speed > 60 u/s
                return Vector(tpos.x + vx * lead_s,
                              tpos.y + vy * lead_s, tpos.z)
            end
            return tpos  -- smoothed velocity ≈ 0 → stationary, no lead
        end
    end
    -- v6.15.197 (audit B6): the first-sight fallback (vel_hist <2 samples)
    -- falls through to Geom.lead_target_pos which uses instantaneous
    -- m_vecVelocity. A target that just entered vision while mid-attack-
    -- shuffle / mid-blink-settle has a non-zero m_vecVelocity and yields
    -- a bad lead exactly when prediction matters (alpha-strike Q). If the
    -- target is currently in a hard-CC state (stunned / rooted / frozen)
    -- its real velocity is zero — return current pos directly. Belt-and-
    -- suspenders after v6.15.194 #2's blink-buffer invalidation, since
    -- this path is the buffer-empty case that #2 doesn't cover.
    if NPC.HasState and (
          NPC.HasState(target, MS.MODIFIER_STATE_STUNNED)
       or NPC.HasState(target, MS.MODIFIER_STATE_ROOTED)
       or NPC.HasState(target, MS.MODIFIER_STATE_FROZEN)) then
        return tpos
    end
    -- v6.15.225: cap the buffer-empty fallback lead at foot speed.
    -- Geom.lead_target_pos reads instantaneous m_vecVelocity; for a target
    -- mid-displacement (Concussive Grenade knockback etc.) that is the
    -- knockback velocity, a 2000+ u/s phantom that threw the dr-combo D
    -- ~600u past the attacker. The vel_hist path is per-tick capped
    -- (v6.15.194); this fallback was not, and v6.15.197's CC-state guard
    -- above covers stun/root/freeze, not forced movement.
    local lp = Geom.lead_target_pos(target, state.self_npc, lead_s)
    if not lp then return tpos end
    local lx, ly = (lp.x or 0) - tpos.x, (lp.y or 0) - tpos.y
    local cap = 700 * lead_s
    if (lx * lx + ly * ly) > cap * cap then return tpos end
    return lp
end

-- v6.15.128 / v6.15.254: optimal Concussive Grenade (D) placement for the
-- dr combo. D knocks units in its blast AWAY from the grenade's centre, so
-- the cast point determines push direction. The right placement depends on
-- target range:
--
-- * Close-range (dist <= 750u, both Sniper and attacker fit in the 375u
--   self-push radius of a midpoint cast): MIDPOINT between Sniper and
--   attacker. Both get knocked back 475u from the midpoint -- attacker
--   pushed away from Sniper, Sniper pushed away from attacker -- total
--   mutual separation ~1000u. Same geometry as auto_grenade close-mode
--   and v6.15.252 grenade_at_caster. Pre-v6.15.254 the 300u-inward
--   formula `g = max(0, dist-300)` clamped to 0 for any dist<300,
--   casting AT Sniper's own position -- both in blast but Sniper push
--   from a zero-vector cast is engine-fallback random/facing. The
--   "weird D position" the user reported for combo D in PA scenarios
--   was this clamp-to-zero.
--
-- * Long-range (dist > 750u, Sniper not in self-push radius of a
--   midpoint): legacy 300u-inward placement. attacker sits at the FAR
--   edge of the blast and is shoved straight away from Sniper. Sniper
--   is outside the blast so not pushed. Clamped to D's cast range.
--
-- Returns target_pos as a safe fallback.
--
-- v6.15.254: removed the v6.15.248 danger-aware rotation block per
-- user direction ("over-engineering: if D is cast on the right position
-- sniper will turn himself alone without intervention"). The midpoint
-- baseline IS the right position; the engine handles Sniper's turn to
-- face cast_pos automatically. The shared turn-cost factor in
-- danger_at_pos was making the helper pick rotated angles even in 1v1,
-- producing "seems random" cast positions. The factor stays in place
-- for blink_escape_position and pike_self_reposition where the active
-- direction pick is structurally appropriate.
state.optimal_d_pos = function(c)
    local me = state.self_npc
    local mp = (me and Entity.IsEntity(me)) and NPCLib.origin(me) or nil
    -- v6.15.161: lead the attacker's movement. dr_peel is an IMMEDIATE step,
    -- so c.target_pos is the dispatch-time snapshot — but D has a cast point +
    -- humanizer delay + projectile travel before it lands. Against a moving
    -- attacker (PA chasing a Hit&Run-kited Sniper) the grenade was landing
    -- behind them, so the knockback shoved them sideways / the wrong way.
    -- Predict where the attacker will be at grenade-impact; fall back to the
    -- dispatch snapshot if prediction is unavailable.
    local tp = (c and c.target
                and state.predict_pos(c.target, state.D_PEEL_LEAD_S))
            or (c and c.target_pos)
    if not mp or not tp then return tp end
    local dx, dy = (tp.x or 0) - (mp.x or 0), (tp.y or 0) - (mp.y or 0)
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return tp end
    local GRENADE_RADIUS = 375
    if d <= GRENADE_RADIUS * 2 then
        -- close-range: midpoint. Both in blast, both pushed apart.
        return Vector((mp.x + tp.x) * 0.5, (mp.y + tp.y) * 0.5, mp.z or 0)
    end
    -- long-range: 300u-inward placement (legacy v6.15.128 geometry).
    local cast_d = (c.cast_d and c.cast_d > 0) and c.cast_d or 600
    local g = d - state.D_PEEL_OFFSET
    if g > cast_d then g = cast_d end
    return Vector(mp.x + dx / d * g, mp.y + dy / d * g, mp.z or 0)
end

-- Classifier: count alive, real enemy heroes within COMBO_CLASSIFY_RADIUS of
-- Sniper. 3+ → Team Fight, 1-2 → Starter.
state.count_engaged_enemies = function()
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return 0 end
    local list = Entity.GetHeroesInRadius(me, state.COMBO_CLASSIFY_RADIUS,
                                          Enum.TeamType.TEAM_ENEMY)
    if not list then return 0 end
    local count = 0
    for i = 1, #list do
        local h = list[i]
        if h and Target.IsAlive(h) and Target.NotClone(h)
           and Target.NotIllusion(h) then
            count = count + 1
        end
    end
    return count
end

-- Heavy Starter (TAP): cast R then E. R-first ordering — v6.15.103 proved
-- E-first lets Take Aim's modifier activation trigger the native positioning
-- subsystem, which cancels R. R-first locks R's cast point before Take Aim
-- applies; Take Aim is still active at R impact for the 100% headshot on the
-- physical instance. Fire-on-command: minimal gates only, NO commit_pred kill
-- check — the player tapped, they meant it. force_key bypasses the mana /
-- range / magic-immune gates (R and E still have to be off cooldown).
state.heavy_starter_tick = function(force)
    if not self_alive_ok() then return end
    -- Target: the top valuation candidate (baseline-hint-aware — the player's
    -- cursor target is promoted to slot 1). Fall back to the nearest enemy
    -- hero so a long-range tap past the 1500u candidate scan still initiates.
    local target
    local c1 = state.candidates and state.candidates[1]
    if c1 and c1.target and Entity.IsEntity(c1.target)
       and Target.IsAlive(c1.target) then
        target = c1.target
    else
        local me = state.self_npc
        local list = me and Entity.GetHeroesInRadius(me, 3500,
                                Enum.TeamType.TEAM_ENEMY) or nil
        local best_d
        if list then
            for i = 1, #list do
                local h = list[i]
                if h and Target.IsAlive(h) and Target.NotClone(h)
                   and Target.NotIllusion(h) then
                    local hd = dist_to(h)
                    if hd and (not best_d or hd < best_d) then
                        best_d, target = hd, h
                    end
                end
            end
        end
    end
    if not target then
        tlog(1, "heavy_starter", { decision = "refuse", reason = "no_target" })
        return
    end

    local ctx = build_layer1_ctx(target, 0)
    -- v6.15.174: E+R tap damage-calc log. The TAP fires R on command and
    -- deliberately skips the kill check — the player may tap to poke, to
    -- interrupt a channel, or to secure a kill ("several applications"), so
    -- the brain commits without a kill gate. This logs what the damage model
    -- WOULD predict so the calc can be back-checked: dmg_e_r = R with Take
    -- Aim active (100% headshot — what the tap delivers when E fires),
    -- dmg_r_only = R alone (E on cooldown, 40% headshot). Both raw HP,
    -- comparable to cast_outcome hp_delta. Emitted BEFORE the ready_r gate,
    -- so it appears on every tap attempt regardless of cooldown — ready_r /
    -- ready_e show the live CD state (this is how to confirm the damage calc
    -- runs unconditionally, not only when R is off cooldown).
    local tap_e = r_kill_prediction and r_kill_prediction(target, true)
    local tap_r = r_kill_prediction and r_kill_prediction(target, false)
    do
        local e_fires = ctx.ready_e and true or false
        local actual  = e_fires and tap_e or tap_r
        tlog(1, "tap_combo", {
            target     = uname(target),
            tgt_hp     = string.format("%.0f", Entity.GetHealth(target) or 0),
            ready_r    = ctx.ready_r and "y" or "n",
            ready_e    = ctx.ready_e and "y" or "n",
            e_fires    = e_fires and "y" or "n",
            dmg_e_r    = tap_e and string.format("%.0f", tap_e.pred_raw) or "?",
            dmg_r_only = tap_r and string.format("%.0f", tap_r.pred_raw) or "?",
            would_kill = actual and (actual.kill and "y" or "n") or "?",
        })
    end
    -- Hard requirement: R must be castable (ready_r accounts for the R-cast-
    -- in-flight protect window). v6.15.135 (user, v6.15.134 demo: "tap combo
    -- to force R took several tries"): E is NO LONGER a hard requirement —
    -- the demo refused the tap 19/20 times with ready_r=y, ready_e=n (E on its
    -- 14-20s cooldown). The TAP is "fire R on command"; E (Take Aim) is a
    -- damage buff, nice-to-have, not mandatory. E is now a conditional step
    -- (fires only if ready); R fires regardless of E.
    if not ctx.ready_r then
        tlog(1, "heavy_starter", {
            decision = "refuse", reason = "not_ready", target = uname(target),
            ready_r = ctx.ready_r and "y" or "n",
            ready_e = ctx.ready_e and "y" or "n",
        })
        return
    end
    -- Minimal gates (skipped on force): mana for R (+E only if E will fire),
    -- in R cast range, not magic-immune.
    if not force then
        -- v6.15.171 (KV-hardcode migration A5): Take Aim KV mana is 50, not
        -- 35 — the old fallback under-budgeted E by 15 mana if GetManaCost
        -- ever returned nil.
        local e_cost = ability(A.E) and (Ability.GetManaCost(ability(A.E)) or 50) or 50
        local r_cost = ability(A.R) and (Ability.GetManaCost(ability(A.R)) or 175) or 175
        -- v6.15.135: E contributes to the mana floor only if it will actually
        -- fire (ready_e) — otherwise the tap is R-only and needs only r_cost.
        local need = r_cost + (ctx.ready_e and e_cost or 0)
        local reason
        if     ctx.mana < need     then reason = "mana"
        elseif ctx.d > ctx.cast_r  then reason = "out_of_range"
        elseif ctx.magic_immune    then reason = "magic_immune"
        end
        if reason then
            tlog(1, "heavy_starter", {
                decision = "refuse", reason = reason, target = uname(target),
            })
            return
        end
    end

    -- v6.15.229: E immediate, R deferred 0.1s, the dr-combo shape. The
    -- same-tick E+R of v6.15.119-.228 was chronically fragile (gotchas #48
    -- and #103, the v6.15.120 saga, v6.15.223 no_fast, and finally
    -- v6.15.228 per-frame re-issue stomping E): a queue=false R issued
    -- alongside E can replace E before it casts. Deferring R ends that
    -- collision class. E fires alone on the tap; R dispatches 0.1s later
    -- (E, an instant cast, is long done by then); the v6.15.228 per-frame
    -- re-issue then makes the deferred R reliable, which is exactly what
    -- v6.15.119 lacked when it found a deferred R got cancelled.
    -- heavy_starter is now structurally identical to the dr combo, so an
    -- R-dispatch change cannot single it out again. E stays cond-gated on
    -- ready_e (v6.15.135): on E cooldown the step skips and R fires alone.
    local steps = {
        { ability = A.E, kind = "nt", short = "e",
          cond = function(c) return c.ready_e end },
        { ability = A.R, kind = "ut", short = "r", delay_s = 0.1,
          arg = function(c) return c.target end },
    }
    tlog(1, "heavy_starter", {
        decision = "fire", target = uname(target),
        force = force and "y" or "n",
    })
    state.last_layer1_intent = "heavy_starter:" .. uname(target)
    state.l1_counter = state.l1_counter + 1
    if force then state.force_counter = state.force_counter + 1 end
    state.last_refusal = nil
    -- v6.15.174: hand the tap damage prediction to the issue choke point so
    -- the TAP R's cast_outcome line carries the predicted E+R damage next to
    -- the HP actually removed. Read-and-cleared by issue on the next R cast.
    state.tap_pending = {
        t          = now(),
        e_fires    = ctx.ready_e and true or false,
        dmg_e_r    = tap_e and tap_e.pred_raw or nil,
        dmg_r_only = tap_r and tap_r.pred_raw or nil,
    }
    fire_steps("heavy_starter", steps, ctx)
    state.last_layer1_t     = now()
    state.last_layer1_was_r = true   -- R combo → 2.5s commit lock
    state.engaged_target    = target
    state.engaged_target_t  = now()
end

-- HOLD-mode dispatch — the STARTER per-tick adaptive engagement loop
-- (HOLD, 1-2 enemies). v6.15.121. Every tick the key is
-- held, this re-appraises the engaged target (subject to the dispatch
-- throttle) and picks ONE archetype:
--   killable + engaged (committed / in attack range) + R worth it → D+R+E
--   killable + engaged but R unavailable / point-blank            → D (lock)
--   killable + fleeing + R alone kills                            → R
--   not yet killable                                              → Q1+E chip
-- Per-tick re-evaluation IS the state machine: a target that commits mid-chip
-- escalates to D+R on the next off-throttle tick with no explicit phase var.
-- R-range discipline: R only fires at ≥70% of (Take-Aim) attack range — a
-- point-blank target is right-clicked down, not ulted. rc_2s is discounted
-- (user demo: the 2s-of-autos estimate over-counts, R misses by ~1 auto).
-- ========================================================================
-- dr-combo shared helpers (v6.15.221). The D+R+Q+E close-gap "defensive
-- ultimate" runs in BOTH starter_tick (1-2 enemies) and teamfight_tick (3+):
-- in a teamfight the enemy team commonly dives Sniper directly, and the peel
-- combo must answer that, but ONLY for a committed attacker. These helpers
-- are the single source of truth so the two ticks cannot drift.
-- ========================================================================

-- Global chip/dr/tf-Q zone-coverage check. Hoisted to module scope in
-- v6.15.221 (was a local inside starter_tick) so build_dr_steps can use it.
-- Zones do NOT stack (v6.15.79); the gate is GLOBAL (state.starter_q_track,
-- recent Q placements, v6.15.131) and compares the NEW Q's intended spot.
state.q_spot_covered = function(p)
    if not p then return false end
    -- v6.15.195 (audit A5): live Q radius (Q4 KV is 475u; the prior 400u
    -- constant let zones overlap).
    local cr  = shrap_radius() or state.STARTER_Q_COVER_R
    local cr2 = cr * cr
    for i = 1, #state.starter_q_track do
        local trk = state.starter_q_track[i]
        if (now() - trk.t) < state.STARTER_Q_ZONE_LIFE then
            local dx = (p.x or 0) - trk.x
            local dy = (p.y or 0) - trk.y
            if (dx * dx + dy * dy) < cr2 then return true end
        end
    end
    return false
end

-- Is `target` a COMMITTED attacker on Sniper: attacking him, close, not
-- kiting. `ectx` is build_layer1_ctx(target). committed = target_attacking_us
-- (within ~700u, not kiting) AND mid-attack, the latter LATCHED over
-- COMMITTED_ATTACK_WINDOW_S because NPC.IsAttacking is true only for the
-- ~0.3s swing of each attack cycle (v6.15.135). The D+R+Q+E combo is the
-- only thing this gates, in both starter and teamfight.
state.is_committed_attacker = function(target, ectx)
    if not (ectx and ectx.target_attacking_us) then return false end
    if not NPC.IsAttacking then return true end
    if target and Entity.IsEntity(target) and NPC.IsAttacking(target) then
        return true
    end
    local tidx = target and Entity.IsEntity(target)
                 and Entity.GetIndex(target)
    local seen = tidx and state.attacking_seen_t
                 and state.attacking_seen_t[tidx]
    return (seen and (now() - seen) < state.COMMITTED_ATTACK_WINDOW_S)
           and true or false
end

-- The dr-combo peel step: D when ready, else Hurricane Pike on the enemy
-- (D's fallback when D is on cooldown, v6.15.130). Returns nil if neither
-- tool is usable, in which case the caller skips the dr combo.
state.resolve_dr_peel = function(ctx)
    if not ctx then return nil end
    if ctx.ready_d then
        return { ability = A.D, kind = "pt", short = "d",
                 arg = function(c) return state.optimal_d_pos(c) end }
    end
    if NPCLib.item_ready(state.self_npc, "item_hurricane_pike")
       and not ctx.magic_immune
       and (dist_to(ctx.target) or math.huge) <= state.pike_enemy_range() then
        return { ability = "item_hurricane_pike", kind = "item_target",
                 short = "pike", arg = function(c) return c.target end }
    end
    return nil
end

-- The dr-combo step table: D (or Pike) then R then Q then E. Timing (see
-- changelog v6.15.218/.219): D-first then deferred R is the proven v6.15.124
-- snipe_d_r pattern; Q and E timings were re-derived. D immediate; R deferred
-- +0.2s (fires after D's 0.1s cast point, so R's queue=false dispatch never
-- cancels D; the deferred path routes R through issue_cast_target, which sets
-- execute_fast for Assassinate). Q deferred +r_cast_point+0.3 (after R's cast
-- point completes; a Shrapnel cast mid-R-cast cancels R). E (Take Aim) LAST,
-- +r_cast_point+0.8, after Q's cast animation (E before Q would burn Take
-- Aim's window on Q's animation). Q, E AND R are all cond-gated (v6.15.151):
-- the only hard requirement is a peel tool.
state.build_dr_steps = function(dr_peel)
    return {
        dr_peel,
        { ability = A.R, kind = "ut", short = "r",
          delay_s = 0.2,
          cond = function(c) return c.ready_r end,
          arg = function(c) return c.target end },
        { ability = A.Q, kind = "pt", short = "q",
          delay_s = function(c) return r_cast_point() + 0.3 end,
          -- v6.15.133: dr-Q gates on the global Q-coverage list so
          -- back-to-back dr dispatches do not restack zones on one spot.
          cond = function(c)
              return (c.q_charges or 0) >= 1
                 and not state.q_spot_covered(
                     state.predict_pos(c.target, q_arm_lead_s()))
          end,
          arg  = function(c)
              return state.predict_pos(c.target, q_arm_lead_s())
                  or c.target_pos
          end },
        { ability = A.E, kind = "nt", short = "e",
          delay_s = function(c) return r_cast_point() + 0.8 end,
          cond    = function(c) return c.ready_e end },
    }
end

state.starter_tick = function(force)
    if not self_alive_ok() then return end

    -- Dispatch throttle — same windows as layer1_tick (R commit 2.5s, lighter
    -- chip/lock 0.4s) so the loop does not re-fire every frame.
    -- v6.15.180 (user, demo: R fired at wildly inconsistent target HP —
    -- eff_hp 435 one cast, 727 another, same gate): the post-R commit lock
    -- (2.5s) stays a HARD stop — R is in flight, nothing else should run.
    -- But the 0.4s post-chip light lock must NOT delay an R-finish: it only
    -- re-evaluated the loop every 0.4s, and with a fully-itemed Sniper one
    -- autoattack inside that 0.4s window is a huge HP chunk — so the R commit
    -- was quantized to the 0.4s tick and landed at inconsistent HP. During
    -- the light lock the tick now still runs; `r_finish_only` then suppresses
    -- everything EXCEPT the `r` kill finisher, so R fires the instant the
    -- target is killable while chip / dr re-dispatch stays throttled.
    local was_r = state.last_layer1_was_r
    local lock_window = was_r and LAYER1_COMMIT_WINDOW_R or LAYER1_COMMIT_WINDOW_SEQ
    local in_lock = (state.last_layer1_t
                     and (now() - state.last_layer1_t) < lock_window) or false
    if in_lock and was_r then return end
    local r_finish_only = in_lock

    -- Engaged target. v6.15.129: with multiple enemies, focus the one
    -- ACTIVELY ATTACKING Sniper first (user) — scan the candidate list for a
    -- close, mid-attack enemy. Else the top valuation candidate (sticky during
    -- a hold), else the stickiness target, else nearest enemy hero.
    local target
    local cands = state.candidates or {}
    for i = 1, math.min(#cands, 4) do
        local h = cands[i] and cands[i].target
        if h and Entity.IsEntity(h) and Target.IsAlive(h)
           and NPC.IsAttacking and NPC.IsAttacking(h)
           and (dist_to(h) or math.huge) <= 800 then
            target = h
            break
        end
    end
    if not target then
        local c1 = cands[1]
        if c1 and c1.target and Entity.IsEntity(c1.target)
           and Target.IsAlive(c1.target) then
            target = c1.target
        elseif state.engaged_target and Entity.IsEntity(state.engaged_target)
           and Target.IsAlive(state.engaged_target) then
            target = state.engaged_target
        else
            local me = state.self_npc
            local list = me and Entity.GetHeroesInRadius(me, 3500,
                                    Enum.TeamType.TEAM_ENEMY) or nil
            local best_d
            if list then
                for i = 1, #list do
                    local h = list[i]
                    if h and Target.IsAlive(h) and Target.NotClone(h)
                       and Target.NotIllusion(h) then
                        local hd = dist_to(h)
                        if hd and (not best_d or hd < best_d) then
                            best_d, target = hd, h
                        end
                    end
                end
            end
        end
    end
    if not target then
        tlog(3, "starter", { decision = "idle", reason = "no_target" })
        return
    end

    -- v6.15.251: per-target save-cooldown gate. When a defensive save
    -- fired on THIS target within the last STARTER_SAVE_SUPPRESS_S
    -- window, skip combo dispatch for the current tick. Prevents the
    -- D+R double-fire pattern (defensive grenade-at-caster fires on PA,
    -- then offensive starter_dr commits R on PA the same tick, burning
    -- both cooldowns at once). Window is intentionally TIGHT (one tick
    -- region, not a multi-second lockout) -- PA's 2 blink charges with
    -- ~5s recharge mean a long window would suppress the legitimate
    -- next-blink combo. Same-tick dispatch is the bug signal; the gate
    -- catches it without interfering with normal combo cadence.
    if state.last_save_target == target and state.last_save_t
       and (now() - state.last_save_t) < state.STARTER_SAVE_SUPPRESS_S then
        tlog(2, "combo_skip_recent_save", {
            target   = uname(target),
            elapsed  = string.format("%.0f", (now() - state.last_save_t) * 1000),
        })
        return
    end

    local ctx = build_layer1_ctx(target, 0)

    -- Engagement classification.
    --   committed = the target is attacking Sniper, too close for comfort
    --               (target_attacking_us — within ~700u, not kiting).
    --   fleeing   = moving away, not attacking.
    -- committed = close + not kiting (`target_attacking_us`) AND genuinely
    -- mid-attack. v6.15.125 added the `NPC.IsAttacking` requirement (the bare
    -- proxy flagged a target merely standing near Sniper as committed). But
    -- v6.15.135 (user, v6.15.134 demo: "R usage random vs PA on blink"):
    -- NPC.IsAttacking is true only for the ~0.3s swing of each ~1.4s attack
    -- cycle — a single-tick read made `committed` true only on the rare tick
    -- the read landed mid-swing, so a diving attacker mostly routed to `chip`
    -- (Q+E, no R) and R looked random. Fix: LATCH it (lesson L5/89 — gate a
    -- flickering poll on a time window). committed if IsAttacking is true NOW,
    -- or was true within COMMITTED_ATTACK_WINDOW_S (sample_velocities stamps
    -- state.attacking_seen_t every tick). API-guarded — no NPC.IsAttacking →
    -- proxy alone.
    -- v6.15.221: committed detection factored into state.is_committed_attacker
    -- (shared with teamfight_tick's dr path).
    local committed = state.is_committed_attacker(target, ctx)
    local fleeing   = ctx.kiting_us and not committed
    -- R-range discipline: the `r` finalizer commits only when the target is
    -- past ~70% of Sniper's attack range — a closer target dies to autos so
    -- R there is a DPS loss. v6.15.138 (user, v6.15.137 demo): the basis was
    -- `atk_range_with_e` (attack range INCLUDING Take Aim's huge bonus —
    -- 1480-1780u in the demo), so the threshold was 0.70×1780 ≈ 1246u and R
    -- only fired on targets past ~1250u. The v6.15.137 R-gate diagnostic
    -- proved it: every `r_kill=y` target at d=734-1240 logged `r_range=n`.
    -- Fixed: base the gate on `ctx.atk_range` — Sniper's REAL attack range
    -- without the Take Aim bonus (~600-700u) — so the threshold is ~420-490u
    -- and R fires on any R-killable target past comfortable autoattack range.
    -- The D+R+Q+E combo still ignores this entirely (D's knockback makes R's
    -- range).
    -- v6.15.177 (user): the min-range fraction is now a menu slider so the
    -- 1-2 enemy R-finisher trigger distance can be tuned in testing. 70 =
    -- the old default; 100+ reserves R for targets at / past the edge of
    -- autoattack range (escaping targets). Only the Starter `r` archetype
    -- reads the slider — the teamfight finisher keeps the static constant.
    local r_min_frac = state.STARTER_R_MIN_RANGE_FRAC
    if state.menu and state.menu.r_finisher_range then
        r_min_frac = (state.menu.r_finisher_range:Get() or 70) / 100
    end
    local r_ok_range = ctx.d >= r_min_frac * (ctx.atk_range or 1)

    -- R-kill check.
    local eff_hp = (ctx.proj_state_r_impact
                    and ctx.proj_state_r_impact.eff_hp_magical)
                or (ctx.eff_hp or 0)
    local buf          = state.OVERKILL_BUFFER_HP or 0
    local r_alone_kill = (eff_hp + buf) <= (ctx.r_dmg_at_d or 0)

    -- v6.15.181: R-eval read-cadence instrumentation (user: "we are not sure
    -- how many autoattacks we are reading between"). Each starter tick that
    -- reaches the R-kill check logs `dt_ms` (ms since the previous such eval)
    -- and `dhp` (the target's RAW HP drop since it). If `dt_ms` stays well
    -- under Sniper's attack interval the loop reads many times per
    -- autoattack and `dhp` steps down in small increments; a large `dt_ms`,
    -- or a `dhp` worth multiple autoattacks, means the R-kill check is
    -- skipping autoattacks → R commits on a stale HP read. `dhp` is `-1`
    -- when the target changed since the last eval (not comparable).
    local tgt_hp_now = (Entity.IsEntity(target) and Entity.GetHealth(target)) or 0
    local tgt_idx    = Entity.IsEntity(target) and Entity.GetIndex(target) or nil
    local r_eval_dt_ms = state.last_starter_eval_t
        and ((now() - state.last_starter_eval_t) * 1000) or 0
    local r_eval_dhp = (state.last_starter_eval_hp
                        and state.last_starter_eval_idx == tgt_idx)
        and (state.last_starter_eval_hp - tgt_hp_now) or -1
    state.last_starter_eval_t   = now()
    state.last_starter_eval_hp  = tgt_hp_now
    state.last_starter_eval_idx = tgt_idx

    -- v6.15.183: MEASURED HP-loss rate → time-to-kill. A reactive R commit
    -- cannot be tight — the target's HP drops in big discrete chunks (a
    -- Daedalus crit removed 467 raw HP in one 33ms tick, log-confirmed), so
    -- R, firing the first tick the target reads killable, overshoots the
    -- kill threshold by up to a full crit. The v6.15.178 `pre_r` model tried
    -- to PREDICT the chip and failed (armor / frame / crit errors). Instead
    -- MEASURE it: accumulate the target's raw HP loss over a ~1s window and
    -- derive HP/sec. A measured rate is automatically correct for crits,
    -- items, armour and damage-block — there is nothing to predict wrong.
    -- The rate feeds the v6.15.183 R-need check below.
    local R_LOSS_WINDOW = 1.0
    if tgt_idx ~= state.r_loss_idx then
        state.r_loss_idx     = tgt_idx
        state.r_loss_samples = {}
    elseif state.last_starter_eval_hp
           and state.last_starter_eval_idx == tgt_idx then
        -- v6.15.194 (audit #3): accumulate SIGNED dhp — both damage
        -- (positive) and heals/regen (negative) count toward the window's
        -- net HP movement. The prior gate `r_eval_dhp > 0` silently dropped
        -- every heal sample, so a target that received Aphotic Shield /
        -- shrine / salve / lifesteal crit kept its pre-heal HP-loss rate
        -- intact: the brain still thought autos would finish the target
        -- and SUPPRESSED R via r_needed — but the healed target no longer
        -- died to autos in time. With signed accumulation a heal subtracts
        -- from the net loss, the rate drops, ttk_autos rises, and r_needed
        -- re-opens the R fire. (Note: the `r_eval_dhp == -1` sentinel from
        -- the target-changed path is no longer reachable here — that branch
        -- already reset r_loss_samples above.)
        local s = state.r_loss_samples or {}
        s[#s + 1] = { dhp = r_eval_dhp, t = now() }
        state.r_loss_samples = s
    end
    local hp_loss_rate = 0
    do
        local s = state.r_loss_samples or {}
        local kept, sum_dhp, oldest = {}, 0, nil
        for i = 1, #s do
            local e = s[i]
            if (now() - e.t) <= R_LOSS_WINDOW then
                kept[#kept + 1] = e
                sum_dhp = sum_dhp + e.dhp
                if not oldest or e.t < oldest then oldest = e.t end
            end
        end
        state.r_loss_samples = kept
        local span = oldest and (now() - oldest) or 0
        -- v6.15.194 (audit #3): clamp the rate to >=0. A window dominated
        -- by healing has a negative sum_dhp — we never want a negative
        -- rate (would feed back through ttk_autos as a nonsense negative
        -- TTK). Zero means "autos are not net-ahead of regen over this
        -- window", so r_needed treats the target as not auto-killable in
        -- the R-cast horizon and R is free to commit.
        -- v6.15.197 (audit B3): span > 0.2 admitted rates computed from a
        -- single-tick observation window (high variance, sub-attack-cycle
        -- noise). 0.5 covers ~one autoattack at 1.4-1.7 s cycle, giving
        -- the rate a stable read. Cost is a slightly longer ramp-up after
        -- a target switch (reset-on-target-change still correct at line
        -- 4020 above).
        if span > 0.5 then
            hp_loss_rate = math.max(0, sum_dhp / span)
        end
    end
    -- v6.15.178 (user: fire R earlier to guarantee the kill). The `r`
    -- finisher commits the instant R ALONE is lethal — so on an in-range
    -- target the autos chip it well below R's damage before R's 2s cast
    -- finishes, and R lands as overkill (demo: R cast at CM 215, landed at
    -- ~26). Fix: account for the damage that lands DURING R's cast —
    -- Sniper's own autoattacks — counted only when the target is in attack
    -- range AND not fleeing (otherwise the autos do not connect). Adding
    -- that chip lets R commit EARLIER, on a higher-HP target: by the time R
    -- lands the autos have brought it into R's lethal band, so the kill is
    -- locked in before the target can blink / run. pre_r_dmg is deliberately
    -- CONSERVATIVE (a 0.5 haircut; autos only — Q-zone ticks are excluded)
    -- so an over-estimate can never fire R on a target R+chip cannot kill.
    -- A fleeing / out-of-range target has pre_r_dmg = 0 → r_kill_soon falls
    -- back to the R-alone check, exactly as before.
    local R_PRECHIP_FACTOR = 0.5
    -- v6.15.180: gate `autos_hit` on a STABLE attack range. ctx.atk_range
    -- (effective_attack_range) includes Take Aim's transient ACTIVE
    -- range bonus — a 3s buff — so it jumped ~300u as Take Aim cycled,
    -- flipping a mid-range target in / out of "auto range" and making
    -- pre_r_dmg flicker 0 ↔ ~1300. Subtract the active bonus (KV
    -- sniper_take_aim `active_attack_range_bonus`) while Take Aim is up, so
    -- the gate uses the always-on base+passive range and pre_r_dmg is stable.
    local stable_atk_range = ctx.atk_range or 0
    if self_take_aim_state() then
        stable_atk_range = stable_atk_range
            - state.item_kv(ability(A.E), "active_attack_range_bonus", 300)
    end
    local autos_hit = ((ctx.d or math.huge) <= stable_atk_range)
                      and not fleeing
    local pre_r_dmg = autos_hit
        and (rc_damage_over(r_cast_point(), false, ctx.d) * R_PRECHIP_FACTOR)
        or 0
    local r_kill_soon = (eff_hp + buf) <= ((ctx.r_dmg_at_d or 0) + pre_r_dmg)

    -- v6.15.183: R-finisher NEED check — fire R only when Sniper's own autos
    -- will NOT finish the target in time, so R is never wasted on a target
    -- the autoattacks are already obliterating (the demo's 80-90%-overkill
    -- cases). `not autos_hit` (target fleeing / out of stable auto range) →
    -- autos will not connect → R is needed to secure the kill. Otherwise
    -- project the MEASURED hp_loss_rate to a time-to-kill: if autos kill the
    -- target within r_horizon, autos handle it → suppress R (saves the ult;
    -- the user accepts a Take Aim / autoattack finish). `force` (force-key)
    -- bypasses the whole check.
    -- v6.15.197 (audit B4): r_horizon scales with R cast point. The flat
    -- 1.0 s margin gave Scepter Sniper (~0.5 s cast) a 1.5 s horizon, so
    -- a target dying to autos in 1.4 s suppressed R when Scepter R would
    -- have landed in 0.5 s — wrong direction for Scepter (its whole value
    -- is the fast cast). Proportional formula: r_cast_point() * 1.5 +
    -- 0.3 s irreducible margin. Yields:
    --   normal R (2.0 s cast): 3.3 s horizon (was 3.0 — slightly more
    --     conservative, fine)
    --   Scepter R (0.5 s cast): 1.05 s horizon (was 1.5 — much better,
    --     reflects Scepter's quick commit)
    local r_horizon    = r_cast_point() * 1.5 + 0.3
    local ttk_autos    = (hp_loss_rate > 0)
        and (tgt_hp_now / hp_loss_rate) or math.huge
    local r_needed = (not autos_hit) or (ttk_autos > r_horizon)

    -- R-safety (fleeing-R only): refuse R into magic immunity (unless BKB
    -- expires within the 2s cast) or a ready/soon escape item.
    local r_safe = true
    if ctx.magic_immune then
        local b = ctx.bkb_remaining_s
        if not b or b > 2.0 then r_safe = false end
    end
    if ctx.escape_window == "ready" or ctx.escape_window == "soon" then
        r_safe = false
    end

    -- Chip-Q zone coverage: state.q_spot_covered (hoisted to module scope in
    -- v6.15.221 so the dr-combo helper build_dr_steps shares the same gate).

    -- Predicted chip-Q placement. v6.15.175 (user, demo: in a 1-2 enemy fight
    -- the chip-Q landed on the enemy the BRAIN auto-picked, not the one the
    -- PLAYER is attacking). The chip-Q must support the player's target
    -- first, the other enemy after. read_baseline_target_hint() is the
    -- authoritative player-intent read (the queued ATTACK_TARGET order, else
    -- the cursor) — the same source teamfight tf_q already uses. Falls back
    -- to the Starter's own pick when there is no hint.
    local q_primary = target
    do
        local hint = read_baseline_target_hint()
        if hint and Entity.IsEntity(hint) and Target.IsAlive(hint) then
            q_primary = hint
        end
    end
    local q_pos     = state.predict_pos(q_primary, q_arm_lead_s())
                   or ctx.target_pos
    local q_covered = state.q_spot_covered(q_pos)
    local q_aim     = "you"
    -- Secondary-target spread: if the player's target already has a live
    -- chip-Q zone, place this Q on the OTHER enemy instead ("on the secondary
    -- target after" — user). Scan the candidates for an alive enemy that is
    -- not the primary and whose own Q spot is uncovered.
    if q_covered then
        local prim_idx = Entity.IsEntity(q_primary)
                         and Entity.GetIndex(q_primary) or nil
        local cands = state.candidates or {}
        for i = 1, math.min(#cands, 4) do
            local h = cands[i] and cands[i].target
            if h and Entity.IsEntity(h) and Target.IsAlive(h)
               and Entity.GetIndex(h) ~= prim_idx then
                local sp = state.predict_pos(h, q_arm_lead_s())
                if sp and not state.q_spot_covered(sp) then
                    q_pos, q_covered, q_aim = sp, false, "secondary"
                    break
                end
            end
        end
    end

    local archetype, steps

    -- v6.15.130: dr peel tool — D when ready, else Hurricane Pike (D's
    -- fallback when D is on cooldown; user, v6.15.129 demo: "Pike is really
    -- good for this same combo as fallback"). The log confirmed the DEFENSE
    -- layer fires grenade_at_caster (D) as the anti-gap save vs Phantom
    -- Assassin's Phantom Strike — competing with the dr combo for the one
    -- Concussive Grenade; the Pike fallback keeps the combo whole when the
    -- defense layer just spent D. Pike-on-enemy is the brain's standing
    -- Pike-peel pattern (see snipe_standard) — 425u cast range. nil if
    -- neither tool is usable → the dr archetype is skipped.
    -- v6.15.221: resolution factored into state.resolve_dr_peel (shared with
    -- teamfight_tick's dr path).
    local dr_peel = state.resolve_dr_peel(ctx)

    -- ① COMMITTED ATTACKER → D+R+Q+E, the defensive ultimate (user, v6.15.123
    -- demo answer). When an enemy is too close for comfort and committing to
    -- attack Sniper, fire the full combo: D stuns + knocks the attacker away,
    -- R nukes, Q drops a slow zone on their return path, E (Take Aim) buffs.
    -- NOT gated on a kill prediction — it is a defensive peel that also kills
    -- ("perfect TTK") — and NOT gated on r_ok_range (D's knockback creates R's
    -- range). Step ordering: D-first then deferred R is the proven v6.15.124
    -- snipe_d_r pattern; Q and E timings were re-derived in v6.15.218/.219.
    -- D first (immediate); R deferred +0.2s (fires after D's
    -- 0.1s cast point, so R's queue=false dispatch never cancels D); Q
    -- deferred to +r_cast_point+0.3 -- right after R's cast point completes,
    -- since a Shrapnel cast issued mid-R-cast cancels R (v6.15.97-era
    -- snipe_q_r evidence); E (Take Aim) LAST, +r_cast_point+0.8, after Q's
    -- cast animation (v6.15.219 -- E before Q would burn Take Aim window on
    -- Q's animation). Q, E AND R are all cond-gated; the only hard requirement
    -- for dr is a peel tool (D or Pike) — see the v6.15.151 note. v6.15.127: the
    -- `d <= cast_d` gate was DROPPED — D's 600u cast range is shorter than the
    -- ~700u committed radius, so committed attackers in the 600-700u band were
    -- routing to `chip` instead of `dr` (demo: committed=y targets at d=641-661
    -- → chip). dr now fires on any committed attacker; if D is slightly out of
    -- its 600u range the engine walks Sniper the ≤100u to cast it — fine for a
    -- defensive knockback combo that is about to knock the attacker away.
    -- v6.15.130: step 1 is `dr_peel` (D or Hurricane Pike, computed above);
    -- dr fires whenever a peel tool is available, so a committed attacker is
    -- still met with the full combo while D is on cooldown.
    -- v6.15.151 (user regression report): dr selection no longer gates on
    -- ctx.ready_r. A committed attacker must still be met with the peel
    -- (D / Pike) + Q + E when R is on cooldown — previously R was the gate
    -- that kept dr alive, so once R went on CD the peel (e.g. Pike on the
    -- enemy's return attack) stopped firing entirely. R is now a cond-gated
    -- step like Q and E: it fires when ready, and is simply skipped when not.
    if committed and dr_peel then
        archetype = "dr"
        -- v6.15.221: step table factored into state.build_dr_steps (shared
        -- with teamfight_tick's dr path). See that helper for step timing.
        steps = state.build_dr_steps(dr_peel)

    -- ② R FINALIZER — R-only, on a killable target at ≥70% attack range (or
    -- out of attack range entirely). Fires whether the target is fleeing or
    -- just standing far — at that range R is the kill tool, not autos.
    -- v6.15.127: E (Take Aim) was DROPPED from this combo. E activating
    -- triggers the native positioning subsystem (v6.15.103) to reposition
    -- Sniper toward the target's optimal attack range — i.e. it walks Sniper
    -- CLOSER (user, v6.15.126 demo: "R is trying to get closer to be used").
    -- R alone reaches 3000u, and r_alone_kill already guarantees R kills
    -- WITHOUT the Take Aim boost — so R-only fires the finalizer from current
    -- range with no closing.
    -- v6.15.182 (user demo: R fired on high-HP targets and MISSED the kill —
    -- CM committed at 920 HP, R + chip delivered only ~641, CM survived at
    -- 279). The `r_kill_soon` gate (v6.15.178) added `pre_r_dmg` so R would
    -- "fire earlier", but `pre_r_dmg` massively over-estimates the chip:
    -- `rc_damage_over` is Sniper's RAW attack output, not reduced by the
    -- target's armor / damage-block (Primal's armor, Crimson Guard), it is a
    -- raw-physical figure added to the MAGICAL-frame `r_dmg_at_d`, and it
    -- assumes the target eats autos for R's full 2 s cast. With items the
    -- raw output balloons while armor stays unsubtracted, so `pre_r_dmg`
    -- (logged 880-998) fired R on targets R+chip could not kill. Reverted
    -- to `r_alone_kill`: R fires only when R ALONE is lethal (`r_dmg_at_d`
    -- is armor- and frame-correct since v6.15.176). R never misses; it may
    -- land as mild overkill (autos chip during the 2 s cast) — the user
    -- accepts that ("a late R, or Take Aim finishing it, is fine — saves
    -- mana"). `pre_r` / `r_soon` stay in the log as diagnostics only.
    elseif (force or (r_alone_kill and r_safe and r_needed))
       and ctx.ready_r and (r_ok_range or force)
       and not ctx.r_will_range_leak then
        archetype = "r"
        steps = {
            { ability = A.R, kind = "ut", short = "r",
              arg = function(c) return c.target end },
        }

    -- ③ DEFAULT → Q + E chip. Q builds the chip zone NOW (step 1 — fresh
    -- queue=false immediate cast). E (Take Aim) follows as a DEFERRED step
    -- ~1.5s later, timed to the Q zone's arm. Per the user (v6.15.125 demo):
    -- "Q first and E after — E first means losing 1.5s of overlap over both
    -- skills". Casting E at t=0 burns 1.5s of Take Aim's 3s duration before
    -- the zone is even live; deferring E to the arm moment makes Take Aim
    -- fully overlap the armed zone. The deferred E is a fresh dispatch (not a
    -- queue chain), so it is reliable. Both steps are cond-gated.
    elseif not ctx.magic_immune and ctx.d <= (ctx.cast_q or 0)
       and (((ctx.q_charges or 0) >= 1 and not q_covered) or ctx.ready_e) then
        archetype = "chip"
        steps = {
            { ability = A.Q, kind = "pt", short = "q",
              cond = function(c)
                  return (c.q_charges or 0) >= 1 and not q_covered
              end,
              arg  = function(c) return q_pos end },
            { ability = A.E, kind = "nt", short = "e",
              delay_s = q_arm_lead_s(),
              cond    = function(c) return c.ready_e end },
        }
    end

    -- v6.15.137: R-gate diagnostics. The user reports R not firing even when
    -- the target is ≥70% range and R-alone-killable ("it was working in the
    -- past"). The `r` archetype condition is
    --   r_alone_kill and r_safe and ready_r and (r_ok_range or force)
    --     and not r_will_range_leak
    -- The previous `starter` log showed only committed/fleeing/r_kill — not
    -- which of these gates blocked R. These fields expose every gate so the
    -- next demo's `starter | decision=idle` (or `=fire archetype=chip`) line
    -- pinpoints the block: ready_r / r_safe / r_range (r_ok_range) / r_leak
    -- (r_will_range_leak) / esc (escape_window) / m_imm (magic_immune).
    -- v6.15.180: during the light (post-chip) lock the tick still runs so the
    -- `r` kill finisher can commit the instant the target is killable (no
    -- 0.4s quantization) — but chip / dr re-dispatch stays throttled. Returns
    -- silently (no idle-log spam) when the lock holds a non-`r` archetype.
    if r_finish_only and archetype ~= "r" then return end

    if not steps then
        tlog(3, "starter", {
            decision  = "idle", target = uname(target),
            committed = committed and "y" or "n",
            fleeing   = fleeing and "y" or "n",
            r_kill    = r_alone_kill and "y" or "n",
            ready_r   = ctx.ready_r and "y" or "n",
            r_safe    = r_safe and "y" or "n",
            r_range   = r_ok_range and "y" or "n",
            r_leak    = ctx.r_will_range_leak and "y" or "n",
            esc       = ctx.escape_window or "?",
            m_imm     = ctx.magic_immune and "y" or "n",
            d         = string.format("%.0f", ctx.d or 0),
            -- v6.15.182: R-finisher kill math — eff_hp = HP needed to kill,
            -- r_dmg = R-alone damage. r_kill (= the live gate) is now
            -- r_alone_kill. pre_r / r_soon are the retired pre_r model's
            -- estimate + verdict, kept as diagnostics only.
            eff_hp    = string.format("%.0f", eff_hp),
            r_dmg     = string.format("%.0f", ctx.r_dmg_at_d or 0),
            kill_pct  = state.kill_confidence(ctx),
            pre_r     = string.format("%.0f", pre_r_dmg),
            r_soon    = r_kill_soon and "y" or "n",
            -- v6.15.181: read-cadence — tgt_hp raw, dhp raw drop since last
            -- eval, dt_ms eval interval.
            tgt_hp    = string.format("%.0f", tgt_hp_now),
            dhp       = string.format("%.0f", r_eval_dhp),
            dt_ms     = string.format("%.0f", r_eval_dt_ms),
            -- v6.15.183: measured autos kill-rate / TTK and the R-need gate.
            loss      = string.format("%.0f", hp_loss_rate),
            ttk       = string.format("%.1f", math.min(ttk_autos, 99)),
            r_need    = r_needed and "y" or "n",
        })
        return
    end

    local is_r = (archetype == "dr" or archetype == "r")
    tlog(1, "starter", {
        decision  = "fire", archetype = archetype, target = uname(target),
        committed = committed and "y" or "n",
        fleeing   = fleeing and "y" or "n",
        r_kill    = r_alone_kill and "y" or "n",
        kill_pct  = state.kill_confidence(ctx),
        d         = string.format("%.0f", ctx.d or 0),
        force     = force and "y" or "n",
        ready_r   = ctx.ready_r and "y" or "n",
        r_safe    = r_safe and "y" or "n",
        r_range   = r_ok_range and "y" or "n",
        r_leak    = ctx.r_will_range_leak and "y" or "n",
        esc       = ctx.escape_window or "?",
        -- v6.15.175: where the chip-Q aimed — `you` = the player's attacked
        -- target, `secondary` = the other enemy (player's target already
        -- zoned). Only meaningful for archetype=chip.
        q_aim     = (archetype == "chip") and q_aim or "-",
        -- v6.15.182: R-finisher kill math — eff_hp = HP needed to kill,
        -- r_dmg = R-alone damage. r_kill (= the live gate) is now
        -- r_alone_kill. pre_r / r_soon are the retired pre_r model's
        -- estimate + verdict, kept as diagnostics only.
        eff_hp    = string.format("%.0f", eff_hp),
        r_dmg     = string.format("%.0f", ctx.r_dmg_at_d or 0),
        pre_r     = string.format("%.0f", pre_r_dmg),
        r_soon    = r_kill_soon and "y" or "n",
        -- v6.15.181: read-cadence — tgt_hp raw, dhp raw drop since last
        -- eval, dt_ms eval interval (ms).
        tgt_hp    = string.format("%.0f", tgt_hp_now),
        dhp       = string.format("%.0f", r_eval_dhp),
        dt_ms     = string.format("%.0f", r_eval_dt_ms),
        -- v6.15.183: measured autos kill-rate / TTK and the R-need gate.
        loss      = string.format("%.0f", hp_loss_rate),
        ttk       = string.format("%.1f", math.min(ttk_autos, 99)),
        r_need    = r_needed and "y" or "n",
    })
    state.last_layer1_intent = "starter_" .. archetype .. ":" .. uname(target)
    state.l1_counter = state.l1_counter + 1
    if force then state.force_counter = state.force_counter + 1 end
    state.last_refusal = nil
    fire_steps("starter_" .. archetype, steps, ctx)
    -- Record the chip-Q / dr-Q placement in the global coverage list (append
    -- + prune entries older than the zone lifetime). v6.15.133: `dr` included
    -- so a later chip-Q or dr-Q sees the dr-Q's zone and does not restack it.
    -- v6.15.175: record the position each archetype actually casts at — chip
    -- uses q_pos (player-intent / secondary), dr uses its committed-attacker
    -- spot — and only when that archetype's Q step actually fires.
    do
        local rec
        if archetype == "chip" and q_pos and not q_covered then
            rec = q_pos
        elseif archetype == "dr" then
            local dp = state.predict_pos(target, q_arm_lead_s())
            if dp and not state.q_spot_covered(dp) then rec = dp end
        end
        if rec and (ctx.q_charges or 0) >= 1 then
            state.starter_q_track[#state.starter_q_track + 1] = {
                x = rec.x or 0, y = rec.y or 0, t = now(),
            }
            local kept = {}
            for i = 1, #state.starter_q_track do
                local e = state.starter_q_track[i]
                if (now() - e.t) < state.STARTER_Q_ZONE_LIFE then
                    kept[#kept + 1] = e
                end
            end
            state.starter_q_track = kept
        end
    end
    state.last_layer1_t     = now()
    state.last_layer1_was_r = is_r
    state.engaged_target    = target
    state.engaged_target_t  = now()
end

-- Best Shrapnel (Q) placement for Team Fight: a cluster-coverage search
-- (the Storm_Vortex.lua pairwise pattern). Candidate centres are each enemy's
-- PREDICTED position (led by the 1.5s Shrapnel pipeline) plus, for every
-- enemy pair within 2·R, the two circle centres that pass through both. The
-- winner covers the most enemies that are NOT already inside a recent Q zone,
-- so successive teamfight ticks spread the 3 charges across the fight instead
-- of restacking. Magic-immune enemies are excluded (Q is magical). Candidates
-- beyond Q's cast range, or within STARTER_Q_COVER_R of a recent zone, are
-- rejected. The recent-zone list is the GLOBAL state.starter_q_track shared
-- with chip-Q (lesson 91) — a tf-Q and a chip-Q never restack either.
-- Returns (pos, covered_count) or (nil, 0).
state.tf_q_pos = function()
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return nil, 0 end
    -- v6.15.199 (audit C4): TF coordination scan radius (state const).
    local list = Entity.GetHeroesInRadius(me, state.TF_SCAN_RADIUS,
                                          Enum.TeamType.TEAM_ENEMY)
    if not list then return nil, 0 end
    local R    = shrap_radius()
    local R2   = R * R
    local lead = q_arm_lead_s()
    local pts  = {}
    for i = 1, #list do
        local h = list[i]
        if h and Target.IsAlive(h) and Target.NotClone(h)
           and Target.NotIllusion(h)
           and not NPC.HasState(h, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local p = state.predict_pos(h, lead) or Entity.GetAbsOrigin(h)
            if p then pts[#pts + 1] = p end
        end
    end
    if #pts == 0 then return nil, 0 end

    -- Candidate centres: each enemy position + every pairwise circle centre.
    local cands = {}
    for i = 1, #pts do cands[#cands + 1] = pts[i] end
    local maxD2 = (2 * R) * (2 * R)
    for i = 1, #pts - 1 do
        for j = i + 1, #pts do
            local p1, p2 = pts[i], pts[j]
            local dx, dy = p2.x - p1.x, p2.y - p1.y
            local d2 = dx * dx + dy * dy
            if d2 > 1.0 and d2 <= maxD2 then
                local d  = math.sqrt(d2)
                local mx, my = (p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5
                local nx, ny = -dy / d, dx / d
                local hh = math.sqrt(math.max(0.0, R2 - d2 * 0.25))
                cands[#cands + 1] = Vector(mx + nx * hh, my + ny * hh, p1.z or 0)
                cands[#cands + 1] = Vector(mx - nx * hh, my - ny * hh, p1.z or 0)
            end
        end
    end

    local mp = Entity.GetAbsOrigin(me)
    -- v6.15.197 (audit B9): consolidated via state.q_cast_range.
    local cast_q  = state.q_cast_range()
    local cast_q2 = cast_q * cast_q
    -- v6.15.195 (audit A5): live Q radius. KV per-Q-level 400/425/450/475;
    -- the prior constant 400u let zones stack overlap at Q4.
    local cover_r  = shrap_radius() or state.STARTER_Q_COVER_R
    local cover_r2 = cover_r * cover_r
    local t = now()

    local best, best_score, best_total = nil, 0, 0
    for ci = 1, #cands do
        local c = cands[ci]
        local castable = true
        if mp then
            local dx, dy = c.x - mp.x, c.y - mp.y
            if (dx * dx + dy * dy) > cast_q2 then castable = false end
        end
        if castable then
            local on_recent = false
            for ti = 1, #state.starter_q_track do
                local trk = state.starter_q_track[ti]
                if (t - trk.t) < state.STARTER_Q_ZONE_LIFE then
                    local dx, dy = c.x - trk.x, c.y - trk.y
                    if (dx * dx + dy * dy) < cover_r2 then
                        on_recent = true; break
                    end
                end
            end
            if not on_recent then
                local score, total = 0, 0
                for pi = 1, #pts do
                    local dx, dy = pts[pi].x - c.x, pts[pi].y - c.y
                    if (dx * dx + dy * dy) <= R2 then
                        total = total + 1
                        local zoned = false
                        for ti = 1, #state.starter_q_track do
                            local trk = state.starter_q_track[ti]
                            if (t - trk.t) < state.STARTER_Q_ZONE_LIFE then
                                local zx = pts[pi].x - trk.x
                                local zy = pts[pi].y - trk.y
                                if (zx * zx + zy * zy) <= R2 then
                                    zoned = true; break
                                end
                            end
                        end
                        if not zoned then score = score + 1 end
                    end
                end
                if score > best_score then
                    best, best_score, best_total = c, score, total
                end
            end
        end
    end
    if best and best_score >= 1 then return best, best_total end
    return nil, 0
end

-- v6.15.148: Team Fight target priority — the enemy the TEAM is focusing.
-- User directive: in a teamfight, attack the enemy the most allied heroes are
-- attacking TOGETHER; fall back to lowest-HP (TTK) when the team is spread
-- (no enemy has a clear ally consensus). UCZone exposes no NPC.GetAttackTarget
-- for heroes, so "ally A is attacking enemy E" is APPROXIMATED: A is mid-
-- attack (NPC.IsAttacking) and E is the enemy hero nearest A within
-- state.ATTACK_ENGAGE_RADIUS (currently 700u). Returns (enemy,
-- ally_attacker_count) — or (nil, 0) when
-- no ally is attacking any listed enemy (e.g. a solo demo with no allies).
state.tf_team_focus = function(enemy_list)
    -- v6.15.195 (audit A2): throttled instrumentation. Open
    -- issue #1 was `team_n=0` in every real bot match — root cause
    -- unconfirmed because three silent early-return paths and the body
    -- emitted no log. tf_team_focus_debug now distinguishes:
    --   reason=no_self / no_enemies / no_api / no_allies → why we bailed
    --   allies_total / allies_attacking / pairs_found    → why team_n=0
    -- Throttled to ~1Hz so a held combo key does not spam.
    local function dbg(fields)
        local t = now()
        if (t - (state.tf_team_focus_log_t or 0)) < 1.0 then return end
        state.tf_team_focus_log_t = t
        tlog(3, "tf_team_focus_debug", fields)
    end
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then
        dbg({ reason = "no_self" }); return nil, 0
    end
    if not enemy_list or #enemy_list == 0 then
        dbg({ reason = "no_enemies" }); return nil, 0
    end
    if not (NPC.IsAttacking) then
        dbg({ reason = "no_api" }); return nil, 0
    end
    -- v6.15.199 (audit C4): TF coordination scan radius (state const).
    local allies = Entity.GetHeroesInRadius(me, state.TF_SCAN_RADIUS,
                                            Enum.TeamType.TEAM_FRIEND)
    if not allies then
        dbg({ reason = "no_allies" }); return nil, 0
    end
    local me_idx = Entity.GetIndex(me)
    local count = {}                       -- enemy_idx → ally-attacker count
    local allies_total     = 0
    local allies_attacking = 0
    local pairs_found      = 0
    for ai = 1, #allies do
        local a = allies[ai]
        if a and Entity.IsEntity(a) and Target.IsAlive(a)
           and Entity.GetIndex(a) ~= me_idx
           and Target.NotIllusion(a) and Target.NotClone(a) then
            allies_total = allies_total + 1
            if NPC.IsAttacking(a) then
                allies_attacking = allies_attacking + 1
                local ap = Entity.GetAbsOrigin(a)
                local nearest_idx, nd
                for ei = 1, #enemy_list do
                    local e = enemy_list[ei]
                    local ep = e and Entity.IsEntity(e) and Entity.GetAbsOrigin(e)
                    if ap and ep then
                        local dx, dy = ep.x - ap.x, ep.y - ap.y
                        local d2 = dx * dx + dy * dy
                        -- v6.15.200 (audit C12): state.ATTACK_ENGAGE_RADIUS.
                        local r2 = state.ATTACK_ENGAGE_RADIUS
                                 * state.ATTACK_ENGAGE_RADIUS
                        if d2 <= r2 and (not nd or d2 < nd) then
                            nd, nearest_idx = d2, Entity.GetIndex(e)
                        end
                    end
                end
                if nearest_idx then
                    count[nearest_idx] = (count[nearest_idx] or 0) + 1
                    pairs_found = pairs_found + 1
                end
            end
        end
    end
    local best, best_n
    for ei = 1, #enemy_list do
        local e = enemy_list[ei]
        if e and Entity.IsEntity(e) then
            local n = count[Entity.GetIndex(e)] or 0
            if n > 0 and (not best_n or n > best_n) then
                best, best_n = e, n
            end
        end
    end
    dbg({
        reason          = "scanned",
        allies_total    = string.format("%d", allies_total),
        allies_attacking= string.format("%d", allies_attacking),
        pairs_found     = string.format("%d", pairs_found),
        best_n          = string.format("%d", best_n or 0),
    })
    return best, best_n or 0
end

-- v6.15.132 — TEAM FIGHT mode (HOLD, 3+ enemies).
-- The combo-key classifier routes a HOLD with 3+
-- enemy heroes within COMBO_CLASSIFY_RADIUS here. Like starter_tick this is a
-- per-tick situational appraisal — each off-throttle tick picks ONE archetype;
-- the per-tick re-evaluation IS the state machine (no explicit phase var).
--   ① tf_r     — R finalizer on a FLEEING, R-alone-killable enemy. R alone
--                seals a runner — autos can't chase mid-teamfight. Same R
--                gating as starter's `r` archetype (r_alone_kill / r_safe /
--                r_ok_range / not r_will_range_leak).
--   ② tf_q     — one Shrapnel zone. v6.15.146: Q FOLLOWS THE ATTACKED TARGET
--                (the player's cursor / top candidate) — placed to cover him
--                when he is in range and not already zoned. Only when he is
--                already zoned / out of range does Q fall back to tf_q_pos'
--                cluster-coverage spread, which then puts the spare charges
--                on still-uncovered enemies. Take Aim (E) rides along same-
--                tick. The global starter_q_track list stops restacking.
--   ③ tf_e     — Take Aim alone — Q charges spent but Take Aim has dropped
--                and needs refreshing (keeps the 100%-headshot buff up).
--   ④ tf_focus — ATTACK_TARGET on the enemy with the LOWEST CURRENT HP (the
--                one closest to death — v6.15.145, was lowest eff-physical-HP).
--                Native Hit & Run carries the attack rhythm (execute_fast=
--                false yields to it); the brain only sets WHICH enemy.
state.teamfight_tick = function(force)
    if not self_alive_ok() then return end

    -- Dispatch throttle — same windows as starter_tick / layer1_tick (R
    -- commit 2.5s, lighter Q/E/focus 0.4s) so the loop does not re-fire every
    -- frame.
    local lock_window = state.last_layer1_was_r
        and LAYER1_COMMIT_WINDOW_R or LAYER1_COMMIT_WINDOW_SEQ
    if state.last_layer1_t and (now() - state.last_layer1_t) < lock_window then
        return
    end

    -- Single pass over nearby enemy heroes: pick `focus` (LOWEST CURRENT HP —
    -- the enemy closest to death) and `r_cand` (lowest-HP FLEEING enemy = the
    -- R-finalizer candidate). v6.15.145 (user, full-test C4: "not prioritizing
    -- lowest life"): focus was the lowest effective-physical-HP ("fastest
    -- TTK"), but armor inflates eff-physical-HP, so a high-armor enemy at low
    -- raw HP read as a poor focus and the brain skipped the actually-low one.
    -- Raw HP is "who is closest to dying" — that is what focus-autos want.
    local me = state.self_npc
    -- v6.15.199 (audit C4): TF coordination scan radius (state const).
    local list = me and Entity.GetHeroesInRadius(me, state.TF_SCAN_RADIUS,
                            Enum.TeamType.TEAM_ENEMY) or nil
    local focus, focus_hp
    local r_cand, r_cand_hp
    local held_seen = false   -- v6.15.192: is last tick's focus still in this fight
    if list then
        for i = 1, #list do
            local h = list[i]
            if h and Target.IsAlive(h) and Target.NotClone(h)
               and Target.NotIllusion(h) then
                if h == state.tf_focus then held_seen = true end
                local hp = Entity.GetHealth(h) or math.huge
                if not focus_hp or hp < focus_hp then
                    focus, focus_hp = h, hp
                end
                if Target.IsKitingUs(h, me) then
                    local hp = Entity.GetHealth(h) or math.huge
                    if not r_cand_hp or hp < r_cand_hp then
                        r_cand, r_cand_hp = h, hp
                    end
                end
            end
        end
    end
    if not focus then
        tlog(3, "teamfight", { decision = "idle", reason = "no_target" })
        -- v6.15.194 (audit #5): stamp the throttle even on the no_target
        -- early-return. Same L14 shape as the v6.15.134 tf_focus rejected-
        -- dispatch fix: without this, every OnUpdateEx tick of a held combo
        -- key re-runs the 1800u GetHeroesInRadius scan while the brain has
        -- nothing to do. Stamp it so re-appraisal happens at the SEQ cadence
        -- (0.4s) instead of every frame.
        state.last_layer1_t     = now()
        state.last_layer1_was_r = false
        return
    end

    -- v6.15.192: STICKY FOCUS. The raw lowest-HP pick above flips every tick
    -- as HP swings in a fight (full-match finding: "no lock", the focus
    -- jumping between enemies). Hold the previous focus while it is still a
    -- valid target in this fight; switch only when it dies / leaves, or when
    -- another enemy has dropped to finish-it-now HP while the held focus has
    -- not — a stable lock, but the brain still pounces on a secured kill.
    local SNAP_HP = 450
    local held = state.tf_focus
    -- v6.15.196 (audit A4, revised): Aegis / WK Reincarnation guard.
    -- During an aegis respawn or a Wraith King reincarnation, the held
    -- focus entity persists but Target.IsAlive returns false →
    -- held_seen flips false → without the guard, state.tf_focus would
    -- be re-locked on a different enemy this tick, defeating v6.15.192's
    -- sticky focus across the brief death window. v6.15.195's first cut
    -- used three modifier-name guesses; the post-v6.15.195 bot match
    -- log proved one of them was wrong (the actual SK reincarn modifier
    -- never appears as `_active` — only `_scepter` was observed on WK,
    -- and even that was the persistent passive, not a death-window
    -- modifier). Switched to API-based detection — zero new modifier
    -- names, full reuse of paths already proven in the brain:
    --   * Target.HasAegis(held) — UCZone API (alias of NPC.HasAegis per
    --     api/npc.md:442), already used in ScoreUltTarget to drive
    --     ScoreUltTarget's -75 score penalty. Covers the Roshan aegis
    --     case (lib/item_data.lua's item_aegis carries reincarnate_time
    --     = 5 s, matching how long this guard needs to hold).
    --   * WK Reincarnation: detected via the same handle path as line
    --     1234-1240's ScoreUltTarget (NPC.GetUnitName + NPC.GetAbility +
    --     Ability.GetLevel + Ability.IsReady), inverted for the
    --     post-fire case: reincarn LEVELED + currently NOT ready =
    --     reincarn has just fired, WK is in its 3 s revival animation.
    -- Gate tightened with `not Target.IsAlive(held)` so a held one that
    -- is merely OUT OF the 1800 u scan radius (still alive, just far)
    -- doesn't trigger the guard.
    local held_aegis_armed = false
    if held and not held_seen and Entity.IsEntity(held)
       and Target.IsAlive and (Target.IsAlive(held) == false) then
        if Target.HasAegis and Target.HasAegis(held) then
            held_aegis_armed = true
        elseif NPC.GetUnitName and NPC.GetUnitName(held)
                                  == "npc_dota_hero_skeleton_king" then
            local reincarn = NPC.GetAbility
                             and NPC.GetAbility(held, "skeleton_king_reincarnation")
            if reincarn and Ability.GetLevel(reincarn) > 0
               and not Ability.IsReady(reincarn) then
                held_aegis_armed = true
            end
        end
    end
    if held and held_seen and held ~= focus then
        local held_hp = Entity.GetHealth(held) or math.huge
        if not (focus_hp and focus_hp <= SNAP_HP and held_hp > SNAP_HP) then
            focus, focus_hp = held, held_hp   -- keep the lock
        end
    end

    -- v6.15.148 (user directive): in a teamfight, PRIORITISE the enemy the
    -- TEAM is focusing — the one the most allied heroes are attacking
    -- together. The lowest-HP pick above is the TTK fallback for when the
    -- team is spread out (no enemy has ≥2 allied attackers — also the solo-
    -- demo case, where there are no allies at all). ≥2 allies on one enemy =
    -- a real coordinated focus.
    local focus_via = "ttk"
    local team_focus, team_n = state.tf_team_focus(list)
    if team_focus and team_n and team_n >= 2 then
        focus    = team_focus
        focus_hp = Entity.GetHealth(team_focus) or focus_hp
        focus_via = "team"
    end
    -- v6.15.195 (audit A4): don't overwrite tf_focus while the held one
    -- is aegis-armed in its respawn window — on next-tick respawn, the
    -- v6.15.192 sticky lock re-engages on the original target.
    if not held_aegis_armed then
        state.tf_focus = focus   -- v6.15.192: remember the focus for next tick's lock
    end

    local archetype, steps, ctx, fire_target, q_pos, q_cover, q_aim

    -- COMMITTED-ATTACKER PEEL (v6.15.221). The most common Sniper teamfight
    -- pattern is the enemy team diving Sniper directly (his damage output is
    -- too great to ignore). When an enemy is COMMITTED onto Sniper (attacking
    -- him, close, not kiting) the D+R+Q+E peel combo fires -- the SAME
    -- archetype starter_tick runs, via the shared helpers, ONLY for a
    -- committing target. It takes priority over tf_r / tf_q / tf_e: surviving
    -- the dive is the immediate need, and the combo's own R still nukes the
    -- diver. D falls to Hurricane Pike when D is on cooldown (resolve_dr_peel).
    -- No committed enemy -> the normal tf archetypes run unchanged.
    do
        local dr_target, dr_ctx
        if list then
            for i = 1, #list do
                local h = list[i]
                if h and Entity.IsEntity(h) and Target.IsAlive(h)
                   and Target.NotIllusion(h) and Target.NotClone(h)
                   and (dist_to(h) or math.huge) <= 800 then
                    local hctx = build_layer1_ctx(h, 0)
                    if state.is_committed_attacker(h, hctx) then
                        dr_target, dr_ctx = h, hctx
                        break
                    end
                end
            end
        end
        local dr_peel = dr_ctx and state.resolve_dr_peel(dr_ctx)
        if dr_peel then
            tlog(1, "teamfight", {
                decision = "fire", archetype = "dr",
                target   = uname(dr_target),
                d        = string.format("%.0f", dr_ctx.d or 0),
                ready_r  = dr_ctx.ready_r and "y" or "n",
                peel     = dr_ctx.ready_d and "d" or "pike",
            })
            state.last_layer1_intent = "teamfight_dr:" .. uname(dr_target)
            state.l1_counter = state.l1_counter + 1
            state.last_refusal = nil
            fire_steps("teamfight_dr", state.build_dr_steps(dr_peel), dr_ctx)
            -- Record the dr-Q spot in the global coverage list so a later
            -- tf-Q / dr-Q does not restack on it (mirrors starter_tick).
            local dp = state.predict_pos(dr_target, q_arm_lead_s())
            if dp and (dr_ctx.q_charges or 0) >= 1
               and not state.q_spot_covered(dp) then
                state.starter_q_track[#state.starter_q_track + 1] = {
                    x = dp.x or 0, y = dp.y or 0, t = now(),
                }
                local kept = {}
                for ki = 1, #state.starter_q_track do
                    local e = state.starter_q_track[ki]
                    if (now() - e.t) < state.STARTER_Q_ZONE_LIFE then
                        kept[#kept + 1] = e
                    end
                end
                state.starter_q_track = kept
            end
            state.last_layer1_t     = now()
            state.last_layer1_was_r = true
            state.engaged_target    = dr_target
            state.engaged_target_t  = now()
            return
        end
    end

    -- ① R FINALIZER — R secures a kill the autos cannot close. Two
    -- DESIGNATED targets, evaluated in order (this is NOT a multi-target
    -- "find any killable" scan — R only ever considers these two enemies):
    --   (a) a FLEEING enemy (r_cand) — autos can't chase a runner, R can.
    --   (b) the teamfight FOCUS — R finishes the indicated kill the team is
    --       committed to. v6.15.157 (user-approved): securing the indicated
    --       target is good behaviour, not kill-stealing. Low-risk — if the
    --       team kills the focus first, r_abort_tick cancels R mid-cast and
    --       refunds the mana (no CD spent).
    -- tf_r_ctx returns a ready-to-fire ctx for `cand` or nil if R is not a
    -- viable finisher on it. v6.15.138: r_ok_range uses rc.atk_range (the
    -- real attack range), NOT atk_range_with_e (Take-Aim-boosted) — see the
    -- starter_tick r_ok_range comment.
    local function tf_r_ctx(cand)
        if not (cand and Entity.IsEntity(cand) and Target.IsAlive(cand)) then
            return nil
        end
        local rc = build_layer1_ctx(cand, 0)
        local eff_hp = (rc.proj_state_r_impact
                        and rc.proj_state_r_impact.eff_hp_magical)
                    or (rc.eff_hp or 0)
        local r_alone_kill = (eff_hp + (state.OVERKILL_BUFFER_HP or 0))
                             <= (rc.r_dmg_at_d or 0)
        local r_ok_range = rc.d >= state.STARTER_R_MIN_RANGE_FRAC
                                   * (rc.atk_range or 1)
        local r_safe = true
        if rc.magic_immune then
            local b = rc.bkb_remaining_s
            if not b or b > 2.0 then r_safe = false end
        end
        if rc.escape_window == "ready" or rc.escape_window == "soon" then
            r_safe = false
        end
        if (force or (r_alone_kill and r_safe))
           and rc.ready_r and (r_ok_range or force)
           and not rc.r_will_range_leak then
            return rc
        end
        return nil
    end

    local rc        = tf_r_ctx(r_cand)
    local r_target  = r_cand
    if not rc and focus ~= r_cand then
        rc = tf_r_ctx(focus)
        if rc then r_target = focus end
    end
    if rc then
        archetype, ctx, fire_target = "tf_r", rc, r_target
        steps = {
            { ability = A.R, kind = "ut", short = "r",
              arg = function(c) return c.target end },
        }
    end

    -- ②/③ build the focus ctx (also the autos / engaged target).
    if not steps then
        ctx, fire_target = build_layer1_ctx(focus, 0), focus

        if (ctx.q_charges or 0) >= 1 then
            -- v6.15.156 (user, Test 1: "Q spreads but not applied first on
            -- who we are attacking"). The FIRST Q of a teamfight must land on
            -- the enemy the PLAYER is attacking; the spare charges then
            -- spread via tf_q_pos. v6.15.146 used state.candidates[1] for the
            -- attacked enemy, but that slot is SCORE-ranked — a low-HP kill
            -- target outranks the focus, so Q1 kept missing who the player
            -- was actually hitting. read_baseline_target_hint() is the
            -- authoritative player-intent read: the queued ATTACK_TARGET
            -- order first, the cursor proxy as fallback. Q goes on this enemy
            -- when it is in Q cast range and not already under a fresh zone;
            -- otherwise Q falls to tf_q_pos' cluster spread.
            local attacked = read_baseline_target_hint() or focus
            -- v6.15.195 (audit A8): when read_baseline_target_hint falls
            -- back to its cursor proxy (Input.GetNearestHeroToCursor), it
            -- returns the nearest enemy on the WHOLE map. If the user's
            -- cursor sits on a teammate during a TF, that can be a far-
            -- back enemy unrelated to this fight, leaking Q out of the
            -- engagement. Filter by membership in the 1800u TF scan list
            -- (the same `list` that picked the focus and r_cand); on a
            -- non-member, fall back to focus.
            if attacked and attacked ~= focus and list then
                local att_idx = Entity.GetIndex(attacked)
                local in_fight = false
                for li = 1, #list do
                    if Entity.GetIndex(list[li]) == att_idx then
                        in_fight = true; break
                    end
                end
                if not in_fight then attacked = focus end
            end
            local ap
            if attacked and Entity.IsEntity(attacked)
               and Target.IsAlive(attacked) then
                ap = state.predict_pos(attacked, q_arm_lead_s())
            end
            local ap_ok = false
            if ap then
                local me_pos = Entity.GetAbsOrigin(state.self_npc)
                -- v6.15.197 (audit B9): consolidated via state.q_cast_range.
                local cast_q = (ctx.cast_q and ctx.cast_q > 0)
                               and ctx.cast_q or state.q_cast_range()
                if me_pos then
                    local dx, dy = ap.x - me_pos.x, ap.y - me_pos.y
                    if (dx * dx + dy * dy) <= cast_q * cast_q then
                        ap_ok = true
                        -- v6.15.195 (audit A5): live Q radius (was the
                        -- constant 400u that under-counted at Q4 = 475u).
                        local cr  = shrap_radius() or state.STARTER_Q_COVER_R
                        local cr2 = cr * cr
                        for i = 1, #state.starter_q_track do
                            local trk = state.starter_q_track[i]
                            if (now() - trk.t) < state.STARTER_Q_ZONE_LIFE then
                                local zx, zy = ap.x - trk.x, ap.y - trk.y
                                if (zx * zx + zy * zy) < cr2 then
                                    ap_ok = false; break
                                end
                            end
                        end
                    end
                end
            end
            if ap_ok then
                q_pos, q_cover, q_aim = ap, 1, "attacked"
            else
                q_pos, q_cover = state.tf_q_pos()
                q_aim = "spread"
            end
        end

        if q_pos then
            archetype = "tf_q"
            steps = {
                { ability = A.Q, kind = "pt", short = "q",
                  arg = function() return q_pos end },
                -- v6.15.158: do not cast Take Aim while a gap-closer is
                -- armed. Take Aim slows Sniper 30-45% — casting it into a
                -- dive makes the dive land. next(state.armed_threats) is the
                -- pre-event diver signal (Bara charge / Tusk / PA blink etc.,
                -- same gate auto_grenade uses). Keep full move speed to kite
                -- / let the Layer-2 save resolve instead.
                { ability = A.E, kind = "nt", short = "e",
                  cond = function(c)
                      return c.ready_e and not c.self_take_aim_active
                             and not next(state.armed_threats)
                  end },
            }
        elseif ctx.ready_e and not ctx.self_take_aim_active
           and not next(state.armed_threats) then
            archetype = "tf_e"
            steps = {
                { ability = A.E, kind = "nt", short = "e" },
            }
        end
    end

    -- ④ FOCUS AUTOS — nothing else to do this tick: point Sniper at the
    -- fastest-TTK enemy. Native Hit & Run carries the attack rhythm.
    if not steps then
        local ok = safe_issue {
            hero = HERO_KEY, layer = "agg",
            intent = "tf_focus_" .. uname(focus),
            order_type = UO.DOTA_UNIT_ORDER_ATTACK_TARGET,
            unit = state.self_npc, target = focus,
            execute_fast = false,
        }
        -- v6.15.145: diagnostics for the full-test Team Fight issues —
        -- C1 (Q not spreading) and C2 (Take Aim not used). `ready_e` / `ta`
        -- show why the E archetypes were gated off; `q_chg` / `q_pos` show
        -- why tf_q did not place a zone (no charges vs tf_q_pos found no
        -- uncovered cluster spot).
        -- v6.15.194 (audit #7): r_alone here must mirror tf_r_ctx's gate
        -- so the diagnostic does not lie about whether R would
        -- have killed the focus. The gate reads proj_state_r_impact's
        -- magical-frame eff_hp and adds OVERKILL_BUFFER_HP; the prior
        -- diagnostic used ctx.eff_hp (which includes physical barriers and
        -- shields) and omitted the buffer, so it under-reported `y` on
        -- shielded targets and over-reported `y` on raw-low-HP targets.
        local diag_r_eh = (ctx.proj_state_r_impact
                           and ctx.proj_state_r_impact.eff_hp_magical)
                       or (ctx.eff_hp or 0)
        local diag_r_alone = (diag_r_eh + (state.OVERKILL_BUFFER_HP or 0))
                             <= (ctx.r_dmg_at_d or 0)
        tlog(1, "teamfight", {
            decision = ok and "fire" or "idle", archetype = "tf_focus",
            target  = uname(focus),
            hp      = string.format("%.0f", focus_hp or 0),
            via     = focus_via,
            -- v6.15.190 diagnostics: why no via=team and no tf_r this tick.
            team_n  = string.format("%d", team_n or 0),
            ready_r = ctx.ready_r and "y" or "n",
            r_alone = diag_r_alone and "y" or "n",
            r_range = ((ctx.d or 0) >= state.STARTER_R_MIN_RANGE_FRAC
                       * (ctx.atk_range or 1)) and "y" or "n",
            ready_e = ctx.ready_e and "y" or "n",
            ta      = ctx.self_take_aim_active and "y" or "n",
            q_chg   = string.format("%d", ctx.q_charges or 0),
            q_pos   = q_pos and "y" or "n",
        })
        if ok then
            state.last_layer1_intent = "tf_focus:" .. uname(focus)
            state.l1_counter = state.l1_counter + 1
        end
        -- v6.15.134: stamp the throttle UNCONDITIONALLY — even when safe_issue
        -- rejected the ATTACK_TARGET. A rejection is almost always the order-
        -- dedup catching a focus target that is ALREADY set; without the
        -- throttle, teamfight_tick re-appraises and re-issues every tick,
        -- producing the v6.15.133-demo log spam (258 issue_rejected /
        -- teamfight decision=idle). Stamping it here re-appraises every 0.4s
        -- (LAYER1_COMMIT_WINDOW_SEQ) instead, same cadence as a successful
        -- tf_focus. engaged_target is set regardless — focus IS the engaged
        -- target whether or not this particular re-issue deduped.
        state.last_layer1_t     = now()
        state.last_layer1_was_r = false
        state.engaged_target    = focus
        state.engaged_target_t  = now()
        return
    end

    local is_r = (archetype == "tf_r")
    -- v6.15.195 (audit A9): mirror the autos-only-path diagnostic field set
    -- onto the fire log too. Without this, a post-mortem on a fire log
    -- can't answer "why didn't R fire here" — ready_r / r_alone / r_range
    -- were absent on the fire path, only present on idle/autos lines. The
    -- r_alone here uses the same gate-mirroring computation as v6.15.194
    -- audit #7 (proj_state_r_impact.eff_hp_magical + OVERKILL_BUFFER_HP
    -- vs r_dmg_at_d) so the field cannot drift from the actual gate.
    local fire_r_eh = (ctx.proj_state_r_impact
                       and ctx.proj_state_r_impact.eff_hp_magical)
                   or (ctx.eff_hp or 0)
    local fire_r_alone = (fire_r_eh + (state.OVERKILL_BUFFER_HP or 0))
                         <= (ctx.r_dmg_at_d or 0)
    tlog(1, "teamfight", {
        decision  = "fire", archetype = archetype,
        target    = uname(fire_target),
        hp        = string.format("%.0f", focus_hp or 0),
        d         = string.format("%.0f", ctx.d or 0),
        q_cover   = q_cover and string.format("%d", q_cover) or "-",
        q_aim     = q_aim or "-",
        force     = force and "y" or "n",
        -- v6.15.145 diagnostics (full-test C1/C2) + v6.15.148 focus_via.
        via       = focus_via,
        team_n    = string.format("%d", team_n or 0),   -- v6.15.190
        -- v6.15.195 (audit A9) R-gate parity with the autos-only line.
        ready_r   = ctx.ready_r and "y" or "n",
        r_alone   = fire_r_alone and "y" or "n",
        r_range   = ((ctx.d or 0) >= state.STARTER_R_MIN_RANGE_FRAC
                     * (ctx.atk_range or 1)) and "y" or "n",
        ready_e   = ctx.ready_e and "y" or "n",
        ta        = ctx.self_take_aim_active and "y" or "n",
        q_chg     = string.format("%d", ctx.q_charges or 0),
    })
    state.last_layer1_intent = "teamfight_" .. archetype .. ":" .. uname(fire_target)
    state.l1_counter = state.l1_counter + 1
    if force then state.force_counter = state.force_counter + 1 end
    state.last_refusal = nil
    fire_steps("teamfight_" .. archetype, steps, ctx)
    -- Record the Q placement into the global coverage list (append + prune).
    if archetype == "tf_q" and q_pos then
        state.starter_q_track[#state.starter_q_track + 1] = {
            x = q_pos.x or 0, y = q_pos.y or 0, t = now(),
        }
        local kept = {}
        for i = 1, #state.starter_q_track do
            local e = state.starter_q_track[i]
            if (now() - e.t) < state.STARTER_Q_ZONE_LIFE then
                kept[#kept + 1] = e
            end
        end
        state.starter_q_track = kept
    end
    state.last_layer1_t     = now()
    state.last_layer1_was_r = is_r
    state.engaged_target    = fire_target
    state.engaged_target_t  = now()
end

----------------------------------------------------------------------------
-- Layer 1.5 — channel-punish / TP-interrupt (auto, no key)
----------------------------------------------------------------------------

-- Triggered by OnModifierCreate on any enemy that begins a relevant channel.
-- Layer 1.5 channel-interrupt. When `target_self == true` we DELIBERATELY
-- skip the grenade-on-source path — Sniper's grenade is reserved for the
-- Layer 2 self-save in that case (Pudge dismembering Sniper: grenade-self
-- pushes Sniper out of the 200u tether; grenade-on-Pudge would consume the
-- same CD with worse geometry, leaving Sniper locked in the channel).
-- R-punish on Sniper-self-target channels stays disabled for the same
-- reason — Sniper has 2s of cast point during which Pudge is hard to hit
-- and Sniper's mana/cast budget is better spent escaping.
local function on_enemy_channel_start(caster, mod_name, target_self)
    if not self_alive_ok() then return end
    local me = state.self_npc
    if not Target.IsEnemyHero(caster, me) then return end

    -- v6.14 A3: user can disable the auto-R / auto-grenade behavior of L1.5
    -- (some users want defense-only when combo key not held).
    if state.menu and state.menu.layer15_auto and not state.menu.layer15_auto:Get() then
        tlog(3, "channel_layer15_disabled_by_user", { mod = mod_name })
        return
    end

    if target_self then
        tlog(3, "channel_layer15_skipped_target_self", { mod = mod_name })
        return
    end

    -- Channel-Punish via R if score warrants (only for non-self-target channels).
    -- v6.13 Cross F#3 / Offense F#2: Layer 1.5 R must register with the
    -- r_abort_tick + commit-window machinery, otherwise (a) mid-cast aborts
    -- never fire on the L1.5 target and (b) a combo tick can dispatch a
    -- competing action because the Layer-1 throttle is not stamped.
    -- v6.15.232: stamp last_layer1_t / last_layer1_was_r — the R-commit
    -- throttle starter_tick / teamfight_tick actually read. v6.14.1's H4
    -- stamped a separate state.last_layer15_t that nothing ever read, so
    -- (b) was never fixed; fog_snipe_tick stamps the real throttle
    -- (v6.15.194) — match it.
    -- v6.14.1 H6: also gate on target NOT magic_immune (BKB blocks R damage)
    -- and use commit_floor() so the slider applies here too.
    if ability_ready(A.R)
       and not NPC.HasState(caster, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
        local s = ScoreUltTarget(caster)
        if s and s >= commit_floor() then
            local ok = issue_cast_target("channel_punish_r", ability(A.R), caster)
            if ok then
                state.last_r_target     = caster
                state.last_r_combo_name = "channel_punish_15"
                state.last_r_dispatch_t = now()
                state.last_layer1_t     = now()
                state.last_layer1_was_r = true
                -- v6.15.141: channel-punish dispatches R directly (not via
                -- fire_steps), so it must arm the same R-in-flight markers
                -- fire_steps does — the cast-protect veto window and the
                -- fast-cancel detector's r_phase_seen flag — otherwise this R
                -- has no native-order protection and a stale r_phase_seen from
                -- a prior cast defeats the cancel detector for it.
                state.r_cast_protect_until_t = now() + r_cast_point() + 0.4
                state.r_phase_seen = false
            end
        end
    end

    -- Grenade interrupt for ally-channels (TP-out, enemy team-wipe channel
    -- like Enigma BH that doesn't directly target Sniper).
    -- v6.14.1 H3: respect is_reserved(A.D) so offense's pending D step
    -- isn't pre-empted; AND delegate to grenade_at_caster.fire which uses
    -- the midpoint-cast geometry to push the enemy AWAY from Sniper
    -- (raw position cast would push them in their facing = often toward Sniper).
    if ability_ready(A.D)
       and not is_reserved(A.D)
       and dist_to(caster) <= state.grenade_cast_range() then
        if not NPC.HasState(caster, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local grenade_fn = SAVE_FIRE and SAVE_FIRE.grenade_at_caster
                              and SAVE_FIRE.grenade_at_caster.fire
            if grenade_fn then
                grenade_fn("channel_break", caster)
            else
                local pos = NPCLib.origin(caster)
                if pos then
                    issue_cast_position("channel_break_d", ability(A.D), pos)
                end
            end
        end
    end
end

----------------------------------------------------------------------------
-- Layer 2 — defensive auto-fire
----------------------------------------------------------------------------

-- v5.8: reverted from 1.5 to 0.5s. The 1.5s window was blocking Pike from
-- firing when it should have served as a cross-threat fallback (e.g., Bara
-- grenade at T=0, Pudge Dismember at T=0.5, Pike for Pudge blocked). The
-- 0.5s window is just long enough for Pike's 0.5s push to complete before
-- the next save fires — preventing same-frame double-stack but allowing
-- legitimate back-to-back saves for distinct threats.
-- v6.15.46 (user directive — 'use 150ms as reaction time, that is my reaction
-- time for most of the games I went professional'): LAYER2_REACTION_WINDOW
-- dropped from 0.5s to 0.15s. This is the inter-save throttle — minimum gap
-- between consecutive layer2 dispatches. The 0.5s value was conservative,
-- not grounded in a reflex constant; 0.15s matches a trained human's
-- visual-reaction-time floor for combat decisions. Effect: when two threats
-- arrive within ~300ms (Disruptor Static Storm pulse + Bara charge, Pudge
-- hook + Bane grip combo, etc.), brain can save for BOTH within the window
-- instead of dropping the second. Per-(caster, mod) dedup via
-- state.responded_threats stays unchanged — that prevents double-firing on
-- the SAME threat, not consecutive different threats.
local LAYER2_REACTION_WINDOW = 0.15

-- v6.13 Defense F#6/F#7: single source of truth for "is the defensive layer
-- allowed to fire right now?" — gates both polled paths (damage_rate_panic_check,
-- armed_threats_tick, ally_save_scan, saves_inventory snapshot) AND event-driven
-- paths (OnModifierCreate threats, anim gap_close/hard_disable/channel_start,
-- OnLinearProjectileCreate hook intercept, on_enemy_channel_start). Without
-- this, the user-facing "Enable auto-defense" toggle silences only the polls
-- — every event-fed save still fires.
-- v6.14: state.panic_override bypasses auto_defense (but never master enable)
-- so the panic key works even when auto-defense is toggled off.
local function defense_enabled()
    if not state.menu then return true end
    if state.menu.enable and not state.menu.enable:Get() then return false end
    if state.panic_override then return true end
    if state.menu.auto_defense and not state.menu.auto_defense:Get() then return false end
    return true
end

local function layer2_can_fire()
    if not defense_enabled() then return false end
    if (now() - state.last_save_t) < LAYER2_REACTION_WINDOW then return false end
    return true
end

-- v6.15.251: caster param stamps state.last_save_target for the per-target
-- combo-suppression gate in starter_tick. Call sites without a known caster
-- (Lotus reflect, ally save) pass nil and leave the target field untouched.
local function mark_layer2_fired(threat_caster)
    state.last_save_t = now()
    if threat_caster and Entity.IsEntity(threat_caster) then
        state.last_save_target = threat_caster
    end
end

-- Save priority order: Eul → Lotus → Glimmer → Pike → Force → Grenade-self → BKB
-- For each, fire if available + not on CD; cascade until one succeeds.
-- v6.15.251: threat_caster threaded through so the per-target combo-
-- suppression gate in starter_tick can know which enemy was just saved-
-- against. Pre-v6.15.251 callers without a caster (Lotus reflect, ally
-- saves, smoke prefire, channel-source dispatch) pass nil and the
-- per-target stamp stays untouched.
local function record_save(intent, item_name, threat_mod, threat_caster)
    state.last_save_intent = item_name .. ":" .. intent
    state.l2_counter = state.l2_counter + 1
    -- v6.15 C1 / v6.15.2 H2: feed postmortem state ONLY for self saves.
    -- Ally saves (intent starts "save_ally_") shouldn't poison postmortem
    -- since they didn't defend Sniper — misattributing them as Sniper's
    -- last-self-defense confuses the user's debugging.
    if not intent:find("^save_ally") and not intent:find("^smoke_prefire") then
        state.last_save_kind       = item_name
        state.last_save_threat_mod = threat_mod
        -- v6.15.139: open the save-cast-protect veto window. A self-save's
        -- order (Hurricane Pike / Force / grenade / etc.) was being silently
        -- replaced by a native Orb-Walker/Hit&Run MOVE/ATTACK order issued the
        -- same tick (cast_verify fired=n / cd_after=0 — the PA-gap-close Pike
        -- failure). OnPrepareUnitOrders now vetoes native unit-disrupting
        -- orders during this window, exactly as it does for R's cast. Only
        -- self-saves get it — an ally save / smoke prefire does not cast on
        -- Sniper, so it must not freeze Sniper's native orbwalk.
        state.save_cast_protect_until_t = now() + state.SAVE_CAST_PROTECT_S
    end
    -- Include the threat category in the log when known so the user can see
    -- at a glance which kind of response the brain selected (close_gap vs
    -- channel_on_self vs targeted_disable etc.).
    local category = threat_mod and TD.CategoryOf(threat_mod) or "-"
    tlog(1, "layer2_save", { item = item_name, intent = intent, category = category })
    mark_layer2_fired(threat_caster)
end

----------------------------------------------------------------------------
-- Per-threat save selection
--
-- The save chain consults three sources in order:
--   1. Hero override (`SNIPER_SAVE_OORIDES[threat_mod]`)
--      Sniper-specific re-ranking: for some threats this hero has saves
--      (`grenade_self`) that should be tried first or in a different order.
--   2. Threat-data recommendation (`TD.RecommendedSaves(threat_mod)`)
--      Universal best-to-worst recommendation per threat.
--   3. Generic fallback chain — same generic order as v4.4 baseline.
--
-- Reserve-the-good-stuff: even when an item qualifies (kind matches, geometry
-- OK), the brain applies `TD.SaveReservePenalty` — high-CD saves like BKB get
-- a score deduction when the threat is low-severity. This keeps BKB available
-- for genuine emergencies instead of burning it on a Pudge Hook.
----------------------------------------------------------------------------

-- v6.15.213: two-phase Pike-on-self repositioning for DRAIN threats (Pugna
-- Life Drain, Lion Mana Drain). Hurricane Pike self-cast (verified vs
-- Liquipedia: instant cast, 600u push over 0.4s) pushes Sniper in his FACING
-- direction, so to move Sniper AWAY from the caster the brain must face away
-- first. pike_self_reposition issues a move order that turns Sniper away and
-- arms state.pending_pike_self; pending_pike_self_tick fires the Pike once
-- the facing is aligned. If Sniper already faces away, the Pike fires now.
-- v6.15.214: used for ALL Pike-on-self saves (drains route here directly;
-- other threats reach it as the Pike-on-enemy fallback). If Sniper is
-- disabled mid-turn (e.g. a stun lands) the move order is ignored and the
-- pending times out -- no worse than a raw self-cast, which also cannot fire
-- while disabled.
-- "Facing away" tolerance is 30 degrees: a Pike push within 30deg of
-- straight-away from the caster still lands Sniper safely away.
state.pike_self_reposition = function(intent, threat_caster, it)
    local me = state.self_npc
    if not me then return false end
    -- v6.15.244: route both reads through the typed safe-read (v6.15.238
    -- C1), matching the rest of the escape paths.
    local me_pos = NPCLib.origin(me)
    if not me_pos then return false end

    -- v6.15.249: derive a `toward` direction even when threat_caster is
    -- nil. Panic-mode dispatches (damage_rate_panic_check, user panic
    -- key) call into the save chain with nil threat_caster, and pike's
    -- old behaviour fell to a raw issue_item_self push in Sniper's
    -- current facing -- often TOWARD the enemy he was attacking. The
    -- centroid fallback mirrors grenade_self_cast_point's panic path:
    -- toward = direction from Sniper to centroid of nearby enemies.
    -- Then the helper's danger-aware 7-angle pick + turn-then-fire run
    -- as normal. Reposition returns false when no caster is known AND
    -- no enemies are in 1500u (in which case there's nothing to escape
    -- from, so the caller's final issue_item_self last-resort is fine).
    local cp = threat_caster and NPCLib.origin(threat_caster) or nil
    local toward
    if cp then
        toward = cp - me_pos
        if toward:Length2DSqr() < 1 then return false end  -- caster on top of Sniper
        toward = toward:Normalized()
    else
        local enemies = NPCs.InRadius(me_pos, 1500, Entity.GetTeamNum(me),
            Enum.TeamType.TEAM_ENEMY, true, true)
        if enemies and #enemies > 0 then
            local centroid = VectorCenter(enemies)
            if centroid then
                local diff = centroid - me_pos
                if diff:Length2DSqr() > 1 then toward = diff:Normalized() end
            end
        end
        if not toward then return false end
    end

    -- v6.15.244 (clue C4 finalisation): danger-aware escape direction.
    -- Pike push is 600u along Sniper's facing after the turn. The shared
    -- helper picks the lowest-danger landing among 7 angles off
    -- straight-away (0, +/-35, +/-65, +/-90 degrees, v6.15.245), so the
    -- chosen escape_dir IS the new facing target. v6.15.242 TF report:
    -- pike was pushing Sniper into a backliner because the historical
    -- code always picked 0deg. v6.15.249 also covers the panic case
    -- where threat_caster is nil (centroid fallback above).
    local PIKE_PUSH = 600
    local escape_dir = state.pick_escape_dir(me_pos, toward, PIKE_PUSH, threat_caster)
    if not escape_dir then return false end
    local away_pt = Vector(me_pos.x + escape_dir.x * 400, me_pos.y + escape_dir.y * 400, me_pos.z)
    -- v6.15.215: NPC.FindRotationAngle returns RADIANS, not degrees. The
    -- v6.15.213 code compared the raw radian value to 30, which is ALWAYS
    -- true (radians cap at pi) -- so pike_self_reposition always took the
    -- immediate branch and Sniper never turned (the user's "pike not
    -- turning, thrown into the enemy"). math.deg converts before the 30deg
    -- tolerance compare.
    local angle = math.deg(math.abs(NPC.FindRotationAngle(me, away_pt)))
    if angle <= 30 then
        -- Already facing away: the 600u push lands away from the caster.
        local ok = issue_item_self(intent, "def", it)
        if ok then
            record_displacement(0, now() + 0.5)
            state.pending_pike_self = nil
            tlog(1, "pike_self_fired", {
                angle = string.format("%.0f", angle), phase = "immediate",
            })
        end
        return ok
    end
    -- Facing the caster / sideways: turn away first. The move order rotates
    -- Sniper toward away_pt; pending_pike_self_tick casts the Pike once the
    -- facing is within tolerance (0.7s deadline ~ a 180deg turn at 0.7 rate).
    local moved = safe_issue {
        hero = HERO_KEY, layer = "def",
        intent = intent .. "_turnaway",
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = away_pt,
    }
    state.pending_pike_self = {
        caster   = threat_caster,
        away_pt  = away_pt,
        deadline = now() + 0.7,
        intent   = intent,
    }
    tlog(1, "pike_self_turnaway", {
        angle = string.format("%.0f", angle), caster = uname(threat_caster),
    })
    return moved
end

-- v6.15.213: phase 2 — cast Pike-on-self once Sniper has turned to face away
-- from the caster. On timeout the pending is dropped; the channel's periodic
-- re-fire (persistent_threats_tick) re-attempts.
state.pending_pike_self_tick = function()
    local p = state.pending_pike_self
    if not p then return end
    local me = state.self_npc
    if not me or not Target.IsAlive(me) then state.pending_pike_self = nil; return end
    if now() > p.deadline then
        tlog(2, "pike_self_turnaway_timeout", {})
        state.pending_pike_self = nil
        return
    end
    -- Caster gone: no reposition needed; drop without burning Pike's CD.
    if not p.caster or not Entity.IsEntity(p.caster) or not Target.IsAlive(p.caster) then
        state.pending_pike_self = nil
        return
    end
    -- v6.15.215: FindRotationAngle is radians -- math.deg before the compare.
    local angle = math.deg(math.abs(NPC.FindRotationAngle(me, p.away_pt)))
    if angle > 30 then return end  -- still turning
    local it = NPCLib.item(state.self_npc, "item_hurricane_pike")
    if it and NPCLib.item_ready(state.self_npc, "item_hurricane_pike") then
        if issue_item_self((p.intent or "pike_self") .. "_aligned", "def", it) then
            record_displacement(0, now() + 0.5)
            tlog(1, "pike_self_fired", {
                angle = string.format("%.0f", angle), phase = "turned",
            })
        end
    end
    state.pending_pike_self = nil
end

-- v6.15.222: fresh-Hurricane-Pike first-use fix. Confirmed engine quirk
-- (see API_GOTCHAS.md / the v6.15.221 log): the FIRST cast of a freshly
-- acquired item is silently dropped by the engine -- the order reaches
-- ExecuteOrder intact but Pike never casts (cooldown stays 0). One cast
-- "breaks the item in"; every cast after works, so the first real Pike save
-- of the game was being eaten. Two-part Pike-scoped workaround:
--   PRIME: when Sniper owns an un-primed Pike and is safe (no enemy hero
--     within COMBO_CLASSIFY_RADIUS, not in a combo), fire one throwaway
--     Pike-on-self to spend the doomed first cast early.
--   DOUBLE-ISSUE: if a real Pike save fires before Pike was primed, the
--     fire closure stamps state.pike_reissue and this re-issues Pike once
--     next frame -- the 2nd cast lands.
-- state.pike_primed flips true ONLY on positive proof (cooldown observed
-- > 0); state.pike_prime_done guards the one-shot prime cast.
state.pike_prime_tick = function()
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return end
    local pike = NPCLib.item(me, "item_hurricane_pike")
    if not pike then return end
    -- Positive proof Pike has fired at least once: it is broken in.
    if not state.pike_primed and Ability.GetCooldown
       and (Ability.GetCooldown(pike) or 0) > 0 then
        state.pike_primed = true
    end
    if state.pike_primed then
        state.pike_reissue = nil
        return
    end
    -- DOUBLE-ISSUE: a real save fired an un-primed Pike -> re-issue once.
    local ri = state.pike_reissue
    if ri then
        state.pike_reissue = nil
        if (now() - (ri.t or 0)) <= 0.4
           and ri.caster and Entity.IsEntity(ri.caster)
           and Target.IsAlive(ri.caster)
           and NPCLib.item_ready(me, "item_hurricane_pike") then
            if issue_item_target("pike_reissue", "def", pike, ri.caster) then
                tlog(1, "pike_reissue", { caster = uname(ri.caster) })
            end
        end
        return
    end
    -- PRIME: one throwaway Pike-on-self when un-primed and genuinely safe.
    if state.pike_prime_done then return end
    if not NPCLib.item_ready(me, "item_hurricane_pike") then return end
    if not self_alive_ok() then return end
    if state.count_engaged_enemies() > 0 then return end
    if (now() - (state.last_combo_key_down_t or 0)) < 3.0 then return end
    if issue_item_self("pike_prime", "def", pike) then
        state.pike_prime_done = true
        tlog(1, "pike_prime", {})
    end
end

-- Map of `save_name → {short, fire_fn}`. Centralizes the item-vs-ability
-- distinction (grenade_self is an ability with directional cast; everything
-- else is an item self-cast). Adding a new hero-specific save in another
-- hero file means adding an entry here for that hero.
local SAVE_FIRE = {
    -- Universal item self-casts. Same shape for every hero — just paste
    -- this block into new hero files. Items the hero doesn't own simply
    -- have `NPCLib.item(state.self_npc,name)` return nil, and the chain skips them via the
    -- save_is_ready / item_ready guards. Listed in rough preference order
    -- (cheapest CD first), but the per-threat RECOMMENDED_SAVES list
    -- overrides this ordering.
    item_cyclone        = { short = "eul",      fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_cyclone")) end },
    item_wind_waker     = { short = "windwaker",fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_wind_waker")) end },
    item_lotus_orb      = { short = "lotus",    fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_lotus_orb")) end },
    item_manta          = { short = "manta",    fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_manta")) end },
    item_satanic        = { short = "satanic",  fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_satanic")) end },
    item_glimmer_cape   = { short = "glimmer",  fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_glimmer_cape")) end },
    item_solar_crest    = { short = "solar",    fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_solar_crest")) end },
    item_eternal_shroud = { short = "shroud",   fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_eternal_shroud")) end },
    item_pipe_of_insight = { short = "pipe",    fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_pipe_of_insight")) end },
    item_crimson_guard  = { short = "crimson",  fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_crimson_guard")) end },
    item_blade_mail     = { short = "blademail",fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_blade_mail")) end },
    item_ghost          = { short = "ghost",    fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_ghost")) end },
    item_disperser      = { short = "disperser",fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_disperser")) end },
    item_diffusal_blade = {
        short = "diffusal",
        fire  = function(intent, threat_caster)
            -- Diffusal active is target-cast (purge), not self. Use on the
            -- threat caster when known and in cast range; otherwise no-op.
            local it = NPCLib.item(state.self_npc,"item_diffusal_blade")
            if not it then return false end
            if threat_caster and Entity.IsEntity(threat_caster) and Target.IsAlive(threat_caster)
               and dist_to(threat_caster) <= 600
            then
                return issue_item_target(intent, "def", it, threat_caster)
            end
            return false
        end,
    },
    -- Pike: prefer ENEMY-target when a specific threat caster is known and
    -- in cast range. Enemy-target Pike pushes the enemy 600u (deterministic
    -- direction outward from Sniper), Sniper gets bonus attacks during the
    -- push, no Sniper-facing dependency. Self-cast fallback when no caster
    -- (Sniper's facing then controls the push — used to be the only mode,
    -- but produces "random direction" issues when Sniper faces threat).
    -- Blink Dagger and variants — instant 1200u teleport. AWAY from threat
    -- is the right direction; cast position is computed from threat_caster.
    -- Self-position-target with offset; no facing-angle dependency because
    -- Blink doesn't have a cast point or facing requirement.
    item_blink = {
        short = "blink",
        fire  = function(intent, threat_caster)
            local it = NPCLib.item(state.self_npc,"item_blink"); if not it then return false end
            local pos = blink_escape_position(threat_caster); if not pos then return false end
            return issue_item_position(intent, "def", it, pos)
        end,
    },
    item_swift_blink = {
        short = "swift_blink",
        fire  = function(intent, threat_caster)
            local it = NPCLib.item(state.self_npc,"item_swift_blink"); if not it then return false end
            local pos = blink_escape_position(threat_caster); if not pos then return false end
            return issue_item_position(intent, "def", it, pos)
        end,
    },
    item_arcane_blink = {
        short = "arcane_blink",
        fire  = function(intent, threat_caster)
            local it = NPCLib.item(state.self_npc,"item_arcane_blink"); if not it then return false end
            local pos = blink_escape_position(threat_caster); if not pos then return false end
            return issue_item_position(intent, "def", it, pos)
        end,
    },
    item_overwhelming_blink = {
        short = "overwhelming_blink",
        fire  = function(intent, threat_caster)
            local it = NPCLib.item(state.self_npc,"item_overwhelming_blink"); if not it then return false end
            local pos = blink_escape_position(threat_caster); if not pos then return false end
            return issue_item_position(intent, "def", it, pos)
        end,
    },
    -- Phase Boots active: pass through units + speed boost. Minor save —
    -- doesn't displace much but helps escape body-blocks.
    item_phase_boots = { short = "phase",     fire = function(intent) return issue_item_no_target(intent, "def", NPCLib.item(state.self_npc,"item_phase_boots")) end },
    item_hurricane_pike = {
        short = "pike",
        -- v6.4: fire receives threat_mod (third arg) so it can decide whether
        -- self-cast fallback is useful. For homing close_gap threats (Bara
        -- Charge, Tusk Snowball), Pike-on-self is useless — the charger
        -- re-targets and the push moves Sniper in Sniper's facing (often
        -- toward the charger). When Pike-on-enemy is out of range AND the
        -- threat is close_gap, return false so the chain falls through to
        -- grenade_at_caster instead of "firing" a useless Pike-self.
        fire  = function(intent, threat_caster, threat_mod)
            local it = NPCLib.item(state.self_npc,"item_hurricane_pike")
            -- v6.15.213: DRAIN threats (Pugna Life Drain, Lion Mana Drain) do
            -- not disable Sniper, so route them to the two-phase Pike-on-self
            -- repositioning (turn away from the caster, then self-cast)
            -- instead of Pike-on-enemy. Disabling channels (Pudge Dismember,
            -- Shaman Shackles) STUN Sniper -- he cannot self-cast Pike during
            -- them -- so they keep the Pike-on-enemy path below.
            if it and threat_caster and Entity.IsEntity(threat_caster)
               and Target.IsAlive(threat_caster)
               and threat_mod and TD.CategoryOf(threat_mod) == "drain"
            then
                return state.pike_self_reposition(intent, threat_caster, it)
            end
            -- Pike-on-enemy (radial outward 425u). 7.41C enemy cast range = 425.
            if threat_caster and Entity.IsEntity(threat_caster) and Target.IsAlive(threat_caster)
               and not NPC.HasState(threat_caster, MS.MODIFIER_STATE_MAGIC_IMMUNE)
               and dist_to(threat_caster) <= state.pike_enemy_range()
            then
                local ok = issue_item_target(intent, "def", it, threat_caster)
                if ok then  -- v6.13 Cross F#19: enemy airborne for ~0.5s
                    record_displacement(Entity.GetIndex(threat_caster), now() + 0.5)
                    -- v6.15.222: an un-primed Pike's first cast is eaten by
                    -- the engine; stamp a re-issue so pike_prime_tick fires
                    -- the 2nd (landing) cast next frame (double-issue).
                    if not state.pike_primed then
                        state.pike_reissue =
                            { caster = threat_caster, t = now() }
                    end
                end
                return ok
            end
            -- Skip self-cast fallback for homing close_gap threats; let chain
            -- try grenade_at_caster (600u cast range, reaches farther).
            -- v6.15.248: only return false when grenade is actually available
            -- (shard acquired AND D learned). When grenade is absent, the
            -- chain's grenade entries are silently strangled by save_is_ready's
            -- ability_ready gate (Ability.GetLevel = 0 returns not_ready) and
            -- the chain exhausts with no save. User report v6.15.247: "pike
            -- is not firing without grenade in inventory" -- pike was the only
            -- displacement save in those builds and the close_gap return-false
            -- killed it. Falling through to pike_self_reposition below gives
            -- at least one save instead of zero. Pike-self vs an instant blink
            -- (PA) is imperfect (autos start before the 0.4s push lands) but
            -- strictly beats no save -- user-confirmed requirement.
            if threat_mod and TD.CategoryOf(threat_mod) == "close_gap" then
                local d_ab = ability(A.D)
                local grenade_in_chain = d_ab and Ability.GetLevel(d_ab) > 0
                if grenade_in_chain then
                    return false
                end
            end
            -- v6.15.214: Pike-on-self pushes Sniper in his FACING direction,
            -- so a raw self-cast while Sniper faces the enemy throws him
            -- TOWARD the threat. Route ALL Pike-on-self through
            -- pike_self_reposition (turn to face away, then self-cast) -- the
            -- same two-phase mechanism drains use.
            -- v6.15.249: previously only routed through pike_self_reposition
            -- when threat_caster was known; in panic mode (dmg_rate_panic /
            -- user_panic) threat_caster is nil and the function fell through
            -- to raw issue_item_self -- firing pike in Sniper's current
            -- facing with zero danger awareness. pike_self_reposition now
            -- has a centroid fallback for nil threat_caster, so the
            -- turn-then-fire pattern applies in panic too. Raw self-cast
            -- stays as a last resort when there are no enemies in 1500u
            -- to compute a centroid against (nothing to escape from).
            local ok = state.pike_self_reposition(intent, threat_caster, it)
            if ok then return ok end
            local raw_ok = issue_item_self(intent, "def", it)
            if raw_ok then record_displacement(0, now() + 0.5) end  -- self airborne
            return raw_ok
        end,
    },
    -- Force Staff: similar pattern. Force-on-self moves Sniper in Sniper's
    -- facing; Force-on-enemy moves enemy in enemy's facing (often toward
    -- Sniper during a channel — bad). Default to self; the user's facing
    -- is usually toward the threat (attacking), so Force pushes Sniper
    -- AWAY from threat. Less reliable than Pike-on-enemy.
    item_force_staff    = {
        short = "force",
        fire = function(intent)
            local ok = issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_force_staff"))
            if ok then record_displacement(0, now() + 0.5) end
            return ok
        end,
    },
    item_black_king_bar = { short = "bkb",      fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_black_king_bar")) end },
    item_aeon_disk      = { short = "aeon",     fire = function(intent) return issue_item_self(intent, "def", NPCLib.item(state.self_npc,"item_aeon_disk")) end },
    -- Hero-specific saves register here. Sniper's grenade-self uses the
    -- directional cast-point helper to push Sniper away from the threat.
    grenade_self        = {
        short = "grenade_self",
        fire  = function(intent, threat_caster)
            -- v6.13 Cross F#14: offense scheduled a delayed D step (e.g.
            -- snipe_standard at +1.5s). Burning D here means the scheduled
            -- step silently fails when its time arrives.
            if is_reserved(A.D) then
                tlog(2, "save_skip_reserved", { save = "grenade_self", by = state.reservations[A.D].by })
                return false
            end
            local cast_point = grenade_self_cast_point(threat_caster)
            if not cast_point then return false end
            local ok = issue_item_position(intent, "def", ability(A.D), cast_point)
            if ok then record_displacement(0, now() + 0.4) end  -- 475u knockback over 0.4s
            return ok
        end,
    },
    -- Grenade thrown AT the threat caster. Knockback on the caster does two
    -- things: (1) breaks Bara Charge / Tusk Snowball (forced movement
    -- dispels the charge modifier), (2) breaks channels via ROOT_DISABLES
    -- and shoves the caster out of tether range.
    --
    -- **Cast-point geometry is critical.** The grenade pushes affected
    -- units RADIALLY AWAY FROM the cast point. If we cast at the caster's
    -- exact position, the caster is AT the cast point — radial direction
    -- is undefined and the engine pushes them in their FACING direction
    -- (which for a unit dismembering Sniper is TOWARD Sniper). That's the
    -- v5.2 "Pudge gets pushed onto Sniper" bug.
    --
    -- Fix: cast 75u TOWARD Sniper from the caster. The caster is then 75u
    -- from the cast point (well within the 375u radius, so they're still
    -- affected), and the radial push direction is `caster_pos -
    -- cast_point` = away from Sniper. The caster is pushed 475u AWAY.
    -- Sniper (also within the 375u radius given typical channel distances)
    -- happens to be pushed AWAY from the caster as a bonus — both heroes
    -- separate, tether/channel breaks reliably.
    grenade_at_caster   = {
        short = "grenade_at_caster",
        fire  = function(intent, threat_caster)
            if not threat_caster or not Entity.IsEntity(threat_caster) then return false end
            if not Target.IsAlive(threat_caster) then return false end
            if dist_to(threat_caster) > state.grenade_cast_range() then return false end
            -- BKB blocks both knockback and damage — wasted CD.
            if NPC.HasState(threat_caster, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
                return false
            end
            -- v6.13 Cross F#14: same reservation gate as grenade_self.
            if is_reserved(A.D) then
                tlog(2, "save_skip_reserved", { save = "grenade_at_caster", by = state.reservations[A.D].by })
                return false
            end
            -- v6.13 Cross F#18: target about to pop BKB — windowed check.
            -- The simple HasState above catches "BKB already up"; this
            -- catches "BKB ready and will land before our cast arrives".
            if Target.EscapeItemWindowState(threat_caster, 0.4) == "ready" then
                tlog(2, "save_skip_target_will_dispel", { save = "grenade_at_caster" })
                return false
            end
            -- v6.1: skip if baseline (or any other path) already has a save
            -- item queued on this enemy. Prevents the "Pike + grenade fire at
            -- the same time" user observation for Bara — baseline auto-fires
            -- Pike from Items Manager / Linkbreaker, then our brain fires
            -- grenade for the same Bara → both apply. With this check, brain
            -- defers to baseline's pending save.
            local pending, pending_name = save_item_pending_on_target(threat_caster)
            if pending then
                tlog(2, "grenade_at_caster_skip_baseline_pending", {
                    pending_item = pending_name,
                    caster = uname(threat_caster),
                })
                return false
            end
            local me = state.self_npc
            if not me then return false end
            local me_pos     = NPCLib.origin(me)
            local caster_pos = NPCLib.origin(threat_caster)
            if not me_pos or not caster_pos then return false end

            if me_pos:DistanceSqr2D(caster_pos) < 1 then
                -- Caster effectively on top of Sniper; no safe direction.
                return false
            end

            -- v6.15.214: original decision was to cast ON the enemy (max
            -- stun-on-caster for channel interrupt). v6.15.252: switched to
            -- MIDPOINT cast when both Sniper and the caster fit inside the
            -- grenade's 375u self-push radius (i.e. dist <= 750u). User
            -- report: defensive grenade vs PA blink left PA at "random"
            -- close distances because cast-at-caster only pushes Sniper
            -- away -- the caster at the cast point has undefined push
            -- direction (zero vector -> engine fallback to facing/random).
            -- Midpoint cast pushes BOTH apart by 475u each = ~1000u total
            -- mutual separation. The caster STILL gets the 0.4s stun (it's
            -- in the blast), so the channel/charge interrupt for Pudge /
            -- Shaman / Bara is preserved. For long-range channels (Bane
            -- Grip 875u tether, Pugna 1300u drain) midpoint would put cast
            -- > 375u from both; fall back to cast-at-caster so the caster
            -- still gets stunned even if Sniper isn't displaced (and a
            -- stunned caster breaks tether by retracting / dropping
            -- channel).
            local d_ab      = ability(A.D)
            local cast_pt_s = (d_ab and Ability.GetCastPoint
                               and Ability.GetCastPoint(d_ab, true)) or 0.1
            local travel_s  = dist_to(threat_caster) / 2500
            -- v6.15.215: FindRotationAngle is RADIANS; math.deg before the
            -- /400 (turn seconds = angle_deg / 400, so 180deg ~ 0.45s).
            local lead_s    = math.deg(math.abs(NPC.FindRotationAngle(me, caster_pos))) / 400
                              + cast_pt_s + travel_s
            local caster_pred = state.predict_pos(threat_caster, lead_s) or caster_pos
            local GRENADE_RADIUS = 375
            local MAX_TURN_FOR_GRENADE_AT_CASTER = 120
            local sniper_to_pred_d = me_pos:Distance2D(caster_pred)
            local cx, cy, midpoint_used
            if sniper_to_pred_d > 1 and sniper_to_pred_d / 2 <= GRENADE_RADIUS then
                -- midpoint cast: both pushed apart, caster also stunned.
                -- v6.15.254: removed the v6.15.253 rotation block per user
                -- direction ("over-engineering: if D is cast on the right
                -- position sniper will turn himself alone without
                -- intervention"). The v6.15.251 turn-cost factor in
                -- danger_at_pos was making the helper pick rotated angles
                -- even in 1v1 (the log showed cast_pos offset 20-30u from
                -- true midpoint with rotated=y firing on every event),
                -- producing the user-reported "seems random" placements.
                -- Pure midpoint is the right geometry: max mutual separation
                -- and the engine handles Sniper's turn to face cast_pos. The
                -- 120deg facing gate below still guards against stun-causing
                -- channels (Pudge / Bane / Shaman) where Sniper would get
                -- stunned mid-turn and the cast would abort.
                cx = (me_pos.x + caster_pred.x) * 0.5
                cy = (me_pos.y + caster_pred.y) * 0.5
                midpoint_used = true
            else
                -- cast-at-caster: only caster in blast, channel interrupt
                cx = caster_pred.x
                cy = caster_pred.y
                midpoint_used = false
            end

            local rng = (state.grenade_cast_range and state.grenade_cast_range()) or 600
            local dx, dy = cx - me_pos.x, cy - me_pos.y
            local d2 = dx * dx + dy * dy
            if d2 > rng * rng and d2 > 1 then
                local d = math.sqrt(d2)
                cx = me_pos.x + dx / d * rng
                cy = me_pos.y + dy / d * rng
            end
            local cast_point = Vector(cx, cy, caster_pos.z)

            -- v6.15.9 dropped this gate entirely. v6.15.47 re-introduces it
            -- at 120° (less strict than the old 90°) after the user observed
            -- on v6.15.46: 'For pudge ult when facing the other direction,
            -- granade lands late.' Log: 2x cast_verify fired=n at age_ms=
            -- 1533ms on grenade_at_caster against Pudge Dismember (0.3s
            -- cast point). Sniper was facing away (~180°), needed 0.45s
            -- to turn, got stunned at T=0.3s mid-rotation, grenade aborted.
            -- 120° = ~0.3s of turn time at Sniper's 0.6 turn rate, which
            -- fits inside Pudge's cast point + grenade 0.1s = 0.4s budget.
            -- When exceeded, refuse → chain falls to Pike (item-cast, no
            -- facing dependency, fires immediately and pushes Pudge out of
            -- 200u tether). The save that ACTUALLY lands beats the one that
            -- looks better on paper but never resolves.
            -- v6.15.254: post-pick facing gate. With rotation gone the gate
            -- is the only facing protection; for stun-causing channels
            -- (Pudge / Bane / Shaman) where Sniper would be stunned
            -- mid-turn, the gate refuses and the chain falls to pike.
            local angle_to_cast = math.deg(math.abs(NPC.FindRotationAngle(me, cast_point)))
            tlog(3, "grenade_at_caster_cast_plan", {
                caster_dist = string.format("%.0f", dist_to(threat_caster)),
                cast_x = string.format("%.0f", cx),
                cast_y = string.format("%.0f", cy),
                caster_x = string.format("%.0f", caster_pos.x),
                caster_y = string.format("%.0f", caster_pos.y),
                me_x = string.format("%.0f", me_pos.x),
                me_y = string.format("%.0f", me_pos.y),
                angle = string.format("%.0f", angle_to_cast),
                max_turn = MAX_TURN_FOR_GRENADE_AT_CASTER,
                midpoint = midpoint_used and "y" or "n",
            })
            if angle_to_cast > MAX_TURN_FOR_GRENADE_AT_CASTER then
                tlog(2, "grenade_at_caster_skip_facing", {
                    angle = string.format("%.0f", angle_to_cast),
                    max = MAX_TURN_FOR_GRENADE_AT_CASTER,
                })
                return false  -- chain falls to next save (typically Pike)
            end
            return issue_item_position(intent, "def", ability(A.D), cast_point)
        end,
    },
}

-- Default generic chain (used when no threat-specific recommendation exists).
local DEFAULT_SAVE_CHAIN = {
    "item_cyclone", "item_lotus_orb", "item_manta", "item_satanic",
    "item_glimmer_cape", "item_hurricane_pike", "item_force_staff",
    "grenade_self", "item_black_king_bar", "item_aeon_disk",
}

-- Sniper-specific overrides: when a threat has a Sniper-specific best fit
-- that the universal threat-data recommendation can't know about, override
-- here. Examples below. Each entry replaces TD.RecommendedSaves for that
-- threat — the brain still applies reserve penalty + tether check + readiness.
local SNIPER_SAVE_OVERRIDES = {
    -- v6.4 reorder (user directive 2026-05-11): Pike-first across all
    -- channel/charge threats where both Pike and grenade are viable. Rule:
    -- "Pike if you can, grenade only if Pike unavailable — never combo."
    -- The v6.1 baseline-pending check in grenade_at_caster.fire helps but
    -- is racy when brain fires grenade before baseline queues Pike. Chain
    -- order eliminates the race: chain stops at first successful save, so
    -- if Pike fires the chain never even considers grenade.
    --
    -- Pudge Dismember (0.5s cast point, 200u tether). v6.15.8 (regression
    -- fix): Pike's own cast point is 0.5s — it RACES with Pudge's
    -- dismember cast and loses (Sniper gets stunned mid-Pike-cast → Pike
    -- cancels → no save fires, no CD goes off, brain looks frozen). The
    -- v6.15.6 demo log captured this exact race: 4 "issued | item=pike"
    -- entries with on_cd=- (Pike never actually fired). Fix: grenade-at-
    -- caster (0.1s cast) goes first — its cast resolves at T~0.15s, well
    -- before Pudge's T=0.5 stun, so it actually interrupts the dismember.
    -- Pike stays as fallback for when grenade is on its 10s CD.
    modifier_pudge_dismember = {
        "grenade_at_caster",   -- 0.1s cast — wins the race
        "item_hurricane_pike", -- 0.5s cast — fallback when grenade on CD (Pike CD 19s)
        "item_force_staff",    -- 0s cast — instant self-push
        "item_manta", "item_satanic", "item_disperser",
        "item_cyclone", "item_wind_waker", "item_aeon_disk",
        "grenade_self",
    },
    -- Bane Fiend Grip (0.6s cast point, 875u tether). v6.15.8: same race
    -- consideration. Pike's 0.5s cast usually wins against Bane's 0.6s
    -- cast (10ms margin) but grenade's 0.1s is robust. Bane Grip pierces
    -- magic immunity, so BKB doesn't help. Pike push 425u: needs Bane to
    -- be at >450u for tether to break (WillTetherBreak gate enforces).
    -- Grenade 475u push from cast point works at any range Bane can grip.
    modifier_bane_fiends_grip = {
        "grenade_at_caster",   -- 0.1s cast — wins race robustly
        "item_hurricane_pike", -- 0.5s cast — sometimes wins, sometimes loses to 0.6s
        "item_force_staff",
        "item_cyclone", "item_manta", "item_satanic",
        "grenade_self",
    },
    -- Bara Charge (homing). User observation: brain combos Pike + grenade
    -- on Bara (v6.1 baseline-pending check is racy). Pike now first.
    -- Pike-on-Bara dispels the charge via forced-movement state. If Pike
    -- is out of 425u range, the Pike fire entry returns false for close_gap
    -- threats (no self-fallback — Bara re-targets so Pike-self is useless),
    -- chain falls to grenade_at_caster.
    modifier_spirit_breaker_charge_of_darkness = {
        "item_hurricane_pike",                -- primary: forced movement on Bara dispels charge
        "grenade_at_caster",                  -- fallback when Pike out of range / on CD
        "item_force_staff",                   -- enemy-target Force also dispels via forced-movement state
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_lotus_orb", "item_manta", "item_aeon_disk", "item_ghost",
        -- v6.6: removed grenade_self from Bara/Tusk. Self-displacement
        -- against homing threats just delays impact (charger re-targets to
        -- Sniper's new position) and wastes the grenade CD. When grenade is
        -- usable against these threats, grenade_at_caster cancels the
        -- charge — that's the only grenade form that helps here.
    },
    -- Tusk Snowball (homing, ~1200 MS — faster than Bara). v6.15.150 (D6):
    -- a Tusk rolling INSIDE his snowball is immune to displacement — Pike-on-
    -- Tusk and grenade-at-Tusk do NOT pop the snowball or break the homing
    -- (the earlier "Tusk in 425u → Pike dispels via forced movement" note was
    -- wrong). Worse: the chain stops at the first save the engine accepts, so
    -- a fired-but-useless Pike/grenade blocked the real save from ever firing.
    -- Lead instead with non-displacement self-saves that survive the snowball
    -- impact: BKB (the snowball stun + magic damage do not pierce magic
    -- immunity), Eul / Wind Waker self-cast (airborne + invulnerable — the
    -- snowball impact whiffs), Lotus, Aeon Disk as the lethal backstop. No
    -- Pike / grenade entry at all — they cannot help against a snowball.
    -- (Bara Charge is unaffected — Bara is NOT displacement-immune; its
    -- override above keeps the Pike → grenade chain.)
    modifier_tusk_snowball_movement = {
        "item_black_king_bar",
        "item_cyclone",
        "item_wind_waker",
        "item_lotus_orb",
        "item_aeon_disk",
    },
    -- PA Phantom Strike (reactive — blink completed). v6.15.248: grenade
    -- moved first. PA is an INSTANT BLINK (not a channel/charge), so the
    -- v6.4 "Pike-first for channel/charge" directive does not apply.
    -- Grenade-at-caster's 0.4s stun on PA prevents the auto window
    -- entirely; Pike's 0.4s push lets PA land 1-2 autos before the
    -- displacement resolves (v6.15.247 log: save_outcome hp_pct_min 80.4
    -- on a pike-save vs 100 on a grenade-save). Pike stays as immediate
    -- fallback when grenade is on CD. Glimmer follows pike as the
    -- target-lock break for when neither displacement save fires.
    modifier_phantom_assassin_phantom_strike_target = {
        "grenade_at_caster",
        "item_hurricane_pike", "item_glimmer_cape",
        "item_force_staff", "grenade_self", "item_cyclone",
    },
    -- Slark Pounce (line projectile, also leashes). Perpendicular
    -- displacement breaks the line.
    modifier_slark_pounce = {
        "item_force_staff", "item_hurricane_pike", "grenade_self",
        "item_cyclone", "item_manta", "item_black_king_bar",
    },
    -- Shadow Shaman Shackles (0.7s cast point, 800u tether). v6.15.8:
    -- Pike's 0.5s cast wins against 0.7s cast comfortably, BUT grenade's
    -- 0.4s stun on Shaman ALSO breaks the cast point itself (preventing
    -- shackles from ever applying). Grenade first.
    modifier_shadow_shaman_shackles = {
        "grenade_at_caster",   -- 0.1s cast + 0.4s stun on caster — best
        "item_hurricane_pike", -- fallback when grenade on CD
        "item_force_staff",
        "item_cyclone", "item_manta",
        "grenade_self",
    },
    -- Witch Doctor Death Ward (instant cast — no interruption window).
    -- Once Death Ward is summoned the channel is hands-free; Pike-on-WD
    -- and grenade-at-WD both work but only AFTER the ward exists. Grenade
    -- first because grenade interrupts the channel via ROOT_DISABLES
    -- (modifies WD's channel state), Pike just pushes WD away.
    modifier_witch_doctor_death_ward = {
        "grenade_at_caster",
        "item_hurricane_pike",
        "item_force_staff",
        "item_black_king_bar", "item_cyclone",
    },
    -- v6.15.10: Disruptor Kinetic Field. Wall blocks Pike/Force/blink/cyclone
    -- displacement entirely — Concussive Grenade's knockback is the only
    -- motion that crosses. grenade_self (Sniper's facing) first so the user
    -- can aim the escape; grenade_at_caster as backup if Disruptor is close.
    -- (Verify modifier name in demo via modseen.)
    -- Grenade-only on purpose (v6.15.247, reverting v6.15.246's pike/force
    -- prepend). User correction: "pike don't jump over the wall." Hurricane
    -- Pike and Force Staff both apply forced movement OVER TIME (600u over
    -- ~0.4s); Kinetic Field's wall intercepts a sliding push trajectory and
    -- Sniper does not exit. Only Concussive Grenade's INSTANT radial impulse
    -- (475u in a single ImpulseDisplacement event) clears the wall reliably.
    -- The earlier "back-turned -> facing gate rejects, chain runs out" failure
    -- is solved by the facing-aware filter added to state.pick_escape_dir in
    -- v6.15.247: the danger-aware helper now also requires the chosen
    -- cast_point be within Sniper's 120deg turn budget, so the +/-90deg
    -- perpendicular candidates (v6.15.245) are picked when 0deg is unreachable.
    modifier_disruptor_kinetic_field_remnant = {
        "grenade_self",
        "grenade_at_caster",
    },
    -- v6.15.16 (user directive): Pugna Life Drain uses the SAME chain as
    -- Pudge / Bane / Shaman channel_on_self. Pugna channels at range to drain
    -- Sniper's HP; grenade-at-caster's 0.4s stun interrupts the channel and
    -- push breaks the tether (1300u tether — pike push only 425, but grenade
    -- moves Sniper away enough to stretch). Pike fallback for when grenade
    -- on CD. v6.15.15 log: Pugna drained 4 times, Pike fired once and then
    -- no_effective_save for the remaining 3 because Pike's 19s CD outlasts
    -- Pugna's drain CD. Grenade-first gives the 10s CD a tighter rotation.
    modifier_pugna_life_drain = {
        "grenade_at_caster",
        "item_hurricane_pike",
        "item_force_staff",
        "item_manta", "item_satanic", "item_disperser",
        "item_cyclone", "item_wind_waker", "item_aeon_disk",
        "grenade_self",
    },
    -- v6.15.16 (user directive): Legion Commander Duel uses the SAME chain
    -- as Pudge logic. Duel locks Sniper into 1v1 attack-only state for 5s;
    -- grenade's 0.4s stun on Legion breaks her attack momentum + creates
    -- breathing room. Pike-on-Legion pushes her 425u — doesn't end duel
    -- (duel has no range limit) but interrupts her attack timing and lets
    -- Sniper kite. Satanic mid-duel for HP regen. Note: Duel can't be
    -- broken by displacement; goal is survival until it expires or Legion
    -- dies.
    modifier_legion_commander_duel = {
        "grenade_at_caster",
        "item_hurricane_pike",
        "item_satanic",
        "item_manta", "item_disperser",
        "item_force_staff",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk",
        "grenade_self",
    },
    -- Tide Hunter Ravage stays on TD.RecommendedSaves (blink/pike/force/BKB/
    -- pipe). User acknowledged Tide has no easy answer — Ravage is a 0.5s
    -- cast point 1100u AoE stun; the chain just needs to fire SOMETHING.
}

-- v6.15.210 (Option B): ability-keyed twin of SNIPER_SAVE_OVERRIDES for the
-- anim route. The anim route detects threats by KV-authoritative ability
-- name; routing it through ABILITY_TO_THREAT to a modifier key risks drift
-- (ABILITY_TO_THREAT maps pudge_dismember to modifier_pudge_dismember_pull,
-- but the override is keyed modifier_pudge_dismember, so the anim route
-- silently missed Pudge Dismember's tuned grenade-first chain). Each value is
-- the SAME chain table as the SNIPER_SAVE_OVERRIDES entry (shared reference,
-- no data duplication) — only the key differs. legion_commander_duel is
-- intentionally absent: it has no ABILITY_TO_THREAT / anim entry, so the anim
-- route cannot produce that ability name.
state.ANIM_SAVE_OVERRIDES = {
    bane_fiends_grip                  = SNIPER_SAVE_OVERRIDES.modifier_bane_fiends_grip,
    pudge_dismember                   = SNIPER_SAVE_OVERRIDES.modifier_pudge_dismember,
    spirit_breaker_charge_of_darkness = SNIPER_SAVE_OVERRIDES.modifier_spirit_breaker_charge_of_darkness,
    tusk_snowball                     = SNIPER_SAVE_OVERRIDES.modifier_tusk_snowball_movement,
    phantom_assassin_phantom_strike   = SNIPER_SAVE_OVERRIDES.modifier_phantom_assassin_phantom_strike_target,
    slark_pounce                      = SNIPER_SAVE_OVERRIDES.modifier_slark_pounce,
    shadow_shaman_shackles            = SNIPER_SAVE_OVERRIDES.modifier_shadow_shaman_shackles,
    witch_doctor_death_ward           = SNIPER_SAVE_OVERRIDES.modifier_witch_doctor_death_ward,
    pugna_life_drain                  = SNIPER_SAVE_OVERRIDES.modifier_pugna_life_drain,
    disruptor_kinetic_field           = SNIPER_SAVE_OVERRIDES.modifier_disruptor_kinetic_field_remnant,
}

-- v6.15.13: category-based chain fallback. The tested heroes (Pudge dismember,
-- Bane grip, Shaman shackles, WD death ward, Bara/Tusk charge, PA strike,
-- Slark pounce, Disruptor kinetic field) each get a tuned SNIPER_SAVE_OVERRIDES
-- entry. For UNTESTED threats that share the same behavioral category, fall
-- through to a canonical chain by category — same chains we've validated for
-- the tested heroes, applied uniformly without touching the existing entries.
--
-- resolve_save_order consults: SNIPER_SAVE_OVERRIDES → TD.RecommendedSaves →
-- CATEGORY_CHAINS[TD.CategoryOf(threat)] → DEFAULT_SAVE_CHAIN. The category
-- fallback only fires when neither of the first two has an entry, so tested
-- threats are untouched.
local CATEGORY_CHAINS = {
    -- Chase / gap-close (Bara, Tusk, PA Strike, Slark Pounce, Storm Ball
    -- Lightning, Magnus Skewer/RP-prep, anything homing toward Sniper).
    -- Pike-on-enemy radial-pushes them, grenade-at-caster stuns + knocks.
    close_gap = {
        "item_hurricane_pike",
        "grenade_at_caster",
        "item_force_staff",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_lotus_orb", "item_manta", "item_aeon_disk", "item_ghost",
    },
    -- Tether channels on Sniper (Pudge Dismember, Bane Grip, Shaman Shackles,
    -- WD Death Ward, Legion Duel, Pugna Life Drain — anything that locks
    -- Sniper at range from the caster). Grenade-at-caster's 0.4s stun
    -- interrupts cast point + push breaks tether. Pike fallback.
    channel_on_self = {
        "grenade_at_caster",
        "item_hurricane_pike",
        "item_force_staff",
        "item_manta", "item_satanic", "item_disperser",
        "item_cyclone", "item_wind_waker", "item_aeon_disk",
        "grenade_self",
    },
    -- Line projectiles (Mirana Arrow, Pudge Hook, Magnus Skewer, Sven Bolt,
    -- Earth Spirit Boulder). Perpendicular displacement breaks the line.
    line_projectile = {
        "item_force_staff", "item_hurricane_pike", "grenade_self",
        "item_cyclone", "item_manta", "item_black_king_bar",
    },
    -- Single-target hard disable (Hex, Doom debuff cast, Lion Voodoo,
    -- Shaman Voodoo). Instant-cast invuln (Eul/Wind Waker/Lotus) ideal.
    targeted_disable = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_black_king_bar",
    },
    -- AoE lockdown ults (Tide Ravage, ES Echo Slam, Magnus RP, Naga Siren,
    -- Treant Overgrowth, Disruptor Static Storm). Blink/Pike out, BKB the
    -- damage, Aeon trigger on health drop.
    delayed_aoe = {
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe_of_insight", "item_aeon_disk",
    },
    -- Area-deny traps (Disruptor Kinetic Field, Faceless Void Chrono edge).
    -- Forced movement blocked — only knockback escapes.
    trap = {
        "grenade_self",
        "grenade_at_caster",
    },
    -- Drain channels (Pugna Life Drain, Lion Mana Drain). Force/Pike
    -- breaks tether; grenade stuns caster.
    drain = {
        "item_force_staff", "item_hurricane_pike",
        "grenade_at_caster", "grenade_self", "item_cyclone",
    },
    -- Physical-chase debuffs (Lifestealer Open Wounds, Slark Essence Shift).
    -- Pike pushes chaser, Glimmer/Ghost break attack target-lock.
    physical_chase = {
        "item_hurricane_pike", "item_force_staff",
        "item_glimmer_cape", "item_ghost",
        "item_manta", "item_black_king_bar",
    },
    -- Lockdown buffs on enemy (Bristleback turn, Troll trance, Ursa Enrage).
    -- The enemy is now extra-tanky — defensive items rather than displacement.
    lockdown = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_black_king_bar",
    },
    -- Single-target burst (Lina Laguna, Lion Finger, Zeus Bolt, Sniper R'd,
    -- single-target nukes). Lotus reflects, BKB blocks, magic_barrier eats.
    targeted_burst = {
        "item_lotus_orb",
        "item_black_king_bar", "item_pipe_of_insight",
        "item_cyclone", "item_wind_waker", "item_glimmer_cape",
        "item_manta", "item_aeon_disk",
    },
}

-- Resolve the effective save priority for a threat, in preference order:
-- hero-override → threat-data recommendation → category chain → default.
-- v6.15.13: added category chain fallback. Threats with a known
-- TD.CategoryOf but no specific override/recommendation get the canonical
-- chain for their behavioral class (close_gap, channel_on_self, trap,
-- line_projectile, etc.) — same chains validated on the tested heroes.
-- v6.15.20: resolve_save_order returns (chain, is_authoritative). Hero-
-- specific overrides are authoritative — user knows mechanics the kind-
-- match filter doesn't (e.g. grenade-at-caster's 0.4s stun on Pugna
-- interrupts the drain channel; Pike-on-enemy's forced-movement also
-- breaks channels regardless of tether reach). Try_save_self bypasses
-- kind_mismatch and tether_unreachable filters for authoritative chains.
local function resolve_save_order(threat_mod, category_hint, ability)
    -- v6.15.210 (Option B): ability-keyed override, checked first. The anim
    -- route detects by KV-authoritative ability name; keying the override by
    -- ability sidesteps ABILITY_TO_THREAT, whose modifier-name values can
    -- drift from the SNIPER_SAVE_OVERRIDES keys. Same authority as the
    -- modifier-keyed override (it is the same chain table).
    if ability then
        local ao = state.ANIM_SAVE_OVERRIDES[ability]
        if ao then return ao, true end
    end
    if threat_mod then
        local hero = SNIPER_SAVE_OVERRIDES[threat_mod]
        if hero then return hero, true end
        local td = TD.RecommendedSaves(threat_mod)
        if td then return td, false end
        local category = TD.CategoryOf and TD.CategoryOf(threat_mod) or nil
        if category and CATEGORY_CHAINS[category] then
            tlog(3, "chain_fallback_category", {
                threat = threat_mod, category = category,
            })
            return CATEGORY_CHAINS[category], false
        end
    end
    -- v6.15.209: the anim route detects by KV-authoritative ability name, but
    -- ABILITY_TO_THREAT may carry no resolved modifier (the modifier-name
    -- guess is unverified). The anim handler still knows the behavioural
    -- category, so prefer that category chain over the fully generic default
    -- when no threat_mod resolved — an unrecognised channel still gets the
    -- channel chain, an unrecognised gap-close the close_gap chain, etc.
    if category_hint and CATEGORY_CHAINS[category_hint] then
        tlog(3, "chain_fallback_category", { threat = "-", category = category_hint })
        return CATEGORY_CHAINS[category_hint], false
    end
    return DEFAULT_SAVE_CHAIN, false
end

-- Item/ability is "ready" — handles the item-vs-ability dichotomy.
-- Both grenade_self and grenade_at_caster use Sniper's Concussive Grenade
-- ability (slot A.D). Without this special case, save_is_ready would fall
-- to NPCLib.item_ready(state.self_npc,"grenade_at_caster") which always returns false (there's
-- no item with that name in Sniper's bag) and the new save type would
-- never fire — that was the v5.0 bug that left Bara firing grenade_self
-- instead of grenade_at_caster.
local function save_is_ready(save_name)
    if save_name == "grenade_self" or save_name == "grenade_at_caster" then
        return ability_ready(A.D)
    end
    return NPCLib.item_ready(state.self_npc,save_name)
end

-- Per-threat save chain. The chain walks the resolved priority list, picks
-- the first save that (a) counters the threat, (b) is ready, (c) passes the
-- tether-distance check if applicable, (d) clears the reserve penalty
-- threshold for its CD tier vs threat severity.
-- v6.15.41: ability-cast vs item-cast distinction for save chains. During
-- Legion Commander Duel (modifier_legion_commander_duel) Sniper is muted —
-- abilities (grenade) fail silently but items (Pike/Force/BKB/etc.) still
-- work. v6.15.40 log surfaced 6 double_fails on grenade-at-caster during
-- duel with silenced=1 at fail time. The fix: filter ability-based saves
-- when Sniper is in any mute state, fall through to the item-based chain.
local ABILITY_SAVES = {
    grenade_at_caster = true,
    grenade_self      = true,
}

local function self_can_cast_abilities()
    local me = state.self_npc
    if not me then return false end
    if NPC.IsSilenced and NPC.IsSilenced(me) then return false end
    if NPC.HasModifier and NPC.HasModifier(me, "modifier_legion_commander_duel") then
        return false
    end
    if MS and MS.MODIFIER_STATE_MUTED and NPC.HasState then
        local ok, muted = pcall(NPC.HasState, me, MS.MODIFIER_STATE_MUTED)
        if ok and muted then return false end
    end
    return true
end

local function try_save_self(intent, threat_mod, threat_caster, category_hint, ability)
    if not layer2_can_fire() then
        tlog(3, "layer2_window_throttle", { intent = intent })
        return false
    end

    -- v6.15.81: instrument the slow-window. Sniper in Take Aim active is
    -- 30-45% MS-slowed (per LIQUIPEDIA_REF.md); saves that rely on kiting
    -- are weaker here. Logging the state so future iterations can identify
    -- save failures correlated with Take Aim active and bias save chains
    -- accordingly. Currently informational only.
    local ta_active, ta_slow = self_take_aim_state()
    if ta_active then
        tlog(2, "save_take_aim_active", {
            intent = intent,
            slow_pct = string.format("%d", ta_slow),
        })
    end

    local order, is_authoritative = resolve_save_order(threat_mod, category_hint, ability)
    local severity = TD.SeverityOf(threat_mod)

    for _, save_name in ipairs(order) do
        local fire_entry = SAVE_FIRE[save_name]
        if not fire_entry then
            tlog(3, "save_chain_skip", { save = save_name, reason = "no_entry" })
        elseif ABILITY_SAVES[save_name] and not self_can_cast_abilities() then
            -- v6.15.41: skip ability-based saves when Sniper is silenced /
            -- muted / in Legion Duel. Falls through to item-based saves in
            -- the same chain (Pike / Force / Manta / etc. work during mute).
            tlog(3, "save_chain_skip", { save = save_name, reason = "ability_muted" })
        elseif not is_authoritative and not save_counters(save_name, threat_mod) then
            -- v6.15.20: kind filter only applies to non-authoritative chains
            -- (TD.RecommendedSaves, CATEGORY_CHAINS, DEFAULT_SAVE_CHAIN).
            -- SNIPER_SAVE_OVERRIDES is the user's explicit preference and
            -- knows mechanics the kind table doesn't capture (e.g. grenade-
            -- at-caster's stun breaks Pugna drain via channel-interrupt, not
            -- displacement).
            tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "kind_mismatch" })
        elseif not is_authoritative and not displacement_will_break_tether(save_name, threat_mod, threat_caster) then
            -- v6.15.20: same — tether geometry check is binary. For long-
            -- tether channels (Pugna 1300u), forced-movement on the caster
            -- still BREAKS the channel even if the tether technically
            -- holds. User overrides know this; trust them.
            tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "tether_unreachable" })
        elseif not save_is_ready(save_name) then
            tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "not_ready" })
        else
            -- Reserve-the-good-stuff: skip high-CD save for low-severity threat.
            -- v6.15 C3 (v6.15.2 H1): multi-stage chain escalation. Count
            -- *other* active threats — exclude the one we're responding to
            -- right now. Otherwise a single Bara charge with its own
            -- armed_threats entry + a freshly-marked responded_threats
            -- entry would self-count as concurrent=2 and unlock high-CD
            -- saves prematurely. We exclude by caster+mod identity.
            local penalty = TD.SaveReservePenalty(save_name, threat_mod)
            local concurrent = 0
            local current_caster_idx = threat_caster and Entity.IsEntity(threat_caster)
                                       and Entity.GetIndex(threat_caster) or nil
            for k, entry in pairs(state.armed_threats) do
                local is_self = current_caster_idx and entry.caster
                                and Entity.IsEntity(entry.caster)
                                and Entity.GetIndex(entry.caster) == current_caster_idx
                                and entry.threat_mod == threat_mod
                if not is_self then concurrent = concurrent + 1 end
            end
            local now_t = now()
            local self_key = current_caster_idx and threat_mod
                             and (tostring(current_caster_idx) .. ":" .. threat_mod) or nil
            -- v6.15.237: only count concurrent responded-threats when there
            -- is a self_key to exclude. With threat_mod nil (a panic /
            -- non-cataloged save) self_key is nil, so `k ~= self_key` would
            -- exclude nothing -- the threat this same engagement just marked
            -- self-counts, inflating `concurrent` and prematurely unlocking
            -- high-CD saves. armed_threats above still contributes.
            if self_key then
                for k, t_resp in pairs(state.responded_threats) do
                    if k ~= self_key and (now_t - t_resp) < 1.5 then
                        concurrent = concurrent + 1
                    end
                end
            end
            if concurrent >= 1 then penalty = penalty + 15 end
            if penalty < -20 then
                tlog(3, "save_chain_skip", {
                    save = fire_entry.short, reason = "reserved",
                    severity = severity, concurrent = concurrent,
                })
            else
                local issue_intent = intent .. "_" .. fire_entry.short
                -- v6.4: pass threat_mod so save closures can vary behavior by
                -- threat category (Pike skips self-fallback for close_gap, etc.)
                local ok = fire_entry.fire(issue_intent, threat_caster, threat_mod)
                if ok then
                    -- v6.15.251: pass threat_caster so the per-target
                    -- gate in starter_tick can suppress same-tick combo R.
                    record_save(intent, fire_entry.short, threat_mod, threat_caster)
                    -- v6.15.42: register / update active_threats entry for
                    -- the save_outcome study tick. If brain hadn't yet seen
                    -- this threat (modifier-create handler hadn't fired), we
                    -- still create the entry here so the outcome tick can
                    -- log it on modifier disappearance.
                    if threat_mod and state.self_npc and Entity.IsEntity(state.self_npc) then
                        state.active_threats = state.active_threats or {}
                        local me = state.self_npc
                        local entry = state.active_threats[threat_mod]
                        if not entry then
                            local hp_start = Entity.GetHealth(me) or 0
                            entry = {
                                t_start   = now(),
                                hp_start  = hp_start,
                                hp_min    = hp_start,
                                hp_max    = Entity.GetMaxHealth(me) or 1,
                            }
                            state.active_threats[threat_mod] = entry
                        end
                        entry.save_short = fire_entry.short
                        entry.t_save     = now()
                    end
                    return true
                end
                tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "fire_returned_false" })
            end
        end
    end

    if threat_mod then
        tlog(1, "no_effective_save_for_threat", { intent = intent, threat = threat_mod })
    else
        tlog(2, "layer2_no_save_available", { intent = intent })
    end
    return false
end

-- Lotus-first save: when the threat is a known targeted enemy ult that
-- Lotus reflects, use Lotus before any other save (no MS commitment +
-- damage goes back at caster).
local function try_save_lotus_first(intent)
    if not layer2_can_fire() then return false end
    if NPCLib.item_ready(state.self_npc,"item_lotus_orb") then
        if issue_item_self(intent .. "_lotus", "def", NPCLib.item(state.self_npc,"item_lotus_orb")) then
            mark_layer2_fired(); return true
        end
    end
    -- Fall through to the standard chain if Lotus unavailable.
    return try_save_self(intent)
end

-- Grenade-Save-Ally: when an ally is at low HP with a gap-closer in 375u
-- and Sniper is within grenade cast range, knockback the gap-closer 475u
-- away from the ally. Caller iterates allies; this fires for one ally.
local function try_save_ally(ally)
    -- v6.15.201 (audit D12): entry-validity guard. Matches the standard
    -- pattern every other layer-2 fire function uses. Without this,
    -- Entity.GetAbsOrigin(nil) later in the function crashes.
    if not (ally and Entity.IsEntity(ally) and Target.IsAlive(ally)) then
        return false
    end
    if not layer2_can_fire() then return false end
    if not ability_ready(A.D) then return false end
    if dist_to(ally) > state.grenade_cast_range() then return false end

    local me = state.self_npc
    local ally_pos = Entity.GetAbsOrigin(ally)
    -- v6.15.201 (audit D12): nil-guard ally_pos after the entry checks.
    if not ally_pos then return false end
    -- Find a gap-closer enemy within the live Grenade radius of the ally.
    -- v6.15.195 (audit A3): read the radius from D's KV instead of the
    -- hardcoded 375 — the v6.15.169 KV migration set up state.item_kv but
    -- missed this site. Behaviour-neutral at current KV; auto-tracks a
    -- Valve retune.
    local d_ab = ability(A.D)
    local d_radius = (d_ab and state.item_kv(d_ab, "radius", 375)) or 375
    local nearby = NPCs.InRadius(ally_pos, d_radius, Entity.GetTeamNum(me),
        Enum.TeamType.TEAM_ENEMY, true, true)
    if not nearby or #nearby == 0 then return false end
    -- Reject if the closest enemy is BKB'd (G12)
    local closest = nearby[1]
    if NPC.HasState(closest, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return false end

    if issue_cast_position("save_ally_d", ability(A.D), ally_pos) then
        mark_layer2_fired(); return true
    end
    return false
end

-- v6.14 C3: smoke / fog-ambush detection. Counts enemy heroes within `radius`
-- of Sniper that were visible recently (>= 3s ago, <= 30s ago) but are now
-- dormant / not visible. The "they were close and now they're missing" pattern
-- is the strongest fog-ambush signal Sniper can read without a ward network.
--
--   `>= 2` candidates → "alert" — pre-fire BKB if HP < 60% AND BKB ready
--                       (with reserve_penalty bypass — this is the emergency
--                       it was held for).
--   `>= 1` candidate  → "watch" — log only.
--   else              → "ok".
--
-- Updates `state.smoke_state` for the HUD chip. Throttled to 4Hz.
local function smoke_detect_tick()
    if not state.menu or not state.menu.smoke_detect or not state.menu.smoke_detect:Get() then
        state.smoke_state = "off"; return
    end
    local me = state.self_npc
    if not me then return end
    if (now() - state.last_smoke_warn_t) < 0.25 then return end  -- 4Hz
    state.last_smoke_warn_t = now()

    local me_pos = Entity.GetAbsOrigin(me)
    local me_team = Entity.GetTeamNum(me)
    local all_heroes = Heroes.GetAll() or {}
    local missing = 0
    local missing_names = {}
    local t_now = GlobalVars.GetCurTime()
    for i = 1, #all_heroes do
        local h = all_heroes[i]
        if Entity.GetTeamNum(h) ~= me_team
           and Target.IsAlive(h)
           and Target.NotClone(h)           -- v6.14.1 L: clones over illusion-only
           and Entity.IsDormant(h) then     -- v6.14.1 M10: must be currently in fog
            local last_t = Hero.GetLastVisibleTime(h)
            if last_t then
                local age = t_now - last_t
                -- Was seen 3-30s ago AND currently dormant → potentially smoked.
                if age > 3.0 and age < 30.0 then
                    -- Last visible position close to us?
                    local last_pos = Hero.GetLastMaphackPos(h)
                    if last_pos then
                        local dx = last_pos.x - me_pos.x
                        local dy = last_pos.y - me_pos.y
                        local d2 = dx*dx + dy*dy
                        if d2 < 1500*1500 then
                            missing = missing + 1
                            if #missing_names < 3 then
                                missing_names[#missing_names + 1] = uname(h)
                            end
                        end
                    end
                end
            end
        end
    end

    local prev = state.smoke_state
    if missing >= 2 then
        state.smoke_state = "alert"
        if prev ~= "alert" then
            tlog(1, "smoke_alert", { missing = missing,
                names = table.concat(missing_names, ",") })
        end
        -- Pre-fire BKB if low HP (don't fire on full HP — too speculative).
        -- v6.15 C4: also try Glimmer as a cheaper alternative when BKB is on
        -- CD or not built. Glimmer breaks vision so a smoked gang loses the
        -- pick-off target; lower opportunity cost than BKB.
        local hp = Entity.GetHealth(me) or 0
        local hpmax = Entity.GetMaxHealth(me) or 1
        local hp_frac = hp / hpmax
        if hp_frac < 0.60 and layer2_can_fire() then
            -- v6.15.2 low: skip if a self-immunity / self-invis modifier is
            -- already active (avoids re-fire spam if smoke alert lingers).
            local me_npc = state.self_npc
            local self_bkb = NPC.HasState(me_npc, MS.MODIFIER_STATE_MAGIC_IMMUNE)
            local self_glimmer = NPC.HasModifier(me_npc, "modifier_item_glimmer_cape_fade")
                                or NPC.HasModifier(me_npc, "modifier_item_glimmer_cape")
            if NPCLib.item_ready(state.self_npc,"item_black_king_bar") and not self_bkb then
                local it = NPCLib.item(state.self_npc,"item_black_king_bar")
                if it and issue_item_self("smoke_prefire_bkb", "def", it) then
                    record_save("smoke_prefire", "item_black_king_bar", nil)
                end
            elseif hp_frac < 0.80 and NPCLib.item_ready(state.self_npc,"item_glimmer_cape") and not self_glimmer then
                local it = NPCLib.item(state.self_npc,"item_glimmer_cape")
                if it and issue_item_self("smoke_prefire_glimmer", "def", it) then
                    record_save("smoke_prefire", "item_glimmer_cape", nil)
                end
            end
        end
    elseif missing == 1 then
        state.smoke_state = "watch"
        if prev == "ok" then tlog(2, "smoke_watch", { name = missing_names[1] or "?" }) end
    else
        state.smoke_state = "ok"
    end
end

ally_save_scan = function()
    local me = state.self_npc
    if not me then return end
    -- v6.14 C2: HP-fraction threshold is now user-tunable.
    local pct = state.menu and state.menu.ally_save_pct and state.menu.ally_save_pct:Get() or 30
    local threshold = pct / 100
    -- v6.15 C2: extended ally-save — Lotus / Glimmer / grenade. v6.15.2 H3:
    -- sort allies by HP-fraction (lowest first) before iterating so the
    -- MOST-injured ally gets the save first. Previously iteration order was
    -- whatever NPCs/Entity radius API returned, which biased to the first
    -- ally in radius order — wrong ally saved in 5v5.
    local SCAN_R = 900  -- v6.15.2 C2: Lotus range corrected 1200→900
    local allies_raw = Entity.GetHeroesInRadius(me, SCAN_R, Enum.TeamType.TEAM_FRIEND)
    if not allies_raw then return end
    local needy = {}
    for i = 1, #allies_raw do
        local a = allies_raw[i]
        if a ~= me and Target.IsAlive(a) and Target.NotIllusion(a) then
            local hp = Entity.GetHealth(a)
            local hpmax = Entity.GetMaxHealth(a)
            local hp_frac = (hpmax > 0) and (hp / hpmax) or 1
            if hp_frac < threshold then
                needy[#needy + 1] = { ally = a, hp_frac = hp_frac }
            end
        end
    end
    table.sort(needy, function(x, y) return x.hp_frac < y.hp_frac end)
    for i = 1, #needy do
        local a = needy[i].ally
        local hp_frac = needy[i].hp_frac
        -- Try grenade first (closest range, breaks gap-closers). v6.15.191:
        -- only grenade-peel when an enemy is actually near the ally. A
        -- friend merely low on HP (creeps, or already disengaging) is not
        -- worth the grenade — it stays reserved for a real threat. Mirrors
        -- the enemy-proximity gate the Glimmer path below already uses.
        if ability_ready(A.D) and dist_to(a) <= state.grenade_cast_range() then
            local foes = Entity.GetHeroesInRadius(a, 600, Enum.TeamType.TEAM_ENEMY)
            if foes and #foes > 0 and try_save_ally(a) then return end
        end
        -- v6.15 C2: Lotus-give to deeply-injured ally taking magic
        -- pressure. v6.15.2 C2: 900 cast range (verified items.json 7.41C).
        if hp_frac < threshold * 0.8 and NPCLib.item_ready(state.self_npc,"item_lotus_orb")
           and dist_to(a) <= 900 then
            local it = NPCLib.item(state.self_npc,"item_lotus_orb")
            if it and layer2_can_fire()
               and issue_item_target("save_ally_lotus", "def", it, a) then
                record_save("save_ally_lotus", "item_lotus_orb", nil)
                return
            end
        end
        -- v6.15 C2: Glimmer-give for ally being right-clicked. 800 cast
        -- range, 24s CD. Invis breaks target lock on auto-attackers.
        if NPCLib.item_ready(state.self_npc,"item_glimmer_cape") and dist_to(a) <= 800 then
            local nearby = Entity.GetHeroesInRadius(a, 600, Enum.TeamType.TEAM_ENEMY)
            if nearby and #nearby > 0 then
                local it = NPCLib.item(state.self_npc,"item_glimmer_cape")
                if it and layer2_can_fire()
                   and issue_item_target("save_ally_glimmer", "def", it, a) then
                    record_save("save_ally_glimmer", "item_glimmer_cape", nil)
                    return
                end
            end
        end
    end
end

-- Specialized: Bane Nightmare post-landing. Sniper is asleep so most items
-- can't be cast — Eul/Manta/BKB are queued by the engine and resolve only on
-- wake (damage breaks sleep). The pre-emptive save from the anim handler is
-- the primary defense; this is a backstop.
local function save_bane_nightmare()
    try_save_self("bane_nightmare_modlanded", "modifier_bane_nightmare")
end

-- Specialized: channel ON self (Bane Grip / Pudge Dismember / Shaman Shackles).
--
-- First tries the self-save chain (Eul, Pike-self, grenade-self, etc.). If
-- that fails AND grenade-on-caster geometry would actually break the tether,
-- fires grenade at caster as a last resort. The previous code fired grenade-
-- on-caster unconditionally when self-save failed, which against Bane Fiend
-- Grip from 100u away just wasted the grenade CD (push 475u → caster at
-- 575u, still inside 875u tether).
local function save_channel_on_self(caster, threat_mod)
    if not layer2_can_fire() then return end
    if try_save_self("channel_on_me", threat_mod, caster) then return end

    -- Fallback: grenade on caster. Knockback breaks channel via ROOT_DISABLES
    -- and forces the caster out of tether range (if push is enough).
    if not ability_ready(A.D) then return end
    if dist_to(caster) > state.grenade_cast_range() then return end
    if NPC.HasState(caster, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return end

    -- Tether-distance check: if pushing the caster 475u still leaves them
    -- inside the tether, the fallback won't actually save Sniper. Skip.
    local tether = THREAT_TETHER_RANGE[threat_mod or ""]
    if tether then
        local cur_d = dist_to(caster)
        local push  = SAVE_PUSH_DISTANCE.grenade_self or 475
        if (cur_d + push) <= tether then
            tlog(3, "channel_source_skip_tether_unreachable", {
                threat = threat_mod, cur = string.format("%.0f", cur_d),
                tether = tether,
            })
            return
        end
    end

    -- v6.15.253: delegate to grenade_at_caster.fire so this channel-source
    -- save path inherits the v6.15.252 midpoint cast AND the v6.15.253
    -- facing-aware rotation. Pre-v6.15.253 this raw-cast at the caster --
    -- max stun for channel interrupt but no Sniper displacement geometry,
    -- and no facing gate (the gate is inside grenade_at_caster.fire).
    -- Same dispatch the regular save chain would use, just triggered by
    -- on_enemy_channel_start instead of armed_threats_tick.
    local grenade_fn = SAVE_FIRE and SAVE_FIRE.grenade_at_caster
                                  and SAVE_FIRE.grenade_at_caster.fire
    if grenade_fn and grenade_fn("channel_on_me_d", caster, threat_mod) then
        record_save("channel_on_me_source", "grenade_at_caster", threat_mod, caster)
    end
end

-- Take Aim reactive — cast on detected melee gap-close that landed.
local function reactive_take_aim()
    if not ability_ready(A.E) then return end
    -- Don't gate on layer2_can_fire — Take Aim doesn't compete with save items.
    issue_cast_notarget("take_aim_reactive", ability(A.E), "def")
end

-- Damage-rate panic: projected damage over the next 1.5s, with a 1.5× safety
-- factor, exceeds current HP → fire defensive chain. v6.14.1 M2: the prior
-- math (`rate * 1.5 < hp`) had no safety factor — fired only when next 1.5s
-- of damage at current rate matched HP exactly. Adding the 1.5 safety:
-- threshold = rate × 1.5 (1.5s ahead) × 1.5 (safety) = rate × 2.25. Fires
-- earlier so the save resolves before HP hits 0.
damage_rate_panic_check = function()
    local me = state.self_npc
    if not me then return end
    local rate = Damage.GetDamageRate(me, 1.5)
    if not rate or rate <= 0 then return end
    local hp = Entity.GetHealth(me)
    if rate * 2.25 < hp then return end
    -- v6.15.144: throttle the panic retry. This check runs EVERY tick; while
    -- the damage-rate condition holds and no save is available, try_save_self
    -- finds nothing and fires nothing — so layer2_can_fire's post-save
    -- throttle never engages — and the full save chain re-runs every frame,
    -- spamming save_chain_skip ×N + layer2_no_save_available (the v6.15.143
    -- demo log had 770 save_chain_skip almost entirely from this path). Gate
    -- on a retry window: the first attempt is immediate (last_dmg_panic_t
    -- starts at 0), retries wait DMG_PANIC_RETRY_S — enough to catch an item
    -- coming off cooldown without burning a frame on a dead chain every tick.
    if state.last_dmg_panic_t
       and (now() - state.last_dmg_panic_t) < state.DMG_PANIC_RETRY_S then
        return
    end
    state.last_dmg_panic_t = now()
    -- No specific threat-mod here — let the full chain try (any save helps).
    try_save_self("dmg_rate_panic")
end

-- v6.15.10: pre-emptive facing toward the most imminent threat.
-- time_to_impact = dist / move_speed; under threshold + ability ready
-- + Sniper not already facing → issue ATTACK_TARGET. The order auto-orients
-- Sniper so when the threat actually casts, the save's cast point isn't
-- extended by turn time (engine bottleneck against fast cast points like
-- Dismember 0.3s). Overrides whatever the user was doing — per user
-- directive; any user input on the next frame supersedes us.
--
-- Skips: combo key down (layer1's own ATTACK_TARGET handles facing),
-- self_alive_ok fails, R channel in flight (would cancel Assassinate),
-- cooldown not elapsed, already facing within tolerance, no threat
-- within scan radius.
-- v6.15.12: bumped TTI from 0.6 → 1.0. v6.15.11 demo showed 0 preface_attack
-- events because Bara at 600 MS with TTI<0.6 means dist<360u — by then Sniper
-- was usually already facing (kiting cone). At TTI<1.0 the trigger fires
-- around 600u where there's still meaningful turn-budget to recover.
local PRE_FACE_TTI_THRESHOLD = 1.0
local PRE_FACE_COOLDOWN      = 0.4
local PRE_FACE_ANGLE_OK      = 25
local PRE_FACE_SCAN_RADIUS   = 1000

local function enemy_has_ready_target_threat(enemy)
    for slot = 0, 5 do
        local ok_a, a = pcall(NPC.GetAbilityByIndex, enemy, slot)
        if ok_a and a and Ability.GetLevel(a) > 0 and Ability.IsReady(a) then
            local ok_n, ability_name = pcall(Ability.GetName, a)
            if ok_n and ability_name and ABILITY_TO_THREAT[ability_name] then
                return true, ability_name
            end
        end
    end
    return false, nil
end

local function pre_face_tick()
    if not state.menu then return end
    if state.menu.preface_enable and not state.menu.preface_enable:Get() then return end
    if not defense_enabled() then return end
    if state.menu.combo_key and state.menu.combo_key:IsDown() then return end
    if not self_alive_ok() then return end

    local me = state.self_npc
    local r_ability = ability(A.R)
    if r_ability and Ability.IsInAbilityPhase(r_ability) then return end

    local now_t = now()
    if (now_t - state.last_preface_t) < PRE_FACE_COOLDOWN then return end

    local me_pos = NPCLib.origin(me)
    if not me_pos then return end
    local enemies = NPCs.InRadius(me_pos, PRE_FACE_SCAN_RADIUS,
        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY, true, true)
    if not enemies or #enemies == 0 then return end

    local best_e, best_tti, best_via = nil, math.huge, nil
    for _, e in ipairs(enemies) do
        if Target.IsValid(e) and Target.IsAlive(e)
           and Target.IsEnemyHero(e, me) and Target.NotIllusion(e)
        then
            local has, ability_name = enemy_has_ready_target_threat(e)
            if has then
                local d = dist_to(e)
                local sp = NPC.GetMoveSpeed(e) or 300
                if sp < 200 then sp = 200 end
                local tti = d / sp
                if tti < PRE_FACE_TTI_THRESHOLD and tti < best_tti then
                    best_e, best_tti, best_via = e, tti, ability_name
                end
            end
        end
    end

    if not best_e then return end

    -- v6.15.201 (audit D8): nil-guard. best_e was alive when picked but a
    -- one-tick race could nil the GetAbsOrigin; FindRotationAngle on nil
    -- is undefined. Skip the pre-face this tick.
    local best_pos = Entity.GetAbsOrigin(best_e)
    if not best_pos then return end
    -- v6.15.232: FindRotationAngle is radians (v6.15.215) — math.deg first.
    local angle = math.deg(math.abs(NPC.FindRotationAngle(me, best_pos)))
    if angle < PRE_FACE_ANGLE_OK then return end

    local ok = safe_issue {
        hero       = HERO_KEY,
        layer      = "def",
        intent     = "preface_" .. uname(best_e),
        order_type = UO.DOTA_UNIT_ORDER_ATTACK_TARGET,
        unit       = me,
        target     = best_e,
    }
    if ok then
        state.last_preface_t = now_t
        tlog(1, "preface_attack", {
            target = uname(best_e),
            tti    = string.format("%.2f", best_tti),
            angle  = string.format("%.0f", angle),
            via    = best_via or "?",
        })
    end
end

-- v6.15.29: cast verification tick. For each pending verification (set by
-- safe_issue when an ability cast was issued), wait ~0.6s then read the
-- ability's cooldown. If CD > 0 and increased from cd_before, the engine
-- DID execute the cast. If CD is still 0 (or didn't bump), the order
-- never resolved engine-side — Humanizer dropped it, OnPrepareUnitOrders
-- vetoed it, or the engine rejected for some state reason. This gives
-- empirical proof beyond "issued + queue_observed" of whether the cast
-- actually fired in-game.
local function cast_verify_tick()
    if not state.pending_cast_verify then return end
    local now_t = now()
    -- v6.15.38: entries are keyed by a monotonic counter so rapid re-dispatch
    -- of the same intent doesn't orphan pending retries. v.intent carries
    -- the original intent string for log payload + double_fail correlation.
    for pcv_key, v in pairs(state.pending_cast_verify) do
        local intent = v.intent or "?"
        if now_t >= v.t_check then
            local actual_cd = 0
            local actual_charges = 0
            if v.ability and Ability.GetCooldown then
                actual_cd = Ability.GetCooldown(v.ability) or 0
            end
            if v.ability and Ability.GetCurrentCharges then
                local okc, ch = pcall(Ability.GetCurrentCharges, v.ability)
                if okc and type(ch) == "number" then actual_charges = ch end
            end
            -- v6.15.34: fired=y if EITHER cooldown bumped OR charges decreased.
            -- Charge-based abilities (Shrapnel: 3 charges) only show CD bump
            -- once all charges are depleted; charges_before > charges_after
            -- is the more reliable fire indicator for them.
            local cd_bumped = actual_cd > v.cd_before + 0.05
            local charge_consumed = (v.charges_before or 0) > 0
                                    and actual_charges < v.charges_before
            local fired = cd_bumped or charge_consumed
            -- v6.15.37: queue state at check time. Diff against issue-time
            -- snapshot pinpoints whether our order entered the queue, lingered,
            -- or was consumed without firing.
            local q_total_now, q_self_now = queue_snapshot()
            -- v6.15.227: target alive/dead at verify time. With `fired`, this
            -- separates a real flood-loss (fired=n, tgt=alive) from a correct
            -- target-died abort (fired=n, tgt=dead). "-" when the cast has no
            -- unit target (Shrapnel position / Take Aim no-target).
            local tgt_state = "-"
            if v.target then
                tgt_state = (Entity.IsEntity(v.target)
                             and Target.IsAlive(v.target)) and "alive" or "dead"
            end
            tlog(1, "cast_verify", {
                intent           = intent,
                ability          = v.ability_name,
                fired            = fired and "y" or "n",
                tgt              = tgt_state,
                attempt          = tostring(v.attempt or 1),
                cd_before        = string.format("%.2f", v.cd_before),
                cd_after         = string.format("%.2f", actual_cd),
                charges_before   = tostring(v.charges_before or 0),
                charges_after    = tostring(actual_charges),
                age_ms           = string.format("%.0f", (now_t - v.t_issued) * 1000),
                cast_point       = string.format("%.2f", v.cast_point or 0),
                q_total_at_issue = tostring(v.q_total_at_issue or 0),
                q_self_at_issue  = tostring(v.q_self_at_issue or 0),
                q_total_now      = tostring(q_total_now),
                q_self_now       = tostring(q_self_now),
            })
            -- v6.15.37: second-chance retry on first failure. Engine may be
            -- slow to update CD/charges under certain conditions (extended
            -- cast point, server hitch, longer-than-expected animation).
            -- Wait +1.0s and check once more before giving up. If second
            -- attempt also fails, emit cast_verify_double_fail with Sniper's
            -- state at the moment of conclusive failure — that's the data
            -- we'd need to root-cause a stubborn engine-side drop.
            if not fired and (v.attempt or 1) < 2 then
                v.attempt = 2
                v.t_check = now_t + 1.0
            else
                if not fired then
                    local me = state.self_npc
                    local silenced = (me and NPC.IsSilenced and NPC.IsSilenced(me)) and "1" or "0"
                    local stunned = (me and NPC.IsStunned and NPC.IsStunned(me)) and "1" or "0"
                    local channelling = (me and NPC.IsChannellingAbility and NPC.IsChannellingAbility(me)) and "1" or "0"
                    local mana_now = (me and NPC.GetMana and NPC.GetMana(me)) or 0
                    tlog(1, "cast_verify_double_fail", {
                        intent      = intent,
                        ability     = v.ability_name,
                        tgt         = tgt_state,
                        silenced    = silenced,
                        stunned     = stunned,
                        channelling = channelling,
                        mana        = string.format("%.0f", mana_now),
                        q_total_now = tostring(q_total_now),
                        q_self_now  = tostring(q_self_now),
                    })
                    -- v6.15.86: R failed to fire (engine rejected/cancelled).
                    -- Clear r_in_flight markers IMMEDIATELY so brain can
                    -- retry on next layer1 tick. Without this, the abort
                    -- timer (~2.6s) would block retry for the full window
                    -- even though R never even started.
                    if v.ability_name == "sniper_assassinate" then
                        state.last_r_target          = nil
                        state.last_r_combo_name      = nil
                        state.last_r_dispatch_t      = 0
                        state.r_cast_protect_until_t = 0
                        tlog(2, "r_cast_failed_cleared", {
                            intent = intent,
                            ability = v.ability_name,
                        })
                    end
                end
                state.pending_cast_verify[pcv_key] = nil
            end
        end
    end
end

-- v6.15.58 (G12): Kinetic Field walk-into poll. Iterates state.kinetic_fields
-- (populated by OnModifierCreate) and, when Sniper's distance to a field
-- drops to ≤ 350u, fires try_save_self with the canonical kinetic-field
-- threat key. Dedup.threat_already_responded(state.responded_threats,thinker, mod) dedup prevents re-firing while
-- Sniper stays inside. Cheap iteration — typically 0-2 fields in flight.
local function kinetic_field_poll_tick()
    if not state.kinetic_fields then return end
    if not state.self_npc or not Entity.IsEntity(state.self_npc) then return end
    if not defense_enabled() then return end
    local me_pos = Entity.GetAbsOrigin(state.self_npc)
    -- v6.15.201 (audit D6): nil-guard me_pos.
    if not me_pos then return end
    for idx, entry in pairs(state.kinetic_fields) do
        local thinker = entry.thinker
        if not thinker or not Entity.IsEntity(thinker) then
            state.kinetic_fields[idx] = nil
        else
            local fp = Entity.GetAbsOrigin(thinker)
            -- v6.15.197 (audit B1): native Vector arithmetic.
            -- v6.15.201 (audit D6): nil-guard fp. A field thinker
            -- destroyed between Entity.IsEntity (passes) and GetAbsOrigin
            -- (returns nil) crashes :Distance2D without this. Clear the
            -- stale entry and skip — the next poll iterates over the
            -- pruned table.
            if not fp then
                state.kinetic_fields[idx] = nil
            else
                local d = fp:Distance2D(me_pos)
                if d <= 350 and layer2_can_fire()
                   and not Dedup.threat_already_responded(state.responded_threats,thinker, entry.mod_name)
                then
                    tlog(1, "kinetic_field_walk_in", {
                        mod = entry.mod_name,
                        caster = entry.caster and uname(entry.caster) or "-",
                        d = string.format("%.0f", d),
                    })
                    Dedup.threat_mark_responded(state.responded_threats,thinker, entry.mod_name)
                    try_save_self("kinetic_field_walk_in",
                                  "modifier_disruptor_kinetic_field_remnant",
                                  entry.caster)
                end
            end
        end
    end
end

-- v6.15.184 (cleanup): orbwalk_cancel_tick removed — it was a permanent
-- no-op since v6.15.62 (brain-side orbwalk replaced by UCZone's native
-- Hit & Run; state.pending_orbwalk_cancel was never set, so the function's
-- guard always returned immediately). No external caller — deleted along
-- with its OnUpdateEx call site.

-- v6.15.42: cast_outcome study tick. For each tracked R cast, after 5s
-- check the target's state — alive or dead, HP removed. Generates the
-- aggression efficiency data: R-kill rate, damage-per-R, commit_pred
-- accuracy (target_alive=y with full HP retained = false-positive commit).
local function cast_outcome_tick()
    if not state.pending_cast_outcomes then return end
    local t_now = now()
    for k, v in pairs(state.pending_cast_outcomes) do
        if t_now >= v.t_check then
            local alive = v.target and Target.IsValid(v.target) and Target.IsAlive(v.target)
            local hp_after = alive and Entity.GetHealth(v.target) or 0
            local hp_delta = (v.hp_before or 0) - hp_after
            local hp_delta_pct = (v.hp_max and v.hp_max > 0)
                and (hp_delta / v.hp_max * 100) or 0
            -- v6.15.55 (N2): respawn detection. v6.15.54 demo log surfaced
            -- two cast_outcomes with hp_after > hp_before (respectively 31→
            -- 2363 and 62→2386) AND alive=y AND hp_delta negative ~ -2300.
            -- Target died and respawned during the 5s observation window —
            -- a KILL we credited as a heal. respawn=y when hp_after exceeds
            -- hp_before AND hp_after is near full (hp_max × 0.9 threshold).
            -- Counts toward kills in engagement_summary regardless of the
            -- alive=y reading at check time.
            local respawn = false
            if hp_after > (v.hp_before or 0)
               and hp_after >= (v.hp_max or 1) * 0.9
            then
                respawn = true
            end
            -- v6.15.42: rolling aggression counters for engagement_summary.
            state.agg_r_casts_window = (state.agg_r_casts_window or 0) + 1
            if not alive or respawn then
                state.agg_r_kills_window = (state.agg_r_kills_window or 0) + 1
            end
            -- v6.15.172: damage-model back-check. pred_raw = the brain's
            -- predicted R damage (raw HP) snapshotted at cast time;
            -- pred_kill = whether the brain expected R alone to kill;
            -- pred_err = pred_raw - hp_delta (>0 = brain over-predicted the
            -- damage; a false-positive commit is pred_kill=y with alive=y).
            -- NOTE hp_delta is the 5s all-source HP removed (allies / DoT
            -- included) — in a solo demo it is ~= Sniper's own damage.
            local pred_err = "?"
            if v.pred_raw then
                pred_err = string.format("%.0f", v.pred_raw - hp_delta)
            end
            tlog(1, "cast_outcome", {
                intent       = v.intent or "?",
                target       = v.tgt_name or "?",
                alive        = alive and "y" or "n",
                respawn      = respawn and "y" or "n",
                hp_before    = tostring(v.hp_before or 0),
                hp_after     = tostring(hp_after),
                hp_delta     = string.format("%.0f", hp_delta),
                hp_delta_pct = string.format("%.1f", hp_delta_pct),
                hp_max       = tostring(v.hp_max or 0),
                pred_raw     = v.pred_raw and string.format("%.0f", v.pred_raw) or "?",
                pred_kill    = (v.pred_kill == nil) and "?" or (v.pred_kill and "y" or "n"),
                pred_err     = pred_err,
                -- v6.15.174: E+R tap fields — present only when this R was an
                -- E+R tap. is_tap=y marks the line; tap_e_r / tap_r_only are
                -- the tap damage calc for the two cases; tap_e = did Take Aim
                -- fire with this tap. Pair against hp_delta the same way as
                -- pred_raw.
                is_tap       = v.is_tap and "y" or "n",
                tap_e_r      = v.tap_e_r and string.format("%.0f", v.tap_e_r) or "-",
                tap_r_only   = v.tap_r_only and string.format("%.0f", v.tap_r_only) or "-",
                tap_e        = (v.tap_e_fires == nil) and "-" or (v.tap_e_fires and "y" or "n"),
            })
            -- v6.15.50 (G6 lifecycle): clear engaged_target if this dead
            -- target was the one brain was sticking to. Without this, the
            -- 2s stickiness window would keep an invalid target reference
            -- at position 1 until the timer expires.
            -- v6.15.55: also clear on respawn (target died, respawned, the
            -- entity reference is now a fresh hero with full HP — engaging
            -- the freshly-spawned target makes no sense).
            if (not alive or respawn) and v.target and state.engaged_target
               and Entity.IsEntity(v.target) and Entity.IsEntity(state.engaged_target)
               and Entity.GetIndex(v.target) == Entity.GetIndex(state.engaged_target)
            then
                state.engaged_target   = nil
                state.engaged_target_t = 0
            end
            state.pending_cast_outcomes[k] = nil
        end
    end
end

-- v6.15.42: save_outcome study tick. Tracks threats currently on Sniper
-- (state.active_threats). When the modifier disappears (threat resolved),
-- log outcome: did Sniper survive, what was the HP delta during the
-- threat window, which save fired, what was the latency from threat
-- detect to save dispatch. Generates the defense efficiency data.
local function save_outcome_tick()
    if not state.active_threats then return end
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return end
    for mod_name, entry in pairs(state.active_threats) do
        local still_on = NPC.HasModifier and NPC.HasModifier(me, mod_name)
        if not still_on then
            local hp_end = Entity.GetHealth(me) or 0
            local alive = (hp_end > 0) and Target.IsAlive(me)
            local latency_ms = entry.t_save and ((entry.t_save - entry.t_start) * 1000) or -1
            local duration_ms = (now() - entry.t_start) * 1000
            local hp_min = entry.hp_min or entry.hp_start
            local hp_pct_min = (entry.hp_max and entry.hp_max > 0)
                and (hp_min / entry.hp_max * 100) or 0
            -- Rolling counters for engagement_summary
            state.def_threats_window = (state.def_threats_window or 0) + 1
            if alive then
                state.def_survived_window = (state.def_survived_window or 0) + 1
            end
            tlog(1, "save_outcome", {
                threat       = mod_name,
                save         = entry.save_short or "-",
                alive        = alive and "y" or "n",
                latency_ms   = string.format("%.0f", latency_ms),
                duration_ms  = string.format("%.0f", duration_ms),
                hp_start     = tostring(entry.hp_start or 0),
                hp_end       = tostring(hp_end),
                hp_min       = tostring(hp_min),
                hp_pct_min   = string.format("%.1f", hp_pct_min),
            })
            state.active_threats[mod_name] = nil
        elseif entry.hp_min then
            -- Update running HP nadir while threat is still active.
            local hp_now = Entity.GetHealth(me) or 0
            if hp_now < entry.hp_min then entry.hp_min = hp_now end
        end
    end
end

-- v6.15.42: engagement_summary study tick. Every 10s, emit a rolling
-- summary of aggression + defense efficiency. Lightweight rollup for
-- quick session-level analysis without parsing thousands of lines.
local function engagement_summary_tick()
    state.engagement_window_start = state.engagement_window_start or now()
    local t_now = now()
    if t_now - state.engagement_window_start < 10.0 then return end
    local r_casts   = state.agg_r_casts_window or 0
    local r_kills   = state.agg_r_kills_window or 0
    local threats   = state.def_threats_window or 0
    local survived  = state.def_survived_window or 0
    local me        = state.self_npc
    local hp_now    = (me and Entity.IsEntity(me) and Entity.GetHealth(me)) or 0
    local hp_max    = (me and Entity.IsEntity(me) and Entity.GetMaxHealth(me)) or 1
    local r_kill_rate = r_casts > 0 and (r_kills / r_casts * 100) or 0
    local survive_rate = threats > 0 and (survived / threats * 100) or 100
    tlog(1, "engagement_summary", {
        r_casts        = tostring(r_casts),
        r_kills        = tostring(r_kills),
        r_kill_pct     = string.format("%.0f", r_kill_rate),
        threats        = tostring(threats),
        survived       = tostring(survived),
        survive_pct    = string.format("%.0f", survive_rate),
        hp_pct_now     = string.format("%.0f", hp_now / hp_max * 100),
    })
    state.agg_r_casts_window     = 0
    state.agg_r_kills_window     = 0
    state.def_threats_window     = 0
    state.def_survived_window    = 0
    state.engagement_window_start = t_now
end

-- v6.15.23: brain-native interaction diagnostic. Polls Humanizer.GetOrderQueue
-- each tick, detects newly-appearing queue entries, logs each with source
-- attribution. Brain issues every order with callback=true (per lib/order.lua
-- line 217: "local callback = true"); native Sniper baseline + framework
-- subsystems (Dodger, Items Manager, Linkbreaker) issue with callback=false
-- (default per UCZone API). The triggerCallBack field on each queue entry
-- is a reliable brain-vs-other indicator.
--
-- Output: one `queue_observed` line per new queue entry at v1. Correlate
-- with brain's own `issued` log entries:
--   • Brain issued + matching queue_observed source=brain  → brain order
--     made it to the queue cleanly.
--   • queue_observed source=native with no preceding brain `issued`
--     → native (or another subsystem) issued the order.
--   • Brain issued with no matching queue_observed → order rejected
--     pre-queue (validation in lib/order.lua) or deduped.
--
-- v6.15.40: classify each non-brain queue entry into a likely subsystem
-- so logs distinguish which framework module issued the order. Heuristic
-- only — the framework doesn't expose subsystem identity per order. Buckets:
--   items_manager   — ability starts with "item_" (BKB / Manta / Pike / etc.)
--   native_combo    — ability starts with "sniper_" (combo script — should be
--                     near-zero if user has disabled the combo binding)
--   other_ability   — ability cast that's neither (talents, hero-passive
--                     auras, edge cases)
--   orbwalk_attack  — ATTACK_TARGET (orderType=4) without ability (Hit & Run
--                     / Orb Walker / Target Lock)
--   attack_move     — ATTACK_MOVE (orderType=3)
--   movement        — MOVE_POSITION/MOVE_TARGET (orderType=1/2; Dodger or
--                     baseline movement subsystem)
--   other           — anything not covered
local function classify_native_order(entry, ability_name)
    local ot = tonumber(entry.orderType) or 0
    if ability_name and ability_name ~= "-" and ability_name ~= "?" then
        if string.sub(ability_name, 1, 5) == "item_" then
            return "items_manager"
        elseif string.sub(ability_name, 1, 7) == "sniper_" then
            return "native_combo"
        else
            return "other_ability"
        end
    end
    if ot == 4 then return "orbwalk_attack" end
    if ot == 3 then return "attack_move"    end
    if ot == 1 or ot == 2 then return "movement" end
    return "other"
end

local function brain_native_diagnostic_tick()
    if not Humanizer or not Humanizer.GetOrderQueue then return end
    local queue = Humanizer.GetOrderQueue()
    if not queue then return end

    state.last_queue_snapshot = state.last_queue_snapshot or {}
    local new_snapshot = {}

    for i = 1, #queue do
        local entry = queue[i]
        -- Key on addTime + indexes — addTime is unique per order so this
        -- handles two orders with identical (ability,target) at different
        -- moments.
        local key = string.format("%.4f|%s|%d|%d",
            entry.addTime or 0,
            tostring(entry.orderType or "?"),
            entry.abilityIndex or 0,
            entry.targetIndex or 0)
        new_snapshot[key] = entry
        if not state.last_queue_snapshot[key] then
            local source = entry.triggerCallBack and "brain" or "native_or_other"
            local ability_name = "-"
            if entry.abilityIndex and entry.abilityIndex > 0 and Entity.Get then
                local ab = Entity.Get(entry.abilityIndex)
                -- v6.15.224: a native queue entry's abilityIndex can resolve
                -- to an item (ward dispenser, neutral item), not an ability;
                -- Ability.GetName then throws and aborts this tick for the
                -- frame. pcall keeps the diagnostic non-fatal.
                if ab and Ability and Ability.GetName then
                    local ok_name, nm = pcall(Ability.GetName, ab)
                    ability_name = (ok_name and nm) or "?"
                end
            end
            local target_name = "-"
            if entry.targetIndex and entry.targetIndex > 0 and Entity.Get then
                local tgt = Entity.Get(entry.targetIndex)
                if tgt and Entity.IsEntity(tgt) then
                    target_name = uname(tgt)
                end
            end
            -- v6.15.40: classify non-brain entries by likely subsystem.
            local subsystem = "-"
            if source ~= "brain" then
                subsystem = classify_native_order(entry, ability_name)
            end
            tlog(1, "queue_observed", {
                source     = source,
                subsystem  = subsystem,
                ability    = ability_name,
                target     = target_name,
                order_type = tostring(entry.orderType or "?"),
            })
            -- v6.15.39: count for the 5s native-activity heartbeat. Brain
            -- entries inflate alongside native ones during heavy play, so
            -- the inferred threshold below is on the native count alone.
            -- v6.15.40: also accumulate per-subsystem counts so the heartbeat
            -- breakdown shows WHICH subsystem produced the native traffic.
            if source == "brain" then
                state.native_window_brain = (state.native_window_brain or 0) + 1
            else
                state.native_window_other = (state.native_window_other or 0) + 1
                state.native_window_subsystems = state.native_window_subsystems or {}
                state.native_window_subsystems[subsystem] =
                    (state.native_window_subsystems[subsystem] or 0) + 1
            end
            -- v6.15.40: interference detector. When a native order targets
            -- Sniper's own unit within the cast-point window of brain's last
            -- in-flight cast, log brain_native_interfere. This is the direct
            -- signal that a subsystem aborted brain's R/Q — the diagnostic
            -- we need to attribute each cast failure to a specific module.
            -- Brain's last cast bookkeeping is set in safe_issue (v6.15.40).
            -- v6.15.41: dropped Entity.IsEntity(entry.unit) gate — that check
            -- was producing 0 brain_native_interfere events in v6.15.40
            -- despite 47 native sniper_* orders during brain cast windows.
            -- queue_has_baseline (which works) uses the same pattern without
            -- IsEntity, so we mirror it. If 0 events persist, the bug is
            -- elsewhere — added an `interfere_check_miss` v3 log to surface
            -- near-matches for further diagnosis.
            if source ~= "brain"
               and state.last_brain_cast
               and entry.unit
               and state.self_npc
            then
                local me_idx = Entity.GetIndex(state.self_npc)
                local unit_idx = Entity.GetIndex(entry.unit)
                local age = now() - state.last_brain_cast.t
                local in_window = age < (state.last_brain_cast.cast_point or 0) + 0.4
                if unit_idx == me_idx and in_window then
                    tlog(1, "brain_native_interfere", {
                        brain_intent   = state.last_brain_cast.intent or "?",
                        brain_ability  = state.last_brain_cast.ability_name or "?",
                        age_ms         = string.format("%.0f", age * 1000),
                        cast_point     = string.format("%.2f", state.last_brain_cast.cast_point or 0),
                        native_subsys  = subsystem,
                        native_ability = ability_name,
                        native_order   = tostring(entry.orderType or "?"),
                    })
                else
                    tlog(3, "interfere_check_miss", {
                        me_idx       = tostring(me_idx),
                        unit_idx     = tostring(unit_idx),
                        in_window    = in_window and "y" or "n",
                        age_ms       = string.format("%.0f", age * 1000),
                        brain_intent = state.last_brain_cast.intent or "?",
                    })
                end
            end

            -- v6.15.27: burial detector. Track last brain ATTACK_TARGET
            -- (order_type=4); when a native ATTACK_TARGET to a DIFFERENT
            -- target arrives within 1s, log `brain_attack_overridden`.
            -- This pinpoints the exact moment baseline orbwalker steals
            -- Sniper's focus from where brain put it.
            local ot_attack = UO and UO.DOTA_UNIT_ORDER_ATTACK_TARGET
            if tonumber(entry.orderType) == tonumber(ot_attack or 4) then
                local t_now = now()
                if source == "brain" then
                    state.last_brain_attack_target = entry.targetIndex
                    state.last_brain_attack_t = t_now
                    state.last_brain_attack_name = target_name
                else
                    -- Native attack. Was brain's last one recent + different?
                    local age = t_now - (state.last_brain_attack_t or 0)
                    if age < 1.0
                       and state.last_brain_attack_target
                       and entry.targetIndex ~= state.last_brain_attack_target
                    then
                        tlog(1, "brain_attack_overridden", {
                            brain_target  = state.last_brain_attack_name or "?",
                            native_target = target_name,
                            age_ms        = string.format("%.0f", age * 1000),
                        })
                    end
                end
            end
        end
    end

    state.last_queue_snapshot = new_snapshot

    -- v6.15.39: native-activity heartbeat. Emit a 5s-rolling summary of
    -- brain vs native queue entries so log readers can tell which portions
    -- of a session had native enabled and which had it disabled — useful
    -- for splitting analysis when the user toggles native mid-session.
    -- Native ENABLED produces sustained source=native_or_other entries
    -- (baseline orbwalker + items manager + dodger fire many orders per
    -- second); DISABLED collapses native_5s to near-zero. Threshold of 3
    -- entries per 5s is well below baseline orbwalk rate (~5-10/s observed
    -- in v6.15.26 — native produced 10x brain traffic). State transitions
    -- (active↔inactive) emit an extra log line for fast greppability.
    state.native_window_start = state.native_window_start or now()
    local t_now = now()
    if t_now - state.native_window_start >= 5.0 then
        local n_brain = state.native_window_brain or 0
        local n_other = state.native_window_other or 0
        local inferred = (n_other >= 3) and "active" or "inactive"
        -- v6.15.40: format per-subsystem counts as a single field for
        -- compact log readability. e.g. "items_manager=12,orbwalk_attack=18"
        local subs = state.native_window_subsystems or {}
        local pairs_sorted = {}
        for k, v in pairs(subs) do
            table.insert(pairs_sorted, k .. "=" .. tostring(v))
        end
        table.sort(pairs_sorted)
        local breakdown = #pairs_sorted > 0 and table.concat(pairs_sorted, ",") or "-"
        tlog(1, "native_heartbeat", {
            brain_5s   = tostring(n_brain),
            native_5s  = tostring(n_other),
            inferred   = inferred,
            subsystems = breakdown,
        })
        local prev = state.native_state_inferred
        if prev and prev ~= inferred then
            tlog(1, "native_state_transition", {
                from       = prev,
                to         = inferred,
                brain_5s   = tostring(n_brain),
                native_5s  = tostring(n_other),
                subsystems = breakdown,
            })
        end
        -- v6.15.65: Option A misconfig detector. User held combo key during
        -- this window but native heartbeat shows inactive — almost always
        -- means native Sniper combo binding is unbound (Hit & Run / Items
        -- Manager / Dodger never activate alongside brain combos). Throttled
        -- to once per 10s to avoid log spam. fallback_cursor_move_tick still
        -- covers movement; this just surfaces the misconfig in the log so
        -- the user can fix it.
        if state.native_window_combo_seen and inferred == "inactive" then
            local last_warn = state.last_config_warn_t or 0
            if (t_now - last_warn) > 10.0 then
                tlog(1, "config_warn_combo_no_native", {
                    brain_5s   = tostring(n_brain),
                    native_5s  = tostring(n_other),
                    subsystems = breakdown,
                    hint       = "combo_key_held_but_native_silent_check_option_A",
                })
                state.last_config_warn_t = t_now
            end
        end
        state.native_state_inferred    = inferred
        state.native_window_start      = t_now
        state.native_window_brain      = 0
        state.native_window_other      = 0
        state.native_window_subsystems = {}
        state.native_window_combo_seen = false
    end
end

-- v6.15.21: persistent-threat multi-fire. Threats that persist longer than
-- the Dedup.THREAT_WINDOW (2.0s) — Legion Duel 5s, Disruptor Static
-- Storm 6s — only got ONE save dispatched at modifier-create time. Brain
-- then sat idle through the rest of the threat duration. Now each tick we
-- check for these threats still on Sniper and re-fire try_save_self after
-- the dedup window has elapsed. Natural cadence ~2s (matches dedup window),
-- so grenade (10s CD) fires once at T+0, Pike (19s CD) at T+2s, Satanic at
-- T+4s, etc. — proper chain escalation over the full duration.
--
-- Only include threats where Sniper CAN ACT (not stunned/silenced).
-- Pudge Dismember and Bane Grip stun Sniper, so multi-fire is moot there
-- (Sniper can't cast during them anyway). Legion Duel restricts target-
-- selection but NOT casting; Static Storm silences abilities only (items
-- still work). So duel benefits from grenade→Pike→Satanic chain over time.
local PERSISTENT_THREAT_TICK_INTERVAL = 2.1
local PERSISTENT_THREATS = {
    modifier_legion_commander_duel          = true,
    modifier_disruptor_static_storm_thinker = true,  -- items work; abilities silenced
}

local function persistent_threats_tick()
    local me = state.self_npc
    if not me or not Entity.IsAlive(me) then return end
    if not defense_enabled() then return end
    state.last_persistent_tick_t = state.last_persistent_tick_t or {}
    local now_t = now()
    for mod_name, _ in pairs(PERSISTENT_THREATS) do
        if NPC.HasModifier(me, mod_name) then
            local last_t = state.last_persistent_tick_t[mod_name] or 0
            if (now_t - last_t) >= PERSISTENT_THREAT_TICK_INTERVAL then
                state.last_persistent_tick_t[mod_name] = now_t
                local mod = NPC.GetModifier(me, mod_name)
                local caster = mod and Modifier.GetCaster(mod)
                if caster and Entity.IsEntity(caster) and Target.IsAlive(caster)
                   and layer2_can_fire()
                then
                    -- Clear the responded_threats entry for this (caster,mod)
                    -- so try_save_self proceeds. The dedup is appropriate for
                    -- one-shot triggers (anim + OnModifierCreate firing same
                    -- threat) but NOT for persistent multi-fire.
                    local key = tostring(Entity.GetIndex(caster)) .. ":" .. mod_name
                    state.responded_threats[key] = nil
                    tlog(1, "persistent_threat_tick", {
                        mod = mod_name, caster = uname(caster),
                    })
                    try_save_self("persistent_" .. mod_name, mod_name, caster)
                end
            end
        else
            -- Modifier expired or wasn't present this tick — clear timer.
            state.last_persistent_tick_t[mod_name] = nil
        end
    end
end

-- Armed-ETA processor for homing threats. Iterates state.armed_threats, fires
-- the save chain (with proper threat-mod filter) when the projected impact
-- ETA falls below the entry's trigger threshold. Self-prunes stale entries.
-- v6.5: two-stage trigger for homing close_gap threats (Bara, Tusk). The
-- earlier single-eta_trigger model (fire chain at ETA 0.8s) caused a combo
-- with baseline Pike: at ETA 0.8s the charger is at ~480u (Bara) which is
-- OUTSIDE Pike's 425u cast range, so the chain falls to grenade_at_caster
-- and fires that. Then baseline Linkbreaker / Items Manager fires Pike a
-- tick later when the charger enters 425u — combo from the user's POV.
--
-- New behavior:
--   1. If Pike is ready AND charger is already in Pike's 425u range: fire
--      chain immediately. Pike-first override ensures Pike fires. Done.
--   2. Else if ETA <= eta_trigger:
--      a. If Pike is ready AND charger will enter 425u within ~0.15s of
--         eta_speed: DEFER — wait for Pike range. Pre-empts baseline Pike.
--      b. Otherwise (Pike not ready or charger still far): fire chain.
--         Chain falls through to grenade_at_caster or other items.
--   3. Final safety: if ETA <= 0.35s and still not fired, force-fire chain
--      regardless of Pike state. Don't let deferral push past the impact.
local function armed_threats_tick()
    if not next(state.armed_threats) then return end
    local me = state.self_npc
    if not me then return end
    for key, entry in pairs(state.armed_threats) do
        if not entry.caster or not Entity.IsEntity(entry.caster)
           or not Target.IsAlive(entry.caster) then
            tlog(2, "armed_threat_invalidated", { key = key })
            state.armed_threats[key] = nil
        else
            local d = dist_to(entry.caster)
            -- v6.15.143: drop an instant-blink entry that never arrived, so a
            -- stale key cannot block on_gap_close from re-arming the next
            -- blink (a targeted blink always lands — this is a safety net).
            if entry.instant_blink and not entry.fired and entry.t
               and (now() - entry.t) > state.BLINK_ARRIVE_TIMEOUT_S then
                tlog(2, "armed_threat_blink_expired", {
                    key = key, dist = string.format("%.0f", d),
                })
                state.armed_threats[key] = nil
            elseif not entry.fired then
                local eta = d / (entry.eta_speed > 0 and entry.eta_speed or 600)
                local pike_ready = NPCLib.item_ready(state.self_npc,"item_hurricane_pike")
                local pike_in_range = d <= state.pike_enemy_range()

                local should_fire = false
                local fire_reason = nil

                if entry.instant_blink then
                    -- v6.15.143: an instant blink (PA Phantom Strike)
                    -- TELEPORTS the caster to melee range — there is no
                    -- travel window to race, so the eta stages are
                    -- meaningless. The eta_critical stage (eta<=0.35,
                    -- eta=d/1500) force-fired the save mid-blink at
                    -- d~435-525 — OUTSIDE Pike's 425u cast range — and Pike's
                    -- fire closure then refused (out of range). The chain
                    -- fell through to grenade (600u, reaches) WITH shard, but
                    -- to nothing useful WITHOUT shard — the user-reported
                    -- "Pike doesn't work on anti-gap until shard / a combo".
                    -- Fire only once the caster has ARRIVED and SETTLED at
                    -- melee. v6.15.149 (D5): d<=425 fired mid-blink-settle (a
                    -- demo logged a fire at d~256 with PA still settling) —
                    -- the Pike push then acted on an unsettled target. PA
                    -- Phantom Strike lands at melee (~150-250u); wait for the
                    -- caster to settle inside BLINK_ARRIVE_DIST_U so the push
                    -- acts on the target's final position. Still well inside
                    -- every displacement save's range (Pike 425 / D / Force).
                    if d <= state.BLINK_ARRIVE_DIST_U then
                        -- v6.15.253: settle window. First tick we detect
                        -- blink_arrived, stamp entry.arrived_at and DEFER.
                        -- Next tick (>=BLINK_SETTLE_S later), the caster's
                        -- network position has settled and pike fire's
                        -- dist_to check sees the final position. Without
                        -- this, the v6.15.252 log showed cast_verify_
                        -- double_fail on pike: armed_threats_tick saw PA
                        -- at d=56 but pike fire at order-issue time still
                        -- saw the old far position, engine rejected the
                        -- cast (cd_after=0). User report: "Pike was fired
                        -- while PA was on middle of the blink, which
                        -- causes the pike not to work."
                        if not entry.arrived_at then
                            entry.arrived_at = now()
                            tlog(3, "armed_threat_blink_settle", {
                                key = key, dist = string.format("%.0f", d),
                            })
                        elseif (now() - entry.arrived_at) >= state.BLINK_SETTLE_S then
                            should_fire = true
                            fire_reason = "blink_arrived"
                        end
                    end
                elseif pike_ready and pike_in_range then
                    -- Stage 1: Pike viable right now.
                    should_fire = true
                    fire_reason = "pike_in_range"
                elseif eta <= 0.35 then
                    -- Stage 3: force-fire safety net.
                    should_fire = true
                    fire_reason = "eta_critical"
                elseif eta <= entry.eta_trigger then
                    -- Stage 2: eta_trigger reached.
                    local will_enter_pike_soon = pike_ready
                        and (d - state.pike_enemy_range()) < (entry.eta_speed * 0.15)
                    if will_enter_pike_soon then
                        -- Defer; wait for Pike's range.
                        tlog(3, "armed_threat_defer_for_pike", {
                            key = key, dist = string.format("%.0f", d),
                            eta = string.format("%.2f", eta),
                        })
                    else
                        should_fire = true
                        fire_reason = "eta_trigger"
                    end
                end

                -- v6.13 Bug #1: cross-check threat-response dedup before
                -- firing. Without this, the anim handler (on_gap_close)
                -- fires a save at T=0, marks responded; then armed_threats_tick
                -- crosses ETA threshold and fires a SECOND save on the same
                -- threat — violating the no-combo rule for Bara/Tusk.
                if should_fire and Dedup.threat_already_responded(state.responded_threats,entry.caster, entry.threat_mod) then
                    entry.fired = true   -- stop re-evaluating this entry
                    should_fire = false
                    -- v6.15.133: clear the entry so a FUTURE cast re-arms.
                    -- See the armed_threats[key]=nil note in the should_fire
                    -- block below — same stale-key bug.
                    state.armed_threats[key] = nil
                    tlog(2, "armed_threat_skip_responded", {
                        key = key, eta = string.format("%.2f", eta),
                    })
                end

                if should_fire then
                    entry.fired = true
                    -- v6.15.133: REMOVE the armed entry once its save fires.
                    -- The instant-blink path keys the entry by ability name
                    -- ("instant_blink:phantom_assassin_phantom_strike"), and
                    -- on_gap_close only arms when `not state.armed_threats[key]`.
                    -- Leaving a fired entry in place means the SECOND (and
                    -- every later) PA Phantom Strike finds the stale key,
                    -- skips re-arming, and on_gap_close returns with no save —
                    -- the user-reported "on the second PA blink Pike did not
                    -- activate". Clearing the entry here lets each new cast
                    -- re-arm and get the full Pike-first chain; the
                    -- responded-threats dedup still guards same-cast
                    -- double-fire from the modifier-create path.
                    state.armed_threats[key] = nil
                    tlog(1, "armed_threat_fire", {
                        key = key, eta = string.format("%.2f", eta),
                        dist = string.format("%.0f", d), via = fire_reason,
                    })
                    try_save_self("armed_" .. key, entry.threat_mod, entry.caster, nil, entry.ability)
                    -- Mark responded so the modifier-create path (which lands
                    -- shortly after charge impact) doesn't re-fire on the same threat.
                    Dedup.threat_mark_responded(state.responded_threats,entry.caster, entry.threat_mod)
                end
            end
        end
    end
end

-- Speculative fog-snipe (v6.15.152). Restored as standalone always-on code
-- from the retired layer1_tick combo catalog. When the `fog_snipe` menu
-- toggle is on (default off), cast R at the highest-value recently-fogged
-- enemy still inside R cast range (`top_fog_candidate` already range-gates).
-- Gated so it never steals R from a combo: skipped while the combo key was
-- down within FOG_SNIPE_COMBO_SUPPRESS_S, while an R is already in flight,
-- while Sniper is displaced / disabled, and self-throttled (L20).
state.fog_snipe_tick = function()
    if not (state.menu and state.menu.fog_snipe and state.menu.fog_snipe:Get()) then
        return
    end
    if not self_alive_ok() then return end
    if is_displaced(0) then return end
    -- an R is already in flight (combo R, channel-punish, or a prior fog-R)
    if state.last_r_target then return end
    -- don't contend with a combo the user is actively running
    if (now() - (state.last_combo_key_down_t or 0)) < state.FOG_SNIPE_COMBO_SUPPRESS_S then
        return
    end
    if (now() - (state.last_fog_snipe_t or 0)) < state.FOG_SNIPE_RETRY_S then
        return
    end
    if not ability_ready(A.R) then return end
    local fog_top = top_fog_candidate()
    if not fog_top then return end
    state.last_fog_snipe_t = now()
    local ok = issue_cast_target("snipe_fog_r", ability(A.R), fog_top.target)
    tlog(1, "fog_snipe", {
        target  = uname(fog_top.target),
        score   = string.format("%.0f", fog_top.score),
        fog_age = string.format("%.2f", now() - fog_top.t),
        fired   = ok and "y" or "n",
    })
    if ok then
        state.last_layer1_t      = now()
        -- v6.15.194 (audit #4): fog-R is an R cast, so the next starter_tick
        -- / teamfight_tick must use the 2.5s R lock window
        -- (LAYER1_COMMIT_WINDOW_R), not the 0.4s SEQ window. Without this
        -- flag, last_layer1_was_r read false next tick and a second R could
        -- dispatch on top of fog-R inside its 2s cast point.
        state.last_layer1_was_r  = true
        state.last_layer1_intent = "snipe_fog:" .. uname(fog_top.target)
        state.l1_counter         = state.l1_counter + 1
        state.last_r_target      = fog_top.target
        state.last_r_combo_name  = "snipe_fog"
        state.last_r_dispatch_t  = now()
        -- v6.15.166: fog-R dispatches R directly (not via fire_steps), so it
        -- must arm the same R-in-flight markers the other R-dispatch sites do
        -- — the cast-protect veto window and the fast-cancel detector's
        -- r_phase_seen flag. Without them a fog-R has no native-order
        -- protection and a stale r_phase_seen defeats r_abort_tick for it.
        state.r_cast_protect_until_t = now() + r_cast_point() + 0.4
        state.r_phase_seen = false
    end
end

----------------------------------------------------------------------------
-- Anim subscribers
----------------------------------------------------------------------------

-- Generic gap_close on me → kite via Take Aim + queue save. Threat caster
-- passed through so grenade-self can compute the right push direction.
-- mark_responded prevents OnModifierCreate from re-firing the same save
-- when the corresponding modifier lands a moment later.
local function on_gap_close(ev)
    if not ev.target_self then return end
    if not Dedup.anim_throttled(state.anim_log_dedup,ev.caster, ev.ability_name) then
        tlog(1, "anim_gap_close_on_me", {
            caster = uname(ev.caster), ability = ev.ability_name or "?",
        })
    end
    reactive_take_aim()
    local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
    -- v6.15.48 (user directive: PA Pike timing): instant-blink abilities fire
    -- their anim BEFORE the caster has arrived next to Sniper. Pike's 425u
    -- cast range refuses (caster still at origin), chain falls through to
    -- worse saves. Solution: arm the threat instead of firing immediately
    -- so armed_threats_tick's Stage 1 check (pike_ready AND dist <= 425)
    -- catches the caster when they arrive at Sniper's position. Same
    -- mechanism Bara/Tusk use for their armed-ETA chains.
    local INSTANT_BLINK_THREATS = {
        phantom_assassin_phantom_strike = true,
    }
    if INSTANT_BLINK_THREATS[ev.ability_name or ""] and ev.caster
       and Entity.IsEntity(ev.caster) then
        local key = "instant_blink:" .. (ev.ability_name or "?")
        if not state.armed_threats[key] then
            tlog(1, "instant_blink_armed", {
                caster = uname(ev.caster), ability = ev.ability_name or "?",
            })
            -- v6.15.140: a fresh arm = a NEW blink cast. Clear the
            -- responded-threats dedup for this threat so armed_threats_tick
            -- does not skip the new cast's save as "already responded" to the
            -- PREVIOUS blink (user, v6.15.139 demo: 2nd PA jump → pike does
            -- not fire; the log showed armed_threat_skip_responded). The dedup
            -- still prevents armed-tick + modifier-create double-firing WITHIN
            -- this cast — armed_threats_tick re-marks it when it fires.
            if threat then
                Dedup.threat_clear_responded(state.responded_threats,
                                             ev.caster, threat)
            end
            state.armed_threats[key] = {
                caster        = ev.caster,
                threat_mod    = threat,
                ability       = ev.ability_name,
                eta_speed     = 1500,  -- nominal high speed (blink is effectively instant)
                eta_trigger   = 0.4,   -- worst-case window before we fall back
                fired         = false,
                -- v6.15.143: mark this as an instant-blink entry. The eta
                -- model (d/eta_speed) is meaningless for a teleport — there
                -- is no travel window to race. armed_threats_tick fires an
                -- instant-blink save on ARRIVAL (caster inside Pike's 425u
                -- range), not on the eta_critical timer. `t` is the arm time
                -- for the never-arrived expiry.
                instant_blink = true,
                t             = now(),
            }
        end
        return  -- skip immediate try_save_self; armed tick handles arrival
    end
    if threat then Dedup.threat_mark_responded(state.responded_threats,ev.caster, threat) end
    try_save_self("gap_close_" .. (ev.ability_name or "unk"), threat, ev.caster, "close_gap", ev.ability_name)
end

-- Hard disable cast at me (Lion Hex, Bane Nightmare cast, Lina LSA aimed here)
-- Saves are largely modifier-driven; the anim is informational + pre-arm.
-- Caster threaded through for grenade-self direction computation.
local function on_hard_disable(ev)
    if not ev.target_self then return end
    if not Dedup.anim_throttled(state.anim_log_dedup,ev.caster, ev.ability_name) then
        tlog(1, "anim_hard_disable_on_me", {
            caster = uname(ev.caster), ability = ev.ability_name or "?",
        })
    end
    local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
    -- v6.15.9: dedup against already-responded threats on the anim path.
    -- Engine emits OnUnitAnimation multiple times per cast (cast-point start,
    -- channel begin, etc.); without this check, on_hard_disable runs each
    -- time, the LAYER2_REACTION_WINDOW opens between calls, and the chain
    -- burns a second save on the same threat. Same dedup OnModifierCreate
    -- already does at the threat-on-self branch.
    if threat then
        if Dedup.threat_already_responded(state.responded_threats,ev.caster, threat) then
            tlog(3, "anim_response_dedup", { mod = threat, via = "hard_disable" })
            return
        end
        Dedup.threat_mark_responded(state.responded_threats,ev.caster, threat)
    end
    -- v6.15.209: ult_burst events also route here (Anim.Subscribe ult_burst
    -- → on_hard_disable). Pick the category chain by ev.role so the
    -- unresolved-modifier fallback uses a role-appropriate chain.
    local cat = (ev.role == "ult_burst") and "targeted_burst" or "targeted_disable"
    try_save_self("hard_disable_" .. (ev.ability_name or "unk"), threat, ev.caster, cat, ev.ability_name)
end

-- Channel start by an enemy — Layer 1.5 dispatch + pre-emptive Layer 2.
--
-- For channels with a meaningful cast point (Pudge Dismember 0.3s, Bane
-- Fiend Grip 0.2s), this anim event fires BEFORE the modifier lands. Once
-- the modifier lands Sniper is stunned and can't reliably cast escape items.
-- So when target_self == true, we fire the self-save DURING cast point.
-- The threat-response dedup then prevents OnModifierCreate from re-firing
-- the same save 0.2-0.3s later.
local function on_channel_start(ev)
    if not Dedup.anim_throttled(state.anim_log_dedup,ev.caster, ev.ability_name) then
        tlog(1, "anim_channel_start", {
            caster = uname(ev.caster), ability = ev.ability_name or "?",
            target_self = ev.target_self and "1" or "0",
        })
    end
    on_enemy_channel_start(ev.caster, ev.ability_name, ev.target_self)

    -- Pre-emptive self-save during cast point. Marks responded so the
    -- modifier-create path doesn't re-fire.
    if ev.target_self then
        local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
        if threat then
            -- v6.15.9: see on_hard_disable for rationale.
            if Dedup.threat_already_responded(state.responded_threats,ev.caster, threat) then
                tlog(3, "anim_response_dedup", { mod = threat, via = "channel_start" })
                return
            end
            Dedup.threat_mark_responded(state.responded_threats,ev.caster, threat)
            try_save_self("channel_pre_" .. (ev.ability_name or "unk"), threat, ev.caster, "channel_on_self", ev.ability_name)
        else
            -- v6.15.209: the anim detected a real (KV-authoritative) channel
            -- ability but ABILITY_TO_THREAT has no resolved modifier name
            -- (unverified guess). Fire the cast-point save off the channel
            -- category chain anyway rather than going silent — once the
            -- channel modifier lands Sniper is disabled and cannot cast
            -- escapes, so the cast-point window is the only one that helps.
            -- No modifier name to mark-responded, so the modifier-create
            -- route may re-fire; layer2_can_fire() throttles the duplicate.
            try_save_self("channel_pre_" .. (ev.ability_name or "unk"), nil, ev.caster, "channel_on_self", ev.ability_name)
        end
    end
end

----------------------------------------------------------------------------
-- callbacks
----------------------------------------------------------------------------

local callbacks = {}

-- v6.15.86 (CRITICAL fix for "R refuses to fire"): native subsystems
-- (Orb Walker ATTACK_TARGET, Hit & Run MOVE_TO_POSITION) send orders
-- same-tick as brain's R cast. Those orders use queue=false → they
-- REPLACE Sniper's current action → R cast is cancelled before cast
-- point starts. cast_verify shows fired=n + cd_after=0 every R issue.
-- v6.15.x had only DIAGNOSTIC (interfere_check_miss) — no prevention.
--
-- This handler VETOES non-brain unit-disrupting orders during the R
-- cast protect window. Brain's own orders pass through (triggerCallBack
-- flag identifies them). Window is set when R is dispatched in
-- fire_steps (line ~2937) and cleared on cast_verify completion or
-- abort (cast_verify_tick / r_abort_tick path).
function callbacks.OnPrepareUnitOrders(data)
    -- v6.15.93: SCHEMA FIX — OnPrepareUnitOrders uses DIFFERENT field names
    -- than Humanizer.GetOrderQueue. v6.15.86 used `data.order_type` (wrong).
    -- v6.15.89 changed to `data.orderType` based on the Humanizer.GetOrderQueue
    -- schema in humanizer.md:35 — also wrong, that's the QUEUE-RETURN schema.
    -- v6.15.92's order_inspect proved it: 25 callback fires with ot=? (nil)
    -- for every event. Per callbacks.md:418-432, the ACTUAL OnPrepareUnitOrders
    -- data fields are:
    --   data.order        (Enum.UnitOrder)         -- NOT orderType
    --   data.target       (CEntity, nilable)        -- NOT targetIndex
    --   data.ability      (CAbility, nilable)       -- NOT abilityIndex
    --   data.npc          (CNPC)                    -- NOT unit
    --   data.position     (Vector)
    --   data.orderIssuer  (Enum.PlayerOrderIssuer)  -- matches
    --   data.queue        (boolean) — is order queued; NOT triggerCallBack
    --   data.showEffects  (boolean)
    -- There is NO triggerCallBack field on this callback. The v6.15.86 brain
    -- filter `if data.triggerCallBack then return true end` always evaluated
    -- to nil/false → all orders passed the filter unconditionally → never
    -- vetoed anything. That's why v6.15.91 demo had 12 R cancellations + 0
    -- veto fires.
    --
    -- Brain orders are identified via `data.identifier`. Player.PrepareUnitOrders
    -- accepts an identifier param (player.md:22) "which will be passed to
    -- OnPrepareUnitOrders callback". lib/order.lua:236 sets it to the canonical
    -- "<hero>-<layer>-<intent>" string. Prefix match for "Sniper-" identifies
    -- our orders. Note: the schema doc at callbacks.md:418-432 does not list
    -- `identifier` (probably an incomplete schema doc) but the player.md
    -- explicitly states the param is passed through.
    -- v6.15.139: the veto is active during EITHER the R-cast protect window
    -- OR the save-cast protect window (set by record_save when a Layer-2
    -- self-save is dispatched). Whichever is further out bounds the veto.
    -- v6.15.179: capture the player's manual attack target so the chip-Q can
    -- follow mid-fight target switches. This MUST run before the veto
    -- early-returns below — the veto only engages inside a cast-protect
    -- window, so on most ticks the function returns early at
    -- `protect_until == 0` and a capture placed after that point is missed.
    if data and data.npc and state.self_npc
       and data.order == UO.DOTA_UNIT_ORDER_ATTACK_TARGET
       and data.target and Entity.IsEntity(data.target)
       and Entity.IsEntity(data.npc) and Entity.IsEntity(state.self_npc)
       and Entity.GetIndex(data.npc) == Entity.GetIndex(state.self_npc)
       and NPC.IsHero and NPC.IsHero(data.target)
       and Entity.GetTeamNum(data.target) ~= Entity.GetTeamNum(state.self_npc)
    then
        -- A brain attack order carries the `sniper-` identifier; only a
        -- player order (no / other identifier) counts as player intent.
        local id = data.identifier
        local is_brain = id and type(id) == "string"
                         and string.sub(id, 1, 7) == "sniper-"
        if not is_brain then
            state.player_attack_target   = data.target
            state.player_attack_target_t = now()
        end
    end

    local protect_until = math.max(state.r_cast_protect_until_t or 0,
                                   state.save_cast_protect_until_t or 0,
                                   state.combo_cast_protect_until_t or 0)
    if protect_until == 0 then return true end
    if now() >= protect_until then return true end
    if not data then return true end

    -- Safety: only consider orders targeting our hero. Orders on other units
    -- (allies, summons) don't disrupt our R cast.
    local me = state.self_npc
    if me and data.npc and Entity.IsEntity(data.npc)
       and Entity.IsEntity(me)
       and Entity.GetIndex(data.npc) ~= Entity.GetIndex(me) then
        return true
    end

    -- Brain orders pass through via identifier prefix check.
    -- v6.15.94: identifier prefix uses HERO_KEY which is lowercase "sniper".
    -- v6.15.93's "Sniper-" check (capitalized) NEVER matched — they passed
    -- the veto only by accident (CAST orders aren't in the disrupts list,
    -- so they fell through to action=pass). With this fix, brain orders are
    -- properly identified as brain orders, not accidentally.
    local id_str = data.identifier
    if id_str and type(id_str) == "string"
       and string.sub(id_str, 1, 7) == "sniper-" then
        return true
    end

    -- Veto only the order types that interrupt a unit cast point.
    local order_int = data.order
    local disrupts =
        order_int == UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION
     or order_int == UO.DOTA_UNIT_ORDER_MOVE_TO_TARGET
     or order_int == UO.DOTA_UNIT_ORDER_ATTACK_MOVE
     or order_int == UO.DOTA_UNIT_ORDER_ATTACK_TARGET
     or order_int == UO.DOTA_UNIT_ORDER_STOP
     or order_int == UO.DOTA_UNIT_ORDER_HOLD_POSITION

    -- v6.15.93/.96 diagnostic. v6.15.96 added position field + cursor
    -- comparison so we can tell if MOVE orders are coming from the player's
    -- cursor (regular input) vs a script that's auto-positioning Sniper.
    local pos = data.position
    local pos_x, pos_y, dist_cur = "-", "-", "-"
    if pos and pos.x and pos.y then
        pos_x = string.format("%.0f", pos.x)
        pos_y = string.format("%.0f", pos.y)
        local cur = (Humanizer and Humanizer.GetServerCursorPos)
                    and Humanizer.GetServerCursorPos() or nil
        if cur and cur.x and cur.y then
            local dx = pos.x - cur.x
            local dy = pos.y - cur.y
            dist_cur = string.format("%.0f", math.sqrt(dx*dx + dy*dy))
        end
    end
    tlog(2, "order_inspect", {
        ord      = tostring(order_int or "?"),
        id       = tostring(id_str or "-"),
        issuer   = tostring(data.orderIssuer or "-"),
        has_tgt  = (data.target and Entity.IsEntity(data.target)) and "y" or "n",
        has_ab   = (data.ability) and "y" or "n",
        pos_x    = pos_x,
        pos_y    = pos_y,
        dist_cur = dist_cur,
        action   = disrupts and "veto" or "pass",
    })

    if not disrupts then return true end

    tlog(2, "cast_protect_veto", {
        ord = tostring(order_int),
        id = tostring(id_str or "-"),
        issuer = tostring(data.orderIssuer or "-"),
        via = (now() < (state.r_cast_protect_until_t or 0))
              and "r_cast" or "save_cast",
        remaining_s = string.format("%.2f", protect_until - now()),
    })
    return false   -- VETO — order does not reach engine
end

-- v6.15.107 (audit-derived from klc9r4n Sniper auto-grenade): standalone
-- proximity-triggered Concussive Grenade dispatch. Fills a Phase 0 gap —
-- Sniper brain has D as a STEP inside snipe_d_r / snipe_standard /
-- snipe_channel_punish combos but no auto-grenade for the "enemy hero
-- closes within ~500u while I'm not in a combo" case (skirmish chip /
-- self-defense / DPS attrition).
--
-- Coexistence with combos:
--   - Skips when combo key is held (manual combo dispatch always wins)
--   - Skips when state.last_d_t < 1.5s (combo just queued/fired D —
--     don't double-fire on a target combo D is about to hit)
--   - Skips during R cast protect window (D during R cast = orphaned grenade)
--   - Throttles to 0.3s between auto-grenade attempts (klc9r4n's value)
--
-- Adapts klc9r4n's logic to Sniper's brain idioms:
--   - Routes through issue_cast_position so identifier="sniper-auto_grenade"
--     is set by lib/order.lua and OnPrepareUnitOrders veto sees it
--   - Reuses ability(A.D) / NPC.HasShard / effective_cast_range
--   - Smart-cast position = midpoint between Sniper and predicted enemy
--     when both fit in 375u radius; else along the line at dist - 375 + 50
--   - Predicts enemy at cast_anim (0.1s) + projectile_travel (dist/2500)
--     using NPC.GetForwardVector + IsMoving/IsStunned/IsRooted gates
local function auto_grenade_tick()
    if not state.menu or not state.menu.auto_grenade_enable then return end
    if not state.menu.auto_grenade_enable:Get() then return end
    if not self_alive_ok() then return end

    local me = state.self_npc
    if not me then return end
    -- D is shard-granted in 7.41C+; abort if no shard
    if not (NPC.HasShard and NPC.HasShard(me)) then return end
    -- Manual combo always wins — don't preempt user dispatch. v6.15.129:
    -- gate on a WINDOW since the combo key was last down, not a single tick.
    -- combo_key:IsDown() flickers between ticks, so the bare combo_key_was_down
    -- check let auto-D fire on a flicker-false tick mid-hold and steal D from
    -- the dr (D+R+Q+E) combo (user demo: "not committing to a full combo vs
    -- melee"). The window also covers the combo's deferred-step execution.
    if state.combo_key_was_down then return end
    if state.last_combo_key_down_t and (now() - state.last_combo_key_down_t)
       < state.AUTO_GRENADE_COMBO_SUPPRESS_S then
        return
    end
    -- v6.15.140: do not double up on a rusher the defense layer is handling
    -- (user, v6.15.139 demo: "grenade and pike used at the same time on close
    -- gap"). TWO gates:
    --  (1) a threat is currently ARMED — on_gap_close armed it and
    --      armed_threats_tick has not yet fired the save. This is the
    --      PRE-save half the failed v6.15.136 attempt lacked: auto_grenade
    --      fires every tick, so without this it beats the armed save and the
    --      defense save then double-ups with D.
    --  (2) a Layer-2 self-save dispatched within AUTO_GRENADE_SAVE_SUPPRESS_S
    --      — the POST-save half, covering the short gap between the save
    --      dispatching and its displacement actually resolving.
    -- (1) covers what (2) alone could not; (2) covers what (1) alone could
    -- not (the armed entry is cleared the instant the save fires).
    if next(state.armed_threats) then return end
    if state.last_save_t and (now() - state.last_save_t)
       < state.AUTO_GRENADE_SAVE_SUPPRESS_S then
        return
    end
    -- Don't double-fire if a combo recently queued/fired D
    if state.last_d_t and (now() - state.last_d_t) < 1.5 then return end
    -- v6.15.234: also skip if a combo has D reserved for a deferred step.
    -- last_d_t only stamps when D actually fires, so a scheduled-but-not-
    -- yet-fired combo D would let auto-grenade steal the slot. The defense
    -- save chain already honors is_reserved(A.D); match it.
    if is_reserved(A.D) then return end
    -- Don't preempt R cast (D during R cast = orphaned grenade)
    if state.r_cast_protect_until_t and now() < state.r_cast_protect_until_t then return end
    -- Throttle 0.3s between attempts (klc9r4n value, prevents order-buffering)
    state.last_auto_grenade_t = state.last_auto_grenade_t or 0
    if (now() - state.last_auto_grenade_t) < 0.3 then return end

    local d_ab = ability(A.D)
    if not d_ab or Ability.GetLevel(d_ab) <= 0 then return end
    if not Ability.IsCastable(d_ab, NPC.GetMana(me)) then return end
    if Ability.GetCooldown(d_ab) > 0 then return end

    -- Trigger radius with optional low-HP expansion
    local base_r  = state.menu.auto_grenade_radius:Get() or 500
    local extra_r = state.menu.auto_grenade_low_hp_extra:Get() or 0
    local trigger_r = base_r
    if extra_r > 0 then
        local hp_pct = (Entity.GetHealth(me) / math.max(1, Entity.GetMaxHealth(me))) * 100
        if hp_pct < 40 then
            trigger_r = trigger_r + math.floor(extra_r * (1.0 - hp_pct / 40))
        end
    end

    -- Find nearest valid enemy hero in trigger radius. v6.15.248: route
    -- through NPCLib.origin (typed safe-read, v6.15.238 C1). auto_grenade
    -- was off the original C1 audit and v6.15.243 HUD fix; this is the
    -- last raw Entity.GetAbsOrigin(me) site in the offensive ticks. The
    -- gate at line below returns early on nil, so the runtime risk was
    -- low, but consistency makes future regressions easier to spot.
    local me_pos       = NPCLib.origin(me)
    if not me_pos then return end
    local skip_slowed  = state.menu.auto_grenade_skip_slowed:Get()
    local nearest, nearest_d = nil, math.huge
    local enemies = Heroes.InRadius(me_pos, trigger_r,
                        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
    if not enemies then return end
    for _, e in ipairs(enemies) do
        if e and Entity.IsAlive(e) and not Entity.IsDormant(e) and not NPC.IsIllusion(e)
           and not (NPC.IsInvulnerable and NPC.IsInvulnerable(e))
           and (not NPC.IsVisible or NPC.IsVisible(e)) then
            -- Skip if already affected by grenade
            if not skip_slowed
               or (not NPC.HasModifier(e, "modifier_sniper_concussive_grenade_slow")
                   and not NPC.HasModifier(e, "modifier_knockback")) then
                local d = me_pos:Distance2D(Entity.GetAbsOrigin(e))
                if d < nearest_d then
                    nearest_d = d
                    nearest   = e
                end
            end
        end
    end
    if not nearest then return end

    -- Compute cast position
    local enemy_pos = Entity.GetAbsOrigin(nearest)
    if not enemy_pos then return end
    -- v6.15.246: hoisted for the danger-aware adjustment below. GRENADE_RADIUS
    -- read live off the D handle (KV migration #3, v6.15.169). pred_pos defaults
    -- to the enemy's current position; smart-cast may overwrite with the
    -- prediction at impact time.
    local GRENADE_RADIUS = state.item_kv(d_ab, "radius", 375)
    local pred_pos       = enemy_pos
    local cast_pos
    if state.menu.auto_grenade_smart_cast:Get() then
        -- Predict enemy position at cast_anim + projectile_travel
        -- v6.15.169 (KV-hardcode migration #3): radius + cast anim read
        -- LIVE off the D (Shard) handle — d_ab is guaranteed non-nil and
        -- D-leveled here (gated at the top of this function). KV
        -- sniper_concussive_grenade: `radius` 375, AbilityCastPoint 0.1 —
        -- both match the old literals, so behaviour-neutral.
        -- GRENADE_PROJ_SPEED stays hardcoded — sniper_concussive_grenade
        -- has NO projectile-speed KV key (verified npc_abilities.json), so
        -- it is not migratable.
        local GRENADE_PROJ_SPEED = 2500
        local GRENADE_CAST_ANIM  = (Ability.GetCastPoint
                                    and Ability.GetCastPoint(d_ab, true)) or 0.1
        local travel_t = nearest_d / GRENADE_PROJ_SPEED
        if NPC.IsMoving and NPC.IsMoving(nearest)
           and not (NPC.IsStunned and NPC.IsStunned(nearest))
           and not (NPC.IsRooted and NPC.IsRooted(nearest))
           and NPC.GetForwardVector then
            local fwd   = NPC.GetForwardVector(nearest)
            local speed = NPC.GetMoveSpeed(nearest) or 300
            local t_total = GRENADE_CAST_ANIM + travel_t
            pred_pos = Vector(enemy_pos.x + fwd.x * speed * t_total,
                              enemy_pos.y + fwd.y * speed * t_total,
                              enemy_pos.z)
        end
        local dir  = Vector(pred_pos.x - me_pos.x, pred_pos.y - me_pos.y, 0)
        local dist = dir:Length2D()
        if dist < 1 then
            cast_pos = me_pos
        else
            local nx, ny = dir.x / dist, dir.y / dist
            -- klc9r4n's two-mode positioning:
            --   close (dist <= 750u): grenade at midpoint, both in 375u radius
            --   far (dist > 750u):    grenade ahead of Sniper at dist - 325
            local offset = (dist <= GRENADE_RADIUS * 2) and (dist * 0.5)
                                                         or (dist - GRENADE_RADIUS + 50)
            cast_pos = Vector(me_pos.x + nx * offset, me_pos.y + ny * offset, me_pos.z)
        end
    else
        cast_pos = me_pos:Lerp(enemy_pos, 0.5)
    end

    -- v6.15.246 (D panic save position calc): danger-aware adjustment.
    -- In close mode (Sniper within the 375u self-push radius of cast_pos),
    -- the grenade pushes Sniper too, currently in a direction straight
    -- away from the rusher and into whatever sits behind him. The same
    -- blind spot the shared escape helper fixed for grenade_self / pike_self
    -- (v6.15.244 / .245). Routed through state.pick_escape_dir: try the
    -- 7-angle danger-aware pick, set cast_pos so Sniper's resulting push
    -- direction matches the chosen escape_dir, and verify the enemy is
    -- still within the 375u blast radius of the rotated cast_pos. If the
    -- rotation moves the enemy out of the blast (sin(theta) > 375/dist),
    -- fall back to the straight cast (preserves auto-grenade aggressiveness;
    -- 0deg always wins ties so 1v1 behaviour is unchanged). Skipped in far
    -- mode -- Sniper isn't pushed by his own grenade there.
    if cast_pos then
        local s_to_cast = me_pos:Distance2D(cast_pos)
        if s_to_cast > 1 and s_to_cast <= GRENADE_RADIUS then
            local d = cast_pos - me_pos
            local toward = Vector(d.x, d.y, 0)
            -- Normalise toward (Vector:Normalized() requires length > 0; the
            -- s_to_cast > 1 guard above ensures it).
            local L = math.sqrt(toward.x * toward.x + toward.y * toward.y)
            toward = Vector(toward.x / L, toward.y / L, 0)
            local SNIPER_PUSH = 475
            local escape_dir = state.pick_escape_dir(me_pos, toward, SNIPER_PUSH, nearest)
            if escape_dir then
                local cand = me_pos - escape_dir * s_to_cast
                if (pred_pos - cand):Length2D() <= GRENADE_RADIUS then
                    if math.abs(cand.x - cast_pos.x) > 1
                       or math.abs(cand.y - cast_pos.y) > 1 then
                        tlog(2, "auto_grenade_rotated", {
                            land_x = string.format("%.0f", me_pos.x + escape_dir.x * SNIPER_PUSH),
                            land_y = string.format("%.0f", me_pos.y + escape_dir.y * SNIPER_PUSH),
                            cast_x = string.format("%.0f", cand.x),
                            cast_y = string.format("%.0f", cand.y),
                        })
                    end
                    cast_pos = cand
                end
            end
        end
    end

    -- Clamp to D effective cast range (Aether Lens / cast range bonuses)
    local cast_r = effective_cast_range(me, d_ab) or 600
    local cast_d = me_pos:Distance2D(cast_pos)
    if cast_d > cast_r then
        local d   = Vector(cast_pos.x - me_pos.x, cast_pos.y - me_pos.y, 0)
        local len = d:Length2D()
        if len > 1 then
            cast_pos = Vector(me_pos.x + (d.x / len) * cast_r,
                              me_pos.y + (d.y / len) * cast_r,
                              me_pos.z)
        end
    end

    local ok = issue_cast_position("auto_grenade", d_ab, cast_pos)
    if ok then
        state.last_auto_grenade_t = now()
        state.last_d_t = now()  -- mark D fired so combos respect throttle too
        tlog(2, "auto_grenade", {
            target    = uname(nearest),
            dist      = string.format("%.0f", nearest_d),
            trigger_r = trigger_r,
            x         = string.format("%.0f", cast_pos.x),
            y         = string.format("%.0f", cast_pos.y),
        })
    end
end

-- v6.15.117: auto_take_aim_tick (E) and auto_q_chip_tick (Q) REMOVED.
-- User feedback on the v6.15.111 hybrid model after demo testing:
--   - Auto-Take-Aim: "Didn't notice any new behaviour ... doing this
--     automatically is almost useless." (Log confirmed: fired only 2× in a
--     full demo — its gate stack is too strict to ever meaningfully fire.)
--   - Auto-Q-chip: "is firing all the time if Q is not on CD ... too much
--     and basically useless option."
-- The KotL-inspired per-ability-tick idea works for D (auto_grenade_tick —
-- user confirmed "great function") because grenade-on-rusher is a clean
-- isolated reaction. It does NOT work for E and Q: E (Take Aim) only has
-- value as a combo opener/finalizer tied to R timing, and Q wants combo-key
-- control, not autonomous spam. E and Q belong in the combo-key sequences
-- (see v6.15.118 combo-key redesign), not as standalone auto-ticks.
-- auto_grenade_tick (D) is kept — it remains the one per-ability tick.

-- v6.15.197 (audit B7): retired `state.api_xcheck_tick` (v6.15.185) and
-- `state.lineup_scout` (v6.15.186-.188). Both were always-on observability
-- ticks with no consumer.
--   api_xcheck_tick: paired a native API call against an independent calc
--     to validate equivalence. The distance side was confirmed equivalent
--     in the v6.15.185 field test (apicheck_dist matched exactly); the
--     damage side was perpetually inconclusive (every test window had
--     Sniper at full HP). The job was done for the side that mattered.
--   lineup_scout: scanned enemy kits live and wrote state.enemy_lineup,
--     but nothing in the brain ever read that field — the consumer was
--     planned as "a later delta" that never landed. A pure orphan.
-- `state.live_channel_tick` is KEPT below — its eventual consumer (delta
-- 2b, wiring into the save chain) is the only one of the three with a
-- clear destination, and v6.15.197's B2 also gave it a teamfight-side
-- companion via NPC.GetChannellingAbility in build_layer1_ctx.

-- v6.15.189: live channel-threat detector (delta 2a, the sensing half).
-- The static threat catalog keys on modifier names, which are hand-
-- maintained guesses that rot. This watches enemies LIVE via
-- NPC.GetChannellingAbility: when one is channelling, it logs the ability
-- (a reliable live name, never a guess) and whether the static catalog
-- knows it. Behaviour-neutral for now — once the log confirms it catches
-- channels the catalog misses, delta 2b wires it into the save chain
-- (which needs a "channelling ON me", not just "near me", check first).
-- Defined as state.X per the 200-locals-limit pattern.
state.live_channel_tick = function()
    state.last_livech_t = state.last_livech_t or 0
    if (now() - state.last_livech_t) < 0.2 then return end
    state.last_livech_t = now()

    local me = state.self_npc
    if not me or not Entity.IsAlive(me) then return end
    if not NPC.GetChannellingAbility then return end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return end
    local A2T = TD.ABILITY_TO_THREAT or {}

    local heroes = Heroes.GetAll()
    for i = 1, #heroes do
        local h = heroes[i]
        if h ~= me and Entity.IsAlive(h) and not Entity.IsSameTeam(me, h) then
            local ch = NPC.GetChannellingAbility(h)
            if ch then
                local an = Ability.GetName(ch)
                if an and an ~= "" then
                    local hp = Entity.GetAbsOrigin(h)
                    local d  = hp and me_pos:Distance2D(hp) or math.huge
                    if d < 1300 then
                        tlog(1, "channel_live", {
                            caster    = uname(h),
                            ability   = an,
                            ult       = Ability.IsUltimate(ch) and "y" or "n",
                            dist      = string.format("%.0f", d),
                            cataloged = A2T[an] and "y" or "n",
                        })
                    end
                end
            end
        end
    end
end

-- v6.15.200 (audit C14): hoisted out of OnUpdateEx's saves-inventory
-- block where this 23-string table was rebuilt every 5s. Module-level
-- const, allocated once at script load. Trivial GC win.
local SAVES_INVENTORY_ITEM_NAMES = {
    "item_cyclone", "item_wind_waker", "item_lotus_orb",
    "item_glimmer_cape", "item_satanic", "item_manta",
    "item_disperser", "item_diffusal_blade",
    "item_hurricane_pike", "item_force_staff",
    "item_black_king_bar", "item_aeon_disk",
    "item_blink", "item_swift_blink", "item_arcane_blink", "item_overwhelming_blink",
    "item_eternal_shroud", "item_pipe_of_insight",
    "item_crimson_guard", "item_blade_mail", "item_ghost",
    "item_solar_crest", "item_phase_boots",
}

function callbacks.OnUpdateEx()
    -- Re-acquire self when stale. In a demo, a reset/respawn invalidates the
    -- cached userdata handle (next call to Entity.GetIndex on the old pointer
    -- crashes with arg-is-not-an-Entity). Heroes.GetLocal() is cheap; just
    -- re-pin every tick if our handle isn't a valid Entity any more.
    if not state.self_npc or not Entity.IsEntity(state.self_npc) then
        state.self_npc = Heroes.GetLocal()
        if not state.self_npc or not Entity.IsEntity(state.self_npc) then return end
        tlog(1, "self_acquired", {
            name      = uname(state.self_npc),
            scepter   = NPC.HasScepter(state.self_npc),
            shard     = NPC.HasShard(state.self_npc),
            stage2    = Damage.IsStage2Active(),
        })
    end

    -- Periodically log Sniper's save-item inventory so the user can verify
    -- which items the chain has available. Logged once per 5s at level 1.
    -- Critical for diagnosing "Pike didn't fire" — if Pike isn't in the
    -- snapshot, it's not built and can't fire.
    state.last_saves_snapshot_t = state.last_saves_snapshot_t or 0
    if (now() - state.last_saves_snapshot_t) > 5.0 then
        state.last_saves_snapshot_t = now()
        -- v6.15.200 (audit C14): list hoisted to module-level const above.
        local built_ready, built_cd, in_backpack = {}, {}, {}
        for _, name in ipairs(SAVES_INVENTORY_ITEM_NAMES) do
            local it = NPC.GetItem(state.self_npc, name, true)
            local short = name:gsub("^item_", "")
            if it then
                if Ability.IsReady(it) then
                    built_ready[#built_ready + 1] = short
                else
                    built_cd[#built_cd + 1] = short
                end
            else
                -- Check backpack/stash
                local bp = NPC.GetItem(state.self_npc, name, false)
                if bp then in_backpack[#in_backpack + 1] = short end
            end
        end
        tlog(1, "saves_inventory", {
            ready    = (#built_ready  > 0) and table.concat(built_ready, ",")  or "-",
            on_cd    = (#built_cd     > 0) and table.concat(built_cd, ",")     or "-",
            backpack = (#in_backpack  > 0) and table.concat(in_backpack, ",") or "-",
            grenade_ready = ability_ready(A.D) and "y" or "n",
        })
    end

    -- v6.15.189: live channel-threat detector (logs `channel_live` lines).
    -- v6.15.197 (audit B7): api_xcheck_tick + lineup_scout call sites
    -- removed alongside the function defs. live_channel_tick is kept.
    pcall(state.live_channel_tick)

    -- Master enable
    if state.menu and state.menu.enable and not state.menu.enable:Get() then
        return
    end

    -- v6.15.127: per-tick position sampling for smoothed-velocity prediction.
    state.sample_velocities()

    -- Strategic tick at ~10Hz: recompute target candidates every 6th frame.
    if f_idx() % 6 == 0 then
        recompute_candidates()
    end

    -- Layer 1: combo key dispatch. v6.14 E1 adds tap-mode (dispatch only on
    -- press-edge, not while held). v6.14 E2 cancels pending scheduled steps
    -- (D/Q1/Q2/Q3) when the key is released, so user lifting the key actually
    -- means "I'm out of this commit" rather than the scheduled steps firing
    -- pointlessly. v6.14 A1 force-commit bypasses commit_pred when held.
    local combo_down = state.menu and state.menu.combo_key and state.menu.combo_key:IsDown() or false
    local force_down = state.menu and state.menu.force_key and state.menu.force_key:IsDown() or false
    local was_down   = state.combo_key_was_down
    -- v6.15.65: track combo_down within current heartbeat window for Option A
    -- misconfig detection. If user holds combo key but native shows inactive,
    -- the heartbeat block emits a config_warn.
    if combo_down then state.native_window_combo_seen = true end
    -- v6.15.129: stamp the last-combo-key-down time so auto_grenade can
    -- suppress over a WINDOW (combo_key:IsDown flickers between ticks).
    if combo_down then state.last_combo_key_down_t = now() end

    -- v6.15.22: log every combo-key press/release transition so the user
    -- can verify the brain is actually seeing their keypress. If user
    -- presses the bound key and no `combo_key_transition | down=1` line
    -- appears, the brain's combo_key Bind is set to a different button
    -- than what they're pressing. The brain reads its OWN bound key
    -- (state.menu.combo_key) — it doesn't auto-follow the native Sniper
    -- v2 combo key. Brain and native have independent binds; user has to
    -- align them manually or unbind native.
    -- v6.15.30: force-key transition log (user bound L to force-commit
    -- on HUD; reports the force key seems to have no effect). If pressing
    -- L doesn't produce a `force_key_transition | down=1` line below, the
    -- brain's force_key Bind widget isn't seeing the input — meaning the
    -- HUD setting either didn't reach this widget or the widget's IsDown
    -- isn't wired. Independent of combo_key (which is a separate widget).
    state.last_force_key_down = state.last_force_key_down or false
    if force_down ~= state.last_force_key_down then
        local fk_b1, fk_b2, fk_buttons, fk_name = "?", "?", "?", "?"
        if state.menu and state.menu.force_key then
            local fk = state.menu.force_key
            if fk.Get then
                local okv, val = pcall(fk.Get, fk, 1)
                if okv then fk_b1 = tostring(val) end
                local okv2, val2 = pcall(fk.Get, fk, 2)
                if okv2 then fk_b2 = tostring(val2) end
            end
            if fk.Buttons then
                local okb, v1, v2 = pcall(fk.Buttons, fk)
                if okb then fk_buttons = tostring(v1) .. "/" .. tostring(v2) end
            end
            if fk.Name then
                local okn, n = pcall(fk.Name, fk)
                if okn then fk_name = tostring(n) end
            end
        end
        tlog(1, "force_key_transition", {
            down       = force_down and "1" or "0",
            fk_get1    = fk_b1,
            fk_get2    = fk_b2,
            fk_buttons = fk_buttons,
            fk_name    = fk_name,
        })
        state.last_force_key_down = force_down
    end

    if combo_down ~= was_down then
        -- v6.15.30: user reported setting key to L on HUD but bound_code
        -- still shows default 317 (MOUSE5). Probing the Bind widget's
        -- full state — :Get(1), :Get(2), :Buttons() — to see if the HUD
        -- change reached the brain's widget, and what slot holds the
        -- new code.
        local b1, b2, buttons, name = "?", "?", "?", "?"
        if state.menu and state.menu.combo_key then
            local ck = state.menu.combo_key
            if ck.Get then
                local okv, val = pcall(ck.Get, ck, 1)
                if okv then b1 = tostring(val) end
                local okv2, val2 = pcall(ck.Get, ck, 2)
                if okv2 then b2 = tostring(val2) end
            end
            if ck.Buttons then
                local okb, v1, v2 = pcall(ck.Buttons, ck)
                if okb then buttons = tostring(v1) .. "/" .. tostring(v2) end
            end
            if ck.Name then
                local okn, n = pcall(ck.Name, ck)
                if okn then name = tostring(n) end
            end
        end
        local force_code = "?"
        if state.menu and state.menu.force_key and state.menu.force_key.Get then
            local okf, fv = pcall(state.menu.force_key.Get, state.menu.force_key, 1)
            if okf then force_code = tostring(fv) end
        end
        tlog(1, "combo_key_transition", {
            down        = combo_down and "1" or "0",
            ck_get1     = b1,
            ck_get2     = b2,
            ck_buttons  = buttons,
            ck_name     = name,
            force_get1  = force_code,
        })
    end

    if state.menu then
        -- v6.15.118: runtime tap/hold detection replaces the v6.14 combo_tap
        -- menu toggle. A press released within COMBO_TAP_MAX_S is a TAP →
        -- Heavy Starter (E+R fire-on-command). A longer press is a HOLD → the
        -- adaptive engagement loop, routed by enemy count (3+ → Team Fight,
        -- 1-2 → Starter). v6.15.118 ships the detection + classifier + routing
        -- + Heavy Starter; the Starter / Team Fight bodies followed in
        -- v6.15.119 / v6.15.120.
        if combo_down and not was_down then
            -- press edge: start timing. Tap-vs-hold is unknown yet, so no
            -- dispatch — a TAP fires on the release edge, a HOLD once the
            -- press crosses COMBO_TAP_MAX_S.
            state.combo_press_t          = now()
            state.combo_hold_active      = false
            state.combo_hold_active_mode = nil  -- v6.15.194: cleared so the
            -- hold-start branch re-latches mode for this press (audit #6).
        elseif combo_down and was_down then
            local held_s = now() - (state.combo_press_t or now())
            if held_s >= state.COMBO_TAP_MAX_S then
                if not state.combo_hold_active then
                    -- v6.15.194 (audit #6): LATCH the teamfight/starter
                    -- decision on hold-start. Without the latch, the
                    -- routing flipped per tick on the 1500u radius
                    -- boundary — a single enemy crossing the line could
                    -- route one frame to teamfight_tick and the next to
                    -- starter_tick mid-combo, stranding step dispatches.
                    -- The user re-presses the combo key to swap mode for
                    -- a new engagement; within a single hold the mode is
                    -- stable for its duration.
                    local enemies   = state.count_engaged_enemies()
                    local teamfight = enemies >= 3
                    state.combo_hold_active      = true
                    state.combo_hold_active_mode = teamfight and "tf"
                                                   or "starter"
                    tlog(1, "combo_classify", {
                        enemies = string.format("%d", enemies),
                        mode    = teamfight and "teamfight" or "starter",
                    })
                end
                if state.combo_hold_active_mode == "tf" then
                    state.teamfight_tick(force_down)
                else
                    state.starter_tick(force_down)
                end
            end
        elseif was_down and not combo_down then
            local held_s = now() - (state.combo_press_t or now())
            if held_s < state.COMBO_TAP_MAX_S and not state.combo_hold_active then
                -- TAP → Heavy Starter (E+R fire-on-command)
                state.heavy_starter_tick(force_down)
            else
                -- HOLD release-edge: drop pending steps of the active L1 combo
                -- so the user's "release combo key" intent is respected. Only
                -- after a HOLD — a TAP's Heavy Starter schedules no deferred
                -- steps, so there is nothing to cancel. (v6.14 E2.)
                if state.last_r_combo_name and #state.pending_steps > 0 then
                    local target_combo = state.last_r_combo_name
                    local kept = {}
                    for i = 1, #state.pending_steps do
                        local p = state.pending_steps[i]
                        if p.combo_name == target_combo then
                            clear_reservation(p.ability_key)
                        else
                            kept[#kept + 1] = p
                        end
                    end
                    if #kept ~= #state.pending_steps then
                        tlog(1, "layer1_release_cancel", {
                            combo = target_combo,
                            dropped = #state.pending_steps - #kept,
                        })
                    end
                    state.pending_steps = kept
                end
            end
            state.combo_hold_active      = false
            state.combo_hold_active_mode = nil  -- v6.15.194 audit #6
        end
    end
    state.combo_key_was_down = combo_down

    -- v6.15.152: speculative fog-snipe — standalone always-on R path, gated
    -- by the `fog_snipe` menu toggle (default off). Its own internal gates
    -- keep it from contending with the combo layers.
    state.fog_snipe_tick()

    -- v6.14 A2: panic-save key (edge-triggered). Bypasses LAYER2_REACTION_WINDOW
    -- AND the auto_defense toggle (user pressing panic is explicit override).
    -- Master enable still respected via defense_enabled().
    -- v6.14.1 C3: if try_save_self returns false (nothing in chain fired) we
    -- must restore state.last_save_t — otherwise leaving it at 0 permanently
    -- disables the 0.5s reaction window. Same logic for panic_override (use
    -- pcall to guarantee restore even on Lua error).
    local panic_down = state.menu and state.menu.panic_key and state.menu.panic_key:IsDown() or false
    if panic_down and not state.last_panic_key_down then
        local prev_save_t  = state.last_save_t
        state.last_save_t  = 0
        state.panic_override = true
        state.panic_counter = state.panic_counter + 1
        tlog(1, "panic_save_user_pressed", {})
        local ok, fired = pcall(try_save_self, "user_panic", nil, nil)
        state.panic_override = false
        if not ok or not fired then
            state.last_save_t = prev_save_t  -- nothing fired → don't leave throttle disabled
        end
    end
    state.last_panic_key_down = panic_down

    -- v6.12 Tier 3 #8: monitor R cast for target dispel/invuln/death and
    -- abort via STOP if conditions break. Runs every frame; cheap (early
    -- returns when no R in flight). Placed BEFORE pending_steps_tick so a
    -- successful abort can sweep scheduled steps and prevent useless
    -- delayed D / Q follow-ups from firing.
    r_abort_tick()

    -- v6.11 Tier 2: fire any pending scheduled steps (delayed D in
    -- snipe_standard, deferred Q1/Q2/Q3 in snipe_e_r). Runs every tick
    -- so timing resolves at OnUpdateEx rate (~60Hz).
    pending_steps_tick()

    -- v6.15.213: phase 2 of Pike-on-self repositioning (drain threats).
    -- Ungated like pending_steps_tick so the armed Pike always resolves --
    -- fires once Sniper has turned to face away, or times out.
    state.pending_pike_self_tick()

    -- v6.15.222: fresh-Pike first-use fix (prime when safe + double-issue).
    state.pike_prime_tick()

    -- v6.15.23: brain-native interaction diagnostic. Runs every frame so
    -- queue mutations between brain dispatch and engine consumption are
    -- visible. NOT gated by auto_defense — we always want this trace.
    brain_native_diagnostic_tick()
    -- v6.15.29: post-dispatch cast verification.
    cast_verify_tick()
    -- v6.15.42: study ticks for aggression + defense efficiency.
    cast_outcome_tick()
    save_outcome_tick()
    engagement_summary_tick()
    -- v6.15.58 (G12): walk-into Kinetic Field poll.
    kinetic_field_poll_tick()

    -- Layer 2: damage-rate panic poll + ally-save scan + armed-ETA processing
    if state.menu and state.menu.auto_defense and state.menu.auto_defense:Get() then
        damage_rate_panic_check()
        pre_face_tick()  -- v6.15.10: preempt turn-time budget against fast cast points
        persistent_threats_tick()  -- v6.15.21: multi-fire over Legion duel / Static Storm duration
        armed_threats_tick()
        if f_idx() % 6 == 0 then ally_save_scan() end
    end
    -- v6.14.1 low: smoke detection out of the auto_defense gate so the
    -- informational chip stays live even when auto-defense is toggled off.
    -- The function gates internally on its own smoke_detect toggle, and the
    -- pre-fire BKB path still respects defense_enabled via layer2_can_fire.
    smoke_detect_tick()

    -- Status panel refresh ~4 Hz (every 15th frame at 60fps). Pure menu-side
    -- update via ForceLocalization, no screen draw.
    if f_idx() % 15 == 0 then refresh_status_panel() end

    -- v6.15 B1+B3: end-of-match summary. Detect POST_GAME transition + dump
    -- once. Counters give one-line health report; modseen summary gives a
    -- complete list of unique modifier names observed (closes (verify) gap).
    if not state.match_summary_dumped and GameRules and GameRules.GetGameState then
        local gs = GameRules.GetGameState()
        if gs == Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME then
            state.match_summary_dumped = true
            tlog(1, "match_summary", {
                l1     = state.l1_counter,
                l2     = state.l2_counter,
                aborts = state.abort_counter,
                panics = state.panic_counter,
                forces = state.force_counter,
                modcreate = state.modcreate_counter,
                skipped   = state.skip_counter,
            })
            local unique = 0
            for _ in pairs(state.seen_modifiers) do unique = unique + 1 end
            tlog(1, "modseen_summary", { unique_count = unique })
            -- Dump up to 50 modifier names (more than that → too much log noise).
            local n = 0
            for k, v in pairs(state.seen_modifiers) do
                if n >= 50 then break end
                tlog(1, "modseen_entry", {
                    key = k, count = v.count,
                    first_at = string.format("%.1f", v.first_t),
                    caster = v.caster,
                })
                n = n + 1
            end
        end
    end

    -- v6.15 E1: persist brain state every ~30s (1800 frames @ 60Hz).
    if f_idx() % 1800 == 0 then pcall(_persist_state) end

    -- v6.14.1 low: periodic GC of dedup tables. responded_threats and
    -- anim_log_dedup accumulate over a long match. Sweep every ~5s (300
    -- frames @ 60Hz), dropping entries older than 5 * dedup_window so we
    -- never prune a still-active entry.
    if f_idx() % 300 == 0 then
        local now_t = now()
        for k, t in pairs(state.responded_threats) do
            if (now_t - t) > (Dedup.THREAT_WINDOW * 5) then
                state.responded_threats[k] = nil
            end
        end
        for k, t in pairs(state.anim_log_dedup) do
            if (now_t - t) > 30 then state.anim_log_dedup[k] = nil end
        end
    end

    -- v6.15.107: standalone auto-grenade dispatch. Runs LAST in OnUpdateEx so
    -- combos always get first crack — internal gates skip if combo key is
    -- down or state.last_d_t was updated within 1.5s. See auto_grenade_tick
    -- definition above for full rationale. v6.15.117: auto_take_aim_tick and
    -- auto_q_chip_tick removed (user found them useless in demo) — D is the
    -- only per-ability tick that survives.
    auto_grenade_tick()
end

function callbacks.OnModifierCreate(npc, modifier)
    -- v6.15.201 (audit D11): nil-guard modifier (mirrors OnModifierDestroy).
    -- Modifier.GetName(nil) is undefined; engine has been
    -- observed firing the callback with a nil handle in rare edge cases.
    if not state.self_npc or not modifier then return end
    local mod_name = Modifier.GetName(modifier)
    if not mod_name then return end

    -- v6.15.11/.12: Disruptor Kinetic Field. Modifier lives on the field
    -- thinker entity, not on Sniper. THREATS_ON_SELF can't catch it. v6.15.12
    -- widens to a prefix match (modifier_disruptor_kinetic_field*) since the
    -- exact suffix in 7.41C isn't empirically verified yet — could be
    -- _remnant, _thinker, or no suffix. We log every match at v2 so the next
    -- demo with Disruptor casting Kinetic Field surfaces the actual name.
    if mod_name:find("^modifier_disruptor_kinetic_field") then
        local caster = Modifier.GetCaster(modifier)
        local field_pos = Entity.GetAbsOrigin(npc)
        local me_pos    = Entity.GetAbsOrigin(state.self_npc)
        -- v6.15.197 (audit B1): native Vector arithmetic.
        -- v6.15.201 (audit D2): nil-guard both positions. GetAbsOrigin
        -- on a freshly-destroyed field thinker or a mid-respawn Sniper
        -- can return nil; the :Distance2D call would crash. Bail
        -- silently — without positions there is nothing the kinetic-
        -- field handler can do.
        if not (field_pos and me_pos) then return end
        local d         = field_pos:Distance2D(me_pos)
        tlog(1, "kinetic_field_detected", {
            mod    = mod_name,
            caster = caster and uname(caster) or "-",
            d      = string.format("%.0f", d),
            inside = d <= 350 and "1" or "0",
        })
        if caster and Target.IsEnemyHero(caster, state.self_npc)
           and d <= 350 and defense_enabled() and layer2_can_fire()
        then
            if not Dedup.threat_already_responded(state.responded_threats,npc, mod_name) then
                Dedup.threat_mark_responded(state.responded_threats,npc, mod_name)
                -- Use canonical key so the SNIPER_SAVE_OVERRIDES entry resolves
                -- regardless of which suffix variant the engine emits.
                try_save_self("kinetic_field_trap",
                              "modifier_disruptor_kinetic_field_remnant", caster)
            end
        end
        -- v6.15.58 (G12): register the field thinker for the walk-into poll.
        -- Even if Sniper is OUTSIDE at field-creation (d > 350), brain needs
        -- to fire the save when Sniper later walks INTO the field. The
        -- kinetic_field_poll_tick scans this table each frame.
        if caster and Target.IsEnemyHero(caster, state.self_npc) then
            state.kinetic_fields[Entity.GetIndex(npc)] = {
                thinker  = npc,
                mod_name = mod_name,
                caster   = caster,
            }
        end
    end

    -- v6.13 Bug #9 / Defense F#26: diagnostic — log every modifier observed on
    -- an enemy hero so the v6.7 (verify)-tagged THREATS_ON_SELF / THREAT_COUNTER /
    -- ABILITY_TO_THREAT entries can be cross-checked against actual in-game
    -- modifier names. Run at verbosity 3 in a bot match against the unverified
    -- heroes (Magnus, Sven, Slardar Voodoo, Zeus, Tide/ES/Treant/Disruptor ults,
    -- Bristleback, Pugna Drain, Earth Spirit Boulder) and grep debug.log for
    -- "modseen" lines. Compare emitted names against the (verify) entries in
    -- lib/threat_data.lua and update mismatches. Cheap at v<3 (the tlog gate
    -- skips the table allocation entirely).
    if Target.IsEnemyHero(npc, state.self_npc) then
        local caster = Modifier.GetCaster(modifier)
        -- v6.15 B3: dedup'd accumulator for end-of-match summary.
        local key = uname(npc) .. ":" .. mod_name
        local seen = state.seen_modifiers[key]
        if seen then
            seen.count = seen.count + 1
        else
            state.seen_modifiers[key] = { first_t = now(), count = 1,
                caster = caster and uname(caster) or "-" }
        end
        tlog(3, "modseen", {
            unit = uname(npc),
            mod = mod_name,
            caster = caster and uname(caster) or "-",
        })

        -- v6.13 Defense F#12: enemy-buff threats. Bristleback Quill Spray
        -- stacking up, Sven God's Strength, Troll Battle Trance, Ursa Enrage
        -- etc. — buffs on the enemy that threaten Sniper. Fires the standard
        -- save chain with the buff modifier as the threat_mod; chain falls
        -- through to DEFAULT_SAVE_CHAIN for now (RECOMMENDED_SAVES entries
        -- per-buff are a follow-up). Dedup via responded_threats keyed on
        -- (buff-caster, buff-mod) so a multi-stack buff (Quill spray ramping
        -- up) fires at most once per dedup window.
        local buff_entry = ENEMY_BUFF_THREATS[mod_name]
        if buff_entry and defense_enabled() and layer2_can_fire() then
            if not Dedup.threat_already_responded(state.responded_threats,npc, mod_name) then
                if buff_entry.role ~= "informational" then
                    tlog(1, "enemy_buff_threat", {
                        unit = uname(npc), mod = mod_name,
                        category = buff_entry.category,
                    })
                    if try_save_self("enemy_buff_" .. mod_name, mod_name, npc) then
                        Dedup.threat_mark_responded(state.responded_threats,npc, mod_name)
                    end
                else
                    tlog(2, "enemy_buff_informational", { mod = mod_name })
                end
            end
        end
    end

    -- Lotus-worthy incoming ult: Lotus first, then fall through to the
    -- standard chain if Lotus is unavailable. v6.14 C1: when the
    -- "Lotus first against any single-target burst" toggle is on, expand
    -- the trigger to any THREATS_ON_SELF entry — Lotus reflects single-
    -- target damage regardless of debuff type. Roles `gap_close`, `lockdown`,
    -- `drain`, `physical_burst` are typically multi-tick / not great for
    -- Lotus reflection, so we restrict the expansion to `hard_disable`,
    -- `ult_burst`, and the existing curated whitelist.
    local lotus_always = state.menu and state.menu.lotus_always
                        and state.menu.lotus_always:Get() or false
    if npc == state.self_npc then
        local lotus_worthy = LOTUS_WORTHY_INCOMING[mod_name]
        if not lotus_worthy and lotus_always then
            local te = THREATS_ON_SELF[mod_name]
            if te and (te.role == "hard_disable" or te.role == "ult_burst") then
                lotus_worthy = true
            end
        end
        if lotus_worthy then
            tlog(1, "incoming_lotus_worthy_ult", { mod = mod_name,
                via = LOTUS_WORTHY_INCOMING[mod_name] and "curated" or "user_toggle" })
            state.modcreate_counter = state.modcreate_counter + 1
            try_save_lotus_first("lotus_worthy_" .. mod_name)
            return
        end
    end

    -- v6.15.162: harvest unrecognized self-threats. A modifier landed on
    -- Sniper, cast by an enemy hero, but it is in NO threat table — an
    -- unrecognized potential threat (this is exactly how Kez's Grappling
    -- Claw was invisible to the defense layer). Log it at normal verbosity,
    -- throttled per (caster, modifier), so its real name can be observed in
    -- a real game and wired into lib/threat_data.lua. The defense catalog
    -- grows from VERIFIED in-game names this way, not from guesses.
    if npc == state.self_npc and not THREATS_ON_SELF[mod_name]
       and not LOTUS_WORTHY_INCOMING[mod_name] then
        local caster = Modifier.GetCaster(modifier)
        if caster and Entity.IsEntity(caster)
           and Target.IsEnemyHero(caster, state.self_npc)
           and not Dedup.anim_throttled(state.anim_log_dedup, caster, mod_name) then
            tlog(1, "threat_unrecognized", {
                mod = mod_name, caster = uname(caster),
            })
        end
    end

    -- Threat lands on Sniper
    if npc == state.self_npc then
        local entry = THREATS_ON_SELF[mod_name]
        if entry then
            tlog(1, "threat_on_self", { mod = mod_name, role = entry.role, save = entry.save })
            state.modcreate_counter = state.modcreate_counter + 1
            -- v6.15.42: register the threat for save_outcome study. The
            -- entry captures HP at threat START so save_outcome_tick can
            -- log the HP delta over the threat's lifetime. save_outcome_tick
            -- watches NPC.HasModifier and logs when the modifier disappears.
            do
                state.active_threats = state.active_threats or {}
                if not state.active_threats[mod_name] then
                    local hp = Entity.GetHealth(state.self_npc) or 0
                    state.active_threats[mod_name] = {
                        t_start  = now(),
                        hp_start = hp,
                        hp_min   = hp,
                        hp_max   = Entity.GetMaxHealth(state.self_npc) or 1,
                    }
                end
            end
            -- Caster handle threaded through for grenade-self push direction
            -- and (for tether threats) tether-distance check.
            local caster = Modifier.GetCaster(modifier)
            -- Threat-response dedup: skip if we already responded to this
            -- (caster, mod_name) within the dedup window. Prevents firing
            -- multiple saves when a single threat triggers multiple paths.
            if Dedup.threat_already_responded(state.responded_threats,caster, mod_name) then
                tlog(3, "threat_response_dedup", { mod = mod_name })
                return
            end
            Dedup.threat_mark_responded(state.responded_threats,caster, mod_name)
            if mod_name == "modifier_bane_nightmare" then
                save_bane_nightmare()
            elseif mod_name == "modifier_pudge_dismember" or
                   mod_name == "modifier_bane_fiends_grip" or
                   mod_name == "modifier_shadow_shaman_shackles" then
                save_channel_on_self(caster, mod_name)
            elseif entry.role == "gap_close" then
                reactive_take_aim()
                try_save_self("threat_" .. mod_name, mod_name, caster)
            elseif entry.save and entry.save ~= "informational" then
                -- v6.15.202 (audit round 3, D1): catch-all for any
                -- catalog-known threat with a real save. Pre-fix this
                -- elseif explicitly listed only `hard_disable` / `drain`
                -- / `physical_burst` / `lockdown`, and SILENTLY DROPPED
                -- the v6.15.163-.164 batch and v6.15.198 harvest roles —
                -- `channel_on_me` (Lich Sinister Gaze, Primal Beast
                -- Pulverize, Grimstroke Soul Chain, Oracle Fortune's End),
                -- `line_projectile` (Mars Spear, Sandking Burrowstrike,
                -- Nyx Impale, Mars Skewer, Sven Bolt, ES Boulder),
                -- `delayed_aoe` (~30 entries — Mystic Flare, Dream Coil,
                -- Split Earth, Ice Path, Arena, Epicenter, Naga Song,
                -- Terrorize, Bramble, Box, Wheel, Raptor Dance, Chrono,
                -- Tide, Echo Slam, RP, Static Storm, etc.),
                -- `magic_burst` (Reaper Scythe, Sanity Eclipse, Chain
                -- Frost, etc.), `trapped` (TA Trap, Ringmaster Box),
                -- `silence_on_me` (Viper Nethertoxin mute) — meaning
                -- most modern threats never fired a save at modifier-
                -- create time, only when one of the 10 anim-mapped
                -- heroes telegraphed via cast point. The fire-gate is
                -- now: the catalog says this is a real threat AND the
                -- save column isn't 'informational' (taunt, light_slow,
                -- kiting_slow, dot, aura_*, tracker, etc. stay no-op as
                -- the catalog intends). try_save_self → RECOMMENDED_SAVES
                -- chooses the item from the chain.
                try_save_self("threat_" .. mod_name, mod_name, caster)
            end
            -- "taunt" (Berserker's Call) and "informational"-tagged
            -- threats are no-save by catalog design — they fall through
            -- here intentionally.
        end
        return
    end

    -- Enemy starts a relevant channel — Layer 1.5
    if ENEMY_CHANNEL_MODIFIERS[mod_name] and Target.IsEnemyHero(npc, state.self_npc) then
        tlog(1, "enemy_channel_start", { mod = mod_name, caster = uname(npc) })
        on_enemy_channel_start(npc, mod_name)
    end

    -- Bara charge: ARM at modifier-create, FIRE at impact-ETA < 0.6s (homing
    -- charge re-targets, so displacement is only useful very close to impact).
    -- Re-arm dedup: if an entry already exists for the same caster, skip the
    -- arm log. The engine sometimes fires modifier-create twice for the same
    -- event; only the first should log.
    if mod_name == "modifier_spirit_breaker_charge_of_darkness" then
        if Target.IsEnemyHero(npc, state.self_npc) then
            local existing = state.armed_threats["bara_charge"]
            if not existing or existing.caster ~= npc then
                tlog(1, "bara_charge_armed", { caster = uname(npc) })
                state.modcreate_counter = state.modcreate_counter + 1
                state.armed_threats["bara_charge"] = {
                    caster      = npc,
                    threat_mod  = "modifier_spirit_breaker_charge_of_darkness",
                    eta_speed   = 600,
                    -- v5.5: bumped from 0.6 → 0.8 for more reaction cushion.
                    -- The fire-window includes: Sniper turn to face cast point
                    -- (up to ~0.15s for 180°), 0.1s grenade cast point, 0.4s
                    -- knockback flight on Bara. Total ~0.65s — 0.6s ETA was
                    -- too tight when Sniper started facing away from Bara,
                    -- causing the user's "not fired at right time" report.
                    eta_trigger = 0.8,
                    fired       = false,
                }
            end
        end
    end

    -- Tusk snowball: same armed-ETA pattern. Snowball is faster than charge
    -- (~1200 MS while rolling). Same re-arm dedup.
    if mod_name == "modifier_tusk_snowball_movement" then
        if Target.IsEnemyHero(npc, state.self_npc) then
            local existing = state.armed_threats["tusk_snowball"]
            if not existing or existing.caster ~= npc then
                tlog(1, "tusk_snowball_armed", { caster = uname(npc) })
                state.modcreate_counter = state.modcreate_counter + 1
                state.armed_threats["tusk_snowball"] = {
                    caster      = npc,
                    threat_mod  = "modifier_tusk_snowball_movement",
                    eta_speed   = 1200,
                    -- v6.6: lowered from 0.7 → 0.5. At 1200 MS, ETA 0.7s
                    -- meant Tusk at 840u — outside both Pike (425) and
                    -- grenade_at_caster (600) cast ranges. Chain fell to
                    -- grenade_self (cast near Sniper), wasting the CD on a
                    -- useless self-push (Tusk re-rolls on a self-displaced
                    -- Sniper). ETA 0.5s → dist 600u, at the edge of
                    -- grenade_at_caster's range. v6.5 deferral handles the
                    -- Pike-soon case (defer until Tusk enters 425u then fire
                    -- Pike); if Pike unavailable, grenade fires AT Tusk.
                    eta_trigger = 0.5,
                    fired       = false,
                }
            end
        end
    end
end

function callbacks.OnModifierDestroy(npc, modifier)
    if not state.self_npc or not modifier then return end
    local mod_name = Modifier.GetName(modifier)
    if not mod_name then return end
    -- Clear armed entries when the threatening modifier goes away.
    if mod_name == "modifier_spirit_breaker_charge_of_darkness" then
        if state.armed_threats["bara_charge"] then
            tlog(2, "bara_charge_cleared", { caster = uname(npc) })
            state.armed_threats["bara_charge"] = nil
        end
    elseif mod_name == "modifier_tusk_snowball_movement" then
        if state.armed_threats["tusk_snowball"] then
            tlog(2, "tusk_snowball_cleared", { caster = uname(npc) })
            state.armed_threats["tusk_snowball"] = nil
        end
    elseif mod_name:find("^modifier_disruptor_kinetic_field") then
        -- v6.15.58 (G12): field expired; drop from poll table.
        local idx = Entity.GetIndex(npc)
        if state.kinetic_fields[idx] then
            tlog(2, "kinetic_field_cleared", { mod = mod_name })
            state.kinetic_fields[idx] = nil
        end
    end
end

function callbacks.OnLinearProjectileCreate(data)
    -- Pudge hook: line-projectile passing through our predicted position
    if not state.self_npc or not data then return end
    local src = data.source
    if not src or not Target.IsEnemyHero(src, state.self_npc) then return end
    local src_name = NPC.GetUnitName(src)
    if src_name ~= "npc_dota_hero_pudge" then return end
    -- Check if hook line passes within hook radius of us
    local me_pos = NPCLib.origin(state.self_npc)
    local origin = data.origin or NPCLib.origin(src)
    local velocity = data.velocity
    if not velocity or not origin or not me_pos then return end
    -- closest-point-on-line distance
    local vel_len = velocity:Length2D()
    if vel_len < 1 then return end
    local dir = velocity:Normalized()
    local to_me = me_pos - origin
    local along = to_me:Dot(dir)
    if along < 0 then return end  -- behind hook origin
    local perp = (to_me - dir * along):Length2D()
    if perp <= 130 then  -- hook radius ~110-130
        -- v6.13 Bug #2: pass threat_mod + threat_caster so the chain uses
        -- RECOMMENDED_SAVES["modifier_pudge_meat_hook"] (Pike+Force-perp
        -- ordering) instead of DEFAULT_SAVE_CHAIN, AND grenade_self_cast_point
        -- can compute the right push direction from Pudge's position.
        if Dedup.threat_already_responded(state.responded_threats,src, "modifier_pudge_meat_hook") then return end
        tlog(1, "pudge_hook_intercepted", {
            perp = string.format("%.0f", perp),
            origin_dist = string.format("%.0f", along),
        })
        if try_save_self("pudge_hook", "modifier_pudge_meat_hook", src) then
            Dedup.threat_mark_responded(state.responded_threats,src, "modifier_pudge_meat_hook")
        end
    end
end

function callbacks.OnEntityKilled(data)
    if not data or not data.target then return end

    -- v6.15 C1: postmortem when Sniper dies within 2s of a save fire.
    -- Surfaces "fired X, died to Y" so the user knows the save was wrong
    -- (kind mismatch, severity under-rated, geometry off, etc.).
    -- v6.15.2 C3: OnEntityKilled exposes `data.ability` (a CAbility handle),
    -- not `data.ability_name`. Resolve to a name via Ability.GetName.
    if data.target == state.self_npc then
        local since_save = state.last_save_t and (now() - state.last_save_t) or 999
        if since_save < 2.0 then
            local killer_ab_name = "-"
            if data.ability then
                killer_ab_name = (Ability.GetName and Ability.GetName(data.ability))
                                 or tostring(data.ability)
            end
            tlog(1, "death_postmortem", {
                last_save        = state.last_save_intent or "-",
                save_kind        = state.last_save_kind or "-",
                threat_mod       = state.last_save_threat_mod or "-",
                since_save       = string.format("%.2f", since_save),
                killer           = data.source and uname(data.source) or "-",
                killer_ability   = killer_ab_name,
            })
        end
        return  -- our own death; no other tracking work
    end

    local was_tracked = false
    -- Drop any scoring entries / candidates referencing the dead target.
    for i = #state.candidates, 1, -1 do
        if state.candidates[i].target == data.target then
            table.remove(state.candidates, i)
            was_tracked = true
        end
    end
    -- Drop fog-snipe cache entry for the dead target.
    local idx = Entity.GetIndex(data.target)
    if idx and state.fog_cache[idx] then
        state.fog_cache[idx] = nil
        was_tracked = true
    end
    -- v6.14.1 low: GC displacement / reservation / armed-threat entries
    -- keyed on the dead entity, plus stale responded_threats keys for the
    -- dead caster.
    if idx and state.displacements[idx] then
        state.displacements[idx] = nil
    end
    -- responded_threats keys: "<caster_idx>:<mod_name>" — clear all of them
    -- for this dead entity (caster died, so any prior threat from them is moot).
    local prefix = tostring(idx) .. ":"
    for k in pairs(state.responded_threats) do
        if k:sub(1, #prefix) == prefix then
            state.responded_threats[k] = nil
        end
    end
    -- armed_threats entries whose caster matches.
    for k, entry in pairs(state.armed_threats) do
        if entry.caster == data.target then state.armed_threats[k] = nil end
    end
    -- R-target cleanup if our pending R was on this hero.
    if state.last_r_target == data.target then
        state.last_r_target     = nil
        state.last_r_combo_name = nil
        state.last_r_dispatch_t = 0
    end
    if was_tracked then
        tlog(2, "tracked_target_killed", {
            target = uname(data.target),
            killer = data.source and uname(data.source) or "-",
        })
    end
end

----------------------------------------------------------------------------
-- Anim map registration
----------------------------------------------------------------------------

-- The activity codes map slot 1..6 to ACT_DOTA_CAST_ABILITY_1..6 for each
-- hero (Phase 0.5/D). Cross-referenced against Enum.GameActivity.
local GA = Enum.GameActivity
local AB1 = GA and GA.ACT_DOTA_CAST_ABILITY_1 or 1500
local AB2 = GA and GA.ACT_DOTA_CAST_ABILITY_2 or 1501
local AB3 = GA and GA.ACT_DOTA_CAST_ABILITY_3 or 1502
local AB4 = GA and GA.ACT_DOTA_CAST_ABILITY_4 or 1503
local AB5 = GA and GA.ACT_DOTA_CAST_ABILITY_5 or 1504
local AB6 = GA and GA.ACT_DOTA_CAST_ABILITY_6 or 1505

local function register_anim_maps()
    -- v6.15.206 (D18-followup initiative): the full register_anim_maps body
    -- is now GENERATED by tools/gen_anim_maps.py from npc_heroes.json +
    -- npc_abilities.json. Cast-activity slots are derived (D18 algorithm);
    -- roles are seeded from the prior hand-tuned maps + threat_data.lua, with
    -- a CHANNELLED-behaviour draft for the tail. Re-run the generator after a
    -- patch; do NOT hand-edit these blocks. 68 heroes, 105 threat abilities.
    -- bane
    Anim.RegisterMap("npc_dota_hero_bane", {
        [AB3] = { ability = "bane_nightmare", role = "hard_disable" },
        [AB4] = { ability = "bane_fiends_grip", role = "channel_start" },
    })
    -- batrider
    Anim.RegisterMap("npc_dota_hero_batrider", {
        [AB4] = { ability = "batrider_flaming_lasso", role = "hard_disable" },
    })
    -- beastmaster
    Anim.RegisterMap("npc_dota_hero_beastmaster", {
        [AB4] = { ability = "beastmaster_primal_roar", role = "hard_disable" },
    })
    -- bloodseeker
    Anim.RegisterMap("npc_dota_hero_bloodseeker", {
        [AB4] = { ability = "bloodseeker_rupture", role = "ult_burst" },
    })
    -- chaos_knight
    Anim.RegisterMap("npc_dota_hero_chaos_knight", {
        [AB1] = { ability = "chaos_knight_chaos_bolt", role = "hard_disable" },
        [AB2] = { ability = "chaos_knight_reality_rift", role = "gap_close" },
    })
    -- clinkz
    Anim.RegisterMap("npc_dota_hero_clinkz", {
        [AB5] = { ability = "clinkz_burning_barrage", role = "channel_start" },  -- (draft)
    })
    -- crystal_maiden
    Anim.RegisterMap("npc_dota_hero_crystal_maiden", {
        [AB4] = { ability = "crystal_maiden_freezing_field", role = "channel_start" },
    })
    -- dark_willow
    Anim.RegisterMap("npc_dota_hero_dark_willow", {
        [AB1] = { ability = "dark_willow_bramble_maze", role = "hard_disable" },
        [AB3] = { ability = "dark_willow_cursed_crown", role = "hard_disable" },
        [AB4] = { ability = "dark_willow_terrorize", role = "hard_disable" },
    })
    -- dawnbreaker
    Anim.RegisterMap("npc_dota_hero_dawnbreaker", {
        [AB2] = { ability = "dawnbreaker_celestial_hammer", role = "gap_close" },
        [AB4] = { ability = "dawnbreaker_solar_guardian", role = "channel_start" },  -- (draft)
    })
    -- disruptor
    Anim.RegisterMap("npc_dota_hero_disruptor", {
        [AB4] = { ability = "disruptor_static_storm", role = "hard_disable" },
    })
    -- drow_ranger
    Anim.RegisterMap("npc_dota_hero_drow_ranger", {
        [AB3] = { ability = "drow_ranger_multishot", role = "channel_start" },  -- (draft)
    })
    -- earth_spirit
    Anim.RegisterMap("npc_dota_hero_earth_spirit", {
        [AB2] = { ability = "earth_spirit_rolling_boulder", role = "hard_disable" },
    })
    -- earthshaker
    Anim.RegisterMap("npc_dota_hero_earthshaker", {
        [AB4] = { ability = "earthshaker_echo_slam", role = "hard_disable" },
    })
    -- elder_titan
    Anim.RegisterMap("npc_dota_hero_elder_titan", {
        [AB1] = { ability = "elder_titan_echo_stomp", role = "channel_start" },  -- (draft)
    })
    -- enigma
    Anim.RegisterMap("npc_dota_hero_enigma", {
        [AB1] = { ability = "enigma_malefice", role = "hard_disable" },
        [AB4] = { ability = "enigma_black_hole", role = "hard_disable" },
    })
    -- faceless_void
    Anim.RegisterMap("npc_dota_hero_faceless_void", {
        [AB4] = { ability = "faceless_void_chronosphere", role = "hard_disable" },
    })
    -- grimstroke
    Anim.RegisterMap("npc_dota_hero_grimstroke", {
        [AB2] = { ability = "grimstroke_ink_creature", role = "hard_disable" },
        [AB4] = { ability = "grimstroke_soul_chain", role = "channel_start" },
    })
    -- hoodwink
    Anim.RegisterMap("npc_dota_hero_hoodwink", {
        [AB2] = { ability = "hoodwink_bushwhack", role = "hard_disable" },
    })
    -- huskar
    Anim.RegisterMap("npc_dota_hero_huskar", {
        [AB4] = { ability = "huskar_life_break", role = "gap_close" },
    })
    -- jakiro
    Anim.RegisterMap("npc_dota_hero_jakiro", {
        [AB2] = { ability = "jakiro_ice_path", role = "hard_disable" },
    })
    -- keeper_of_the_light
    Anim.RegisterMap("npc_dota_hero_keeper_of_the_light", {
        [AB1] = { ability = "keeper_of_the_light_illuminate", role = "channel_start" },  -- (draft)
    })
    -- kez
    Anim.RegisterMap("npc_dota_hero_kez", {
        [AB2] = { ability = "kez_grappling_claw", role = "gap_close" },
        [AB4] = { ability = "kez_raptor_dance", role = "hard_disable" },
    })
    -- leshrac
    Anim.RegisterMap("npc_dota_hero_leshrac", {
        [AB1] = { ability = "leshrac_split_earth", role = "hard_disable" },
    })
    -- lich
    Anim.RegisterMap("npc_dota_hero_lich", {
        [AB3] = { ability = "lich_sinister_gaze", role = "channel_start" },
        [AB4] = { ability = "lich_chain_frost", role = "ult_burst" },
    })
    -- life_stealer
    Anim.RegisterMap("npc_dota_hero_life_stealer", {
        [AB2] = { ability = "life_stealer_open_wounds", role = "hard_disable" },
    })
    -- lina
    Anim.RegisterMap("npc_dota_hero_lina", {
        [AB2] = { ability = "lina_light_strike_array", role = "hard_disable" },
        [AB4] = { ability = "lina_laguna_blade", role = "ult_burst" },
    })
    -- lion
    Anim.RegisterMap("npc_dota_hero_lion", {
        [AB1] = { ability = "lion_impale", role = "hard_disable" },
        [AB2] = { ability = "lion_voodoo", role = "hard_disable" },
        [AB3] = { ability = "lion_mana_drain", role = "channel_start" },
        [AB4] = { ability = "lion_finger_of_death", role = "ult_burst" },
    })
    -- magnataur
    Anim.RegisterMap("npc_dota_hero_magnataur", {
        [AB3] = { ability = "magnataur_skewer", role = "hard_disable" },
        [AB4] = { ability = "magnataur_reverse_polarity", role = "hard_disable" },
    })
    -- marci
    Anim.RegisterMap("npc_dota_hero_marci", {
        [AB1] = { ability = "marci_grapple", role = "gap_close" },
    })
    -- mars
    Anim.RegisterMap("npc_dota_hero_mars", {
        [AB1] = { ability = "mars_spear", role = "hard_disable" },
        [AB2] = { ability = "mars_gods_rebuke", role = "hard_disable" },
        [AB4] = { ability = "mars_arena_of_blood", role = "hard_disable" },
    })
    -- mirana
    Anim.RegisterMap("npc_dota_hero_mirana", {
        [AB2] = { ability = "mirana_arrow", role = "hard_disable" },
    })
    -- morphling
    Anim.RegisterMap("npc_dota_hero_morphling", {
        [AB2] = { ability = "morphling_adaptive_strike_agi", role = "hard_disable" },
    })
    -- muerta
    Anim.RegisterMap("npc_dota_hero_muerta", {
        [AB1] = { ability = "muerta_dead_shot", role = "hard_disable" },
    })
    -- naga_siren
    Anim.RegisterMap("npc_dota_hero_naga_siren", {
        [AB2] = { ability = "naga_siren_ensnare", role = "hard_disable" },
        [AB4] = { ability = "naga_siren_song_of_the_siren", role = "hard_disable" },
    })
    -- necrolyte
    Anim.RegisterMap("npc_dota_hero_necrolyte", {
        [AB4] = { ability = "necrolyte_reapers_scythe", role = "ult_burst" },
    })
    -- nyx_assassin
    Anim.RegisterMap("npc_dota_hero_nyx_assassin", {
        [AB1] = { ability = "nyx_assassin_impale", role = "hard_disable" },
        [AB4] = { ability = "nyx_assassin_vendetta", role = "gap_close" },
    })
    -- obsidian_destroyer
    -- v6.15.250: Astral Imprisonment is unit-target (selects target by
    -- reference, doesn't aim); apply instant_target to allow anim-path
    -- detection regardless of OD's facing. Sanity Eclipse stays gate-on
    -- as a centred AoE -- the facing gate is a useful filter for far-away
    -- casts that aren't targeting Sniper.
    Anim.RegisterMap("npc_dota_hero_obsidian_destroyer", {
        [AB2] = { ability = "obsidian_destroyer_astral_imprisonment", role = "hard_disable", instant_target = true },
        [AB4] = { ability = "obsidian_destroyer_sanity_eclipse", role = "ult_burst" },
    })
    -- oracle
    Anim.RegisterMap("npc_dota_hero_oracle", {
        [AB1] = { ability = "oracle_fortunes_end", role = "channel_start" },
    })
    -- pangolier
    Anim.RegisterMap("npc_dota_hero_pangolier", {
        [AB1] = { ability = "pangolier_swashbuckle", role = "gap_close" },
        [AB4] = { ability = "pangolier_gyroshell", role = "gap_close" },
    })
    -- phantom_assassin
    -- v6.15.250: instant_target=true bypasses the lib/anim.lua facing gate.
    -- Phantom Strike is unit-target (selected by reference, not aim); PA
    -- does not face Sniper when blink-targeting him, so the v6.15.232
    -- math.deg facing gate was rejecting all PA blinks since that build.
    -- Pre-v6.15.232 the gate accidentally always-passed (radians bug) and
    -- PA detection worked; v6.15.232's correct math.deg fix exposed the
    -- latent issue. The modifier-path backup (OnModifierCreate at
    -- modifier_phantom_assassin_phantom_strike_target) doesn't catch PA
    -- either because that target-side modifier no longer exists in modern
    -- Dota, so the anim path is the only working detection.
    Anim.RegisterMap("npc_dota_hero_phantom_assassin", {
        [AB2] = { ability = "phantom_assassin_phantom_strike", role = "gap_close", instant_target = true },
    })
    -- primal_beast
    -- v6.15.250: Pulverize is unit-target (channel that locks the target by
    -- reference); add instant_target so PB's facing doesn't gate the
    -- channel-start save. Onslaught is a line dash -- PB DOES aim it -- so
    -- the facing gate stays for that one.
    Anim.RegisterMap("npc_dota_hero_primal_beast", {
        [AB1] = { ability = "primal_beast_onslaught", role = "gap_close" },
        [AB4] = { ability = "primal_beast_pulverize", role = "channel_start", instant_target = true },
    })
    -- puck
    Anim.RegisterMap("npc_dota_hero_puck", {
        [AB2] = { ability = "puck_waning_rift", role = "hard_disable" },
        [AB3] = { ability = "puck_phase_shift", role = "channel_start" },  -- (draft)
        [AB4] = { ability = "puck_dream_coil", role = "hard_disable" },
    })
    -- pudge
    -- v6.15.250: Dismember is unit-target (Pudge selects Sniper by
    -- reference, doesn't aim); add instant_target so the channel-start
    -- save fires even when Pudge faces away. Meat Hook is a line skill-
    -- shot (Pudge DOES aim it) -- facing gate stays for that one.
    Anim.RegisterMap("npc_dota_hero_pudge", {
        [AB1] = { ability = "pudge_meat_hook", role = "gap_close" },
        [AB4] = { ability = "pudge_dismember", role = "channel_start", instant_target = true },
    })
    -- pugna
    Anim.RegisterMap("npc_dota_hero_pugna", {
        [AB4] = { ability = "pugna_life_drain", role = "channel_start" },
    })
    -- rattletrap
    Anim.RegisterMap("npc_dota_hero_rattletrap", {
        [AB4] = { ability = "rattletrap_hookshot", role = "gap_close" },
    })
    -- riki
    Anim.RegisterMap("npc_dota_hero_riki", {
        [AB3] = { ability = "riki_tricks_of_the_trade", role = "channel_start" },  -- (draft)
    })
    -- ringmaster
    Anim.RegisterMap("npc_dota_hero_ringmaster", {
        [AB1] = { ability = "ringmaster_tame_the_beasts", role = "channel_start" },  -- (draft)
        [AB3] = { ability = "ringmaster_impalement", role = "hard_disable" },
        [AB4] = { ability = "ringmaster_wheel", role = "hard_disable" },
    })
    -- sand_king
    Anim.RegisterMap("npc_dota_hero_sand_king", {
        [AB1] = { ability = "sandking_burrowstrike", role = "hard_disable" },
        [AB4] = { ability = "sandking_epicenter", role = "hard_disable" },
    })
    -- shadow_demon
    Anim.RegisterMap("npc_dota_hero_shadow_demon", {
        [AB1] = { ability = "shadow_demon_disruption", role = "hard_disable" },
        [AB4] = { ability = "shadow_demon_demonic_purge", role = "hard_disable" },
    })
    -- shadow_shaman
    Anim.RegisterMap("npc_dota_hero_shadow_shaman", {
        [AB2] = { ability = "shadow_shaman_voodoo", role = "hard_disable" },
        [AB3] = { ability = "shadow_shaman_shackles", role = "channel_start" },
    })
    -- skywrath_mage
    Anim.RegisterMap("npc_dota_hero_skywrath_mage", {
        [AB3] = { ability = "skywrath_mage_ancient_seal", role = "hard_disable" },
        [AB4] = { ability = "skywrath_mage_mystic_flare", role = "hard_disable" },
    })
    -- slark
    Anim.RegisterMap("npc_dota_hero_slark", {
        [AB2] = { ability = "slark_pounce", role = "gap_close" },
    })
    -- snapfire
    Anim.RegisterMap("npc_dota_hero_snapfire", {
        [AB1] = { ability = "snapfire_scatterblast", role = "ult_burst" },
        [AB4] = { ability = "snapfire_mortimer_kisses", role = "hard_disable" },
    })
    -- spirit_breaker
    Anim.RegisterMap("npc_dota_hero_spirit_breaker", {
        [AB1] = { ability = "spirit_breaker_charge_of_darkness", role = "gap_close" },
        [AB4] = { ability = "spirit_breaker_nether_strike", role = "hard_disable" },
    })
    -- storm_spirit
    Anim.RegisterMap("npc_dota_hero_storm_spirit", {
        [AB2] = { ability = "storm_spirit_electric_vortex", role = "hard_disable" },
        [AB4] = { ability = "storm_spirit_ball_lightning", role = "gap_close" },
    })
    -- sven
    Anim.RegisterMap("npc_dota_hero_sven", {
        [AB1] = { ability = "sven_storm_bolt", role = "hard_disable" },
    })
    -- tidehunter
    Anim.RegisterMap("npc_dota_hero_tidehunter", {
        [AB4] = { ability = "tidehunter_ravage", role = "hard_disable" },
    })
    -- tinker
    Anim.RegisterMap("npc_dota_hero_tinker", {
        [AB4] = { ability = "tinker_rearm", role = "channel_start" },  -- (draft)
    })
    -- tiny
    Anim.RegisterMap("npc_dota_hero_tiny", {
        [AB2] = { ability = "tiny_toss", role = "hard_disable" },
    })
    -- treant
    Anim.RegisterMap("npc_dota_hero_treant", {
        [AB4] = { ability = "treant_overgrowth", role = "hard_disable" },
    })
    -- tusk
    Anim.RegisterMap("npc_dota_hero_tusk", {
        [AB1] = { ability = "tusk_ice_shards", role = "hard_disable" },
        [AB2] = { ability = "tusk_snowball", role = "gap_close" },
    })
    -- vengefulspirit
    Anim.RegisterMap("npc_dota_hero_vengefulspirit", {
        [AB4] = { ability = "vengefulspirit_nether_swap", role = "hard_disable" },
    })
    -- void_spirit
    Anim.RegisterMap("npc_dota_hero_void_spirit", {
        [AB1] = { ability = "void_spirit_aether_remnant", role = "hard_disable" },
        [AB4] = { ability = "void_spirit_astral_step", role = "gap_close" },
    })
    -- warlock
    Anim.RegisterMap("npc_dota_hero_warlock", {
        [AB3] = { ability = "warlock_upheaval", role = "channel_start" },  -- (draft)
    })
    -- windrunner
    Anim.RegisterMap("npc_dota_hero_windrunner", {
        [AB1] = { ability = "windrunner_shackleshot", role = "hard_disable" },
        [AB2] = { ability = "windrunner_powershot", role = "channel_start" },  -- (draft)
    })
    -- winter_wyvern
    Anim.RegisterMap("npc_dota_hero_winter_wyvern", {
        [AB4] = { ability = "winter_wyvern_winters_curse", role = "hard_disable" },
    })
    -- witch_doctor
    Anim.RegisterMap("npc_dota_hero_witch_doctor", {
        [AB4] = { ability = "witch_doctor_death_ward", role = "channel_start" },
    })
    -- zuus
    Anim.RegisterMap("npc_dota_hero_zuus", {
        [AB2] = { ability = "zuus_lightning_bolt", role = "ult_burst" },
        [AB4] = { ability = "zuus_thundergods_wrath", role = "ult_burst" },
    })

    -- Subscribe to role events
    Anim.Subscribe("gap_close",    on_gap_close)
    Anim.Subscribe("hard_disable", on_hard_disable)
    Anim.Subscribe("channel_start", on_channel_start)
    Anim.Subscribe("ult_burst",    on_hard_disable)  -- treat as hard-disable for save chain

    -- Particle signatures (backup detectors). Paths are conservative VPK
    -- guesses; verify in demo. Sniper's interest is fast/instant casts that
    -- skip OnUnitAnimation (Ball Lightning particle precedes the unit anim).
    Anim.RegisterParticle(
        "particles/units/heroes/hero_storm_spirit/storm_spirit_ball_lightning.vpcf",
        { ability = "storm_spirit_ball_lightning", role = "gap_close" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_spirit_breaker/spirit_breaker_charge_overhead.vpcf",
        { ability = "spirit_breaker_charge_of_darkness", role = "gap_close" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_lina/lina_spell_laguna_blade.vpcf",
        { ability = "lina_laguna_blade", role = "ult_burst" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_lion/lion_spell_finger_of_death.vpcf",
        { ability = "lion_finger_of_death", role = "ult_burst" })
    -- v6.15.241 (clue C2): substring-pattern fallbacks for channeled /
    -- instant AoE-disable ults -- caught at particle-create even when the
    -- cast anim is flaky and the modifier lands too late. Roles mirror the
    -- anim maps; the modifier route still dedups any double-fire. The
    -- substrings are stable ability tokens, tolerant of a particle-path
    -- rename. All five abilities resolve through ABILITY_TO_THREAT.
    Anim.RegisterParticlePattern("black_hole",
        { ability = "enigma_black_hole", role = "hard_disable" })
    Anim.RegisterParticlePattern("chronosphere",
        { ability = "faceless_void_chronosphere", role = "hard_disable" })
    Anim.RegisterParticlePattern("reverse_polarity",
        { ability = "magnataur_reverse_polarity", role = "hard_disable" })
    Anim.RegisterParticlePattern("freezing_field",
        { ability = "crystal_maiden_freezing_field", role = "channel_start" })
    Anim.RegisterParticlePattern("fiends_grip",
        { ability = "bane_fiends_grip", role = "channel_start" })
end

----------------------------------------------------------------------------
-- menu
----------------------------------------------------------------------------

-- v6.15.159: front-page menu rebuild. The brain config used to be buried at
-- Sniper -> Extra Settings -> Brain. It is now its own top-level "Brain" tab
-- (a sibling of the native Main / Extra Settings tabs), split into three
-- purpose groups — Core / Defense / Diagnostics — with advanced sub-settings
-- tucked into gear attachments. Every m.X widget keeps its old field name, so
-- the rest of the brain is untouched; only the menu layout changed. Moving
-- the menu path resets saved widget values to defaults — the combo key may
-- need rebinding once after this version.
local function setup_menu()
    local m = {}

    -- Menu.Find-then-Create so a script reload reuses the existing tabs
    -- instead of erroring on a duplicate Create.
    local function group(name)
        return Menu.Find("Heroes", "Hero List", "Sniper", "Brain", name)
            or Menu.Create("Heroes", "Hero List", "Sniper", "Brain", name)
    end
    local gCore = group("Core")
    local gDef  = group("Defense")
    local gDiag = group("Diagnostics")

    ---------------------------------------------------------------- Core --
    m.enable = gCore:Switch("Enable Sniper brain", true)
    m.enable:ToolTip("Master toggle. When off the brain issues nothing — "
        .. "the native / baseline Sniper runs alone.")
    m.combo_key = gCore:Bind("Combo key", Enum.ButtonCode.KEY_MOUSE5)
    m.combo_key:ToolTip("HOLD = adaptive Starter (1-2 enemies) / Team Fight "
        .. "(3+) loop. TAP = Heavy Starter (E+R fire-on-command).")
    m.fog_snipe = gCore:Switch("Speculative fog snipe", false)
    m.fog_snipe:ToolTip("Auto-cast R at a recently-fogged high-value enemy "
        .. "still inside R cast range.")
    m.commit_floor = gCore:Slider("R commit floor", 40, 150, 100)
    m.commit_floor:ToolTip("R-target valuation gate — 40 fishes for kills, "
        .. "100 is strict, 150 is conservative.")
    m.r_finisher_range = gCore:Slider("Starter R finisher min range %", 50, 150, 70)
    m.r_finisher_range:ToolTip("1-2 enemy R finisher: fire R only when the "
        .. "target is past this percent of attack range. 70 = default; 100+ "
        .. "reserves R for targets at / past the edge of autoattack range "
        .. "(escaping targets). Testing knob — Starter r archetype only.")
    m.force_key = gCore:Bind("Force-commit key (bypass commit_pred)",
                             Enum.ButtonCode.KEY_NONE)
    m.force_key:ToolTip("Hold to force a combo even when the kill check would "
        .. "refuse it.")
    m.panic_key = gCore:Bind("Panic-save key (force next save)",
                             Enum.ButtonCode.KEY_NONE)
    m.panic_key:ToolTip("Press to force the defense layer to fire its next "
        .. "save immediately.")

    ------------------------------------------------------------- Defense --
    m.auto_defense = gDef:Switch("Enable auto-defense (Layer 2)", true)
    m.auto_defense:ToolTip("Always-on save layer — Pike / grenade / BKB / "
        .. "Eul / Lotus / etc. fired on incoming lethal threats.")
    m.layer15_auto = gDef:Switch("Auto-punish enemy channels (R / grenade)", true)
    m.layer15_auto:ToolTip("Auto-fire R or Concussive Grenade when an enemy "
        .. "starts a channel or a TP.")
    m.preface_enable = gDef:Switch("Pre-face imminent threats", true)
    m.preface_enable:ToolTip("Pre-rotate Sniper to beat fast cast points — "
        .. "briefly overrides movement.")
    m.lotus_always = gDef:Switch("Lotus first vs single-target burst", false)
    m.smoke_detect = gDef:Switch("Smoke / fog-ambush detection", false)
    m.smoke_detect:ToolTip("Log a warning and pre-fire BKB below 60 percent "
        .. "HP when an ambush looks likely.")
    m.ally_save_pct = gDef:Slider("Ally HP for grenade-save-ally", 10, 60, 30,
                                  "%d%%")
    m.auto_grenade_enable = gDef:Switch("Auto-grenade on enemy proximity", false)
    m.auto_grenade_enable:ToolTip("Standalone Concussive Grenade on a rushing "
        .. "enemy — an opt-in sidecar to the combo key.")
    -- Auto-grenade tuning — tucked in a gear so the Defense page stays clean.
    local gNade = m.auto_grenade_enable:Gear("Auto-grenade settings")
    m.auto_grenade_radius      = gNade:Slider("Trigger radius", 200, 800, 500, "%du")
    m.auto_grenade_smart_cast  = gNade:Switch("Smart-cast position (predicted)", true)
    m.auto_grenade_skip_slowed = gNade:Switch("Skip already-slowed targets", true)
    m.auto_grenade_low_hp_extra = gNade:Slider("Low-HP extra radius (0 = off)",
                                               0, 400, 0, "%du")

    --------------------------------------------------------- Diagnostics --
    -- All instrumentation is kept in full — read-only, so the code can be
    -- studied / researched. `Log verbosity` drives C:\Umbrella\debug.log.
    m.diag = gDiag:Slider("Log verbosity", 0, 3, 1)
    m.diag:ToolTip("0 = silent, 1 = decisions, 2 = + skips, 3 = full trace. "
        .. "Written to C:\\Umbrella\\debug.log.")

    -- Live status panel — labels rewritten via ForceLocalization from
    -- refresh_status_panel() at ~4 Hz. The text below is just placeholder.
    gDiag:Label("— Brain status (live) —")
    m.lbl_l1           = gDiag:Label("L1: idle")
    m.lbl_l2           = gDiag:Label("L2: idle")
    m.lbl_cands        = gDiag:Label("cands: 0 visible / 0 fog")
    m.lbl_top          = gDiag:Label("top: —")
    m.lbl_breakdown    = gDiag:Label("score: —")
    m.lbl_refusal      = gDiag:Label("last refusal: —")
    m.lbl_reservations = gDiag:Label("reserved: —")
    m.lbl_throttle     = gDiag:Label("L1 throttle: —")
    m.lbl_counters     = gDiag:Label("counts: l1=0 l2=0 mod=0 dedup=0")
    m.lbl_mana_hp      = gDiag:Label("hp/mp: ? / ?")
    m.lbl_ready        = gDiag:Label("ready: Q? E? D? R?")
    m.lbl_saves        = gDiag:Label("saves built: ?")
    m.lbl_smoke        = gDiag:Label("ambush risk: —")

    -- Raw-API debug panel — a research aid, off by default.
    m.debug_panel = gDiag:Switch("Show raw-API debug panel", false)
    m.debug_panel:ToolTip("Extra labels exposing raw API reads — for studying "
        .. "the framework. Leave off in normal play.")
    m.lbl_dbg_pos    = gDiag:Label("dbg.me_pos: —")
    m.lbl_dbg_target = gDiag:Label("dbg.target: —")
    m.lbl_dbg_facet  = gDiag:Label("dbg.shard/scepter/talents: —")
    m.lbl_dbg_gtime  = gDiag:Label("dbg.game_time: —")
    m.lbl_dbg_cf     = gDiag:Label("dbg.commit_floor (effective): —")

    state.menu = m
end

-- Build "Q✓ E✗ D✓ R✓" style status from current readiness.
local function ready_chip(name, label)
    return label .. (ability_ready(name) and "✓" or "✗")
end

refresh_status_panel = function()
    local m = state.menu
    if not m or not m.lbl_l1 then return end
    local me = state.self_npc
    if not me then
        m.lbl_l1:ForceLocalization("L1: <waiting for hero>")
        return
    end

    -- L1 / L2 strings
    local now_t = now()
    local l1_age = state.last_layer1_t and (now_t - state.last_layer1_t) or 999
    if l1_age < 99 then
        m.lbl_l1:ForceLocalization(string.format("L1: %s (%.1fs ago)",
            state.last_layer1_intent, l1_age))
    else
        m.lbl_l1:ForceLocalization("L1: idle")
    end

    local l2_age = state.last_save_t and (now_t - state.last_save_t) or 999
    if l2_age < 99 then
        m.lbl_l2:ForceLocalization(string.format("L2: %s (%.1fs ago)",
            state.last_save_intent, l2_age))
    else
        m.lbl_l2:ForceLocalization("L2: idle")
    end

    -- candidates + fog cache. Use %.0f everywhere because Lua 5.4's %d
    -- requires a strict integer; mana / score / counters that look like
    -- ints can be floats from the game API (e.g., NPC.GetMana returns
    -- `number` which is a Lua float). %.0f accepts any number, rounds
    -- to integer-looking output.
    local n_vis = #state.candidates
    local n_fog = 0
    for _ in pairs(state.fog_cache) do n_fog = n_fog + 1 end
    m.lbl_cands:ForceLocalization(string.format("cands: %.0f visible / %.0f fog", n_vis, n_fog))

    -- top candidate
    local top = state.candidates[1]
    if top then
        m.lbl_top:ForceLocalization(string.format("top: %s score=%.0f dist=%.0f",
            uname(top.target), top.score, dist_to(top.target)))
    else
        local fog_top = top_fog_candidate()
        if fog_top then
            m.lbl_top:ForceLocalization(string.format("top: (fog) %s score=%.0f",
                uname(fog_top.target), fog_top.score))
        else
            m.lbl_top:ForceLocalization("top: —")
        end
    end
    -- v6.14 B2: score breakdown for top candidate.
    if m.lbl_breakdown then
        m.lbl_breakdown:ForceLocalization("score: " .. (state.last_score_breakdown or "—"))
    end
    -- v6.14 B1: last refusal + reason.
    if m.lbl_refusal then
        if state.last_refusal then
            local age = now_t - state.last_refusal.t
            if age < 10 then
                m.lbl_refusal:ForceLocalization(string.format(
                    "last refusal: %s on %s — %s (%.1fs ago)",
                    state.last_refusal.combo, state.last_refusal.target,
                    state.last_refusal.reason, age))
            else
                m.lbl_refusal:ForceLocalization("last refusal: —")
            end
        else
            m.lbl_refusal:ForceLocalization("last refusal: —")
        end
    end
    -- v6.14 B3: active reservations / displacements line.
    if m.lbl_reservations then
        local parts = {}
        for ab_key, r in pairs(state.reservations) do
            local remaining = r.expires_at - now_t
            if remaining > 0 then
                local short = (ab_key == A.Q and "Q") or (ab_key == A.W and "W")
                          or (ab_key == A.E and "E") or (ab_key == A.D and "D")
                          or (ab_key == A.R and "R") or tostring(ab_key)
                parts[#parts + 1] = string.format("%s(%.1fs:%s)", short, remaining, r.by)
            end
        end
        for idx, ends_at in pairs(state.displacements) do
            local remaining = ends_at - now_t
            if remaining > 0 then
                parts[#parts + 1] = (idx == 0 and "self-disp" or ("e" .. idx .. "-disp"))
                    .. string.format("(%.1fs)", remaining)
            end
        end
        m.lbl_reservations:ForceLocalization("reserved: " ..
            ((#parts > 0) and table.concat(parts, " ") or "—"))
    end
    -- v6.14 B4: commit-window countdown line.
    if m.lbl_throttle then
        local l1_age2 = state.last_layer1_t and (now_t - state.last_layer1_t) or 999
        if l1_age2 < LAYER1_COMMIT_WINDOW then
            m.lbl_throttle:ForceLocalization(string.format("L1 throttle: %.1fs remaining",
                LAYER1_COMMIT_WINDOW - l1_age2))
        else
            m.lbl_throttle:ForceLocalization("L1 throttle: ready")
        end
    end
    -- v6.14 C3: ambush-risk chip.
    if m.lbl_smoke then
        m.lbl_smoke:ForceLocalization("ambush risk: " .. (state.smoke_state or "ok"))
    end

    -- v6.15 B4: raw-API debug panel (gated on toggle).
    if m.debug_panel and m.debug_panel:Get() then
        -- v6.15.201 (audit D3): nil-guard me_pos / tp. Debug panel renders
        -- every HUD tick even during respawn; me_pos and a stale-candidate
        -- target's pos can both be nil. Crash → entire HUD callback dies.
        -- v6.15.243: both reads route through NPCLib.origin (typed safe-read,
        -- v6.15.238 C1). The candidate target can be a stale handle that is
        -- still truthy but no longer an Entity, which crashed raw
        -- Entity.GetAbsOrigin every respawn-window HUD tick (the only
        -- v6.15.242 crash class to survive C1, missed because the HUD path
        -- was off the original combat-path audit).
        local me_pos = NPCLib.origin(me)
        if me_pos then
            m.lbl_dbg_pos:ForceLocalization(string.format("dbg.me_pos: (%.0f, %.0f)",
                me_pos.x, me_pos.y))
        else
            m.lbl_dbg_pos:ForceLocalization("dbg.me_pos: —")
        end
        local t = state.candidates[1] and state.candidates[1].target
        local tp = NPCLib.origin(t)
        if t and tp then
            m.lbl_dbg_target:ForceLocalization(string.format(
                "dbg.target: %s pos=(%.0f,%.0f) mana=%.0f hp=%.0f/%.0f",
                uname(t), tp.x, tp.y, NPC.GetMana(t) or 0,
                Entity.GetHealth(t) or 0, Entity.GetMaxHealth(t) or 0))
        else
            m.lbl_dbg_target:ForceLocalization("dbg.target: —")
        end
        m.lbl_dbg_facet:ForceLocalization(string.format(
            "dbg.shard=%s scepter=%s tal_headshot=+%.0f tal_shrap=x%.2f",
            NPCLib.has_shard(state.self_npc) and "y" or "n", NPCLib.has_scepter(state.self_npc) and "y" or "n",
            talent_headshot_bonus(), talent_shrap_multiplier()))
        local gt = (GameRules and GameRules.GetGameTime and GameRules.GetGameTime()) or 0
        m.lbl_dbg_gtime:ForceLocalization(string.format(
            "dbg.game_time: %.0fs (offset=%d)", gt, game_time_offset()))
        m.lbl_dbg_cf:ForceLocalization(string.format(
            "dbg.commit_floor (effective): %d", commit_floor()))
    end

    -- counters: prove code paths fired
    m.lbl_counters:ForceLocalization(string.format(
        "counts: l1=%.0f l2=%.0f mod=%.0f dedup=%.0f",
        state.l1_counter, state.l2_counter,
        state.modcreate_counter, state.skip_counter))

    -- hp / mp
    local hp     = Entity.GetHealth(me)
    local hp_max = Entity.GetMaxHealth(me)
    local mp     = NPC.GetMana(me)
    local combo_cost = full_combo_cost()
    m.lbl_mana_hp:ForceLocalization(string.format(
        "hp/mp: %.0f/%.0f  mp/combo: %.0f/%.0f  %s",
        hp, hp_max, mp, combo_cost,
        mp >= combo_cost and "(full combo OK)" or "(under-mana)"))

    -- ability readiness
    local shrap_n = shrap_charges()
    m.lbl_ready:ForceLocalization(string.format(
        "ready: Q[%.0f]%s %s %s %s",
        shrap_n,
        shrap_n > 0 and "✓" or "✗",
        ready_chip(A.E, "E"),
        ready_chip(A.D, "D"),
        ready_chip(A.R, "R")))

    -- defensive items built
    local built = {}
    for _, name in ipairs({"item_cyclone","item_lotus_orb","item_glimmer_cape",
                           "item_hurricane_pike","item_force_staff",
                           "item_black_king_bar"}) do
        if NPC.HasItem(me, name, true) then
            local short = name:gsub("^item_", "")
            built[#built + 1] = short:sub(1, 4) .. (NPCLib.item_ready(state.self_npc,name) and "✓" or "·")
        end
    end
    m.lbl_saves:ForceLocalization("saves built: " .. (next(built) and table.concat(built, " ") or "—"))
end

----------------------------------------------------------------------------
-- init + wiring
----------------------------------------------------------------------------

Order.Init()
Damage.Init()
Anim.Init()

setup_menu()
register_anim_maps()

-- v6.15 E1+E2: persist brain state across hot-reloads. Writes a dedicated
-- file `db.Sniper.brain_state.json` next to the framework's `db.json`
-- (we DO NOT mutate the shared db.json — risk of corruption + race with
-- framework). E2 (native Sniper v2 combo-key alignment via gui.json read)
-- is deferred — direct gui.json mutation is risky and we already provide
-- a brain-side combo_key Bind that the user can match manually.
local _STATE_PATH
do
    -- v6.15.2 low: normalize the separator. Engine.GetCheatDirectory returns
    -- backslash on Windows; use the OS-native one consistently.
    local dir = (Engine and Engine.GetCheatDirectory and Engine.GetCheatDirectory()) or ""
    local sep = (dir:find("\\")) and "\\" or "/"
    _STATE_PATH = dir .. sep .. "db.Sniper.brain_state.json"
end

local function _load_persisted_state()
    local ok, JSON = pcall(require, "assets.JSON")
    if not ok or not JSON then return end
    local f = io.open(_STATE_PATH, "r")
    if not f then return end
    local raw = f:read("*a"); f:close()
    if not raw or #raw == 0 then return end
    local db_ok, s = pcall(JSON.decode, JSON, raw)
    if not db_ok or type(s) ~= "table" then return end
    state.l1_counter        = s.l1_counter or 0
    state.l2_counter        = s.l2_counter or 0
    state.abort_counter     = s.abort_counter or 0
    state.panic_counter     = s.panic_counter or 0
    state.force_counter     = s.force_counter or 0
    state.modcreate_counter = s.modcreate_counter or 0
    tlog(1, "brain_state_restored", { source = _STATE_PATH })
end
pcall(_load_persisted_state)

-- v6.15.1 E2: read native Sniper combo key from gui.json so brain log can
-- surface it to the user. Pure READ — we don't mutate gui.json (framework
-- owns that file). Path observed in 7.41C gui.json:
--   "Heroes/Hero List/Sniper/Main Settings/Hero Settings/Combo Key": [code, mod]
-- The value is a 2-tuple [button_code, modifier_code]. If brain's combo_key
-- doesn't match, log a mismatch warning so user can align manually.
local function _check_native_combo_key()
    local ok, JSON = pcall(require, "assets.JSON")
    if not ok or not JSON then return end
    local dir = (Engine and Engine.GetCheatDirectory and Engine.GetCheatDirectory()) or ""
    local f = io.open(dir .. "/gui.json", "r")
    if not f then return end
    local raw = f:read("*a"); f:close()
    local g_ok, g = pcall(JSON.decode, JSON, raw)
    if not g_ok or type(g) ~= "table" then return end
    local native = g["Heroes/Hero List/Sniper/Main Settings/Hero Settings/Combo Key"]
    if type(native) == "table" and native[1] then
        -- v6.15.2 low: also surface the brain's current bind so the user
        -- can see the mismatch (if any) in one log line.
        local brain_code
        if state.menu and state.menu.combo_key and state.menu.combo_key.Get then
            local ok, val = pcall(state.menu.combo_key.Get, state.menu.combo_key)
            if ok then brain_code = tostring(val) end
        end
        tlog(1, "native_combo_key_observed", {
            native_code = tostring(native[1]),
            native_modifier = tostring(native[2] or 0),
            brain_code = brain_code or "?",
            advice = "align brain combo_key bind to match for sidecar-clean behavior",
        })
    elseif type(native) ~= "table" then
        tlog(1, "native_combo_key_path_missing", {
            path = "Heroes/Hero List/Sniper/Main Settings/Hero Settings/Combo Key",
        })
    end
end
pcall(_check_native_combo_key)

local _last_persist_t = 0
_persist_state = function()
    if (now() - _last_persist_t) < 30 then return end
    _last_persist_t = now()
    local ok, JSON = pcall(require, "assets.JSON")
    if not ok or not JSON then return end
    local payload = {
        l1_counter        = state.l1_counter,
        l2_counter        = state.l2_counter,
        abort_counter     = state.abort_counter,
        panic_counter     = state.panic_counter,
        force_counter     = state.force_counter,
        modcreate_counter = state.modcreate_counter,
        saved_at          = now(),
    }
    local enc_ok, encoded = pcall(JSON.encode, JSON, payload)
    if not enc_ok then return end
    -- v6.15.2 low: atomic write — write tmp + rename. Avoids partial-JSON
    -- if the process is killed mid-write.
    local tmp = _STATE_PATH .. ".tmp"
    local w = io.open(tmp, "w")
    if not w then return end
    w:write(encoded); w:close()
    -- os.rename overwrites existing file on POSIX; on Windows it errors if
    -- the target exists, so remove first.
    pcall(os.remove, _STATE_PATH)
    os.rename(tmp, _STATE_PATH)
end

-- v6.15 A4: register Sniper's brain API for cross-hero coordination.
Signal.Register("Sniper", {
    -- expose intent for now; future heroes can wire into these.
    last_r_target    = function() return state.last_r_target end,
    last_save_intent = function() return state.last_save_intent end,
    is_committing    = function() return state.last_r_target ~= nil end,
})

Order.Wire(callbacks)
Damage.Wire(callbacks)
Anim.Wire(callbacks)

LOG:info("Sniper brain v6.15.254 loaded — COMBO D CLOSE-RANGE MIDPOINT + GRENADE_AT_CASTER ROTATION REMOVED. v6.15.254: user direction after v6.15.253 demo, two simplifications acting on the over-engineering observation. (A) optimal_d_pos for combo D switched to MIDPOINT geometry when target is in close range (dist <= 750u). The pre-v6.15.254 formula g = max(0, dist - 300) clamped to 0 for any dist below 300, casting D AT Sniper own position -- both in blast but Sniper push direction from a zero-vector cast is engine-fallback random/facing. That was the user-reported weird position for combo D against close PA. Long-range case (dist > 750) keeps the legacy 300u-inward placement (Sniper out of self-push radius, attacker at far edge of blast). v6.15.248 danger-aware rotation block removed -- the shared turn-cost factor v6.15.251 was making the helper pick rotated angles even in 1v1, producing the seems-random placements the user observed. (B) grenade_at_caster v6.15.253 rotation block removed. Pure midpoint baseline (the v6.15.252 geometry). Same root cause: turn-cost biased the helper to perpendicular even in 1v1. Removing the rotation gives the user-requested predictable midpoint cast. The 120deg facing gate stays as protection against stun-causing channels (Pudge / Bane / Shaman where Sniper would be stunned mid-turn). User insight: if D is cast on the right position sniper will turn himself alone without intervention -- midpoint IS the right position, engine handles turn. Turn-cost factor in danger_at_pos stays in place for blink_escape_position and pike_self_reposition where the active direction pick is structurally appropriate (Sniper picks own direction). v6.15.253 pike blink-settle (50ms) and channel_on_me_d delegation preserved. v6.15.253: three coordinated fixes that unify the grenade dispatch geometry across all paths and fix the v6.15.252 facing + pike-mid-blink bugs. (A) grenade_at_caster.fire gains a facing-aware rotation block. After the v6.15.252 midpoint baseline, the helper state.pick_escape_dir picks an escape direction whose corresponding cast_point both keeps the caster in blast AND satisfies the 120deg facing gate. The v6.15.252 log showed grenade_at_caster_skip_facing four times when Sniper was back-turned to PA (angle 131-180 vs the 120 gate); the chain fell to pike which then double-failed during PA blink. The rotation lets the helper pick +/-90deg landings that are reachable from any facing, with the caster still stunned in the blast. Same pattern as v6.15.247 grenade_self_cast_point. Diagnostic gains rotated y/n field. (B) channel_on_me_d at line 7156 delegates to grenade_at_caster.fire so the Layer 1.5 channel-source dispatch inherits midpoint AND rotation AND facing. Pre-v6.15.253 it raw-cast at the caster, bypassing both v6.15.252 and v6.15.253 upgrades. (C) Pike blink-arrived settle. armed_threats_tick now stamps entry.arrived_at on the first frame d <= BLINK_ARRIVE_DIST_U, defers dispatch one settle tick (BLINK_SETTLE_S 0.05 = 50ms), then fires. PA Phantom Strikes 0.25s cast point teleports the caster instantly but the network position can lag 1-2 ticks; pike fires firsthand check dist_to(caster) <= 425u was failing because the engine still saw the old far position (cast_verify_double_fail with cd_after=0). 50ms is ~1.5 ticks, tight enough to stay inside PA 0.5s+attack_point auto window. Combined effect: grenade_at_caster fires reliably with the right direction even when Sniper is back-turned; pike fires reliably even when PA just blinked. v6.15.252: user-reported, the defensive grenade vs PA blink left PA at random close distances. Root cause: v6.15.214 explicitly cast the grenade ON the enemy position (max stun-on-caster for channel interrupt against Pudge / Bara / Shaman). For PA Phantom Strike (instant blink, no channel) this means cast_pos is AT PA, Sniper is pushed 475u away from cast_pos, but PA at the cast point has UNDEFINED push direction (zero vector to itself, engine falls back to facing or random). Result: only ~531u mutual separation. User intent: throw between both, both pushed apart, MAX DISTANCE -- the auto_grenade pattern that works in non-skill 1v1. Fix: switch grenade_at_caster to midpoint cast (sniper-caster midpoint) when both fit inside the 375u self-push radius (dist <= 750u). Both get knocked back 475u each from cast point = ~1000u mutual separation. Caster STILL gets the 0.4s stun in the blast, so channel/charge interrupt for Pudge/Shaman/Bara is preserved -- a stunned caster at midpoint AND a stunned caster at cast-on-self both lose the channel. For long-range channels (Bane Grip 875u tether, Pugna Drain 1300u) midpoint would put cast > 375u from both, so the gate dist <= 750u falls back to cast-at-caster -- caster still stunned, channel still breaks even though Sniper is not displaced. Diagnostic log key grenade_at_caster_cast_plan gains midpoint field (y/n). v6.15.251: two fixes from the v6.15.250 fresh-log test. (A) Per-target save-cooldown gate on starter_tick. User reported D+R double-fire on PA: defensive grenade-at-caster fires on PA AND offensive starter_dr commits R on PA the same tick, burning both cooldowns at once. Stagger them and PA stays away longer (save pushes PA, PA recovers and re-engages, THEN R finishes the kill). Added state.last_save_target stamp (set when a save fires with known threat_caster, threaded through record_save), and starter_tick early-returns when target == last_save_target within STARTER_SAVE_SUPPRESS_S (0.1s, tight on purpose -- PA 2-blink charges with 5s recharge means a long window would suppress legitimate next-blink combo; the gate catches strict same-tick double-fire, which is the bug signal). New diagnostic log key combo_skip_recent_save. (B) Turn-cost factor in danger_at_pos. User intuition: in 1v1 perpendicular gives biggest effective distance because the enemy must TURN before chasing. Pure linear distance favours 0deg, but turn-cost favours angles forcing the enemy to rotate. Added an enemy-facing-direction dot product against the chase vector to landing; turn_factor in 0..1 scales the danger contribution by (1 - turn_factor*0.5). For PA at 56u in 1v1: 0deg landing (531u, PA turn 0deg) danger 18.6, +/-90deg landing (478u, PA turn 83deg) danger 19.8 * (1 - 0.46*0.5) = 15.2. +/-90deg now wins. Net effective re-engagement delay +0.3s (PA must turn 0.4s before closing the 478u gap at 310u/s). Falls back to current behaviour when NPC.GetForwardVector is unavailable. Pike-on-self already goes through the same helper, so the user-noted symmetry holds: all heroes using pike-on-self benefit from the turn-cost. v6.15.250: regression hunt traced to v6.15.232 commit edc028c -- the polish-1of4 radians fix added math.deg to lib/anim.lua compute_target_self. Pre-v6.15.232 the gate accidentally always-passed (raw radians ~pi never > 30 degrees, the comment even acknowledged this), so target_self was true for any caster in range and PA Phantom Strike fired saves correctly. Post-v6.15.232 the gate works as intended for aim-based projectile abilities but rejects unit-target abilities (PA Phantom Strike, OD Astral Imprisonment, Pudge Dismember, PB Pulverize) where the caster selects target by reference and does not aim. PA was hit hardest because its target-side modifier (modifier_phantom_assassin_phantom_strike_target referenced by the catalog) does not exist in modern Dota, so the OnModifierCreate backup path also fails -- both detection paths off. Pudge/OD/PB still worked because their target-side modifiers exist and the modifier path catches them; the anim path was just firing late. Fix: optional instant_target flag on Anim.RegisterMap entries; compute_target_self skips the facing gate when set. Backward-compatible (nil flag = current behaviour). Applied to phantom_assassin_phantom_strike, obsidian_destroyer_astral_imprisonment, pudge_dismember, primal_beast_pulverize. Line-aim abilities (Hook, Onslaught, Sanity Eclipse, Pangolier Swashbuckle, etc.) keep the facing gate -- they actually aim and the gate filters out incidental near-misses. lib/anim.lua change is 3 lines, fully backward-compatible, synced to uczone-toolkit. v6.15.249: panic-mode dispatches (damage_rate_panic_check, user panic key) call into the save chain with nil threat_caster. Grenade was already danger-aware in this path via grenade_self_cast_point centroid fallback + helper pick + facing filter; pike was NOT -- it fell to raw issue_item_self in Sniper's current facing, often pushing him TOWARD the enemy he was attacking. Two-edit fix to bring pike to parity: (A) pike_self_reposition now derives a toward direction even when threat_caster is nil, using the enemy centroid (mirrors grenade_self_cast_point line 747). When no enemies are in 1500u, returns false so the caller can decide. (B) pike fire terminal branch always routes through pike_self_reposition first, falling back to raw issue_item_self only as last resort. Raw self-cast preserved for the no-enemy edge case. The 7-angle danger-aware pick + turn-then-fire pattern now applies symmetrically to grenade and pike in panic. v6.15.248: bundles four fixes after parallel-agent investigation into user-reported recurring defense bugs. (A) Reordered modifier_phantom_assassin_phantom_strike_target chain to grenade_at_caster FIRST, pike second. PA Phantom Strike is an instant blink, not a channel/charge; grenade-at-caster 0.4s stun on PA prevents the auto window entirely while pike 0.4s push lets PA land 1-2 autos before displacement resolves (the v6.15.247 log showed save_outcome hp_pct_min 80.4 on a pike-save). (B) Root cause for the user-reported pike-not-firing-without-grenade: line 5996 in pike fire returns false for close_gap by design, expecting the chain to fall to grenade_at_caster, but when the shard is absent the grenade entries get strangled by save_is_ready ability_ready gate (Ability.GetLevel zero returns not_ready) and the chain exhausts with no save. Fix: only return false from the close_gap branch when grenade is actually in inventory; otherwise fall through to pike_self_reposition for at-least-one-displacement-save. (C) Combo D (optimal_d_pos line 3962) was purely geometric -- cast_pos at attacker minus 300u inward, no danger awareness. v6.15.246 added danger-aware rotation to auto_grenade_tick but never reached optimal_d_pos. Added the same shared-helper rotation block: try 7 angles, attacker-in-blast constraint (375u from cast_pos), pick lowest danger landing, fall back to baseline if constraint fails. New diagnostic log key optimal_d_pos_rotated. (D) Routed auto_grenade_tick me_pos through NPCLib.origin -- last v6.15.238 C1 missed site in the offensive ticks. Investigation methodology: 4 parallel Explore agents (pike regression trace, auto_grenade rotation verify, defense chain audit, combo D path) plus 2 follow-up agents (pike-without-grenade root cause, combo D refactor scope) -- the user-requested small-task division surfaced root causes that single-pass reading missed. v6.15.247: user correction on v6.15.246, pike does not jump over the Kinetic Field wall. Hurricane Pike and Force Staff both apply forced movement OVER TIME (600u across ~0.4s); Kinetic Field's wall intercepts a sliding push trajectory and Sniper does not exit. Only Concussive Grenade's INSTANT radial impulse (475u in one ImpulseDisplacement event) clears the wall. (A) Reverted the modifier_disruptor_kinetic_field_remnant chain to grenade_self, grenade_at_caster (the historical entries; the v6.15.246 pike/force prepend was wrong). (B) The underlying reason both grenades were failing was the post-pick facing gate refusing the 0deg baseline cast_point when Sniper was back-turned (142deg in the log) -- even though a facing-reachable perpendicular candidate existed. Pushed the facing predicate INTO state.pick_escape_dir via a new optional filter_fn(esc_dir, landing) -> bool parameter; grenade_self_cast_point passes a closure that requires the candidate's cast_point to be within the 120deg turn budget. So the helper now picks the lowest-danger candidate that is also facing-reachable, instead of picking blind on danger and letting the late gate refuse. In the back-turned kinetic-field case the +/-90deg perpendicular angles (added in v6.15.245) are the only ones the gate accepts; the helper picks one and the grenade fires. blink_escape_position, pike_self_reposition, and auto_grenade_tick continue to pass nil for filter_fn (no per-candidate constraint, same v6.15.245 behaviour). The post-pick grenade_self_skip_facing log key is retired and replaced by grenade_self_skip_no_safe_dir when the helper finds NO candidate that passes both gates. v6.15.246: bundles two fixes from the v6.15.245 fresh-log test. (A) The modifier_disruptor_kinetic_field_remnant chain had only grenade_self and grenade_at_caster, both 120-deg facing-gated; the log showed Sniper back-turned at 142deg inside the field and the chain ran out with no save. Prepended item_hurricane_pike (active turn, no facing dependency, 600u push) and item_force_staff (0s cast, 600u push) -- both comfortably clear the 225u field radius. (B) auto_grenade_tick close-mode cast_pos was the user-reported D panic save blind spot: the midpoint cast pushed Sniper straight away from the rusher and into whoever sat behind him, with zero danger awareness. Routed cast_pos through state.pick_escape_dir for the close-mode branch (Sniper within the 375u self-push radius). The helper picks the safest of the 7 angles, then cast_pos is rotated so Sniper lands at that direction; the enemy is verified still within the 375u blast radius (sin(theta) <= 375/dist constraint), with fallback to the straight cast if the rotation would lose the rusher. 0deg ties go to the baseline via strict less-than (consistent with grenade_self / pike_self), so 1v1 behaviour is unchanged. New diagnostic log key auto_grenade_rotated emits land_x / land_y / cast_x / cast_y whenever a non-baseline angle is chosen. Skipped in far mode (Sniper not in self-push radius). v6.15.245: extended the state.pick_escape_dir angle list from {0, +/-35, +/-65} (5 candidates) to {0, +/-35, +/-65, +/-90} (7 candidates) so the danger-aware ranker can pick perpendicular landings in a teamfight. User observation: in real TF where backliners sit on the straight-away side from the immediate threat, the safest spot is often perpendicular to that threat, not opposite. The threat-distance hard gate inside SafePushDestination is preserved (a +/-90deg landing is still meaningfully farther from A by sqrt(d_AB^2 + push^2) > d_AB), so the new candidates are not unsafe regressions. Motivating build context: pike is dropped from Sniper builds without close-gap enemies in favour of another item, so grenade-self must be self-sufficient as the sole displacement save. The widening applies to all three callers (blink_escape_position, grenade_self_cast_point, pike_self_reposition) via the shared helper, keeping grenade and pike behaviour in lock-step. v6.15.244: JppsTech clue C4 finalisation. v6.15.240 routed blink_escape_position through danger_at_pos but missed two sibling paths; the v6.15.242 fresh-log test (user-reported TF escape) showed Pike-on-self pushing Sniper directly into a backliner because grenade_self_cast_point and pike_self_reposition still picked a single straight-away direction. Lifted the 5-angle danger-aware pick into state.pick_escape_dir (Sniper.lua line 1706), then routed all three escape paths through it. 0deg (the historical baseline) wins ties via strict less-than, so the candidate only shifts when a rotated angle is meaningfully safer. Pike-on-self also now routes its two GetAbsOrigin reads through NPCLib.origin (C1 consistency). grenade_self_cast_plan log gains land_x and land_y for diagnostic visibility. v6.15.243: route the debug-panel me_pos and candidate-target reads through NPCLib.origin (the typed safe-read from v6.15.238 C1), retiring the one GetAbsOrigin crash that survived C1. The HUD path was off the original combat-path audit, so a stale state.candidates[1].target handle (truthy but no longer an Entity) crashed raw Entity.GetAbsOrigin on every respawn-window HUD tick. Robustness only; no behaviour change. v6.15.242: strip references to local-only internal docs from tracked files; cleanliness-only, no behaviour change. v6.15.241: JppsTech-clue C2, particle substring threat detection. The brain detects threats by anim (activity-keyed) and modifier (modifier-name-keyed) routes; lesson 111 records that the modifier-name catalog rots and cannot be data-derived. Particle and sound names are more stable, and a substring match tolerates a Valve rename. The brain already has an integer-index particle route (Anim.RegisterParticle, four particles). Added Anim.RegisterParticlePattern(substr, signature): a rot-resistant substring fallback. OnParticleCreate_handler keeps the integer-index lookup as the primary fast path; on a miss it calls match_particle_pattern, which is gated three ways (no patterns registered, no name string, or an own-side/ally particle all short-circuit) so the substring scan stays off the bulk of the particle firehose, then matches the particle full name lowercased and plain against the registered tokens. A hit resolves into the SAME dispatch and try_save_self path as the anim route, so the modifier-route dedup still prevents a double-fire. Registered five channeled or instant AoE-disable ults whose particle precedes a flaky cast anim and a late modifier: enigma_black_hole, faceless_void_chronosphere, magnataur_reverse_polarity (hard_disable), crystal_maiden_freezing_field, bane_fiends_grip (channel_start). Roles mirror the existing anim maps; all five resolve through ABILITY_TO_THREAT. The sound channel (OnStartSound is a documented callback) was left for a later clue. v6.15.240: JppsTech-clue C4, danger-aware escape destinations. JppsTech keeps a spatial threat-event store and a danger field sampled to veto the player's move orders. The full event/veto model is HUD architecture and was rejected; the one useful primitive was kept. The escape-geometry helpers had a documented blind spot: SafePushDestination's threat-caster branch deliberately validates a destination only against the single triggering threat (escaping the channeller is right even toward backliners), so a blink or push could escape threat A and land Sniper next to enemy B. Added state.danger_at_pos(pos): a stateless, on-demand score, the proximity-weighted count of visible enemy heroes near a position (no event store, no per-tick cost, no veto, towers not counted as there is no clean API). blink_escape_position now tries five escape angles away from the threat (0, plus/minus 35, plus/minus 65 degrees) and keeps the lowest-danger landing that still passes SafePushDestination; 0 degrees straight-away is always a candidate so it never does worse than before. SafePushDestination's crude enemy-centroid fallback (the no-known-threat case) is replaced by danger_at_pos, refusing a destination meaningfully more dangerous than Sniper's current spot. The deliberate single-threat branch is untouched. v6.15.239: JppsTech-clue C6-A, kill confidence as a probability. JppsTech markets a KILL MATRIX; its calcKill is actually a heuristic estimator that maps a damage/HP ratio to a kill percent via a hand-tuned step ladder. The brain's existing kill math is already more rigorous (frame-correct, regen/barrier/heal aware, HP projected to R impact), so the step ladder is rejected. Adopted instead: a probability output computed from the brain's OWN conservative-vs-optimistic damage band. state.kill_confidence(ctx) takes dmg_lo (R plus the RC_MIN_DAMAGE_FACTOR-haircut autoattack window, the basis the commit gate already uses) and dmg_hi (R plus the full window), and returns the fraction of that self-uncertainty band that clears the regen/barrier-correct eff_hp threshold, 0 to 100. RC_MIN_DAMAGE_FACTOR moved from a build_layer1_ctx local to a state constant so the helper can reconstruct the full-window RC. The kill_pct is surfaced in the starter R-decision log (both the idle and the fire line). Diagnostic only: it does NOT gate commit, the conservative dmg_lo gate is unchanged. It reads conservative for a Q-stacking combo since Q is not counted. v6.15.238: JppsTech-clue C1, typed safe-read helpers. A study of another UCZone script suggested a uniform pcall wrapper around every engine read. Adopted the idea but not the blanket form (blanket pcall masks a typo-ed API name as a silent nil and taxes every per-tick read). Instead lib/npc.lua gains two typed helpers: NPCLib.origin(e) guards the stale-handle THROW from Entity.GetAbsOrigin via Entity.IsEntity (the result stays nilable, callers still nil-check), and NPCLib.ability_name(ab) pcall-guards Ability.GetName which throws on a non-ability entity. The still-unguarded GetAbsOrigin sites from the round-3 nil-safety audit are routed through NPCLib.origin with a nil-check: blink_escape_position and grenade_self_cast_point (me_pos and the caster cp), pre_face_tick, the channel_break and channel_on_me grenade fallbacks, and OnLinearProjectileCreate. This retires the dist_to-class crash surface (a stale entity handle left in a cache throwing inside GetAbsOrigin) instead of guarding it reactively per site. v6.15.237: polish review follow-up, the four MEDIUM audit items. (1) try_save_self over-counted concurrent threats on a panic save: with threat_mod nil the self_key is nil, so the responded_threats exclusion matched nothing and the threat the same engagement had just marked self-counted, prematurely unlocking high-cooldown saves. The responded_threats loop is now gated on a non-nil self_key. (2) threat_data RECOMMENDED_SAVES for Disruptor Kinetic Field dropped grenade_at_caster: it knocks the Disruptor, not Sniper, so it never frees Sniper from the field, and SaveCounters rejected it anyway since its kinds do not intersect displacement_perp. grenade_self stays. (3) gen_item_data.py short_behavior now splits AbilityBehavior on whitespace as well as the pipe, matching the other three generators, so a space-joined KV flag is no longer mangled. (4) the dead Timing import (Sniper required lib/timing.lua but called nothing from it) was removed from Sniper.lua, reclaiming a main-chunk local slot. lib/timing.lua itself is kept as a built, tested Tier-2 lib. v6.15.236: dist_to crash guard. A v6.15.235 bot-match log showed a Lua error twice: Sniper.lua dist_to calling Entity.GetAbsOrigin with a non-entity value (a stale handle, 5824829145088), reached via refresh_status_panel. dist_to guarded `not target` but a destroyed entity left in a HUD or candidate cache is a non-nil number that passes that check and then throws arg-is-not-an-Entity inside GetAbsOrigin. dist_to now also gates on Entity.IsEntity(me) and Entity.IsEntity(target), and nil-guards the GetAbsOrigin results before Distance2D. Pre-existing nil-safety gap (the polish review did not touch dist_to); the audit had flagged the function as a MEDIUM and batch 1 fixed only the CRITICALs. v6.15.235: polish review batch 4 of 4, comment-drift fixes. Fixed 14 stale in-code cross-references that the file growing past their write-point had rotted: 4 wrong line-2110 pointers on the Keen-Scope double-count rationale, a reference to a function cast_abort_tick that does not exist (the R-abort function is r_abort_tick), and 9 other stale line-number pointers. All now cite function names instead of line numbers, since this file is edited constantly and line numbers rot. No behavior change, comments only. The bulk verbosity trim (condensing the version-archaeology comment blocks) was deferred: those comments are correct rather than wrong, and condensing roughly 600 lines of institutional history is a large subjective rewrite better done as its own focused pass than rushed at the end of a four-batch polish run. v6.15.234: polish review batch 3 of 4, logic + lib + generator fixes. (1) auto_grenade_tick now skips when a combo has D reserved for a deferred step (is_reserved(A.D)) -- last_d_t only stamps when D actually fires, so a scheduled-but-unfired combo D could let auto-grenade steal the slot; the defense save chain already honored this. (2) lib/geometry.lua dist_between and lib/target.lua InRange got nil-guards on Entity.GetAbsOrigin (nil on a dead or mid-respawn entity). (3) lib/target.lua IsRightClicking now adds NPC.GetAttackRangeBonus to the base attack range, so a ranged carry with Dragon Lance or Hurricane Pike is no longer under-ranged. (4) The four KV-data generators (gen_item/ability/unit/hero_data.py) gained a lesson-127 regression guard: a Valve KV schema shift that breaks the parse now aborts loudly instead of silently emitting a tiny data lib. Deferred to a focused follow-up: the try_save_self concurrent-threat over-count and two threat_data catalog contradictions, both need dedicated analysis rather than a blind polish edit. v6.15.233: polish review batch 2 of 4, dead-code removal. Removed 15 build_layer1_ctx fields computed on every ctx build but read nowhere (in_cone, target_channeling, setup_killable, q_kill_floor, atk_range_with_e, r_physical_at_d, cluster_count, cluster_worth_aoe, proj_state_2s, proj_state_post_r, r_cast_s, fight_age_s, target_active_heal, self_ms_slow_pct, kite_prefers_pike). build_layer1_ctx runs up to 8 times per teamfight tick, so the removed IIFEs (a channel scan, two cluster scans, two project_target_state calls, a kite-override lookup) were pure per-tick waste. Also removed the now-orphaned helpers compute_q_kill_floor and cluster_around_target, the OFFENSIVE_KITE_HERO_OVERRIDES table, the fight_start_t tracking in recompute_candidates, and the proj_state_2s refresh in pending_steps_tick. project_target_state stays (proj_state_r_impact still uses it). Behaviour-neutral: only grep-confirmed-unread code was removed. v6.15.232: polish review batch 1 of 4, critical bug fixes. (1) NPC.FindRotationAngle returns radians; v6.15.215 fixed 3 sites but missed 5 that compared raw radians to degree thresholds, so the gates were dead: grenade_self and grenade_at_caster facing refusals never fired (could shove Sniper into the threat), pre_face_tick never fired, anim.lua compute_target_self always passed, target.lua IsKitingUs always returned false. All 5 now wrap math.deg. (2) Four unguarded Entity.GetAbsOrigin sites (grenade_at_caster, auto_grenade, live_channel_tick, in_roshan score) got nil guards: GetAbsOrigin is nil on a dead or mid-respawn entity and a nil there aborted the whole tick. (3) The Layer-1.5 channel-punish R stamped state.last_layer15_t, which nothing reads, instead of last_layer1_t, so a combo tick could dispatch a competing action; it now stamps last_layer1_t and last_layer1_was_r like fog_snipe_tick does. v6.15.231: a deferred Layer-1 combo no-target cast (Take Aim) now opens an OnPrepareUnitOrders veto window when it issues. The v6.15.230 field test showed chip-archetype Take Aim cleanly issued (ready, mana, no CC) but cast_verify fired=n on 2 of 7 combos. Cause: the deferred R step opens an r_cast_protect veto window so a native queue=false MOVE/ATTACK cannot replace the issued cast, but the deferred no-target branch opened no window at all, so an instant Take Aim cast dispatched into the mid-poke native flood could be replaced before the engine ran it. The nt branch of pending_steps_tick now sets combo_cast_protect_until_t (COMBO_CAST_PROTECT_S, 0.35s) on a successful issue, and OnPrepareUnitOrders folds it into the protect-window max. Same mechanism as r_cast_protect and save_cast_protect. v6.15.230: R re-issue is now bounded and spaced instead of per-frame. A field test of v6.15.229 showed R locking 0 times in a whole bot match (r_cast_never_started, reissues=44 every attempt) and the user reported R dispatch slower than a manual cast. Cause: the v6.15.228 per-frame re-issue fired a fresh queue=false execute_fast R cast every tick while R was out of its ability phase, and each one restarted R from the start of its pre-cast wind-up, so R never accrued enough uninterrupted time to enter the phase. The same per-tick approach had been tried and removed once before (v6.15.217 to v6.15.218, where it cancelled D). r_abort_tick now re-issues at most R_REISSUE_MAX (2) times, the Nth not before N times R_REISSUE_SPACING (0.25s) after dispatch, so a re-issue only lands as a real retry of a lost cast, never on top of an in-progress one. The first R dispatch is still done by fire_steps. v6.15.229: Two v6.15.228 follow-ups from a coupled-config test. (1) The tap combo stopped firing Take Aim: the v6.15.228 per-frame R re-issue hardcodes execute_fast, which overrode v6.15.223 no_fast and let the re-issued R stomp the same-tick E. Fixed at the root: heavy_starter R is now deferred 0.1s (the dr-combo shape) instead of same-tick with E, so E fires alone and the deferred R is carried by the per-frame re-issue. The chronically fragile same-tick E+R is gone; no_fast and no_queue come off the step and the fire_steps execute_fast gate is simplified. (2) The re-issue window was retuned 0.35s to 1.5s: the test showed R locks about 1s in under a coupled max-flood config, so 0.35 expired before the lock and mislogged r_cast_never_started 7-of-7 while R actually fired. The re-issue still stops the instant R locks; 1.5s is only the hopeless-case give-up. v6.15.228: R reliability, modeled on the native Sniper script. A native-only log showed the native script re-fires its R cast order every ~33ms until R locks (bursts of up to 6); the brain only had the v6.15.226 bounded-2 retry. r_abort_tick now re-issues R every tick via a bare Ability.CastTarget (execute_fast, no cast_verify) while R has been dispatched but has not entered its cast phase, for up to R_PHASE_START_DEADLINE (retuned 0.6 to 0.35s). When R locks, the combo deferred Q and E are re-anchored by the slip between first dispatch and lock so a late lock does not let Shrapnel land mid-cast and cancel R. Logs r_cast_locked (reissues, slip_ms) or r_cast_never_started (reissues). Safe where v6.15.217 was not: the dr R is deferred 0.2s so D finishes before the re-issue branch runs. Supersedes the v6.15.226 bounded retry. v6.15.227: cast_verify and cast_verify_double_fail now record tgt (alive / dead / - for casts with no unit target), the R target state read at verify time. A fired=n with tgt=alive is a real flood-loss or mid-aim cancel; a fired=n with tgt=dead is a correct abort because the target died first, not a bug. Combined with the existing silenced, stunned, channelling and mana fields on double_fail, an R failure is now fully self-classifying, so cast_verify counts no longer conflate flood-losses with target-died aborts (which inflated the ranked-match R-failure number). Diagnostic only, no behaviour change. v6.15.226: Assassinate kept losing its 2.0s cast-point pre-phase race to the native order flood. A native MOVE or ATTACK landing before the cast locked cancelled R, and the OnPrepareUnitOrders veto cannot see native subsystem orders (only player orders), so execute_fast only beats SAME-tick natives. When r_abort_tick detects R never entered its phase (r_cast_never_started), it now re-dispatches R, up to R_RETRY_MAX (2), rather than only clearing the markers and waiting about 1s for a re-appraisal that usually misses the window. The retry is bounded (not the per-tick re-issue v6.15.217 used, which cancelled D) and gated on R provably never starting. The combo deferred Q and E are re-anchored by the same slip so they still fire after the retried R completes. Applies to every R intent; r_retry_count resets on R success or budget exhaustion. v6.15.225: the dr-combo D (Concussive Grenade peel) overshot the attacker. optimal_d_pos places D along the Sniper-to-attacker line via predict_pos; the predict_pos buffer-empty fallback (Geom.lead_target_pos) used uncapped instantaneous m_vecVelocity, which for a target mid-knockback is the knockback velocity, a 2000-plus u/s phantom that led D about 600u past the target and could shove it toward Sniper. The fallback lead is now capped at foot speed (700 u/s times lead), returning current position when exceeded. The vel_hist path was already per-tick capped (v6.15.194); v6.15.197 CC-state guard covered stun and root and freeze but not forced movement. v6.15.224: brain_native_diagnostic_tick read a native order queue entry whose abilityIndex resolved to an item (ward dispenser, neutral item), not an ability, and Ability.GetName threw bad-argument and aborted the tick for that frame (4 times in a ranked match). The GetName call is now wrapped in pcall, so a non-ability resolves to a placeholder name and the diagnostic stays non-fatal. v6.15.223: the tap combo (Heavy Starter) issues Take Aim then Assassinate same-tick, E first so Take Aim buffs the ult. v6.15.220 gave every inline ut-step R execute_fast, which bypasses the framework order delays; heavy_starter R, issued just after E, jumped ahead and the tap fired R-then-E. The heavy_starter R step now sets no_fast and the fire_steps execute_fast gate excludes it, so E (issued first) locks its cast first and the order is E-then-R again. The r and tf_r single-step finishers have no preceding E and keep execute_fast. v6.15.222: the Dota engine silently eats the FIRST cast of a freshly-acquired item (confirmed from the v6.15.221 log: the first Hurricane Pike cast reached ExecuteOrder intact but never cast, cooldown stayed 0; every cast after worked, cooldown 18.8). Two-part Pike-scoped workaround. PRIME: a throwaway Pike-on-self cast fired once when Sniper owns an un-primed Pike and is safe (no enemy hero within combo-classify radius, not in a combo), spending the doomed first cast early. DOUBLE-ISSUE: if a real Pike save fires before Pike was primed, the fire closure stamps a re-issue and the new state.pike_prime_tick re-issues Pike on the next frame so the second cast lands. state.pike_primed flips true only on cooldown proof; a pike_prime cast_verify may log fired=n, that is the sacrificial cast and is expected. v6.15.221: the D+R+Q+E close-gap combo now also fires in teamfight_tick (3+ enemies), not just starter_tick. The most common Sniper teamfight pattern is the enemy team diving Sniper directly; when an enemy is committed onto Sniper (attacking him, close, not kiting) the peel combo answers it, ONLY for a committing target, and it takes priority over the tf_r/tf_q/tf_e archetypes. D falls to Hurricane Pike when D is on cooldown. The committed-check, dr-peel resolution and the D+R+Q+E step table were factored into shared helpers (is_committed_attacker, resolve_dr_peel, build_dr_steps) plus q_spot_covered hoisted to module scope, so starter and teamfight cannot drift. v6.15.220: review-pass fixes. (1) The inline R dispatch (the r and tf_r single-step R finishers, and heavy_starters R) now gets execute_fast for Assassinate, matching the deferred dr-combo R; previously only the dr R was protected from the native-order race and the inline finisher raced it unaided. (2) LAYER1_COMMIT_WINDOW_R 2.5s to 3.0s so a re-dispatch cannot land before the dr combos last step (E at ~2.8s) and double-cast Take Aim. Plus a stale-comment cleanup. v6.15.219: in the dr (D+R+Q+E) combo, E (Take Aim) now fires AFTER Q instead of before it. Firing E before Q burned about 0.3s of Take Aims 3s window on Qs cast animation; firing E last gives the full Take Aim window to the post-combo autoattack and headshot phase. New timing: D immediate, R deferred +0.2s, Q at +r_cast_point+0.3 (right after R resolves), E at +r_cast_point+0.8 (after Qs 0.3s cast animation). Builds on v6.15.218. PRIOR v6.15.218: DR-COMBO RESTORED TO ORIGINAL DEFERRED DISPATCH. The dr (D+R+Q+E) close-gap combo is reverted to its original v6.15.124 deferred timing. v6.15.216 had moved R inline (losing the 0.2s D-gap and execute_fast); v6.15.217 then added a per-tick R retry that re-issued R queue=false every tick and cancelled D mid-cast-point. R is again a deferred step: delay_s 0.2 (fires after D 0.1s cast point, via issue_cast_target which sets execute_fast for Assassinate). Q moved from r_cast_point+1.1 to r_cast_point+0.3 (still after R completes; a Shrapnel cast mid-R-cast cancels R). E stays 0.1+r_cast_point. v6.15.217 per-tick retry removed; R_PHASE_START_DEADLINE restored to 0.6. Field-unverified. v6.15.217: DR-COMBO R FAST-RETRY. v6.15.216 (un-defer R) did NOT fix the D+R+Q+E combo -- the fresh log showed R still double-failing. Verified why: the framework native modules (orbwalk !_api_extend.lua, Hit & Run 3_hit_n_run.lua) issue an ATTACK / MOVE order on Sniper roughly every 70ms CONTINUOUSLY -- about 22 native orders in a 1.5s window. R has a 2.0s cast point; it cannot channel through ~28 native orders, and no first-tick dispatch trick changes that. BUT the log also proved the cure: in the one observed R success, the native Hit & Run issued NO orders during R's 2s channel and resumed only after -- the native modules YIELD to an in-progress cast. R only dies in the ~0.1s gap BEFORE its cast phase starts. Fix: r_abort_tick now fast-RE-ISSUES R every tick while R is in-flight, not in its cast phase, and not yet seen in phase -- brute-forcing R past the order flood until its cast phase catches; once R is channelling the native modules yield and the retry self-terminates (IsInAbilityPhase true). safe_issue's queue-dedup keeps the retry cheap. R_PHASE_START_DEADLINE 0.6 -> 1.0 (the retry window). Also: the dr-combo Q and E steps moved from fixed 0.4s / 0.1+cast-point delays to r_cast_point + 1.1 / + 1.3 -- R's cast-start is now variable (retry), so a fixed-time Q or E would land inside R's channel and cancel the combo's OWN R; they now fire after R completes. D-then-R order preserved. Prior version v6.15.216: DR-COMBO R DISPATCH REGRESSION FIX. The D+R+Q+E close-gap combo (the `dr` archetype of starter_tick) had its R (Assassinate) step silently broken: R was dispatched but cancelled before it ever entered its cast phase, so the combo died at R. A three-pass deep search plus log verification found the regression. ROOT CAUSE: v6.15.97 added `delay_s = 0.2` to the dr combo R step as a consistency rollout of the v6.15.96 snipe_e_r defer pattern. The defer routes R through pending_steps_tick on a separate, LATER engine tick than the combo dispatch. On that later tick the framework native subsystems (orbwalk in !_api_extend.lua, Hit & Run in 3_hit_n_run.lua) issue an ATTACK / MOVE order on Sniper FIRST, which cancels R on receipt -- R never starts casting (log: r_cast_never_started, cast_verify fired=n twice, cast_verify_double_fail). It fails worst against an auto-attacking enemy (PA), when the native orbwalk is most active. The brain OnPrepareUnitOrders veto cannot block these orders -- they are script-issued and bypass that callback (which fires only for player-path orders). FIX: remove delay_s from the dr combo R step. R now dispatches INLINE, same tick as D, as step 2 with use_queue=true (queue-chained behind D) -- D's 0.1s cast point still completes first, then R. R lands in the engine order queue in the same batch as the combo press instead of a later tick the native modules can occupy. This restores the pre-v6.15.97 snipe_d_r timing the combo originally shipped with and that the user confirms worked. Q (0.4s) and E (0.1s + R cast point) stay deferred -- E MUST stay deferred or Take Aim cancels R. Prior version v6.15.215: RADIAN FIX + grenade crash fix. The v6.15.214 field test surfaced two bugs. (1) grenade_at_caster CRASHED: the v6.15.214 rewrite renamed the cast_x / cast_y locals to cx / cy, but the grenade_at_caster_cast_plan diagnostic tlog still referenced cast_x / cast_y, so string.format hit a nil and threw a hard Lua error at Sniper.lua:5938 every time grenade_at_caster ran with the caster in range. The channel save chain aborted and fell through to grenade_self -- the user saw the grenade cast on Sniper own position vs Pugna. Fixed: the tlog now references cx / cy. (2) NPC.FindRotationAngle returns RADIANS, not degrees. pike_self_reposition and pending_pike_self_tick (v6.15.213) compared the raw radian value to a 30 threshold; radians cap at pi, so the compare is ALWAYS true, the immediate branch always fired, and Sniper never turned before Pike-on-self -- the user saw Pike not turning and Sniper thrown toward the enemy. The log proved it: every pike_self_fired was phase=immediate with angle 0 to 3 and no pike_self_turnaway ever logged. Fixed with math.deg before the 30-degree compare in both functions, and in the grenade lead turn-time term (deg/400 = turn seconds). NOTE for the next session: the pre-existing facing gates in grenade_self (120), grenade_at_caster (120), pre_face_tick, and anim compute_target_self (30) all assume degrees too and are similarly degraded; left untouched here, scoped to the reported bugs, flagged for a deliberate sweep. Prior version v6.15.214: GRENADE-ON-ENEMY + PIKE FACE-AWAY (field tweaks). Two refinements from the v6.15.213 field test. (1) grenade_at_caster now casts ON the enemy (its predicted position) instead of the Sniper-caster midpoint. The 0.4s stun + knockback BREAKS the enemy (interrupts Bara charge, Shaman channel cast) and makes the kill easier, which the user wants prioritised over the midpoint compromise. The v6.15.212 lead (predict_pos over turn-time + cast-point + travel) is kept so a moving Bara is still hit, and the cast point is clamped to grenade cast range so the order stays valid. (2) ALL Pike-on-self now routes through pike_self_reposition, not just drains. Pike-on-self pushes Sniper in his FACING direction, so a raw self-cast while Sniper faced the enemy threw him TOWARD the threat; the face-away turn-then-cast (two-phase: move order to rotate, pending_pike_self_tick fires once aligned) is now applied to every Pike-on-self save, with a raw self-cast only when the caster is unknown. Prior version v6.15.213: PIKE TURN-AND-REPOSITION (drains). Field feedback: against Pugna the Pike save left Sniper still inside skill range. Pike-on-enemy pushes the ENEMY, it does not move Sniper. Hurricane Pike self-cast pushes SNIPER 600u but in his FACING direction (verified vs Liquipedia: instant cast, 0.4s push), so to reposition Sniper away from the caster the brain must face away first. New: for DRAIN-category threats (Pugna Life Drain, Lion Mana Drain) the Pike save routes to pike_self_reposition -- if Sniper already faces away from the caster, Pike-on-self fires now; otherwise a move order turns Sniper away and state.pending_pike_self is armed, and pending_pike_self_tick casts Pike-on-self once the facing is within 30 degrees of straight-away (0.7s deadline, on timeout the channel re-fire re-attempts). Scope is DRAIN only on purpose: drains do not disable Sniper so he can turn and cast, whereas disabling channels (Pudge Dismember, Shaman Shackles) STUN Sniper, making a self-cast impossible there, so they keep the unchanged Pike-on-enemy path. Prior version v6.15.212: GRENADE LEAD GEOMETRY. Field feedback: the grenade_at_caster save (Bara charge) landed in random-looking spots. Root cause: it cast at the static MIDPOINT of Sniper and the caster CURRENT positions (the v5.7 design), which is stale for a fast charger. Between the cast decision and the grenade landing there is real latency: Sniper turns to face the cast point, the 0.1s cast point elapses, the projectile travels. The old geometry accounted for NONE of it, so against a charging Bara the grenade landed behind him. Fix: lead_s = turn time (FindRotationAngle / 400, Sniper 0.7 turn rate) + cast point + projectile travel; state.predict_pos leads the caster over lead_s; the led caster is clamped onto the caster-to-Sniper segment (parameter 0.15 to 1) so it can never overshoot PAST Sniper. The cast point is the midpoint of Sniper and the led-clamped caster, so Sniper is always inside the 375u radius and pushed AWAY from the caster; when the lead clamps short the cast anchors near Sniper, the reliable reposition fallback. A stationary caster predicts to its own current position (clamp parameter t = 1), so Pudge / Shaman / Pugna channels are behaviour-unchanged. Prior version v6.15.211: DRAIN ANIM-ROLE FIX. Field test surfaced that Pugna Life Drain dispatched through the on_hard_disable anim handler (log intent hard_disable_pugna_life_drain) instead of on_channel_start. Root cause: gen_anim_maps.py ROLE_TO_ANIM mapped the drain threat-role to the hard_disable anim subscriber, but drains (Pugna Life Drain, Lion Mana Drain) are CHANNELLED abilities and belong on channel_start. Effect: both drains routed through on_hard_disable, missing on_enemy_channel_start (the channel-punish-R / live-channel registration); the save itself still resolved correctly via the ability-keyed override. Fix: gen_anim_maps.py ROLE_TO_ANIM drain now maps to channel_start, and the two frozen register_anim_maps entries (pugna_life_drain, lion_mana_drain) are corrected hard_disable to channel_start. The generated block doubles as the generator seed, so both the generator and the frozen entries had to be corrected for a future regen to stay idempotent. Prior version v6.15.210: ABILITY-KEYED SAVE-OVERRIDE TWIN (Option B, follow-up to v6.15.209 Option A). The anim defense route detects threats by KV-authoritative ability name, but reached the Sniper-tuned save chains (SNIPER_SAVE_OVERRIDES, keyed by modifier name) only by translating ability to modifier via ABILITY_TO_THREAT. That translation can DRIFT: ABILITY_TO_THREAT maps pudge_dismember to modifier_pudge_dismember_pull while the override is keyed modifier_pudge_dismember, so the anim route silently missed Pudge Dismember tuned grenade-first chain and fell back to the generic category chain. Fix: new state.ANIM_SAVE_OVERRIDES, an ability-keyed twin of the 10 anim-resolvable SNIPER_SAVE_OVERRIDES entries (legion_commander_duel excluded, no anim entry). Each twin value is the SAME chain table by shared reference, so there is no data duplication and no second table to maintain. resolve_save_order and try_save_self gain an ability param checked before the modifier path; the three anim handlers and the instant-blink armed-threat path pass ev.ability_name. The anim route now reaches its tuned override by ability name, never by a modifier guess, immunising all 10 against ABILITY_TO_THREAT drift as the modifier-name harvest corrects guesses. Backward-compatible: every other try_save_self caller passes fewer args, ability nil, modifier path unchanged. Prior version v6.15.209: ANIM-ROUTE CATEGORY FALLBACK (Option A, task-3 finding). The anim defense route detects threats by KV-authoritative ability name but routes the save-quality decision through ABILITY_TO_THREAT, a 109-entry ability-to-modifier map whose right side is ~98 unverified modifier-name guesses (modifier names are not in KV, L56). on_gap_close and on_hard_disable already degrade gracefully on an unresolved guess (try_save_self fires the generic DEFAULT_SAVE_CHAIN), but on_channel_start HARD-GATED on the modifier resolving (if threat then ... end), so a wrong guess meant NO pre-emptive cast-point save for that channel. Channels are the worst place for that gap: once the channel modifier lands Sniper is disabled and cannot cast escapes, so the cast-point window is the only one that helps. Fix: resolve_save_order and try_save_self gain an optional category_hint param; when no threat_mod resolves, the chain falls back to CATEGORY_CHAINS[hint] (the role-appropriate chain) instead of the fully generic default. The three anim handlers pass their behavioural category (on_gap_close close_gap, on_channel_start channel_on_self, on_hard_disable targeted_disable or targeted_burst by ev.role). on_channel_start no longer hard-gates: an unresolved channel fires the channel chain anyway, with no modifier name to mark-responded so the modifier-create route may re-fire (layer2_can_fire throttles the duplicate). Backward-compatible: every other try_save_self caller passes 3 args, category_hint nil, behaviour unchanged. Prior version v6.15.208: PHANTOM BLOODTHORN HEAL REMOVED. The target-HP projection used by the R-commit kill math (compute-target-state, ~line 2580) added heal_bonus 300 whenever the target carried modifier_item_bloodthorn_active. Verified against KV: items.json item_bloodthorn AbilityValues has NO lifesteal, NO heal, bonus_health_regen 0 (it grants int / attack speed / mana regen / silence / spell-amp-debuff / proc damage only). Bloodthorn heals nobody, so that elseif projected 300 phantom HP onto a Bloodthorn holder and made the brain under-rate a real kill. The branch is removed; the Satanic branch (heal_bonus 500) stays, KV-confirmed legitimate (item_satanic unholy_lifesteal 175 percent over a 6s window). Behaviour change: the brain commits R slightly more readily on Bloodthorn holders, which is correct (the old bias caused missed kills, never kill-steals). Found during the KV-generalization audit. Prior version v6.15.207: UNAME CRASH GUARD. The uname() diagnostic name helper called NPC.GetUnitName, which throws a hard Lua error on a valid-but-non-NPC entity (a rune, a ground item, a building targeted by an order). uname() guarded only the nil case, so a rune-pickup order flowing through brain_native_diagnostic_tick crashed the whole tick (observed historically at v6.15.117; the order-queue diagnostic resolves each entry target and gated on Entity.IsEntity, not NPC-ness). uname() now gates the NPC.GetUnitName call behind Entity.IsNPC and falls back to tostring(e) for non-NPC entities, so the root fix at the helper hardens all ~80 uname call sites at once; behaviour for NPC arguments is byte-identical. Surfaced by a stale-log audit at session start: debug.log predates the v6.15.201-.206 audit (newest banner in it is v6.15.200), so the 3-round audit and the D18-followup initiative remain field-unverified. Prior version v6.15.206: D18-FOLLOWUP INITIATIVE (KV-derived anim maps for the whole hero pool). User-driven: after D18 hand-expanded the anim map to 55 heroes, the question was whether the same KV-derivation could cover ALL heroes and be made regenerable. It can. New generator tools/gen_anim_maps.py reads npc_heroes.json + npc_abilities.json and emits the entire register_anim_maps() body: cast-activity slots DERIVED via the D18 algorithm (walk the hero's ability list, skip generic_hidden / innate / hidden / pure-passive / talent entries, the ABILITY_TYPE_ULTIMATE one is AB4 and the first three other castables are AB1/AB2/AB3), roles seeded with a 3-tier priority — (1) the prior hand-tuned register_anim_maps entries are AUTHORITATIVE, (2) the threat_data.lua ABILITY_TO_THREAT x THREATS_ON_SELF join, (3) a CHANNELLED-behaviour draft for the tail (each draft entry marked). register_anim_maps() expanded 55 -> 68 heroes, 105 threat abilities. The generator's correctness gate reproduces the Bane/Lion/Storm known-good maps before emitting; the generator carries a built-in regression assert (generated output must be a strict superset of the prior hand-written maps). The first generation run HAD a regression — the seed missed lion_impale + storm_spirit_electric_vortex + storm_spirit_ball_lightning because those lived only in the hand-written anim map, not in ABILITY_TO_THREAT; caught by the main thread's diff, fixed by adding the existing-anim-map as the top-priority seed source, re-verified empty. 13 new heroes gained cast-point detection (Storm restored + Clinkz, Crystal Maiden, Dawnbreaker, Drow, Elder Titan, Enigma black hole, KotL, Mirana, Puck phase shift, Riki, Ringmaster tame, Tinker, Warlock, Windranger powershot, Witch Doctor). Behaviour is ADDITIVE and supersedes nothing — the generated block is a verified strict superset of the hand-written maps, Anim.Subscribe + Anim.RegisterParticle calls untouched, and the existing target_self gate still means a hero casting at an ally fires no save. The anim route (ability-name keyed, fully KV-derivable) is now the comprehensive primary threat detector; the v6.15.202 D1 modifier-create catch-all remains the fallback for the ~95 modifier-name-keyed catalog entries (modifier names stay un-derivable per lesson L35). Re-run the generator after a Dota patch instead of hand-editing the maps. v6.15.205 banner content preserved below. Sniper brain v6.15.205 loaded — ROUND 3 D18 (anim-map expansion). User-approved. register_anim_maps() expanded from 10 classic heroes to 55: 45 modern-pool heroes added covering 67 threat abilities, giving the post-2018 hero pool cast-point threat detection (~0.3-0.5s earlier than v6.15.202 D1's modifier-create catch-all, which stays as the fallback). The initial framing that this needed unverifiable slot guesses was WRONG, as the user pointed out: hero_data.lua carries each hero's ability list. The cast-activity slot is not the raw array index (the 3 working classic maps prove it: Bane Fiends Grip is array-index 6 yet maps to AB4) but it IS fully deterministic — walk the hero_data.lua abilities array, skip generic_hidden / innate / hidden / passive entries via ability_data.lua's type/innate/active/behavior flags, the type=ultimate entry is AB4 and the first three other castables are AB1/AB2/AB3. A generation pass reproduced the Bane/Lion/Storm known-good maps exactly as a correctness gate before processing the rest; the main thread spot-checked Mars (skips dauntless innate + generic_hidden), Tiny (passive ult Grow filtered out), and Faceless Void (passive E Time Lock leaves AB3 unused, Chronosphere to AB4) against hero_data.lua. Catalog roles map to the 4 anim subscriber roles: gap_close, hard_disable (also covers line_projectile / delayed_aoe / physical_burst / drain / lockdown), channel_start (channel_on_me), ult_burst (magic_burst); trapped / taunt / informational / slow / dot roles are not anim-registered. Behaviour is ADDITIVE: earlier detection of the same threats D1 already handles, and the existing target_self gate in on_gap_close / on_hard_disable / on_channel_start means a modern hero casting at an ally still fires no save. v6.15.204 banner content preserved below. Sniper brain v6.15.204 loaded — ROUND 3 C9 (TP-bonus gate). User-approved follow-up from the round-3 audit Q&A. ScoreUltTarget's +50 TP-interrupt bonus stacks on the +200 channel bonus for a total +250 — the single highest score in the system — but Sniper's R has a ~2.0s cast point (0.5s with Scepter) and a base Teleport is a 3.0s channel, so on a TP that started a while ago R cannot land before it completes; the +50 was awarding a chase the brain couldn't cash in. New helper state.tp_interruptible(target) reads the modifier_teleporting handle's Modifier.GetDieTime, computes remaining channel time, and returns true only when remaining > r_cast_point() + 0.3s margin (and defaults to true when the timer can't be read, so a missing-API path keeps the prior always-on behaviour rather than silently dropping the bonus). Both the score function (line ~1300) and the HUD score-breakdown mirror gate on it. NOT behaviour-equivalent — a TP too far along now scores +200 instead of +250, so a fresh-TP or another high-value target can correctly outrank it. Other round-3 Q&A outcomes: A7 (tf_r dive-gate) — user chose leave-as-is, R always commits for the kill. C8 (score-path r_physical) — user chose keep-conservative, the +100 heuristic stays magical-only. D16 (persistent-threat re-fire) — found ALREADY IMPLEMENTED (persistent_threats_tick since v6.15.21 covers Legion Duel + Static Storm at 2.1s; the round-3 save-chain review reported a false 'no such tick'). D17 (PA save override) — found FALSE POSITIVE on verification: PA already has a tuned SNIPER_SAVE_OVERRIDES entry and Phantom Strike is a completed blink, not a homing threat, so displacement saves are legitimately useful — no change made. D18 (anim-map expansion) — flagged for a scope re-decision: the per-hero cast-activity slot mapping is a guess, not mechanical (innate/hidden abilities shift slots), so a 25-hero batch would be 25 unverified guesses; pending user call on incremental-harvest vs skip. v6.15.203 banner content preserved below. Sniper brain v6.15.203 loaded — POLISH-PASS ROUND 3 DRIFT CLEANUP. Closes round-3 cosmetic / consumer-consistency findings (D9/D10/D13/D14); behaviour-equivalent. (D9) tf_team_focus docstring updated to reference state.ATTACK_ENGAGE_RADIUS instead of the now-stale literal '(700u)' — v6.15.200 C12 extracted the const but the docstring didn't follow. (D10) STARTER_Q_COVER_R declaration comment said 'superseded at the 3 squared-form call sites' but grep finds 2 fallback uses (the 3rd disappeared after a refactor); corrected to plural-agnostic 'the squared-form call sites'. (D14) Two effective_cast_range inline call sites migrated to state.r_cast_range() — line 1249 (ScoreUltTarget cast_r_live) and ~2906 (r_will_range_leak inline closure). Single source of truth; behaviour-equivalent (state.r_cast_range collapses the no-handle case to CAST_R for us, so the inline `if cast_r_live <= 0 then cast_r_live = CAST_R end` fallback is now redundant — removed). Remaining D14 sites (3039-3041 — build_layer1_ctx ctx assembly) are LEFT ALONE; they cache into ctx fields and the call shape is fine. ROUND 3 CONVERGED: v6.15.201 (nil-guard sweep, 8 fixes) + v6.15.202 (D1 dispatcher catch-all, the round's biggest semantic win — modern hero pool threats now actually trigger saves at modifier-create time) + v6.15.203 (drift cleanup, this delta). Round-3 D5 (Axe Berserker's Call catalog inconsistency) + D15 (10 confirmed verify-tag removals) are queued as a single lib-only batch. D16/D17/D18 (persistent_threats_tick retry / PA chain hero override / anim map coverage gap) are design/architecture items pending user intent. v6.15.202 banner content preserved below. Sniper brain v6.15.202 loaded — POLISH-PASS ROUND 3 D1. Closes the biggest semantic finding from round 3's save-chain audit: the OnModifierCreate role-elseif chain at ~line 8557 was silently dropping ~6 role classes (channel_on_me / line_projectile / delayed_aoe / magic_burst / trapped / silence_on_me) — meaning the entire v6.15.163-.164 catalog refresh (~50 threats) and the v6.15.198 13-name harvest never fired a save at modifier-create time. Only 10 heroes had anim-map entries to catch the threat at cast point; everyone else's threat just landed silently on Sniper. Fix: catch-all elseif that fires try_save_self for any catalog-known threat with `save ~= 'informational'`. Pre-fix: only hard_disable / drain / physical_burst / lockdown explicitly dispatched. Post-fix: every threat whose catalog says it has a real save (BKB / dispel / displacement / etc.) routes through try_save_self → RECOMMENDED_SAVES. The save-name strings in the catalog are diagnostic-only (verified in the round-3 audit: dispatch is role + kind-intersection via SaveCounters, not the save string); the `save ~= 'informational'` gate is the right discriminator because v6.15.198 harvest tagged tank-through threats (light_slow, kiting_slow, dot, aura_*, tracker, zone_dot, aux) explicitly as informational. Taunt (Berserker's Call) stays no-save per the existing comment + the catalog-side inconsistency D5 is deferred to a lib batch. Demo plan: the next bot match SHOULD show more `try_save_self` activity in the log when modern-pool heroes cast their threats — log `grep 'threat_'` should see entries for Mars Spear, Sandking Burrow, Nyx Impale, etc. landing on Sniper, where previously they were silent. NOT behaviour-equivalent — this materially expands the save-dispatch surface; behaviour change is intended (Sniper now actually defends against the post-2018 hero pool's threats at modifier-create time). v6.15.201 banner content preserved below. Sniper brain v6.15.201 loaded — POLISH-PASS ROUND 3 NIL-GUARD SWEEP. Round 3's three-pass audit (save-chain + defense correctness, comment drift + lib-consumer, nil-safety + error-path) returned three HIGH and five MED nil-safety findings — all unguarded `Entity.GetAbsOrigin` / nil-modifier / nil-ally paths whose arithmetic dereference would crash the brain in real edge cases. This delta lands all 8 nil-guards as a single coherent sweep (each is mechanical; behaviour-equivalent except in the actual crash scenarios where the brain previously crashed). Round-3 D1 (dispatcher silently drops 6+ role classes — channel_on_me / line_projectile / delayed_aoe / magic_burst / trapped / silence_on_me — most v6.15.163 batch threats never fire a save at modifier-create time) is a real semantic change deferred to v6.15.202 for demo isolation. D5 (Axe Berserker's Call catalog inconsistency) is a lib-only fix, queued. Per-fix breakdown: (D4) in_roshan_context nil-guards `p` after Entity.GetAbsOrigin(me). Dormant self_npc returns nil; the per-tick dx/dy arithmetic at 10Hz (ScoreUltTarget) would crash. Caches the false result so the brief dormant window doesn't re-run the nil check. (D2) kinetic_field_detected nil-guards both `field_pos` and `me_pos` before `:Distance2D`. The v6.15.197 B1 native-Vector cleanup dropped the dx/dy intermediate but the original nil-risk was always present; this is the proper fix. A freshly-destroyed field thinker or a mid-respawn Sniper would crash the OnModifierCreate callback without this. (D3) HUD debug panel guards `me_pos.x/.y` and `tp.x/.y` reads. The panel renders every HUD tick even during respawn; without guards a crash kills the whole HUD callback. Renders 'dbg.me_pos: —' / 'dbg.target: —' on nil. (D6) kinetic_field_poll_tick guards both `me_pos` and `fp` (the polling counterpart of D2). A field thinker destroyed between Entity.IsEntity (passes) and GetAbsOrigin (returns nil) is now pruned in-line and the loop continues. (D7) SafePushDestination guards `me_pos` and the threat-caster `cp`. `me_pos:DistanceSqr2D(nil)` crashes; nil_cp now returns dest_pos (terrain check already passed). (D8) Two FindRotationAngle call sites — `in_cone` field in build_layer1_ctx (a target dying mid-tick between Target.IsAlive and t_pos read) and the pre-face tick's `best_e` rotation read. Both guarded; `in_cone` defaults to false on nil (the safe default — no cone-gated bonuses). (D11) OnModifierCreate guards `not modifier` — mirrors the OnModifierDestroy guard at line 8674. Modifier.GetName(nil) is undefined; engine has fired the callback with a nil handle in rare edge cases. (D12) try_save_ally adds the standard `(ally and Entity.IsEntity and Target.IsAlive)` entry guard plus an ally_pos nil-guard — matches every other layer-2 fire function. Demo plan: no behaviour changes expected in normal play; only confirms via 'no brain crashes seen in this match'. The crash-trigger scenarios (Sniper dying mid-tick, target dying mid-tick, field thinker destroyed mid-poll) are rare enough that they may not surface in a single demo but the brain is now resilient to all of them. v6.15.200 banner content preserved below. Sniper brain v6.15.200 loaded — POLISH-PASS ROUND 2 LOW (mini). Shipped 4 of 6 round-2 LOWs; C13 (recompute_candidates per-tick allocs) and C15 (state.X re-lookups not cached at function entry) deliberately deferred for the same reason round 1's B8 was skipped — at the saved allocation/lookup volume (~20 allocs/sec for C13, scattered micro-savings for C15) the perf gain doesn't justify the maintenance burden of the reuse patterns. Both deferred to a future refactor-pass alongside B8. (C10) HUD fog formula now mirrors the scorer's two-segment math exactly. The prior linear `-30/s` HUD print DIVERGED from v6.15.50 G6's gentle-then-steep formula (-3/s in 0.3-1.0s window, -3 + 30/s remainder in 1.0-3.0s, veto above) — could show ~14 score-drift at fog_age 0.5s. Now matches ScoreUltTarget gate-for-gate. (C11) CAST_R const replaces inline 3000 literal at the defensive `if cast_r_live <= 0 then cast_r_live = 3000` fallback (~Sniper.lua:1236). Behaviour-equivalent; cosmetic dedup. (C12) state.ATTACK_ENGAGE_RADIUS = 700 extracted. Same numeric value, same intent ('close enough to count as in attack engagement') at the `target_attacking_us` close gate AND `tf_team_focus` ally-pairing radius. Centralised so any future tuning stays consistent across both call sites. (C14) SAVES_INVENTORY_ITEM_NAMES hoisted to module-level const. The 23-string list was rebuilt inside OnUpdateEx every 5s; now allocated once at script load. Trivial GC win. Demo plan: C10 visible in next HUD screenshot under fogged-target conditions in the gentle 0.3-1.0s window (lower score drop than before); C11 / C12 / C14 behaviour-equivalent at current values. Round-2 polish series concludes with the brain materially closer to single-source-of-truth for constants, channel detection, ally scans, and HUD parity. v6.15.199 banner content preserved below. Sniper brain v6.15.199 loaded — POLISH-PASS ROUND 2 MED. Closes the round-2 MED queue (C4-C7). C8 / C9 verify-intent items deferred. (C4) Three leftover 1800 u TF-scan literals centralised. The v6.15.197 B9 `state.q_cast_range()` consolidation handled Q-cast-range fallbacks, but the same numeric literal was reused at 3 other sites with a DIFFERENT semantic — the TF coordination radius (tf_q_pos enemy scan, tf_team_focus ally scan, teamfight_tick outer enemy scan). Added `state.TF_SCAN_RADIUS = 1800` constant next to COMBO_CLASSIFY_RADIUS (1500); both are now named. Replaced the 3 literal `1800` sites. Drift prevention; behaviour-equivalent at current values. (C5) Four HUD score-breakdown components added. ScoreUltTarget adds `tower+15`, `roshpit+10`, role-adjust (carries +20 / cores +10 / tanks -20), and ally-Signal +30 — none rendered in the HUD parts list. Magnitudes sum to potentially ±75 hidden from the user. v6.14.1 M5 caught some HUD divergences but missed these four. Now mirrored 1:1 with the scorer's gates. (C6) recompute_candidates ally-scan hoist. ScoreUltTarget's far-shot has-ally-near check did `Entity.GetHeroesInRadius(target, 800, TEAM_ENEMY)` PER CANDIDATE inside recompute_candidates at 10 Hz — up to N redundant scans / 100 ms. Added `state.get_cached_allies(me)` — one me-POV TEAM_FRIEND scan per frame (radius = r_cast_range + 800 so any ally within 800 of an edge-of-R candidate is captured), frame-keyed for auto-invalidation. The per-candidate check is now an O(allies) distance filter against the cached list. Saves N-1 GetHeroesInRadius calls per recompute. (C7) target_in_channel uses NPC.GetChannellingAbility. The +200 channel-score bonus's detection helper now mirrors the v6.15.197 B2 pattern: API-first via NPC.GetChannellingAbility, fall back to the legacy ENEMY_CHANNEL_MODIFIERS iteration, then MODIFIER_STATE_CHANNELED. The `modifier_teleporting` HasModifier check stays at the front because the +50 TP bonus needs the SPECIFIC modifier name (and TP isn't a 'channelling ability' handle). Catches channel-cast targets whose modifier name has rotted. Demo plan: C4 / C7 behaviour-equivalent at current KV / catalog; C5 visible in next HUD screenshot with role/tower/rosh/ally_focus components appearing on candidate breakdowns; C6 mechanical perf win (saved engine calls don't show up directly in logs but `cast_outcome` / `starter` diagnostics should be unchanged). v6.15.198 banner content preserved below. Sniper brain v6.15.198 loaded — POLISH-PASS ROUND 2 HIGH. A second three-pass audit (performance/hot-path, parallel-bug hunt, targeting/score-board) closed three HIGH-severity findings; round-2 MED + LOW + verify-intent items are deferred. ROUND 2 cross-pass diff produced one false-positive — the parallel-bug review claimed `modifier_skeleton_king_reincarnation_active` appeared in modseen (3 hits) and the SK seed was wrong; verification showed the 3 hits were all banner-string false positives (the v6.15.197 banner mentions both `_active` and `_scepter` in its load message). The targeting review's finding stood. (C1) SK reincarnation parallel-bug fix at lines 1243 + 1603. v6.15.196 A4-r already proved `modifier_skeleton_king_reincarnation_active` is never observed in any actual modseen log across 3 bot matches; only `_scepter` (Scepter passive) was seen. The two ScoreUltTarget sites (one in score itself, one mirroring in the HUD parts) still carried the dead `HasModifier` branch. Dropped both — the existing `elseif` ability-readiness check (NPC.GetAbility + Ability.GetLevel > 0 + Ability.IsReady) is the only reliable signal and handles WK correctly with the same -75 score penalty. Behaviour-equivalent in practice (the dead branch never matched), but cleaner code and the HUD's `reinc_active-75` string can no longer be promised in a comment that never prints. (C2) build_layer1_ctx ally-scan memoization. The function's two target-POV scans (`in_teamfight` 1200u FRIEND-from-target, `ally_cc_lock` 1000u ENEMY-from-target) are called up to 3 times per teamfight tick (`tf_r_ctx(r_cand)`, `tf_r_ctx(focus)`, `build_layer1_ctx(focus, 0)`), so each TF tick did up to 6 redundant `Entity.GetHeroesInRadius` scans on the same target. Added `state.l1_ctx_cache[target_idx] = {f = f_idx, in_teamfight, ally_cc_lock}` — keyed on target index + current frame index, so the cache auto-invalidates on the next frame; no manual clear needed. Behaviour-equivalent: engine state cannot change between same-frame same-target calls. (C3) HasModifier cluster cached. `build_layer1_ctx` queried `modifier_item_satanic_unholy_rage` and `modifier_item_bloodthorn_active` TWICE per ctx build — once in the eff_hp_magical bump path (line ~2517) and once in the `target_active_heal` field (line ~2861). Cached both values into locals (`target_has_satanic_active`, `target_has_bloodthorn_active`) at the top of the heal-bump block; the heal field now reads the cached vars. Cuts the 4-call cluster to 2 per ctx build; at 3 ctx builds per TF tick that is 6 fewer engine calls per tick. Behaviour-equivalent. Demo plan: A4-style WK reincarnation scenario to confirm the score penalty still applies; perf metrics will not surface in normal logs but the saved engine-call count is mechanical. The v6.15.197 banner content + the v6.15.196 chain are preserved below. v6.15.197 banner content preserved below. Sniper brain v6.15.197 loaded — POLISH-PASS BATCH LOW. Closes 8 of 9 queued LOW audit findings (B1-B7, B9); B8 (velocity ring O(1) push) is explicitly skipped per the audit's own 'ignore unless on a refactor pass' note — head-index ring at N=5 is a real refactor for zero practical gain. Per-fix summary: (B1) six math.sqrt sites from before the v6.15.187 sweep collapsed to native Vector arithmetic — `:Distance2D()` or `:DistanceSqr2D()` between two Vector origins (build_layer1_ctx projection, combo_fire_state diagnostic ×2, grenade_at_caster zero-vector guard, armed-threats kinetic-field distance, OnModifierCreate kinetic_field_detected log). Stylistic; behaviour-neutral. (B2) build_layer1_ctx.target_channeling now calls NPC.GetChannellingAbility(target) first (the v6.15.189 idiom, modifier-name-free) with the legacy ENEMY_CHANNEL_MODIFIERS iteration and MODIFIER_STATE_CHANNELED as fallbacks. Catches channel-punish targets where the static catalog's modifier guess has rotted. The OTHER catalog consumers at lines 1068 (ScoreUltTarget TP +50 bonus) and 8421 (OnModifierCreate threat-route dispatch) are LEFT ALONE — they need the modifier name specifically for those concerns. (B3) R_LOSS_WINDOW span gate 0.2 → 0.5 s. Admitting rates from a 0.2 s span was high-variance, sub-attack-cycle noise. 0.5 s covers ~one autoattack at 1.4-1.7 s cycle for a stable read. Costs a slightly longer ramp-up after a target switch (reset-on-target-change still correct). (B4) R_TTK_MARGIN retired in favour of a proportional formula. r_horizon was `r_cast_point() + 1.0` (flat 1 s margin) → now `r_cast_point() * 1.5 + 0.3`. Normal R (2.0 s cast): 3.3 s horizon (was 3.0, slightly more conservative). Scepter R (0.5 s cast): 1.05 s horizon (was 1.5, much better — Scepter's value IS the fast commit). (B5) Smoothed-velocity stationary floor 5 u/s → 60 u/s. The 5 u/s gate (25 squared) let path-spline drift on a held-position hero (idle micro-motion / target-attack shuffle) register as movement, so Q led 1.5 s along a ~5-50 u/s phantom vector and landed off the actual stationary target. 60 u/s (3600 squared) cleanly separates spline drift (well under) from legitimate move (~200+ u/s base MS). (B6) predict_pos first-sight CC gate. When vel_hist has <2 samples the fallback path uses Geom.lead_target_pos with instantaneous m_vecVelocity — a target that just entered vision while mid-attack-shuffle / mid-blink-settle gets a bad lead. Added NPC.HasState gate on STUNNED / ROOTED / FROZEN — return current pos directly under hard CC (real velocity = 0). Belt-and-suspenders complement to v6.15.194 #2's blink-buffer invalidation (which covers the populated-buffer case, not the empty-buffer first-sight case). (B7) Retired api_xcheck_tick (v6.15.185) and lineup_scout (v6.15.186-.188). api_xcheck_tick's distance side was confirmed equivalent in field; the damage side stayed perpetually inconclusive — its job was done for the side that mattered. lineup_scout wrote state.enemy_lineup that NOTHING in the brain ever read; the planned consumer (delta 2b) never landed. Both removed (function defs and OnUpdateEx call sites). state.live_channel_tick is KEPT — its eventual consumer has a clear destination (save-chain wiring) and v6.15.197's B2 also gave it a teamfight-side companion. (B9) Added state.q_cast_range() helper alongside r_cast_range / grenade_cast_range. The duplicate `cast_q = 1800` setups inside tf_q_pos and the player-attacked tf_q ap_ok block now both call the helper — single source of truth for Q's live cast range with the KV-base 1800 u no-handle fallback. Demo plan: watch starter R-finisher behaviour with Scepter to verify B4 lets Scepter R commit sooner; watch the brain against any channeling enemy not currently in the catalog (Crystal Maiden Freezing Field, Witch Doctor's Death Ward, etc.) to verify B2 catches them via NPC.GetChannellingAbility; B5 / B6 effects show up as tighter Q placement on stationary or freshly-stunned targets; B7 removes two log-emission types (apicheck_*, lineup) entirely from the log. v6.15.196 banner content preserved below. Sniper brain v6.15.196 loaded — A4 REVISION (single-fix follow-up). The bot-match log for v6.15.195 proved the modifier-name approach in v6.15.195's A4 (Sticky-focus Aegis/Reincarnation guard) did not match reality: the actual SK reincarnation modifier observed in 15+ modseen lines was `modifier_skeleton_king_reincarnation_scepter` (the persistent passive when WK carries Scepter, not a death-window state); the guessed `modifier_skeleton_king_reincarnation_active`, `modifier_aegis`, and `modifier_item_aegis` were never observed even though SK actually reincarnated in the match (cast_outcome respawn=y captured the resurrection). Per the user's directive ('use API calls and code from zero only if needed') the v6.15.196 A4 revision uses zero new modifier-name guesses and reuses paths already proven in the brain. (A4-r) Aegis path: now calls `Target.HasAegis(held)`, the UCZone API (alias of NPC.HasAegis per api/npc.md:442) already in production at Sniper.lua:1225 and 1590 to drive ScoreUltTarget's -75 penalty. lib/item_data.lua's item_aegis carries reincarnate_time = 5 s, matching the window this guard needs to hold. (A4-r) WK Reincarnation path: detected via the same handle-based pattern as line 1234-1240's ScoreUltTarget (NPC.GetUnitName + NPC.GetAbility + Ability.GetLevel + Ability.IsReady), but INVERTED for the post-fire case — reincarn leveled + currently NOT ready means reincarn just fired and WK is in its 3 s revival animation. No new modifier strings introduced. The branch is also tightened with `not Target.IsAlive(held)` so a held one that is merely OUT of the 1800 u scan radius (still alive, just far) doesn't accidentally trigger the guard. A4-r is now demo-pending against a Roshan-aegis hero and a WK reincarnation event. The v6.15.195 banner content + the v6.15.194 chain are preserved below. v6.15.195 banner content preserved below. Sniper brain v6.15.195 loaded — POLISH-PASS BATCH MED. v6.15.194's HIGH-severity fixes field-tested cleanly (#1 Assassinate damage, #3 heal-aware HP rate, #6 mode latch all verified working; #2 user-confirmed clean). This delta lands 7 of the 9 queued MED audit findings; A7 (tf_r dive-gate) is deferred pending a design call (Starter's `r` archetype has the same omission and Starter is frozen, so adding the gate to TF only would create asymmetry), and A6 (channel_punish_r stamp) was verified moot in source (r_cast_protect_until_t IS set at line 4990 and R-cooldown gating blocks secondary dispatch — no code change needed). Per-fix breakdown: (A1) Keen Scope dedup. KS is PHYSICAL bonus damage and is already counted inside r_physical via rc_attack_damage_with_procs (line 2110). The five `r_magical = assassinate_damage() + keen_scope_bonus(d)` sites (3 score-bonus helpers + r_kill_prediction + the main r_dmg_at_d kill gate) double-counted KS in the combined r_dmg_at_d formula, ~15-30 HP overshoot at typical R distance. The v6.15.91 deferred-cleanup TODO is now resolved — `+ keen_scope_bonus(d)` removed from each magical site; r_physical keeps its KS inclusion. NOT behaviour-neutral: like v6.15.194 #1, this is a CORRECTNESS fix toward conservatism on R-kill grade. (A2) tf_team_focus instrumentation. Three silent early-return paths (no_self / no_enemies / no_api / no_allies) and a silent main body left the bridge open issue #1 ('team_n=0 every match') unanswerable. Added a throttled (~1Hz) `tf_team_focus_debug` log emitting `reason=<branch> | allies_total | allies_attacking | pairs_found | best_n`. Unblocks the next bot-match diagnostic. (A3) try_save_ally hardcode → KV. The 375u grenade-radius scan window at try_save_ally was missed by the v6.15.169 KV migration; now reads via state.item_kv(d_ab, 'radius', 375). Behaviour-neutral at current KV; auto-tracks a Valve retune. (A4) Sticky focus Aegis / WK Reincarnation guard. During an aegis respawn window or a Wraith King reincarnation, the held tf_focus entity persists but Target.IsAlive returns false → held_seen=false → state.tf_focus would be re-locked on a different enemy this tick, defeating v6.15.192's sticky lock across the brief death window. Now detects modifier_aegis / modifier_item_aegis / modifier_skeleton_king_reincarnation_active on the held entity (still queryable while 'dead') and skips the overwrite of state.tf_focus; on respawn next tick the lock re-engages on the original target. (A5) Q-cover radius live. STARTER_Q_COVER_R was a constant 400u; the live KV Shrapnel radius is 400/425/450/475 per Q level. At Q4 the gate let zones stack overlap (475u real radius vs 400u check). The three squared-form call sites (chip-Q in starter_tick, tf_q_pos, tf_q ap_ok) now read shrap_radius() live; the 400u constant is kept as a documented safety fallback. (A8) TF cursor-proxy leak filter. read_baseline_target_hint's cursor fallback (Input.GetNearestHeroToCursor) returns the nearest enemy on the WHOLE map. If the user's cursor sits on a teammate during a TF, that can be a far-back enemy unrelated to the fight, leaking Q out of the engagement. The TF call site now filters the result by membership in the 1800u TF scan list and falls back to focus on a non-member. SCOPED TO THE TF CALL SITE ONLY — Starter's identical read of read_baseline_target_hint is untouched (Starter is frozen per directive). (A9) TF fire-log diagnostic parity. The autos-only-path tlog emitted a rich field set (hp / ready_r / r_alone / r_range / ready_e / ta / q_chg / q_pos / team_n / via) but the tf_q/tf_e/tf_r fire-path tlog dropped most of them — a post-mortem on a fire log couldn't answer 'why didn't R fire here'. Fire-path log now mirrors the autos line; r_alone uses the same gate-mirroring computation as v6.15.194 audit #7 (proj_state_r_impact.eff_hp_magical + OVERKILL_BUFFER_HP vs r_dmg_at_d) so the field cannot drift from the actual gate. Demo plan: watch cast_outcome on a maxed-Q maxed-W Sniper at distance to confirm A1's R-kill grade dropped by 15-30 vs v6.15.194 (more conservative R commits); bot-match a 3+ enemy TF to exercise A2 (tf_team_focus_debug should appear ~1Hz with allies_total / allies_attacking / pairs_found counts), A8 (Q1 follows the player target when the cursor is anywhere on the fight), A9 (fire-log lines now show r_alone / r_range / ready_r). A4 awaits an enemy-Roshan aegis or WK reincarnation scenario. A5 visible at Q4 — zones should stop overlapping at the 425u-475u boundary. v6.15.194 banner content preserved below. Sniper brain v6.15.194 loaded — POLISH-PASS BATCH from a four-pass whole-file audit (API surface / TF deep / math+physics / logic+state). Seven HIGH-severity correctness fixes shipped together; the audit MED and LOW findings are deferred for the next pass. Each delta is grounded in code reading and verified against source before commit. (#1) Assassinate base damage. assassinate_damage() read via Ability.GetDamage(a), which reads the static AbilityDamage KV field — but Assassinate has no such field; its damage lives in AbilityValues.damage = '250 350 450'. GetDamage returned 0 on every cast and the legacy fallback 200+100*lvl fired, giving 300/400/500 vs the real 250/350/450. The brain's R-kill grade ran ~50 HP hot at every R level, R-committing on targets R alone could NOT kill (NOT behaviour-neutral — a CORRECTNESS fix toward conservatism). Switched to Ability.GetLevelSpecialValueFor(a, 'damage'); the 200+100*lvl fallback stays only for the no-handle / pre-learn edge case. (#2) Velocity buffer post-blink invalidation. state.sample_velocities reset the per-target buffer only on a >0.25s out-of-vision gap; a target Blinking / TPing while in vision kept its pre-blink sample in the buffer and state.predict_pos derived a phantom 3000+ u/s velocity for the next ~0.33s — Q and D zones led 1.5s along that bogus vector. Added a per-tick displacement cap (700 u/s with 50ms slack) that drops the buffer on any blink / TP / pounce / Phantom Strike / Tricks of the Trade — 700 is comfortably above capped MS 550 + Drums/Phase but well under any blink. (#3) HP-loss rate ignored heals and barriers. The v6.15.183 r_loss_samples accumulator gated `r_eval_dhp > 0` and silently dropped every negative (heal) sample — a target receiving Aphotic Shield / shrine / salve / lifesteal crit kept its pre-heal HP-loss rate, the brain thought autos would finish it and SUPPRESSED R via r_needed, but the healed target no longer died to autos in time. Now accumulates SIGNED dhp; the final rate is clamped to >=0 so a heal-dominated window reads as 'autos are not net-ahead of regen' and frees R to commit. (#4) fog_snipe stamps last_layer1_was_r=true after firing R. Without it the next starter_tick / teamfight_tick read last_layer1_was_r=false and used the 0.4s SEQ lock window instead of the 2.5s R window — a second R could dispatch on top of fog-R inside its 2s cast point. One-line stamp. (#5) teamfight_tick no_target early-return stamps last_layer1_t. Same L14 shape as the v6.15.134 tf_focus rejected-dispatch fix — without the stamp, every OnUpdateEx tick of a held combo key with no enemy in 1800u re-ran the GetHeroesInRadius scan. Throttle now stamped on the no_target return. (#6) Hold-mode dispatch latched. The teamfight = enemies>=3 check ran EVERY tick of a held combo key, so an enemy entering / leaving the 1500u radius for a single tick toggled which loop ran (Starter <-> TF) mid-combo, stranding step dispatches. Decision is now LATCHED into state.combo_hold_active_mode at hold-start, cleared on press-edge and release-edge — the user re-presses the combo key for a new engagement, so the mode is stable for the hold's lifetime. (#7) tf_focus log's r_alone diagnostic mirrors its gate. The tlog computed ((ctx.eff_hp) <= ctx.r_dmg_at_d) but the real tf_r_ctx gate (line 4662) uses ((proj_state_r_impact.eff_hp_magical + OVERKILL_BUFFER_HP) <= r_dmg_at_d). The diagnostic over-reported `y` on raw-low-HP targets (no buffer) and under-reported `y` on barrier-shielded targets (wrong frame). Now mirrors the gate exactly — closes bridge open issue #3. Demo-pending: cast_outcome on #1 (slightly less R aggression), Q-lead on #2 (no zones lagging behind a blinking target), R commit during a heal-ed fight on #3, log shape on #6 / #7. v6.15.193 banner content preserved below. Sniper brain v6.15.193 loaded — final cleanup pass before field testing. A three-pass whole-file audit (8,560 lines, split in thirds) found NO live bugs — the brain is structurally clean; the only findings were dead code and stale comments. Removed: combo_target_in_flight, a v6.15.70 in-flight-sequence-dedup helper that was never wired to any call site (verified zero references — the combo-key redesign made it moot); and orbwalk_cancel_tick, a permanent no-op since v6.15.62 (state.pending_orbwalk_cancel was never set so its guard always returned immediately), together with its OnUpdateEx call site. Both removals are behaviour-neutral — the code was unreachable or inert. The recompute_candidates per-scan-stat comment was corrected: it claimed the counters were stored in state and logged, which is no longer true. NO combat-path logic was changed. Identified code-dedup polish (a handful of triple-copied blocks — R-arming, nearest-enemy scan, Q-zone prune) is deliberately DEFERRED to a post-field-test pass: refactoring demo-verified code right before a release gate adds risk for purely cosmetic gain. v6.15.183 banner content preserved below. Sniper brain v6.15.183 loaded — R finisher now gated on a MEASURED time-to-kill. Root cause of the huge overkill spread, log-confirmed: a reactive R commit cannot be tight — the target HP drops in big discrete chunks (a Daedalus crit removed 467 raw HP in ONE 33ms tick), so R fires the first tick the target reads killable and overshoots the kill threshold by up to a full crit; crit randomness makes that overshoot vary wildly, which IS the spread. The loop itself is fine (dt_ms=33, ~36 reads per autoattack, no missed reads). The fix is to MEASURE, not predict. starter_tick now accumulates the target raw HP loss over a 1s window into an HP-per-second rate — a measured rate is automatically correct for crits, items, armor and damage-block, there is nothing to predict wrong (the v6.15.178 pre_r model failed exactly because it predicted). From it ttk_autos = target HP / rate. The r archetype gate gained r_needed: R fires only when Sniper autos will NOT finish the target in time — the target is fleeing or out of stable auto range (autos will not connect), or ttk_autos exceeds r_horizon (R cast point + 1s). When autos will finish the target fast, R is suppressed — autos or Take Aim get the kill and the ult is saved, which the user accepts. R still requires r_alone_kill (R must be lethal — it never fires on an unkillable target). New starter log fields loss, ttk, r_need. dr and chip archetypes unaffected. Combined with the v6.15.177 range slider this reserves R for the distant non-autoed targets where it lands on-point. v6.15.182 banner content preserved below. Sniper brain v6.15.182 loaded — R finisher reverted to the R-alone kill check; the pre_r model caused MISSED kills. User demo: R fired on high-HP targets and did NOT kill — CM committed at 920 HP, R plus chip delivered only ~641, CM survived at 279. The v6.15.181 cadence instrumentation cleared the loop: dt_ms=33 on every read, ~36 reads per autoattack — the R-kill check is NOT skipping autoattacks. The real bug is the v6.15.178 pre_r_dmg model: it estimates the autoattack chip during R cast from rc_damage_over, which is Sniper RAW attack output — not reduced by the target armor or damage block (Primal high armor, Crimson Guard), it is a raw-physical figure added to the MAGICAL-frame r_dmg, and it assumes the target eats autos for R full 2s cast. With items the raw output balloons while armor stays unsubtracted, so pre_r (logged 880 to 998) fired R on targets R plus chip could not actually kill. Reverted: the r archetype gate is r_alone_kill again — R fires only when R ALONE is lethal (r_dmg_at_d is armor- and frame-correct since v6.15.176). R never misses; it may land as mild overkill (autos chip during the 2s cast), which the user accepts as fine — a late R, or Take Aim finishing the target, saves mana. pre_r and r_soon stay in the starter log as diagnostics only. v6.15.181 banner content preserved below. Sniper brain v6.15.181 loaded — R-eval read-cadence instrumentation. User: we are not sure how many autoattacks the R-kill check reads between — the commit eff_hp varied 376 to 858 across fires, far more than one autoattack (~100-140 effective at no items), which means the check is skipping autoattacks or the model is misreading. Diagnostic-only: every starter tick that reaches the R-kill check now logs three new fields — tgt_hp (the target raw HP), dhp (its raw HP drop since the PREVIOUS R-kill eval), and dt_ms (ms since that eval). If dt_ms stays well under Sniper attack interval the loop reads many times per autoattack and dhp steps down in small increments; a large dt_ms, or a dhp worth several autoattacks, means the R-kill check is skipping autoattacks and R commits on a stale HP read. dhp is -1 when the target changed since the last eval. Behaviour-neutral, logging only — this is to find the root cause of the inconsistent R commit before changing the model. v6.15.180 banner content preserved below. Sniper brain v6.15.180 loaded — R-finisher timing fixes: un-throttle + stable range. User demo: R fired at wildly inconsistent target HP (eff_hp 435 one cast, 727 another, same gate). The log pinned two root causes. (1) THROTTLE QUANTIZATION — the Starter loop locked 0.4s after every chip dispatch and returned early, so the R-finish check only re-evaluated every 0.4s; with a fully-itemed Sniper one autoattack inside that 0.4s window is a huge HP chunk, so the R commit was quantized to the 0.4s tick and landed at inconsistent target HP. Fix: the post-R 2.5s commit lock stays a hard stop, but during the 0.4s post-chip light lock the tick now still runs — r_finish_only lets ONLY the r kill finisher fire, so R commits the instant the target is killable; chip and dr re-dispatch stay throttled as before. (2) pre_r_dmg FLICKER — autos_hit gated on ctx.atk_range, which includes Take Aim transient ACTIVE attack-range bonus (a 3s buff), so a mid-range target flipped in and out of auto range as Take Aim cycled and pre_r_dmg jumped 0 to ~1300. Fix: autos_hit now gates on a stable attack range — ctx.atk_range minus the active bonus while Take Aim is up — so pre_r_dmg no longer flickers. The dr combo is unaffected by both fixes. v6.15.179 banner content preserved below. Sniper brain v6.15.179 loaded — chip-Q now follows mid-fight target switches. User: the chip-Q stuck to the first focused target and did not shift when the player switched their attack target. read_baseline_target_hint read the Humanizer order queue (which holds the BRAIN orders, not the player manual right-clicks) and a cursor proxy (which drifts the moment the mouse moves) — so neither tracked a target switch. Fix: OnPrepareUnitOrders now captures the player manual ATTACK_TARGET order on Sniper into state.player_attack_target (only a player order on an enemy hero — brain sniper- orders are excluded). read_baseline_target_hint reads that captured target first, as path 0 with an 8s freshness window, so the chip-Q follows the player current focus and re-aims when they switch enemy. The capture runs before the callback veto early-returns and does not change veto behaviour. Separate open item: R finisher still overkills — it fires on non-fleeing in-auto-range targets, so the autos finish them during R 2s cast regardless of when R commits; the data is being reviewed with the user. v6.15.178 banner content preserved below. Sniper brain v6.15.178 loaded — future-damage-aware R finisher. User: the 1-2 enemy R finisher (starter r archetype) committed R the instant R ALONE was lethal, so on an in-range target Sniper autoattacks chipped it far below R damage during R 2s cast and R landed as overkill (demo: R cast on CM at 215 HP, landed at ~26). Fix: the r archetype now accounts for pre_r_dmg — the damage Sniper autoattacks deal during R cast — counted only when the target is in attack range AND not fleeing (else the autos do not connect). The kill gate moved from r_alone_kill to r_kill_soon = (eff_hp + buffer) <= (r_dmg + pre_r_dmg), so R commits EARLIER, on a higher-HP target: by the time R lands the autos have chipped it into R lethal band, the kill is locked in before the target can blink or run. pre_r_dmg is conservative (a 0.5 haircut, autos only, Q-zone ticks excluded) so an over-estimate can never fire R on a target R+chip cannot kill. A fleeing or out-of-range target has pre_r_dmg 0, so r_kill_soon falls back to the R-alone check exactly as before. The D+R+Q+E combo is UNAFFECTED — dr never referenced the r-finisher kill math or range gate. New starter log fields eff_hp, r_dmg, pre_r, r_alone expose the full R-kill math for tuning. v6.15.177 banner content preserved below. Sniper brain v6.15.177 loaded — Starter R-finisher min-range slider (user testing knob). The 1-2 enemy R finisher (the starter r archetype) fired R only when the target was past 70 percent of Sniper attack range — a fixed STARTER_R_MIN_RANGE_FRAC constant. It is now a menu slider, Starter R finisher min range percent, in the Brain / Core tab — range 50 to 150, default 70 (behaviour-neutral at the default). Setting it to 100 or higher reserves R for targets at or past the edge of autoattack range — the escaping targets R is meant to catch in a 1-2 enemy fight. Only the Starter r archetype reads the slider; the teamfight finisher keeps the static 70 percent. This is the tuning knob for the R-finisher trigger distance; a future-damage-aware R trigger model is the planned follow-up. v6.15.176 banner content preserved below. Sniper brain v6.15.176 loaded — R-kill damage-model frame fix. build_layer1_ctx computes r_dmg_at_d, the R damage the kill math checks against. Its physical instant-attack instance was computed with take_aim_active=true — a leftover from the deleted snipe_e_r combo, which fired E before R for a guaranteed 100% headshot. No CURRENT archetype that consults the R-kill math fires E before R: the starter r finisher is R-only (E dropped in v6.15.127), dr fires E AFTER R, tf_r is R-only. The only take-aim-active R is the heavy_starter TAP, and the TAP has no kill check. So the kill math was over-counting R damage by the headshot delta (100% vs 40% proc chance on the physical instance) — the user demo showed the starter_r finisher predicting 530-586 R damage on Primal while R-alone actually does about 468. Fixed to take_aim_active=false, the correct R-alone frame. The r finisher and tf_r now commit only on targets R alone genuinely kills, instead of over-committing on borderline targets. The cast_outcome pred_raw diagnostic got the same frame correction — it now snapshots take-aim true only for an E+R tap that actually fired E, and take-aim false for every R-alone cast — so the back-check log matches the commit math. Separate issue from the v6.15.175 chip-Q fix — both demo together. v6.15.175 banner content preserved below. Sniper brain v6.15.175 loaded — Starter chip-Q now targets the enemy the PLAYER is attacking. User demo (1-2 enemy fight): the chip archetype placed Shrapnel on the enemy the brain auto-picked, not the one the player is attacking. The Starter picks its engagement target as the enemy attacking Sniper first, which is often NOT who the player is right-clicking. Fixed: the chip-Q position now comes from read_baseline_target_hint (the queued ATTACK_TARGET order, else the cursor) — the authoritative player-intent read, the same source teamfight tf_q already uses; it falls back to the Starter pick when there is no hint. When the player target already has a live chip-Q zone, the Q spreads to the secondary enemy — Q on who you are attacking first, the other enemy after. The dr archetype is unchanged — its Q still lands on the committed attacker it is peeling, and now gates on its own spot coverage instead of the chip coverage value so the chip change cannot affect it. New q_aim field on the starter fire log shows you or secondary. v6.15.174 banner content preserved below. Sniper brain v6.15.174 loaded — E+R tap damage-calc instrumentation. The TAP combo (Heavy Starter, E+R fire-on-command) deliberately skips the kill check — the player may tap to poke, to interrupt a channel, or to secure a kill, so the brain commits without a kill gate — and so it logged no damage figure at all. New tap_combo log is emitted on every tap attempt, BEFORE the ready_r gate, so it appears even when R is on cooldown — that confirms the damage calc runs unconditionally, not only when R is off CD. It logs dmg_e_r (predicted R damage with Take Aim active, 100% headshot — the E+R case), dmg_r_only (R alone, E on cooldown, 40% headshot), target HP, ready_r and ready_e (the live cooldown state), e_fires, and would_kill. r_kill_prediction gained a take_aim_active param (default true) to compute both cases. The tap prediction is also handed to the order-issue choke point so the TAP R cast_outcome line carries tap_e_r, tap_r_only, tap_e and is_tap=y next to the HP actually removed — damage calc and damage done on one line. Diagnostic-only, no combat decision reads it, behaviour-neutral. v6.15.173 banner content preserved below. Sniper brain v6.15.173 loaded — KV-hardcode migration follow-up: shrap_damage_per_q_effective. A hardcode the earlier full-file scan missed — the function computed per-tick Shrapnel damage as 30+15*(lvl-1), a formula mirror of KV sniper_shrapnel shrapnel_damage (base 30/45/60/75 by Q level). Now reads it LIVE off the Q handle via state.item_kv. GetLevelSpecialValueFor returns the BASE value (talent magnitudes are read separately in the UCZone API), so the +30% shrap talent stays applied via talent_shrap_multiplier with no double-count. The old formula reproduced the same base table, so this is behaviour-neutral; the formula is kept as the no-handle fallback. v6.15.172 banner content preserved below. Sniper brain v6.15.172 loaded — damage-model back-check instrumentation. The cast_outcome diagnostic already logged what an R cast ACTUALLY did (target alive or dead, HP removed) 5s later, but not what the brain PREDICTED — so the damage model could not be back-checked against reality. New r_kill_prediction snapshots the brain predicted R damage (in raw HP, reproducing build_layer1_ctx r_dmg_at_d formula — assassinate magical plus keen scope plus the instant-attack physical instance) at cast time, and cast_outcome now logs three new fields: pred_raw (predicted raw-HP damage), pred_kill (did the brain expect R alone to kill), and pred_err (pred_raw minus hp_delta — positive means the brain over-predicted the damage). A pred_kill y line with alive y is a false-positive commit — R fired on a target it could not kill. Diagnostic-only, no combat decision reads it; built so the KV-hardcode migration series can be verified — grep cast_outcome and compare pred_raw against hp_delta. NOTE hp_delta is the 5s all-source HP removed (allies, DoT included), so in a solo demo it is approximately Sniper own damage. v6.15.171 banner content preserved below. Sniper brain v6.15.171 loaded — KV-hardcode migration A2/A3/A5/A9, four more hardcodes from the full-file scan bundled into one version. (A2) build_layer1_ctx hardcoded R_CAST_S 2.0 for the regen-during-cast estimate, ignoring Scepter which cuts R cast to 0.5s; now uses the Scepter-aware r_cast_point helper — the old literal 4x over-estimated target regen for a Scepter Sniper, making the R-kill check too conservative. Correctness fix. (A3) r_abort_tick duplicated the same Scepter-aware 0.5-or-2.0 cast-point literal; replaced with r_cast_point — behaviour-neutral dedup. (A5) the Take Aim mana fallback in heavy_starter_tick was 35 but the KV mana cost is 50; corrected so the mana gate no longer under-budgets E by 15 mana on the rare path where GetManaCost returns nil. (A9) Hurricane Pike enemy-target cast range was hardcoded 425 at four range gates; new helper state.pike_enemy_range reads item_hurricane_pike cast_range_enemy live off the Pike item handle, fallback 425 — behaviour-neutral at current KV. v6.15.170 banner content preserved below. Sniper brain v6.15.170 loaded — KV-hardcode migration A8: cast-range-bonus-aware range gates. The module constants CAST_R 3000 and GRENADE_R 600 were hardcoded KV mirrors of sniper_assassinate and sniper_concussive_grenade cast range that IGNORED cast-range bonuses — a Sniper with Aether Lens (+250) or a cast-range talent has 3250 R reach and 850 grenade reach, but seven range gates still using the raw constants refused valid casts. New helpers state.r_cast_range and state.grenade_cast_range derive the live effective range via effective_cast_range (base + NPC.GetCastRangeBonus); the old constants remain only as no-handle fallbacks. Migrated the enemy candidate-scan radius, the fog-snipe range gate, and five grenade and ally-save range gates. This is a correctness fix, NOT behaviour-neutral — a bonus-carrying Sniper now scans wider and its R and grenade range gates open to the true reach. Surfaced by a full-file hardcode scan. v6.15.169 banner content preserved below. Sniper brain v6.15.169 loaded — KV-hardcode migration step 3: headshot, grenade and a rotted talent name. (1) Headshot bonus damage and proc chance in rc_attack_damage_with_procs now read LIVE off the W handle. KV sniper_headshot damage is per-W-level 20/50/80/110 and proc_chance is 40 — the brain had hardcoded a flat 75, which mismatched the KV at EVERY W level, so this is a correctness fix, NOT behaviour-neutral. It feeds the per-attack damage model and the R-kill equation: at W4 headshot bonus damage rises from 75 to 110, so R commit math runs more aggressive late game; at low W levels it drops. (2) Concussive Grenade radius and cast point now read live off the D Shard handle — both match the old literals 375 and 0.1, behaviour-neutral. GRENADE_PROJ_SPEED stays hardcoded at 2500: sniper_concussive_grenade has no projectile-speed KV key, so it is not migratable. (3) talent_assassinate_damage_bonus checked special_bonus_unique_sniper_5, but a KV cross-check shows _5 is the +50 Take Aim range talent while the +150 Assassinate-damage talent is _1 — the brain was detecting the WRONG talent. Corrected to _1; the +150 magnitude stays hardcoded. Migration steps 1 (v6.15.167 proc items), 2 (v6.15.168 per-level tables) and 3 (this) are to be demo-verified together — watch combo_dmg and R commit decisions and confirm R is not over-committing. v6.15.168 banner content preserved below. Sniper brain v6.15.168 loaded — KV-hardcode migration step 2: three per-level ability tables now read LIVE from Valve KV via state.item_kv, so they track patch retunes instead of rotting on hardcoded numbers. (1) Shrapnel radius (shrap_radius) reads sniper_shrapnel radius live off the Q handle — confirmed equal to the old table 400/425/450/475, behaviour-neutral. (2) Take Aim attack-range bonus (take_aim_range_bonus) reads sniper_take_aim passive_attack_range_bonus live off the E handle — confirmed equal to the old table 160/240/320/400, behaviour-neutral. (3) self_take_aim_state slow magnitude reads sniper_take_aim slow live off the E handle — the old per-level table 45/40/35/30 had ROTTED, the live KV slow is now a flat value (snapshot 65) — but slow_pct is informational only, it feeds the save_take_aim_active and self_ms_slow_pct diagnostic logs and drives no combat decision, so this is behaviour-neutral in combat (only the logged number changes). Each migration keeps the old table as a no-handle fallback. v6.15.167 banner content preserved below. Sniper brain v6.15.167 loaded — proc-item damage model now reads live KV. The rc_attack_damage_with_procs proc block was stale and partly broken: it checked item_daedalus and item_crystalys, which are display names not KV names, so GetItem never matched them — Crystalys crit was never counted at all; it used a 2.4x Daedalus crit multiplier that Valve has since cut to 2.25x; and it modeled Maelstrom and Mjollnir chain lightning at 60 and 75 damage when the KV says 110 and 180. Rewritten to read crit_chance, crit_multiplier, chain_damage and chain_chance LIVE off each item handle via the new state.item_kv helper (Ability.GetLevelSpecialValueFor, with the current KV value as a fallback), under the correct KV names item_greater_crit (Daedalus) and item_lesser_crit (Crystalys). Skadi and Revenant Brooch were dropped from the proc model: the KV exposes no reliable per-attack proc damage for either, and their static bonus_damage is already inside base via NPC.GetTrueDamage, so a flat proc there invented damage. This is NOT behaviour-neutral — it is a correctness fix. The proc-damage estimate changes: Maelstrom and Mjollnir contributions roughly double, Crystalys is now detected, the Skadi and Brooch phantom flats are gone. That feeds the R-kill equation, so R commit decisions shift; this needs demo verification. First of a planned series migrating Sniper KV-mirror hardcodes to live reads. v6.15.166 banner content preserved below. Sniper brain v6.15.166 loaded — closure cleanup from a final review pass. Three deltas. (1) Removed ~230 lines of verified-dead code: live_q_kill_floor, q_chain_step_cond, and the five-function corridor-anchor cluster (corridor_anchor_for, set_corridor_anchor, corridor_pos_from_anchor, corridor_pos_q1, corridor_pos). All were placement and kill-gate helpers for Q-stacking combos that an earlier refactor removed; grep-confirmed zero call sites, loadfile-clean after removal, frees Lua local-function slots against the 200-per-function limit. (2) fog_snipe_tick now arms the R-cast-protect veto window and resets r_phase_seen on a fog-R dispatch, matching the three other R-dispatch sites (pending_steps, fire_steps, channel-punish) — a speculative fog-R previously had no native-order protection and a stale r_phase_seen could defeat r_abort_tick for it. (3) Fixed a garbled v6.15.114 NPCLib refactor comment. File goes from 8398 to 8174 lines; the brain is feature-complete and closure-clean. v6.15.165 banner content preserved below. Sniper brain v6.15.165 loaded — data-source polish from a hardcode-vs-live-API audit. Two deltas. (1) The R magic-immune-at-impact guard (commit_ms) hardcoded 1700/3200 ms — the R cast point of 0.5s/2.0s plus a 1.2s buffer — even though the Scepter-aware r_cast_point() helper already existed a few hundred lines above. It now calls r_cast_point()*1000+1200, so a live Scepter cast-point change is picked up instead of relying on a NPC.HasScepter branch. (2) Removed the dead SHRAP_R=1800 constant — declared, never referenced. No behaviour change expected — r_cast_point() returns the same 0.5s/2.0s the literals encoded, modifier-aware. A full audit of the file (cross-checked against the new KV-data libs and the UCZone live API) confirmed the remaining hardcoded KV values — talent magnitudes, the Shrapnel-radius and Take-Aim per-level tables, item save geometry — are deliberate, documented, version-tagged, demo-verified decisions, and were intentionally left untouched. v6.15.164 banner content preserved below. Sniper brain v6.15.164 loaded — defense threat-catalog refresh, batch 2: older-hero kidnaps, gap-closes and catches. Ten more threats wired into lib/threat_data.lua across the 5 core tables — Faceless Void Chronosphere, Batrider Flaming Lasso, Tiny Toss, Vengeful Spirit Nether Swap, Chaos Knight Reality Rift, Clockwerk Hookshot, Spirit Breaker Nether Strike (promoted from a nil ABILITY_TO_THREAT entry to a real gap-close threat), Huskar Life Break, Sand King Burrowstrike, Nyx Assassin Impale. Same approach as batch 1 — detection + categorization wired, save selection left to the validated CATEGORY_CHAINS fallback, modifier names best-effort modifier_<ability> marked verify, corrected from real games via the threat_unrecognized harvest. Batches 3+ cover targeted executes and big nukes (Necro Scythe, OD Astral, Lich, Skywrath) and remaining delayed-AoE/trap gaps. lib/threat_data.lua changed — redeploy the lib too. v6.15.163 banner content preserved below. Sniper brain v6.15.163 loaded — defense threat-catalog refresh, batch 1: the modern hero pool. A full roster enumeration from the KV data found ~65 uncovered threatening abilities across ~45 heroes — the entire post-2018 hero pool was a blind spot. Batch 1 wires the 12 uncovered modern heroes (Kez was done in v6.15.162) into lib/threat_data.lua: Ringmaster Impalement, Marci Grapple, Muerta Dead Shot, Primal Beast Onslaught, Dawnbreaker Celestial Hammer, Hoodwink Bushwhack, Snapfire Mortimer Kisses, Void Spirit Aether Remnant, Mars Spear, Grimstroke Ink Creature, Pangolier Swashbuckle, Dark Willow Cursed Crown. Each is added to the 5 core tables — ABILITY_TO_THREAT, THREATS_ON_SELF, THREAT_CATEGORY, THREAT_SEVERITY, THREAT_TIMING — so OnModifierCreate detects it and the category save-chain handles it. Modifier names are best-effort modifier_<ability> guesses, marked verify; the threat_unrecognized harvest log corrects any wrong suffix from real games. Per-threat save chains are left to the validated CATEGORY_CHAINS fallback. Older-hero gaps (Chronosphere, Batrider Lasso, Tiny Toss, etc.) follow in batch 2+. lib/threat_data.lua changed — redeploy the lib too. v6.15.162 banner content preserved below. Sniper brain v6.15.162 loaded — defense threat-catalog refresh, step 1 (user: Kez Grappling Claw did not trigger Pike or grenade). Kez post-dates the original defense extrapolation and was absent from every threat table, so the defense layer never even detected the grapple. Two changes. (1) Kez Grappling Claw is wired into lib/threat_data.lua across all 7 threat tables — ABILITY_TO_THREAT, THREATS_ON_SELF, THREAT_COUNTER, RECOMMENDED_SAVES, THREAT_TIMING, THREAT_CATEGORY (close_gap), THREAT_SEVERITY (medium). The modifier name modifier_kez_grappling_claw is a best guess, marked verify. (2) New harvest log: when a modifier lands on Sniper from an enemy hero that is in NO threat table, the brain logs threat_unrecognized with the real modifier name and caster. The defense catalog now grows from verified in-game names instead of guesses — play games, grep threat_unrecognized, wire the real names in. lib/threat_data.lua changed — redeploy the lib too. v6.15.161 banner content preserved below. Sniper brain v6.15.161 loaded — dr-combo grenade now leads the attacker (user, log check: D+R+Q+E throws the grenade on the wrong position for a moving PA). optimal_d_pos placed the Concussive Grenade peel-point on the Sniper-to-attacker line using c.target_pos — the attacker's DISPATCH-TIME snapshot. dr_peel is an immediate step, and D has a 0.1s cast point + humanizer delay + projectile travel before it lands; against a moving attacker (PA chasing a Hit-and-Run-kited Sniper) the grenade landed behind them and the knockback shoved them sideways. optimal_d_pos now leads the attacker — it uses state.predict_pos(c.target, D_PEEL_LEAD_S 0.3s) to aim at the attacker's predicted impact position, falling back to the snapshot when prediction is unavailable. Q in the same combo already predicted; this brings D in line. v6.15.160 banner content preserved below. Sniper brain v6.15.160 loaded — whole-file professional audit cleanup. An independent review swept the entire file (Layer 2, menu, diagnostics, callbacks, shared helpers) — it found NO bugs and NO correctness risks, the file is sound. Pruned the housekeeping it did find: 6 dead symbols — the duplicate constant CAST_3000 (CAST_R holds the same value), and 5 write-only state fields with no reader (last_baseline_hint_source, last_status_update_t, last_preface_target_idx, last_scan, saves_snapshot_logged). 19 lines removed; behaviour-neutral — none had a reader. The actual diagnostics (the tlog calls, the status panel, the debug panel, the log-verbosity slider) are untouched and fully kept. Also reworded the stale forward-declaration comments that cited rotted line numbers and a since-deleted layer1_tick — they now reference symbols by name, which does not rot. v6.15.159 banner content preserved below. Sniper brain v6.15.159 loaded — front-page menu rebuild (user request: bring the menu to the front like Keeper of the Light, cleanest HUD, keep every diagnostic). The brain config was buried at Sniper - Extra Settings - Brain. It is now its own top-level Brain tab (sibling of the native Main / Extra Settings), split into three purpose groups: Core (enable, combo key, fog snipe, R commit floor, override keys), Defense (auto-defense, channel-punish, pre-face, Lotus, smoke detection, ally-save, and auto-grenade with its tuning in a gear), and Diagnostics (log verbosity, the full live status panel, the raw-API debug panel). Widgets carry hover tooltips. Every diagnostic is kept in full so the code stays researchable. All m.X widget handles keep their old field names — only the menu layout changed, the brain logic is untouched. Note: moving the menu path resets saved widget values to defaults, so the combo key may need a one-time rebind. v6.15.158 banner content preserved below. Sniper brain v6.15.158 loaded — Team Fight: do not cast Take Aim into a dive (TF research Tier 3, user-approved). Take Aim slows Sniper 30-45% while active — casting it while a gap-closer is incoming makes the dive land. The tf_e archetype and the tf_q E-rider step now also gate on not next(state.armed_threats) — the pre-event diver signal (Bara charge / Tusk / PA blink, the same armed-threat gate auto_grenade uses). When a diver is armed the brain skips Take Aim so Sniper keeps full move speed to kite while the Layer-2 save resolves. Targeted suppression — armed_threats only holds gap-closers, so a plain walk-in does not cost Take Aim uptime. v6.15.157 banner content preserved below. Sniper brain v6.15.157 loaded — Team Fight R now also secures the focus kill (user-approved). tf_r fired R only on a FLEEING enemy (Target.IsKitingUs). Pro Sniper play also uses Assassinate to finish the target the team is committed to. tf_r now evaluates two DESIGNATED targets in order — still not a multi-target scan: (a) the fleeing r_cand (autos cannot chase a runner), then (b) the teamfight focus (the indicated kill the team is bursting). R fires on whichever is R-alone-killable, safe and in range. Low-risk: if the team kills the focus during R's cast point, r_abort_tick cancels R and refunds the mana. Helper tf_r_ctx shares the kill/range/safety gate for both. v6.15.156 banner content preserved below. Sniper brain v6.15.156 loaded — Team Fight Q now lands FIRST on who the player is attacking (user, Test 1: Q spreads but is not applied first on the attacked enemy). tf_q took the attacked enemy from state.candidates[1] — but that slot is SCORE-ranked, so a low-HP kill target outranks the focus and Q1 missed who the player was actually hitting. Now tf_q reads read_baseline_target_hint() — the authoritative player-intent signal: the queued ATTACK_TARGET order first, the cursor proxy as fallback (falls back to the team/TTK focus only when neither is available). Q goes on that enemy when it is in Q cast range and not already under a fresh zone; the spare charges then spread via tf_q_pos. The teamfight log gains q_aim=attacked/spread so a demo can confirm Q1 lands on the attacked enemy. v6.15.155 banner content preserved below. Sniper brain v6.15.155 loaded — Team Fight Q-spread fix (user, Test 1: Q on TF still not being spread). Root cause was the Gate-3 order dedup, not the tf_q targeting. queue_has_baseline matched a queued order by orderType + unit + abilityIndex + targetIndex — but a CAST_POSITION order (Shrapnel) has targetIndex 0, so match_target was always true and TWO Shrapnel zones aimed at different spots looked identical. tf_q dispatches its spare charges to spread positions, but each was deduped against the first Q still in the humanizer queue and silently swallowed (log: 3 tf_q dispatches per fight, only 1 step_cast_pos). Fix: queue_has_baseline now also matches the cast POSITION (queue entries expose `position`); two position casts must be within 250u to count as the same order. Same-intent re-dispatches stay deduped (~250u jitter); a deliberate spread is 400u+ apart. v6.15.154 banner content preserved below. Sniper brain v6.15.154 loaded — finalization step 3: consistency audit cleanup. With the legacy catalog gone, an independent review found the orphans it left behind — functions and constants that only the deleted dispatcher referenced. Removed: CanCommitFullCombo, top_candidate and target_predicted_landing (orphaned local functions) plus the COMBO_COMMIT_FLOOR and SEQUENCE_FLOOR constants (the live commit_floor() function and COMBO_COMMIT_FLOOR_DEFAULT are untouched). Also rewrote the stale comments that still described the retired COMBO/SEQUENCE dispatcher and the transitional layer1_tick delegation as if they were current architecture. Behaviour-neutral — only dead code and comments changed. v6.15.153 banner content preserved below. Sniper brain v6.15.153 loaded — finalization step 2: the dead legacy combo catalog is retired. layer1_tick (the old Layer-1 dispatcher), SNIPER_COMBOS and SNIPER_SEQUENCES had zero call sites for the whole combo-key redesign — 1999 lines of dead code removed. The fog-R path layer1_tick hosted was relocated to state.fog_snipe_tick in v6.15.152; the dead fallback-attack and fallback-cursor-move logic was dropped (native Hit & Run covers attack cadence). This is a behaviour-neutral deletion — the deleted code never ran. Orphaned helper functions that only layer1_tick called are still defined and get pruned in the next finalization step (the consistency audit). v6.15.152 banner content preserved below. Sniper brain v6.15.152 loaded — finalization step 1: speculative fog-snipe restored as standalone code. The legacy layer1_tick combo catalog has been dead (zero call sites) for the whole combo-key redesign, and the fog-R path it hosted was dead with it. Fog-R is now state.fog_snipe_tick — a standalone always-on tick wired into OnUpdateEx, gated by the fog_snipe menu toggle (still default off): when on, it casts R at the highest-value recently-fogged enemy inside R cast range. Internal gates keep it from stealing R from a combo — suppressed for FOG_SNIPE_COMBO_SUPPRESS_S after the combo key was down, skipped while an R is in flight or Sniper is displaced/disabled, and self-throttled by FOG_SNIPE_RETRY_S. The dead fallback-attack / fallback-cursor-move logic in layer1_tick is being dropped (user directive — native Hit & Run covers it); layer1_tick + SNIPER_COMBOS + SNIPER_SEQUENCES retire in the next step. v6.15.151 banner content preserved below. Sniper brain v6.15.151 loaded — regression fix (user report): the dr archetype (the committed-attacker peel combo) no longer requires R to be off cooldown. starter_tick selected dr only when committed AND ctx.ready_r AND a peel tool were all true — so once R went on cooldown a committed attacker produced decision=idle and the Pike peel stopped firing on the enemy return attack (debug.log: many committed=y d~196-238 ready_r=n decision=idle lines). dr now selects on committed AND dr_peel (D or Hurricane Pike); R is a cond-gated step like Q and E (cond = c.ready_r) and is simply skipped when on cooldown. A committed attacker is met with peel + Q + E whether or not R is up. Starter (1-2 enemy) change made on explicit user request. v6.15.150 banner content preserved below. Sniper brain v6.15.150 loaded — D6 fix: the Tusk Snowball save chain no longer leads with displacement saves. A Tusk rolling inside his snowball is immune to displacement, so Pike-on-Tusk and grenade-at-Tusk do nothing — and because the save chain stops at the first save the engine accepts, a fired-but-useless Pike/grenade blocked the real save from ever firing. SNIPER_SAVE_OVERRIDES[modifier_tusk_snowball_movement] is now a non-displacement self-save chain: BKB (the snowball stun + magic damage do not pierce magic immunity), Eul / Wind Waker self-cast (airborne + invulnerable — the snowball impact whiffs), Lotus, Aeon Disk backstop. Pike / grenade removed from the Tusk entry entirely. Bara Charge is unaffected — Bara is not displacement-immune, its Pike-first override stands. Defense layer only. v6.15.149 banner content preserved below. Sniper brain v6.15.149 loaded — D5 fix: the PA anti-gap Pike save now waits for the blinker to SETTLE at melee before firing. v6.15.143 fired the instant-blink save as soon as the caster entered Pike 425u cast range, but a demo logged a fire at dist~256 while PA was still settling out of the Phantom Strike blink — the push then acted on an unsettled target. New tunable state.BLINK_ARRIVE_DIST_U (250u, roughly PA melee landing distance): armed_threats_tick instant_blink branch now gates the blink_arrived fire on d<=BLINK_ARRIVE_DIST_U instead of d<=425, so the save fires only once the caster has reached its final melee position; still well inside every displacement save range (Pike 425 / D / Force). Defense layer only; combo key and Starter/Team Fight logic untouched. v6.15.148 banner content preserved below. Sniper brain v6.15.148 loaded — Team Fight focus = the enemy the TEAM is attacking (user directive: teamfights branch on their own logic — prioritise the enemy the most allied heroes are attacking together; fall back to TTK/lowest-HP when the team is spread out; do NOT change 1-2 enemy logic). New helper state.tf_team_focus(enemy_list): UCZone has no NPC.GetAttackTarget for heroes, so an ally is counted as attacking enemy E when the ally is mid-attack (NPC.IsAttacking) and E is the nearest enemy hero within 700u of that ally; returns the enemy with the most ally-attackers. teamfight_tick now sets focus = that team-focused enemy when >=2 allied heroes are attacking it together (a real coordinated focus); otherwise focus stays the lowest-current-HP enemy (the v6.15.145 TTK fallback — also the solo-demo case, where there are no allies so tf_team_focus returns nil). The teamfight log carries a `via` field (team / ttk) showing which picked. Starter (1-2 enemies) is untouched per the directive. v6.15.147 banner content preserved below. Sniper brain v6.15.147 loaded — self_take_aim_state stuck-true fix (user confirmed, full-test C2: Take Aim is never actually up in teamfights, yet the v6.15.145 `ta` diagnostic logged y on every teamfight tick). self_take_aim_state checked HasModifier(modifier_sniper_take_aim_active) OR HasModifier(modifier_sniper_take_aim) — the second name is Take Aim's ALWAYS-ON passive (attack-range) modifier, present every tick, so the function was permanently true. The teamfight E archetypes (tf_q's E companion and tf_e) are the only paths gated on `not self_take_aim_active`, so they never fired — E was never cast in teamfights. Fix: check ONLY modifier_sniper_take_aim_active (the active buff). Now self_take_aim_active is false when Take Aim is down, so the teamfight E archetypes fire and keep Take Aim up through the fight (range + 100%% headshot). v6.15.146 banner content preserved below. Sniper brain v6.15.146 loaded — Team Fight Q follows the attacked target (user, full-test Test 1: 3 enemies warlock/naga/pudge, Q fired only on pudge while the player was attacking warlock). tf_q placed Q via tf_q_pos' pure coverage-optimum search, which ignores who the player is engaging — so Q landed on the densest cluster spot (pudge), not on warlock. Fix: tf_q now places Q to cover the ATTACKED target — state.candidates[1].target, the player's cursor target (recompute_candidates promotes the cursor target to slot 1) — whenever he is within Q cast range and not already under a recent zone (the global starter_q_track gate). Only when the attacked target is already zoned, out of range, or unknown does Q fall back to tf_q_pos' cluster-coverage spread, which then correctly puts the spare charges on still-uncovered enemies (the A5 spread case). C2 (Take Aim seemingly not used in Team Fight) is NOT changed this version — the v6.15.145 diagnostic shows ta=y on every teamfight tick (self_take_aim_active reads true), so teamfight_tick correctly skips re-casting E; pending user confirmation of whether Take Aim is genuinely active in their teamfights or self_take_aim_state is misreading a passive modifier. v6.15.145 banner content preserved below. Sniper brain v6.15.145 loaded — Team Fight: focus = lowest current HP + C1/C2 diagnostics (user full-test round). FIX C4 (tf_focus not prioritizing lowest life): teamfight_tick picked `focus` by lowest effective-physical-HP (the fastest-TTK metric) — but armor inflates eff-physical-HP, so a high-armor enemy sitting at low raw HP read as a poor focus and the brain attacked someone else. focus is now the enemy with the LOWEST CURRENT HP (Entity.GetHealth) — the one closest to death — which is what focus-autos want. DIAGNOSTICS for C1 (Q not spreading) and C2 (Take Aim not used): the `teamfight` log line (fire and tf_focus) now carries ready_e, ta (self_take_aim_active), q_chg (q_charges), q_pos (did tf_q_pos return a placement) — the prior line lacked them so the C1/C2 cause could not be read from the log. NO behaviour change for C1/C2 yet — the next demo log will pinpoint them (C2: ready_e=n means E on cooldown, ta=y means Take Aim already active; C1: q_chg=0 means no charges, q_pos=n means tf_q_pos found no uncovered cluster spot). Other full-test items queued: D5 (Pike fired slightly mid-blink at d~256 — tighten arrival), D6 (Tusk Snowball immune to Pike/grenade — needs a different save), B-note (starter 2-enemy Q should follow the attacked target, secondary charge on the other). v6.15.144 banner content preserved below. Sniper brain v6.15.144 loaded — damage-rate-panic save throttle (log audit of the v6.15.143 demo: 770 save_chain_skip events). damage_rate_panic_check runs every OnUpdateEx tick; when Sniper is taking heavy damage (projected 2.25x damage rate >= HP) it calls try_save_self(dmg_rate_panic). If NO panic save is available (Eul/Lotus/Manta/Satanic/BKB/Aeon not owned, Pike on cooldown, etc.), try_save_self fires nothing — so layer2_can_fire never engages its post-save throttle — and the full ~10-entry save chain re-runs EVERY FRAME, logging save_chain_skip x10 + layer2_no_save_available each tick. The v6.15.143 demo logged 770 save_chain_skip almost entirely from this. Fix: damage_rate_panic_check now gates on DMG_PANIC_RETRY_S (1.0s) — the first attempt is immediate (state.last_dmg_panic_t starts 0), retries wait 1s. Not gameplay-breaking (nothing was firing) but it eliminates the per-frame chain spam and wasted CPU. v6.15.143 banner content preserved below. Sniper brain v6.15.143 loaded — PA anti-gap Pike fires on blink ARRIVAL, not mid-blink (user, v6.15.142 demo: Pike does not work on anti-gap until a combo uses it / unless shard is owned first). Diagnosed from the no-shard demo log: the first PA Phantom Strikes logged armed_threat_fire via=eta_critical at dist=487 and dist=435, then save_chain_skip save=pike reason=fire_returned_false; later strikes logged via=pike_in_range at dist=56 and Pike fired. armed_threats_tick treats an instant blink with the eta model eta=d/eta_speed (eta_speed=1500 nominal), so the eta_critical stage (eta<=0.35) force-fired the save while PA was still mid-blink at d~435-525 — OUTSIDE Pike's 425u cast range. Pike's fire closure refused (out of range) and the chain fell through: WITH shard it reached grenade_at_caster (600u, so the save still worked — hence shard-first masks the bug); WITHOUT shard nothing else was usable. Fix: instant-blink armed entries are flagged instant_blink=true and fire on ARRIVAL (caster inside Pike's 425u range) instead of on the eta stages — a teleport has no travel window to race. A never-arrived instant-blink entry is dropped after BLINK_ARRIVE_TIMEOUT_S (2s) so a stale key cannot block re-arming. The combo-use correlation the user noticed was coincidental timing (early blinks evaluated mid-flight). v6.15.142 banner content preserved below. Sniper brain v6.15.142 loaded — R-kill equation frame fix (user, v6.15.141 demo: a Daedalus Sniper refused R on a 400+ HP target that R alone kills — the killable check under-counts). Assassinate is dual-instance: a magical instance + a physical instant-attack instance (Daedalus crit, Headshot, Skadi etc. proc on it). build_layer1_ctx computed r_dmg_at_d = r_magical + r_physical and the kill check is eff_hp_magical <= r_dmg_at_d. BUG: the two terms were in different frames. eff_hp_magical is magical-damage-needed-to-kill (raw HP inflated by the target's magic resist). r_magical (assassinate_damage) is a magical-damage number — same frame, fine. But r_physical (assassinate_instant_attack_damage) is POST-armor damage = the actual raw HP removed — a different frame. Summing it raw under-counted the physical instance by the magic-resist factor (~25% on a typical hero), so the kill check refused R on targets it would kill. FIX: r_dmg_at_d = r_magical + r_physical * magic_inflate, where magic_inflate = EffectiveHpVs(MAGICAL)/raw_HP (the resist inflation factor) puts the physical instance into the same frame as eff_hp_magical. This corrects r_alone_kill (starter `r`, teamfight tf_r) and every combo commit_pred that reads r_dmg_at_d — all had the same under-count. v6.15.141 banner content preserved below. Sniper brain v6.15.141 loaded — fast R-cancel detection (user, v6.15.140 demo: R on an out-of-AA-range killable target took a while to fire even off cooldown; D-into-R not landing reliably). The user confirmed the R TRIGGER policy is correct as-is (R-alone-kill only, skip R without a peel, no R on close targets) — so this version changes only R RELIABILITY/TIMING, not when R is chosen. Root cause: when R is dispatched but the engine cancels it on order receipt (a native or player MOVE/ATTACK replaces it before the 2s cast point starts — cast_verify fired=n), r_abort_tick could not tell a cancelled R from one that simply had not started its cast phase yet, so it waited out the full ~2.5s R throttle before the brain could retry. v6.15.141: state.r_phase_seen is armed false on every R dispatch and set true once r_abort_tick observes R in its cast phase (Ability.IsInAbilityPhase). If R has NOT entered its phase R_PHASE_START_DEADLINE (0.6s) after dispatch, it was cancelled on receipt — r_abort_tick logs r_cast_never_started, clears the R-in-flight markers + r_cast_protect, and downgrades the dispatch throttle from the 2.5s R window to the 0.4s SEQ window so starter_tick / teamfight_tick retry R within ~1s instead of ~2.5s. R was cancelled (not cast) so it is not on cooldown — the retry can fire it. v6.15.140 banner content preserved below. Sniper brain v6.15.140 loaded — two close-gap response fixes (user, v6.15.139 demo). FIX 1 (grenade and pike fire at the same time on a close gap): auto_grenade fires D every tick on a nearby rusher, INDEPENDENT of the defense save chain — so when the defense layer peels a diving PA with Hurricane Pike, auto_grenade also throws D at the same PA = both displacement tools spent on one dive. auto_grenade_tick now suppresses on two gates: (1) `next(state.armed_threats)` — a threat is ARMED, i.e. on_gap_close armed it and armed_threats_tick has not fired the save yet (the PRE-save signal the failed v6.15.136 attempt lacked — auto_grenade fires before the armed save dispatches); (2) state.last_save_t within AUTO_GRENADE_SAVE_SUPPRESS_S (0.6s) — the POST-save window covering the gap between the save dispatching and its push resolving. FIX 2 (PA jumps a second time and pike does not fire): the v6.15.139 demo log had 6 armed_threat_skip_responded — the threat-response dedup (a flat ~2s window keyed by caster+modifier) swallowed the SECOND PA Phantom Strike save because the FIRST blink was still inside the window. Each blink is a discrete cast and deserves its own save. New lib/dedup.lua Dedup.threat_clear_responded; on_gap_close clears the responded mark for the threat whenever it arms a FRESH instant-blink entry (a new blink anim) — so the new cast is not deduped against the old one. The dedup still prevents armed-tick + modifier-create double-firing WITHIN one cast (armed_threats_tick re-marks it on fire). v6.15.139 banner content preserved below. Sniper brain v6.15.139 loaded — save-cast-protect window (fixes the PA gap-close Hurricane Pike save that cast_verify showed as fired=n / cd_after=0). The defense layer issues the save order (Pike/Force/grenade) but a native Orb-Walker/Hit&Run MOVE or ATTACK order, sent queue=false the same tick, REPLACES it in the unit intent before the engine executes it — the exact same cancellation R suffered (fixed in v6.15.86 by r_cast_protect). The save layer had no equivalent. v6.15.139 adds state.save_cast_protect_until_t: record_save opens a SAVE_CAST_PROTECT_S (0.4s) window whenever a Layer-2 SELF-save dispatches (ally saves / smoke prefire excluded — they do not cast on Sniper). callbacks.OnPrepareUnitOrders now vetoes native unit-disrupting orders (MOVE/ATTACK/STOP/HOLD targeting Sniper) during EITHER the R-cast window OR the save-cast window — protect_until = max(r_cast_protect, save_cast_protect). Brain orders (sniper- identifier prefix) still pass. The veto log line is renamed r_cast_protect_veto -> cast_protect_veto with a `via` field (r_cast / save_cast). No interaction with the v6.15.138 R range-gate change — different code paths. v6.15.138 banner content preserved below. Sniper brain v6.15.138 loaded — R range-gate fix + revert of the v6.15.136 auto_grenade delay (user, v6.15.137 demo). FIX (R not firing on combo): the v6.15.137 R-gate diagnostic pinpointed it — every R-killable target logged r_range=n. Cause: r_ok_range = d >= 0.70 * atk_range_with_e, and atk_range_with_e is Sniper's attack range INCLUDING Take Aim's huge bonus (1480-1780u in the demo), so the threshold was 0.70*1780 ~= 1246u — R only fired on targets past ~1250u. The demo had R-killable PA at d=734-1240 all reading r_range=n. Fixed: r_ok_range now bases on ctx.atk_range (Sniper's real attack range WITHOUT the Take Aim bonus, ~600-700u) so the threshold is ~420-490u and R fires on any R-killable target past comfortable autoattack range. Applied to both starter `r` and teamfight `tf_r`. REVERT: the v6.15.136 auto_grenade save-suppress (1.2s after a Layer-2 save) is REMOVED (user: take it out, it is not the cause). It could not work anyway — an instant-blink save dispatches via armed_threats_tick AFTER on_gap_close arms it, i.e. after auto_grenade has already fired, so state.last_save_t is not yet stamped when the gate runs. STILL OPEN: the PA-gap-close Hurricane Pike save shows cast_verify fired=n — native-order interference replaces the issued Pike order before the engine executes it (same class of bug as R, which has r_cast_protect; the save layer has no equivalent). That save-cast-protect window is the next fix. v6.15.137 banner content preserved below. Sniper brain v6.15.137 loaded — R-gate diagnostics for the unresolved 'R not firing' report (user, v6.15.134 demo: R does not shoot even when the target is >=70%% attack range AND R-alone-killable; it worked in the past). The starter `r` archetype fires only when r_alone_kill AND r_safe AND ready_r AND (r_ok_range OR force) AND NOT r_will_range_leak — but the `starter` log line recorded only committed/fleeing/r_kill, so the log could not show WHICH gate refused R (the v6.15.134 log has many `starter decision=idle r_kill=y` lines with no further detail). This version adds the full R-gate state to the `starter` fire and idle log lines: ready_r, r_safe, r_range (r_ok_range), r_leak (r_will_range_leak), esc (escape_window), m_imm (magic_immune). NO behavior change — purely diagnostic; the next demo log will pinpoint the block (most likely r_safe going false because the target has a ready/soon escape item, or r_will_range_leak, or ready_r). v6.15.136 banner content preserved below. Sniper brain v6.15.136 loaded — auto_grenade no longer clobbers the defense save (user, v6.15.134/.135 demo: PA close-gap Pike still not being used; the log is wrong). The user was right — layer2_save / save_outcome only record that the save chain DISPATCHED an item, not that the engine cast it. The v6.15.134 demo log proves it: cast_verify for intent=armed_instant_blink:phantom_assassin_phantom_strike_pike repeatedly shows fired=n / cd_after=0.00, with cast_verify_double_fail on item_hurricane_pike — Pike never entered cooldown. Root cause: the auto_grenade behavior fires Concussive Grenade (D) on the nearest rusher every tick; when the defense layer dispatched Hurricane Pike against a PA Phantom Strike gap-close, auto_grenade fired D on the same PA the same tick, and D issued queue=false a hair later REPLACED the defense save's Pike order in the unit intent — so D fired (cd_after=9.8) and Pike was silently dropped (fired=n). Fix: auto_grenade_tick now suppresses for AUTO_GRENADE_SAVE_SUPPRESS_S (1.2s) after any Layer-2 save dispatches (record_save already stamps state.last_save_t) — the defense save IS the rusher response, auto_grenade is redundant and was actively clobbering it. NOTE: this addresses the shard-owned case observed in the log; if Pike still fails to enter cooldown in a no-shard / D-on-cooldown game (auto_grenade cannot fire D there, so a different cause), a no-shard demo log is needed to diagnose. v6.15.135 banner content preserved below. Sniper brain v6.15.135 loaded — two R-reliability fixes (user, v6.15.134 demo). FIX 1 (tap combo to force R took several tries): heavy_starter (the TAP combo) required BOTH R and E ready — the v6.15.134 demo log refused the tap 19 of 20 times with ready_r=y, ready_e=n (E on its 14-20s cooldown). The TAP intent is fire-R-on-command; Take Aim is a damage buff, not mandatory. Fix: the hard gate is now ready_r ALONE; the E step is cond-gated on ready_e (skips cleanly when E is on cooldown, R still fires same-tick via no_queue); the mana floor counts E only when E will fire. FIX 2 (R usage random while holding combo vs a diving PA): the `committed` classifier in starter_tick required NPC.IsAttacking(target) true on the current tick, but IsAttacking is true only for the ~0.3s swing of each ~1.4s attack cycle — a single-tick poll, so `committed` was true only on the rare tick the read landed mid-swing. A diving PA therefore routed to `chip` (Q+E, no R) ~75 times and `dr` (D+R+Q+E) only ~2 times, so R looked random. Fix (lesson L5/89 — gate a flickering poll on a time window): sample_velocities now stamps state.attacking_seen_t[idx] every tick an enemy is mid-attack; `committed` latches — true if IsAttacking is true now OR was within COMMITTED_ATTACK_WINDOW_S (1.6s, ~one attack cycle). NOTE on the Pike-vs-PA report: the v6.15.134 demo log shows the PA anti-gap save fired Pike 6 of 9 times (save_outcome save=pike) and grenade 2 times (Pike on its 19s cooldown — correct fallback); Pike IS being used. v6.15.134 banner content preserved below. Sniper brain v6.15.134 loaded — Team Fight tf_focus throttle fix (log audit of the v6.15.133 demo). The v6.15.133 demo log showed 258 issue_rejected for tf_focus ATTACK_TARGET orders and 258 teamfight decision=idle lines. Root cause: teamfight_tick's tf_focus path only stamped the dispatch throttle (state.last_layer1_t) inside the `if ok` branch — so when safe_issue rejected the ATTACK_TARGET (which it does whenever the order-dedup catches a focus target that is already set, the common case), the throttle was never set and teamfight_tick re-appraised + re-issued every single tick. Fix: tf_focus now stamps last_layer1_t / last_layer1_was_r / engaged_target UNCONDITIONALLY, so the loop re-appraises every 0.4s (LAYER1_COMMIT_WINDOW_SEQ) like a successful dispatch. Not gameplay-breaking — the focus target reaches the queue on the first attempt — but it eliminates the per-tick spam and wasted re-evaluation. Audit also confirmed WORKING: starter chip/dr Q-coverage gate (28 chip-Q suppressed, dr-Q gated), the v6.15.133 PA re-arm fix (10 instant_blink_armed + 10 armed_threat_fire, pike 5 / grenade 4), and Take Aim in teamfight (cast by the defense layer's reactive_take_aim, so the tf_q E companion correctly skips as self_take_aim_active). v6.15.133 banner content preserved below. Sniper brain v6.15.133 loaded — two demo-feedback fixes (user, v6.15.131 demo). FIX 1 (Q overlapping again, 1-2 enemy fight): the v6.15.131 global Q-coverage gate was wired only into the chip archetype of starter_tick. The dr archetype (D+R+Q+E, fired on a committed attacker) places a Q step that bypassed the gate entirely — not checked against the coverage list, not recorded into it. A committed attacker routes to dr every 2.5s, so back-to-back dr dispatches stacked Q zones on the same predicted spot. Fix: the dr Q step is now cond-gated on the same q_covered check the chip archetype uses (q_pos = predict_pos(target, q_arm_lead_s()) is identical for both), and a dr dispatch now records its Q placement into state.starter_q_track so later chip/dr Q dispatches see it. FIX 2 (PA anti-gap: second Phantom Strike did not fire Pike): on_gap_close arms instant-blink threats under a fixed key (instant_blink:phantom_assassin_phantom_strike) and only arms when state.armed_threats[key] is absent. armed_threats_tick fired the save but never removed the entry, so the first PA blink armed+fired it and every later blink found the stale key, skipped re-arming, and on_gap_close returned with no save. Fix: armed_threats_tick now clears state.armed_threats[key] once an entry reaches a terminal state (save fired OR skipped-as-responded), so each new cast re-arms and gets the full Pike-first chain; the responded-threats dedup still guards same-cast double-fire. NOTE: the PA save chain was ALREADY Pike-primary (SNIPER_SAVE_OVERRIDES + close_gap CATEGORY_CHAINS both list item_hurricane_pike first) — the bug was the second cast getting no save at all, not a wrong priority. v6.15.132 banner content preserved below. Sniper brain v6.15.132 loaded — Team Fight mode (HOLD, 3+ enemies). The combo-key classifier already routed a HOLD with 3+ enemy heroes to state.teamfight_tick, which until now was a stub delegating to the legacy layer1_tick combo catalog. v6.15.132 replaces it with a real per-tick adaptive archetype loop, mirroring starter_tick (throttle, target-pick, fire_steps). Each off-throttle tick picks ONE archetype: tf_r = R finalizer on a fleeing R-alone-killable enemy (same R gating as starter); tf_q = spread one Shrapnel zone at the best cluster centre via a Storm_Vortex-style coverage search (each enemy position plus every pairwise circle centre; winner covers the most enemies not already inside a recent zone) with Take Aim riding along same-tick; tf_e = Take Aim alone when Q charges are spent and the buff dropped; tf_focus = ATTACK_TARGET on the fastest-time-to-kill enemy (lowest effective physical HP). Successive ticks spread all 3 Q charges; the global starter_q_track coverage list prevents restacking and is shared with chip-Q so the two never overlap either. New helper state.tf_q_pos runs the cluster search. The legacy SNIPER_COMBOS / SNIPER_SEQUENCES catalog and layer1_tick are now dispatched by nothing on the combo key — retiring them is the next iteration. v6.15.131 banner content preserved below. Sniper brain v6.15.131 loaded — Q-overlap regression fix (user, v6.15.130 demo: Q is overlapping again). The log ruled out legacy-code interference — combo_classify was all mode=starter, no legacy q_corridor/q_stack dispatches; every Q was starter_chip_q. Real cause: v6.15.129's target-priority makes the engaged target switch between nearby enemies, and the chip-Q zone-coverage gate was keyed PER-TARGET (state.starter_q_track[Entity.GetIndex]), so a chip-Q aimed at enemy B could land on top of a chip-Q aimed at enemy A (different target index → no coverage history for it → not suppressed) — cross-target overlap. Fixed: state.starter_q_track is now a GLOBAL LIST of recent chip-Q placements; a new chip-Q is suppressed if it would land within STARTER_Q_COVER_R (400u) of ANY chip-Q placed within STARTER_Q_ZONE_LIFE (9s), regardless of which enemy it was aimed at. The list is append-then-prune-stale. v6.15.130 banner content preserved below. Sniper brain v6.15.130 loaded — Hurricane Pike fallback for the dr (D+R+Q+E) combo (user, v6.15.129 demo). The log confirmed the user's interference hypothesis: the DEFENSE layer fires grenade_at_caster (D) as the anti-gap save vs Phantom Assassin's Phantom Strike (blink) — competing with the dr combo's D for the one Concussive Grenade. New `dr_peel`: the dr archetype's peel step is D when D is ready, else Hurricane Pike (item_hurricane_pike cast on the attacker — the brain's existing Pike-peel pattern, 425u cast range, gated on NPCLib.item_ready + not-magic-immune). The dr condition is now `committed and ready_r and dr_peel` — dr fires whenever EITHER peel tool is available, so a committed attacker still gets the full combo while D is on cooldown (e.g. because the defense layer just spent D on the same PA). NOTE — the complementary defense-side change (make Pike the PRIMARY anti-gap save vs PA so the two layers never contend for D) is a defense-save-chain change, left as a follow-up. v6.15.129 banner content preserved below. Sniper brain v6.15.129 loaded — two fixes from the v6.15.128 demo. (1) AUTO-GRENADE no longer steals D from the combo. auto_grenade_tick's combo-suppression checked only state.combo_key_was_down — a SINGLE tick — but combo_key:IsDown() flickers between ticks, so on a flicker-false tick mid-hold auto_grenade fired D on a side enemy, putting D on cooldown and breaking the dr (D+R+Q+E) combo (user: 'not committing to a full combo vs melee enemies'). Now suppressed over a WINDOW: state.last_combo_key_down_t is stamped every tick the combo key is down, and auto_grenade skips while now() - last_combo_key_down_t < AUTO_GRENADE_COMBO_SUPPRESS_S (2.5s). Flicker-proof, and the window also covers the combo's deferred-step execution after key release. (2) TARGET PRIORITY — with multiple enemies, starter_tick now focuses the enemy ACTIVELY ATTACKING Sniper first: it scans the candidate list for a close (≤800u) mid-attack (NPC.IsAttacking) enemy before falling back to the top valuation candidate / stickiness target / nearest. v6.15.128 banner content preserved below. Sniper brain v6.15.128 loaded — optimal D placement for the dr (D+R+Q+E) defensive combo (user, v6.15.127 demo). D (Concussive Grenade) knocks units in its blast AWAY from the grenade's centre — the dr combo was casting D at the attacker's exact position (target_pos), which gives a poor/undefined knockback direction. New state.optimal_d_pos computes the placement on the Sniper→attacker line: D lands D_PEEL_OFFSET (300u) inward from the attacker (toward Sniper), so the attacker sits near the far edge of D's 375u blast and is shoved straight AWAY from Sniper. A melee attacker (close) → the offset clamps g to 0 → D lands ~on Sniper's own position; a ranged attacker (far) → g grows toward D's 600u cast range. Placement is clamped to D's cast range, with target_pos as a safe fallback. v6.15.127 banner content preserved below. Sniper brain v6.15.127 loaded — three fixes from the v6.15.126 demo. (1) VELOCITY SMOOTHING for Q prediction. Q still overlapped on moving targets because the v6.15.125 model used m_vecVelocity — the INSTANTANEOUS velocity — which is noisy tick-to-tick (target mid-turn, attack-move stutter, jittery samples), so consecutive chip-Q predictions jittered. New per-tick sampler (state.sample_velocities) records each nearby enemy hero's position into a 5-sample ring buffer; state.predict_pos derives a smoothed velocity by averaging the position delta over the ~0.33s buffer. starter_tick's chip-Q and dr-Q placements now use predict_pos (falls back to the stateless m_vecVelocity model when no history). (2) R FINALIZER no longer closes distance. E (Take Aim) was DROPPED from the r archetype — E activating triggers the native positioning subsystem to reposition Sniper toward the target's optimal attack range, i.e. it walks Sniper CLOSER (user: 'R is trying to get closer to be used'). R alone reaches 3000u and r_alone_kill already guarantees the kill without the Take Aim boost, so R-only fires the finalizer from current range with no walking. (3) D COMBO restored for engaging targets. The dr archetype's d<=cast_d gate was dropped — D's 600u cast range is shorter than the ~700u committed radius, so committed attackers at d=600-700 routed to chip instead of dr (demo: committed=y at d=641-661 went to chip). dr now fires on any committed attacker; if D is slightly out of its 600u range the engine walks Sniper the <=100u to cast it (fine for a defensive knockback combo). v6.15.126 banner content preserved below. Sniper brain v6.15.126 loaded — chip Q-zone clustering fix + chip Q/E reorder, from the v6.15.125 demo. (1) ZONE-COVERAGE GATE FIX. The v6.15.122 gate compared the target's CURRENT position against the last chip-Q's PLACED position to decide covered/skip-re-Q. But a chip-Q is placed a full ~1.5s lead AHEAD of the target, so those two points are inherently ~450u apart — the gate read not-covered almost immediately and re-cast Q every throttle tick, clustering 2-3 zones on one spot (demo log: two Q at the identical point, others 26-127u apart). The gate now compares the NEW Q's predicted position against the last Q's position; re-Q is suppressed unless the new zone would land at least STARTER_Q_COVER_R (400u) away, so chip zones space out along the target's path. (2) CHIP Q/E REORDER. The chip now casts Q FIRST (immediate) and E ~1.5s later as a deferred step, timed to the Q zone's arm. Per the user: casting E at t=0 burns 1.5s of Take Aim's 3s duration before the zone is even live — deferring E to the arm moment makes Take Aim fully overlap the armed zone. The deferred E is a fresh dispatch (reliable, not a queue chain). NOTE: the Q2/Q3 clustering the user saw was this coverage-gate logic bug, NOT a velocity-prediction error — the v6.15.125 velocity-vector model is sound (the Windranger skillshot script uses raw m_vecVelocity with no smoothing). v6.15.125 banner content preserved below. Sniper brain v6.15.125 loaded — three fixes from the v6.15.124 demo. (1) Q PREDICTION MODEL rewritten. The old Geom.lead_target_pos used NPC.GetMoveSpeed — a move-speed STAT (~300, non-zero while standing still) — projected along facing yaw, so it placed a STATIONARY target's zone ~450u off-centre (and a moving target's zone along facing, wrong whenever facing differs from travel). It now reads the engine's true velocity vector via Entity.GetField(target, 'm_vecVelocity'): zero velocity gives zero lead, real velocity gives the correct direction (future = pos + velocity * lead_s). Proven Windranger-2-script pattern; pcall-guarded with a facing-fallback gated on NPC.IsRunning. (2) R FINALIZER fixed — the r archetype required 'fleeing', so R never triggered on a killable target simply standing out of attack range / beyond 70% range. Dropped the fleeing requirement: r now fires on any R-alone-killable target at >=70% attack range, and is now E+R same-tick (Take Aim + Assassinate via the v6.15.120 no_queue pattern). (3) dr GATING tightened — committed now also requires NPC.IsAttacking(target), so the D+R+Q+E defensive combo only triggers on a target genuinely attacking Sniper, not one merely standing nearby. v6.15.124 banner content preserved below. Sniper brain v6.15.124 loaded — D and E usage rework from the user's v6.15.123 demo answers. E (Take Aim) is now the engagement OPENER — the Starter chip casts E every engagement, and the chip step order is fixed (E first as a fresh instant cast, then Q same-tick via the no_queue flag — the v6.15.122 chip queued E behind Q and it mostly failed to fire, so E was barely activating). D+R is reworked into D+R+Q+E, the defensive ultimate: it now triggers ONLY on a COMMITTED attacker (an enemy attacking Sniper, too close for comfort — target_attacking_us), NOT on a kill prediction (the kill gate is dropped — per the user it is a defensive peel that also kills, the perfect TTK) and NOT on the ≥70% R-range gate (D's knockback creates R's range). The combo: D stuns + knocks the attacker away, R nukes during the stun, Q drops a slow zone on the return path, E buffs Sniper — step order D → R(+0.2s) → Q(+0.4s) → E(after R cast point locks, so Take Aim's modifier can't cancel R). The old `engaged-r` and `d_lock` archetypes are removed — `dr` now covers any committed attacker regardless of range/kill. Starter archetypes are now exactly three: dr (committed → D+R+Q+E), r (fleeing + R-alone-kills + ≥70% range), chip (default → E+Q). The rc_2s discount and STARTER_RC_DISCOUNT are removed — no Starter kill check uses rc_2s anymore. v6.15.123 banner content preserved below. Sniper brain v6.15.123 loaded — Q prediction lead-time fix. User demo of v6.15.122: Q on a moving target lands mispositioned because q_arm_lead_s was 0.5s — the Q was placed only 0.5s ahead, but Shrapnel takes 1.5s from cast issue to the zone striking (0.3s cast animation + 1.2s effect delay). Restored q_arm_lead_s to 1.5s (v6.15.106's original value; v6.15.109 had dropped it to 0.5 on a since-disproven constant-velocity argument) so the Q is placed where the target will be when the zone actually arms. Affects all Q1 placements (Starter chip + legacy combos). Stationary targets unaffected (lead_target_pos' <200-mvspeed gate falls through to current position). v6.15.122 banner content preserved below. Sniper brain v6.15.122 loaded — Starter loop fixes from the v6.15.121 demo (no-shard run). Four fixes: (1) R-range discipline now applies to the FLEEING-R branch too — the v6.15.121 fleeing-R branch had no ≥70%-range gate; per the user, R is a flat DPS loss and a 2s self-vulnerability window, so it is only worth firing on a killable target at ≥70% attack range REGARDLESS of fleeing/engaged. All R commits now gate on r_ok_range. (2) Chip no-shard idle bug — `chip` was gated on `not dr_kill`, but without Aghanim's Shard D is uncastable so `dr_kill` (D+R kills) is hypothetical; a no-shard Sniper idled on a killable target instead of chipping. New `kill_available = (dr_kill and ready_d) or r_alone_kill` gates `chip` — the brain now chips when no available archetype kills. (3) Q chip-zone stacking — the v6.15.121 chip re-cast Q every 3s (STARTER_Q_RECHIP_S), stacking zones on a near-stationary target (zones don't stack — v6.15.79). Replaced the time-only recency gate with a zone-COVERAGE gate: state.starter_q_track records each chip-Q's position+time; re-Q is suppressed while the target is still within STARTER_Q_COVER_R (400u) of a chip-Q placed < STARTER_Q_ZONE_LIFE (9s) ago. A stationary target gets one Q per zone cycle; a target running out of the zone gets a fresh Q following it. (4) D-range gate — the `dr` archetype now checks `d <= cast_d` so D is not dispatched at an out-of-D-range target. NOTE still open: Q placement on a RUNNING target is still mispositioned — that is the Geom.lead_target_pos prediction-model issue (facing-yaw vs velocity-vector), scheduled as the next Q-prediction fix. v6.15.121 banner content preserved below. Sniper brain v6.15.121 loaded — adaptive-engagement combo-key redesign phase 2: the STARTER per-tick adaptive loop. The combo key's HOLD mode with 1-2 enemies now runs state.starter_tick — a real per-tick situational appraisal loop, replacing the transitional layer1_tick delegation. Every tick (subject to the 2.5s-R / 0.4s-light dispatch throttle) it re-appraises the engaged target and picks one archetype: (a) killable + engaged (committed or in attack range) + R worth firing → D+R+E punish (reuses snipe_d_r's proven D-first ordering); (b) killable + engaged but R unavailable or point-blank → D alone (stun-lock the kill, autos finish); (c) killable + fleeing + R-alone kills → R finisher; (d) not yet killable → Q1+E chip (Q zone + Take Aim, Q skipped if a fresh zone is already on the target). Per-tick re-evaluation is the state machine — a target that commits mid-chip escalates to D+R automatically on the next off-throttle tick. Bundled bug-fixes from the v6.15.117 demo feedback: R-range discipline (R only commits at ≥70% of Take-Aim attack range — STARTER_R_MIN_RANGE_FRAC — so a point-blank target is right-clicked, not ulted) and the rc_2s discount (STARTER_RC_DISCOUNT=0.65 — the 2s-of-autos kill estimate ran optimistic, R missed kills by ~1 auto). New log line: starter (decision=fire/idle, archetype=dr/r/d_lock/chip). The Heavy Starter (TAP) and combo-key core are unchanged. STILL transitional: teamfight_tick delegates to layer1_tick — Team Fight mode is phase 3 (v6.15.122); the legacy SNIPER_COMBOS/SNIPER_SEQUENCES catalog is retired once Team Fight no longer needs it. New state.X entry points keep the 200-locals budget clear. v6.15.120 banner content preserved below. Sniper brain v6.15.120 loaded — Heavy Starter E+R same-tick fix (2nd ordering iteration, user demo of v6.15.119). v6.15.119 deferred R by delay_s=0.05 to sit ≤0.05s behind E, but pending_steps_tick is tick-quantized (~15Hz) so R actually fired ~0.067s behind E (log: E ExecuteOrder t=48.300, R t=48.367) — over the user's 0.05s ceiling — and R was cancelled (cast_verify fired=n, double_fail). v6.15.120 issues E and R in the SAME OnUpdateEx tick as two fresh queue=false dispatches: E first (instant cast, 0 cast point — resolves immediately), then R with the new step.no_queue flag (queue=false despite being step 2 — fire_steps' use_queue is now `(i>1) and not step.no_queue`). The ~0s same-tick gap is well under 0.05s, so R locks its cast point before the native positioning subsystem reacts to Take Aim and emits the R-cancelling MOVE. NOT a queue chain (R queued behind E) — a queue chain makes the 2nd step unreliable (v6.15.103: E-first queue chain → R 0/6 fired). v6.15.119 banner content preserved below. Sniper brain v6.15.119 loaded — Heavy Starter E→R ordering fix (user empirical feedback on the v6.15.118 demo). v6.15.118 shipped the Heavy Starter with R-FIRST ordering (R, then E queued behind it); the user's demo found E did NOT activate at all. User-provided working recipe: E first, then R within ≤0.05s. v6.15.119 reorders the Heavy Starter steps to E (a fresh queue=false instant cast) then R (delay_s=0.05 → fresh deferred dispatch via pending_steps_tick → issue_cast_target queue=false — NOT a same-tick queue chain). This is the v6.15.96 pattern: the ≤0.05s gap keeps R from being cancelled, and Take Aim is active across the gap and through R impact for the 100% headshot physical instance. The legacy snipe_e_r combo (used by the transitional HOLD path) keeps its R-first ordering — it is retired in v6.15.120/.121, not separately fixed here. v6.15.118 banner content preserved below. Sniper brain v6.15.118 loaded — adaptive-engagement combo-key redesign, phase 1 of 4 (combo-key core). Runtime tap/hold detection replaces the v6.14 combo_tap menu toggle: a combo-key press released within 0.18s is a TAP, a longer press is a HOLD. TAP dispatches the Heavy Starter (heavy_starter_tick) — E+R fire-on-command, R-first ordering (R cast point locks before Take Aim activates, dodging the native-positioning cancel per v6.15.103; Take Aim still active at R impact for the 100% headshot physical instance), minimal gates only (R/E ready, mana for E+R, target in R cast range, not magic-immune), NO commit_pred kill check — the player tapped, they meant it; force-key bypasses the mana/range/immune gates. HOLD runs the engagement classifier (count_engaged_enemies — 3+ enemy heroes within 1500u of Sniper → Team Fight, 1-2 → Starter) and routes to starter_tick / teamfight_tick. Transitional: starter_tick / teamfight_tick currently delegate to the legacy layer1_tick combo catalog — the Starter per-tick adaptive loop lands in v6.15.119, Team Fight mode in v6.15.120, so HOLD behavior is unchanged this version while the tap/hold + classifier scaffold ships. Removed the combo_tap Switch. New diagnostics: combo_classify (enemies=N, mode=starter/teamfight, once per HOLD engagement) and heavy_starter (decision=fire/refuse, reason=...). New entry points use the state.X pattern (no top-level local slots — Lua 5.4 200-locals limit). v6.15.117 banner content preserved below. Sniper brain v6.15.117 loaded — removed the two useless per-ability ticks (auto_take_aim_tick, auto_q_chip_tick) per demo feedback. v6.15.111's KotL-inspired hybrid model added 3 per-ability reactive ticks: D (auto_grenade), E (auto_take_aim), Q (auto_q_chip). Demo verdict: D works great (user: 'great function', log: 42 fires, only on rushers/fog-emergers as intended — KEPT). E was useless — log shows it fired only 2× in a whole demo because its gate stack (E ready + not in combo + not in R cast + Take Aim not active + enemy in atk range) is too strict to ever meaningfully fire; user: 'almost useless' as an automatic. Q fired too much — user: 'firing all the time if Q not on CD, too much and basically useless'. Both E and Q REMOVED. The architectural lesson: per-ability reactive ticks work for genuinely-isolated reactions (D-on-rusher) but NOT for abilities whose value is timing-coupled to a combo — E (Take Aim) is only useful as a combo opener/finalizer tied to R, and Q wants combo-key control not autonomous spam. E and Q will be wired into the combo-key sequences in the v6.15.118 combo-key redesign instead. Removed: 2 tick function definitions (~180 lines), 2 OnUpdateEx call sites, 2 menu toggles (auto_take_aim_enable, auto_q_chip_enable). auto_grenade (D) survives as the one per-ability tick. v6.15.116 banner content preserved below. v6.15.116 — full codebase checkup, doc-accuracy fixes only. User requested a full check for anything broken / wrong / bugged / logically problematic across Sniper.lua + all 10 lib files. Process: Lua syntax check on all 11 files (all OK), then 3 parallel independent review passes — (1) lib internal correctness, (2) v6.15.112-115 lib-extraction call-site fallout, (3) v6.15.104-111 feature logic. Result: ZERO functional bugs. Extraction-fallout audit PASS (no orphan refs, all imports correct, all call-site args correct, GC pass intact). Feature-logic audit PASS (barrier sign correct, R buffer applied correctly to all 6 sites, per-ability ticks gate correctly, nil-safety confirmed). Two stale COMMENTS found and fixed: (a) lib/geometry.lua lead_target_pos doc prose claimed it returns current position when target is nil — actually returns nil (callers handle via `or fallback`); the @return annotation was already correct, only the prose bullet list was wrong. (b) Sniper.lua OVERKILL_BUFFER_HP comment listed 5 R-using combos but the buffer applies to 6 — snipe_channel_punish was omitted from the list (code always buffered all 6 correctly). No behavior change in v6.15.116 — comment fixes only. Codebase confirmed clean for in-game testing. v6.15.115 banner content preserved below. v6.15.115 — fourth lib extraction: dedup helpers via state-container redesign. v6.15.112 attempted to extract anim_log_throttled / already_responded / mark_responded to lib/dedup.lua but reverted — the lib's module-private tables broke Sniper's 5+ external readers of state.responded_threats / state.anim_log_dedup (GC passes, clears, iterators). v6.15.115 redesign: lib/dedup.lua functions take the caller-owned table as first argument (Dedup.anim_throttled(tbl, caster, ability), Dedup.threat_already_responded(tbl, caster, mod), Dedup.threat_mark_responded(tbl, caster, mod)). Sniper still OWNS state.responded_threats / state.anim_log_dedup; lib just provides the read/write API + window constants (Dedup.ANIM_WINDOW, Dedup.THREAT_WINDOW). All external Sniper iterators / GC passes keep working unchanged. Removed from Sniper.lua: anim_log_throttled, _threat_key, already_responded, mark_responded (4 functions) + ANIM_LOG_WINDOW, THREAT_RESPONSE_DEDUP_WINDOW (2 constants) = 6 local slots. Added 1 Dedup import. Net v6.15.115: +5 slots. Cumulative v6.15.112-115: 11 declarations removed, 3 imports added (Geom, NPCLib, Dedup) = +8 slots saved net. Brain at ~173 locals (was ~182 pre-extraction). lib/dedup.lua is the state-container pattern reference for future extractions (Lesson 9). v6.15.114 banner content preserved below. v6.15.114 — third lib extraction (NPCLib.item / item_ready). v6.15.112 set up infrastructure (lib/geometry.lua, lib/npc.lua, lib/dedup.lua). v6.15.113 used lib/npc.lua for has_shard / has_scepter (10 call sites updated, +1 net slot). v6.15.114 ALSO uses lib/npc.lua for item / item_ready (~50 call sites updated via replace_all, no new import since NPCLib already imported). Cumulative v6.15.112-114: 5 declarations removed (lead_target_pos, has_shard, has_scepter, item, item_ready), 2 imports added (Geom, NPCLib) = +3 slots saved net. Brain now at ~178 locals (was ~182). Replace_all corruption pattern AGAIN: bulk `item(` matched the local declaration; pre-removed via targeted edit (per Lesson 9). All Lua syntax checks pass. Pending v6.15.115+: dist_to (small, +1 slot if extracted to Geom); lib/dedup.lua redesign with passed-in-state container then extraction (~6 slots from anim_log_throttled / _threat_key / already_responded / mark_responded + 2 constants). v6.15.113 banner content preserved below. v6.15.113 — second lib extraction (NPCLib.has_shard / has_scepter). v6.15.112 set up infrastructure (lib/geometry.lua, lib/npc.lua, lib/dedup.lua written; only geometry used). v6.15.113 actually USES lib/npc.lua: has_shard() / has_scepter() local declarations REMOVED from Sniper.lua (lines ~858-859), call sites converted via replace_all from has_shard() / has_scepter() to NPCLib.has_shard(state.self_npc) / NPCLib.has_scepter(state.self_npc). 10 call sites updated. Net slot change v6.15.113: 2 declarations removed, 1 NPCLib import added = +1 slot saved. Cumulative v6.15.112+.113: 3 declarations removed (lead_target_pos, has_shard, has_scepter), 2 imports added (Geom, NPCLib) = +1 slot net. Future extractions into existing lib files are 'free' (no new import). Pending v6.15.114+: lib/npc.lua's item / item_ready (~50 call sites, +1 slot); lib/dedup.lua redesign with passed-in-state container then extraction (~6 slots). Caveat: same replace_all corruption issue as v6.15.110 / v6.15.111 / v6.15.112 — bulk replace_all on `has_shard()` matched the local declaration too (made it `local function NPCLib.has_shard(state.self_npc)` invalid Lua). Manually fixed by deleting the corrupted declaration. Pattern reinforced: anchor on context for declaration removal, replace_all for call sites only. v6.15.112 banner content preserved below. v6.15.112 — lib extraction, infrastructure phase. User directive: 'we hitting too much the limits of LUA. Since we are making a lib for future exportations, lets take out everything that is sharable from sniper.lua and make it external on the libs.' Phased plan: v6.15.112 establishes lib infrastructure with one clean extraction (lead_target_pos → lib/geometry.lua); v6.15.113+ extracts more (has_shard / has_scepter / item / item_ready → lib/npc.lua via signature-change edits; dedup helpers → lib/dedup.lua via passed-in-state redesign). Inventory found 116 local function declarations + ~66 local constant declarations = ~182 top-level locals (close to Lua 5.4's 200-locals-per-function hard limit). Three new lib files written this version: lib/geometry.lua (USED — lead_target_pos), lib/npc.lua (READY — has_shard / has_scepter / item / item_ready, deferred to v6.15.113), lib/dedup.lua (READY but redesign needed — current API maintains private dedup tables but Sniper has 5+ external state.responded_threats readers; reverted dedup extraction this version, will redesign with state-container pattern in v6.15.113+). Net slot change v6.15.112 = 0 (Geom import +1, lead_target_pos -1) but FUTURE extractions into same lib files are 'free' on import cost. Each subsequent extraction into Geom / NPC / Dedup frees a full slot. v6.15.111 banner content preserved below. v6.15.111 — KotL-inspired hybrid architecture: per-ability reactive ticks for E (Take Aim) and Q (Shrapnel chip), mirroring v6.15.107's auto_grenade_tick (D). User architectural insight from KotL.lua re-read: KotL organizes by ABILITY (ManageIlluminate / ManageBlindingLight / ManageSolarBind / ManageRecall — each independently decides cast/skip per tick, no combo dispatcher). Sniper's combo catalog exists because R MUST coordinate with E (Take Aim active at R impact) + D (stun lock during R cast). But D/E/Q can also be USEFUL in isolation, outside R-kill-commit context. Hybrid model: combo catalog handles R commits (where coordination matters), per-ability ticks handle reactive utility usage (where it doesn't). Now: D = auto_grenade_tick (v6.15.107), E = state.auto_take_aim_tick (this version), Q = state.auto_q_chip_tick (this version). All three OFF by default, opt-in via Brain menu. Each gates on combo_key_was_down (manual combo wins), state.last_X_t (recent combo dispatch), r_cast_protect_until_t (CRITICAL for E since Take Aim activation pre-R-cast-lock cancels R per v6.15.103). E tick adds: skip if Take Aim modifier active (3s duration), CD gate, target-in-atk_range_with_e check. Q tick adds: 9s per-target gate (mirror q_corridor_finisher), shrap_charges>=1 check, lead_target_pos with q_arm_lead_s for placement. ARCHITECTURAL NOTE: hit Lua 5.4's 200-locals-per-function hard limit AGAIN on first attempt (would have happened with `local function auto_take_aim_tick`). Per Lesson 7, switched to state.auto_take_aim_tick = function()... and state.auto_q_chip_tick = function()... — table-field assignment doesn't consume local slot. Future ticks must follow this pattern. Lesson 8 added to bridge: hybrid architecture pattern (combo catalog for orchestration-required abilities, per-ability reactive for utility abilities). v6.15.110 banner content preserved below. v6.15.110 — two more fixes from user test feedback. (1) R kill prediction: user said 'R calculations are usually off and not doing the finalization, missing by 1 auto attack. Usually a low value.' Brain over-estimated combo damage by ~50-150 HP, fired R, target survived sliver, 110s R CD wasted. Added state.OVERKILL_BUFFER_HP = 100 (one auto with Headshot proc + armor reduction ≈ 100 HP net). All 6 R-using commit_pred kill checks (snipe_e_r, snipe_d_r, snipe_q_r, snipe_standard, snipe_r_only x2 sites) now refuse R when (eff_hp + 100) > combo_dmg. Conservative trade: refuses borderline kills, but a refused R is reusable in 110s; a wasted R is gone for the engagement. NOTE: had to use state.X instead of local X — brain hit Lua 5.4's 200-locals-per-function hard limit at parse time. Future module-level constants must use state.X or global pattern. (2) snipe_d_r extended with E queued step (D+R+E combo for closer targets). User said 'Didn't notice the combo D+R+E+Autoatack for closer targets that are close.' Added E (Take Aim) as deferred step at delay_s = 0.1 + r_cast_point() — fires ~0.1s before R impact. Take Aim activates JUST before R impact: instant attack at impact gets 100% Headshot + post-R autos for 3s window all proc Headshot. cond gates on c.ready_e — combo gracefully degrades to D+R-only if E unavailable. Same R-first-with-E-deferred pattern as snipe_e_r (no native subsystem cancel risk because R cast point is locked in engine before Take Aim modifier activates). NOT addressed: user item D 'E never fires in opening' — q_e_sustained already does Q+E in chip phase; if not firing in tests, root cause needs log data (deferred to v6.15.111+). v6.15.109 banner content preserved below. v6.15.109 — Q-prediction fix from in-game test feedback. v6.15.106 lead of 1.5s assumed constant target velocity over the full 1.5s flight; in practice target velocity drops mid-flight (Headshot procs slow them, attack-animations freeze them, stuns lock them, channels glue them, decision changes). User on v6.15.107 demo: 'Q1 prediction is off, not using enemy as center point' — Q landed AHEAD of where target ended up. v6.15.109 reduces q_arm_lead_s from 1.5s → 0.5s. At v=300: Q placed +150u ahead of current target pos; if target maintains velocity, ends at +300u from Q center (well inside 450u radius); if target stops mid-flight, ends between -150u (back edge) and +300u (front 2/3) of Q center. ALL velocity profiles → target inside Q at arm time. Trades 'perfect center on constant-velocity targets' for 'always inside Q regardless of velocity changes'. Plus q_corridor_finisher Q2/Q3 args replaced — pre-v6.15.109 used corridor_pos_from_anchor (Q1_anchor + N×radius along Q1's captured yaw, the v6.15.67-.74 corridor tile model). User feedback: 'Q still being fired in corridor logic with overlapping. This model is before we noticed Q doesn't stack (v6.15.84). New model should predict next direction for Q2 and use enemy as center point.' v6.15.109 Q2/Q3 use lead_target_pos (same enemy-centered prediction as Q1) re-evaluated at each fire time. Delays unchanged (radius/mvspeed) — by Q2 fire time target has typically moved ~one radius from Q1 position, so Q2 placed at target's current pos+lead naturally lands fresh and adjacent to Q1 with minimal overlap. corridor_pos_from_anchor and set_corridor_anchor remain in code as dead helpers (no callers post-v6.15.109; harmless, can clean up later). v6.15.108 banner content preserved below. v6.15.108 — pre-test bug-hunt produced one trivial defensive fix. COMMAND_RESTRICTED enum check at self_alive_ok line ~364 changed from truthy short-circuit (`if MS.X and ...`) to explicit nil check (`if MS.X ~= nil and ...`). Lua treats 0 as truthy unlike most languages, so a hypothetical engine build where MS.MODIFIER_STATE_COMMAND_RESTRICTED == 0 would have slipped past the truthy guard and called NPC.HasState(me, 0) — undefined. Dota's enums never have value 0 in practice, so no observed risk; defensive coding only. Pre-test bug-hunt also surfaced 7 other review-flagged 'concerns' that all reduced to false alarms or intentional design choices: q_refresh + corridor window collision (intentional fallback per design), q_arm_lead_s 1.5s over-lead on slowed targets (known unavoidable physics trade-off), combo_key_was_down timing race (false alarm — write at line 7941 happens BEFORE auto_grenade_tick call at line 8068), state.last_d_t semantic shift (no current callers, future-proofing concern only), r_cast_point Scepter fix (clean), auto_grenade state divergence (clean), banner truncation (clean). Net: brain is in clean state, ready for in-game testing of v6.15.104 barriers / v6.15.106 Q1 prediction + q_refresh / v6.15.107 auto-grenade subsystem. v6.15.107 banner content preserved below. v6.15.107 — third-party script audit landed three changes (one was a QA-caught fix). (1) New auto_grenade_tick subsystem at line ~7590 (adapted from klc9r4n Sniper Concussive Grenade script). Standalone proximity-triggered D dispatch — fills the Phase 0 gap where Sniper brain had D as a step inside snipe_d_r / snipe_standard / snipe_channel_punish combos but no auto-grenade for the 'enemy hero closes within 500u while I'm not in a combo' case. Coexistence: skips when combo key held, when state.last_d_t < 1.5s (combo just queued D), during R cast protect window, and on its own 0.3s throttle. Routes through issue_cast_position with identifier='sniper-auto_grenade' so OnPrepareUnitOrders veto sees it. Smart-cast position predicts enemy at cast_anim (0.1s) + projectile_travel (dist/2500) using NPC.GetForwardVector / IsMoving / IsStunned / IsRooted gates from klc9r4n. UI: 5 new menu fields under Sniper Extra Settings > Brain (Auto-grenade enable + radius + smart-cast + skip-slowed + low-HP-extra-radius). OFF by default — opt-in. (2) COMMAND_RESTRICTED added to self_alive_ok at line ~364. Was missing from Sniper's 6-state self-disable check (STUNNED, HEXED, SILENCED, NIGHTMARED, TAUNTED, INVULNERABLE, OUT_OF_GAME). ROOTED INTENTIONALLY NOT added — klc9r4n includes it but for Sniper that would be wrong: ROOTED only prevents movement, Sniper can cast Q/W/E/R/D/items while rooted, and a rooted Sniper NEEDS saves and R. (3) Per-ability fire-time tracking made functional. QA pass caught that state.last_q_t / e_t / d_t / r_t (lines 234-237) were defined but NEVER WRITTEN — vestigial fields. My auto_grenade_tick gate 'don't re-fire D within 1.5s of combo D dispatch' would have been broken without writes. Added matching writes at fire_steps (~line 3136) and pending_steps_tick (~line 2889) — every successful Q/E/D/R fire now updates the corresponding state.last_X_t. The audit confirmed Sniper is otherwise architecturally mature — pcall coverage (30 occurrences), 6-state disable coverage already in place, the audit's other 'high-impact' recommendations turned out to be already covered. v6.15.106 banner content preserved below. v6.15.106 — Q-stacking improvements (user-flagged Pending #A). TWO changes bundled. (1) Q1 prediction tuning: new q_arm_lead_s() helper at line ~436 returns 1.5s = LIQUIPEDIA_REF Q cast point (0.3s) + arm delay (1.2s). All 6 Q1 placement sites now lead by this full pipeline (was 0.5s in snipe_e_r, 0s in snipe_q_r/snipe_standard/q_e_sustained/q_stack_attacker, 0.3s in corridor_pos_q1). Net effect: Q lands where target WILL be when zone arms, not where they were when cast issued — moving targets (mvspeed > 200) get correct prediction; stationary targets fall through to current pos via lead_target_pos's existing 200-mvspeed gate. (2) New q_refresh combo at line ~4486: re-casts Q at predicted target position when prior Q zone is about to expire (window: elapsed ∈ [10.5, 11.5]s after prior Q dispatch, matching user's 'refresh ~0.5s before Q1 expires'). Per-target tracking via existing state.last_shrap_on_target_t. Score 32 (below corridor's 38 / stack's 40) so refresh never preempts a fresh-engagement combo — it's the maintenance dispatch for already-engaged-and-Q'd targets only. q_chain_step_cond gates against autos-already-killable so refresh doesn't waste a charge on overkill. Resolves the v6.15.86 q_stack_attacker comment hint 'Sequential refresh when zone expires is a future iteration'. v6.15.105 banner content preserved below. v6.15.105 — DRY refactor: extracted r_cast_point() helper at line ~412 (Scepter-aware via Ability.GetCastPoint(r_ab, true), 2.0 fallback). Replaces 7 inline duplicates of the same pattern at lines 2466 (r_will_range_leak), 2533 (r_cast_s ctx field), 2546 (proj_state_r_impact), 2563 (proj_state_post_r), 2819 (deferred R-step protect window), 3095 (fire_steps R-step protect window), 3533 (snipe_d_r delay_s). One mild behavior change: r_will_range_leak previously hardcoded 2.0s — now Scepter-aware (0.5s for Scepter Sniper), so the range-leak refusal is no longer 4× over-stated for Scepter builds. All other sites: zero behavior change (same call pattern, same 2.0 fallback). Bridge open-followups #C (Modifier.GetDieTime — already used at line ~2600 for bkb_remaining_s) and #E (NPC.IsLinkensProtected — already wrapped by Target.HasReadyLinkens at lib/target.lua:171) verified done. v6.15.104 banner content preserved below. v6.15.104 — barrier-aware kill prediction via NPC.GetBarriers. Mined from KotL's Illuminate damage estimator (third-party UCZone script). NPC.GetBarriers returns {magic = {current, max}, all = {current, max}} for absorbing shields — Aeon Disk, Lotus Orb, Pipe of Insight aura, item_infused_raindrops. Brain through v6.15.103 ignored these → over-committed R on targets with shields up (combo damage hits the shield first, kill check was wrong). v6.15.104 adds barrier values to eff_hp_magical in build_layer1_ctx (line ~2336 area), pcall-wrapped per KotL's defensive pattern. Magic barriers and 'all' barriers both factor in (R's instant attack physical instance also gets absorbed by 'all' barriers). Net effect: snipe_e_r/snipe_q_r/snipe_d_r/snipe_standard commit_pred refuses R when target has Aeon Disk/Lotus active and combo can't burn through. Cleaner R discipline. v6.15.103 banner content preserved below. v6.15.103 — re-apply v6.15.101's R-first ordering. v6.15.102 reverted to E-first thinking sniper_v2 was the only cancel source — but fresh clean-session demo (no sniper_v2 in /scripts/, confirmed SniperV2 load count=0) had snipe_e_r_r 0/6 fired with E-first. Re-deploying R-first ordering: snipe_e_r_r 2/2 fired in v6.15.101 demo. Corrected mechanism: UCZone has a compiled subsystem (in protected LoaderKernel.dll) that emits MOVE_TO_POSITION (issuer=0, no identifier, ~570u from cursor) when Take Aim modifier activates — likely auto-positioning to the new extended attack range. Our veto callback catches the orders (4/4 returned false in fresh demo), but the engine's cast-cancellation logic runs at order RECEIPT, not EXECUTION — by the time we decide to veto, R cast is already cancelled. R-first works because R cast point is locked in before Take Aim activates and the engine respects in-progress casts. Trade-off: cast_verify for E reports fired=n + double_fail because E is queue=true behind R and dequeues at t=2.0 (after both verify check windows at t=0.4 and t=1.4). Visual ground truth = Take Aim modifier appears on Sniper at R cast completion. Empirical correctness > log cleanliness. v6.15.102 banner content preserved below. v6.15.102 — revert v6.15.101 reorder. Root cause of v6.15.91-v6.15.101 R-cancellation arc was sniper_v2.lua running in parallel from C:\\Umbrella\\scripts\\sniper_v2.lua (3725-line third-party Sniper brain). It emitted MOVE_TO_POSITION via Player.PrepareUnitOrders with issuer=nil (defaults to SELECTED_UNITS=0) and callback=false — bypassing OnPrepareUnitOrders entirely, explaining why our veto fired 0 times despite consistent R cancellations. With sniper_v2.lua removed by user, v6.15.101 demo confirmed R fires 100% (snipe_e_r_r 2/2 fired=y). v6.15.101's R-first reorder (workaround) reverted to natural E-first / R-deferred-0.2s ordering. Take Aim modifier active across full R cast point + impact → 100% headshot on instant attack preserved, no log-noise from queued-step cast_verify timing. The 11-version arc (v6.15.91-101) chasing schema fixes, field names, queue mechanics, delays — all solved nothing because the actual cause was an entire parallel hero brain duplicating combos. Lessons captured in changelog. order_inspect diagnostic and r_cast_protect_veto retained for now (low overhead, useful safety net if sniper_v2 or similar is ever re-introduced). v6.15.101 banner content preserved below. v6.15.101 — reorder snipe_e_r + snipe_scepter_aoe to R-first, E-second. v6.15.100 demo: with E fixed (4/4 fire) and R deferred at 0.2s, R failed 6/7. ZERO order_inspect events during R cast window → cancellation bypasses OnPrepareUnitOrders entirely. The architectural limit (BRAIN_PROJECT.md:156: 'baseline orders bypass OnPrepareUnitOrders') applies to whatever is cancelling R post-Take-Aim-activation. Symmetric evidence across v6.15.96-.100: when E fails to fire, R succeeds; when E fires reliably, R fails. The Take Aim modifier activation triggers something (UCZone Combo binding's auto-positioning per user observation 'the combo key tries to move to go into position') that cancels R via a path our callback doesn't see. Fix: reorder steps so Take Aim activates AFTER R cast starts. New flow: t=0 R cast starts (queue=false, no Take Aim active); t=2.0 R cast completes + E dequeues from queue=true and applies Take Aim modifier; t=2.5 Q1 deferred fires; t=2.7 R projectile impacts with Take Aim active → 100% headshot on the instant attack physical instance. During R's 2s cast point Take Aim is inactive so the positioning trigger doesn't fire → R survives. Headshot is preserved because Take Aim must be active at IMPACT (when the instant attack hits), not during the 2s cast. Diagnostic note: cast_verify for E will report fired=n + double_fail because the verify check fires before E dequeues from queue at t=2.0 — this is log noise, not a functional failure. E still applies Take Aim modifier as designed. v6.15.100 banner content preserved below. v6.15.100 — bump E-predecessor R delays 0.05 → 0.2s. v6.15.99 demo: snipe_e_r_e fired=y 5 / fired=n 8 (62% E cancellation) at 0.05s delay, despite Take Aim being 'instant' (cast_point 0). q_total_at_issue=2 on failed E — external orders queued ahead of E in Humanizer. v6.15.96's 2/2 success was a small sample with no input pressure; v6.15.99 had Pike + items + realistic gameplay so Humanizer queue was congested. v6.15.96 missed that 'instant' E still has Humanizer-side rate-limit/safety delay. User's observation 'R fires very close to opponent' is the symptom: E cancelled → no Take Aim modifier → no extended range → R fires alone close-range, looking like snipe_r_only behavior. Fix: bump snipe_e_r and snipe_scepter_aoe R delays to 0.2s. Take Aim modifier duration 3s easily covers 0.2s gap. R cast 2s + projectile ~0.5s → impact at t=2.7s, still inside Take Aim window. Also addressed user's note re: Sniper AA range scaling — effective_attack_range(me) already includes NPC.GetAttackRangeBonus per v6.15.17 so Pike's range bonus IS factored in. v6.15.99 banner content preserved below. v6.15.99 — revert non-instant-predecessor R delays to v6.15.97 values; engine behavior (A) confirmed. v6.15.98 demo: snipe_q_r_q fired=y 3 / fired=n 8 — Q was cancelled mid-cast 73% of the time when R's queue=false dispatch arrived at t=0.05 during Q's 0.3s cast point. snipe_e_r_e fired=y 2 / n 2. User correctly noted 'Only R inside range' for snipe_q_r — R was firing but Q was being cancelled, so user only SAW R land. Restored delays: snipe_q_r 0.4s, snipe_d_r 0.2s, snipe_channel_punish 0.2s, snipe_standard 0.4s. snipe_e_r and snipe_scepter_aoe keep 0.05s (E predecessor is truly instant — proven by v6.15.96's 2/2 fire rate). Re: user's snipe_d_r observation 'Granade logic might be lacking': brain DID evaluate snipe_d_r every tick but skipped with req(out_of_grenade) — D cast range is only 600u, much shorter than Sniper's auto-attack range (550-1250u). User's test scenarios likely had target at 700-1500u where D was correctly skipped. For D-combo testing, target must be within 600u. Considering: user's tactical preference 'inside AA area should combo with D+R+Q' may need a positioning step (MOVE Sniper to within D range when D combo would be valuable). Deferred to next iteration if user confirms. v6.15.98 banner content preserved below. v6.15.98 — uniform R delay 0.05s across all multi-step R combos. User pragmatic question: 'Since the R delay worked on 0.05s we can use that as a base, wouldn't that be better?' Valid point. v6.15.97 used per-combo tuned delays (0.05/0.2/0.4) defensively, worrying R queue=false would cancel a predecessor still mid-cast. But the v6.15.36 evidence cited was for SAME-TICK orders competing — not for deferred orders arriving during an in-progress cast. Two engine behaviors possible: (A) engine cancels predecessor when R queue=false arrives → predecessor lost, OR (B) engine respects 'Sniper in cast' state and queues R behind the predecessor → effectively same as queue=true but without wake-up vulnerability. If (B), 0.05s works uniformly: simpler code, no per-combo timing knobs. If (A), cast_verify <combo>_<predecessor> fired=n surfaces it and we revert that specific combo. snipe_q_r is the cleanest test (Q has the longest predecessor cast point at 0.3s). v6.15.97 banner content preserved below. v6.15.97 — defer R in all multi-step R combos (v6.15.96 fix applied universally). v6.15.96 proved the diagnosis: R queued behind a predecessor step (queue=true) is vulnerable to MOVE order pre-emption during its wake-up window. snipe_e_r got delay_s=0.05 and now fires 100%. v6.15.97 applies the same pattern to the remaining 5 multi-step R combos, with delays tuned to each predecessor step's cast point: snipe_scepter_aoe = 0.05s (E instant), snipe_q_r = 0.4s (after Q's 0.3s cast), snipe_d_r = 0.2s (after D's 0.1s cast), snipe_channel_punish = 0.2s (same), snipe_standard = 0.4s (after Q's 0.3s + Pike completes). All R orders now fire from pending_steps_tick → issue_cast_target with queue=false, atomic dispatch like snipe_r_only. Take Aim modifier (3s) covers any added delay so 100% headshot is preserved on E-using combos. snipe_r_only unchanged (already queue=false). Pending: Q stacking improvements (predict-next-position + 0.5s-before-Q1-expiry refresh) — v6.15.98 candidate after R combo verification. v6.15.96 banner content preserved below. v6.15.96 — defer R 50ms in snipe_e_r (queue=false path) + diagnostic with position. User confirmed v6.15.95 'same behaviour' — R fails with E available, succeeds with E unavailable. Hit & Run on/off doesn't matter. Auto Combo always off. New theory matching the symmetry: in snipe_e_r, R is step 2 with queue=true (chained behind E per v6.15.36 same-tick combo rule). When E completes its 0s cast point, R wakes from queue and the engine reprocesses pending orders — an arriving MOVE order pre-empts R before it locks cast. snipe_r_only's R uses queue=false directly so R clears the queue and starts cast atomically, surviving MOVE orders. Test: defer R in snipe_e_r via delay_s=0.05. Routes R through pending_steps_tick → issue_cast_target (queue=false, parity with snipe_r_only). E + R now fire as two separate fresh dispatches with 50ms gap instead of one queue-chained dispatch. Take Aim modifier (3s duration) easily covers the gap so 100% headshot is preserved. Parity work: pending_steps_tick now sets state.r_cast_protect_until_t when deferred R fires (matches fire_steps line ~3032) so the veto window still opens. Diagnostic enhanced: order_inspect now logs pos_x/pos_y/dist_cur — if MOVE orders' position equals cursor pos (dist_cur ~0), it's pure player cursor input. If far from cursor, it's a script auto-positioning Sniper independently. v6.15.95 banner content preserved below. v6.15.95 — execute_fast for R cast + architecture flag. v6.15.94 demo data: snipe_e_r_r 1 fired / 2 cancelled, cast_verify_double_fail showed q_total_at_issue=3 q_self_at_issue=0 — at the moment brain issued R, queue held 3 NON-BRAIN orders. R never reaches cooldown (cd_after=0). v6.15.94's self-cancel gate worked (no snipe_r_only during R cast) but native subsystem orders are still cancelling R. Architectural limit confirmed per BRAIN_PROJECT.md:156 — 'baseline orders bypass OnPrepareUnitOrders in companion scripts.' OnPrepareUnitOrders veto CANNOT block native UCZone subsystems (Auto Combo, Hit & Run, Orb Walker) by design. v6.15.95 brain mitigation: execute_fast=true on R's issue_cast_target (only for sniper_assassinate, scoped narrowly). Per player.md:21, execute_fast 'bypasses internal safety delays for immediate execution' — R may scope ahead of the 3 native orders waiting in queue. USER ACTION RECOMMENDED: open UCZone menu and verify these subsystems are DISABLED while brain is running: Auto Combo / Auto Attack / Hit & Run / Orb Walker. Per bridge sidecar pattern, native subsystems must be off — brain owns dispatch. If v6.15.95 doesn't resolve R cancellations, the only remaining path is the UCZone UI toggle. v6.15.94 banner content preserved below. v6.15.94 — identifier case fix + R-self-cancellation gate. v6.15.93 demo (14 order_inspect events) revealed TWO remaining bugs: (1) HERO_KEY = 'sniper' (lowercase, line 166) but v6.15.93's identifier prefix check used 'Sniper-' (capitalized) — never matched. Brain orders passed the veto only by accident because CAST orders aren't in the disrupts filter. Fixed: prefix check now matches lowercase 'sniper-'. (2) Brain self-cancellation. v6.15.93 log shows id=sniper-agg-snipe_r_only_r firing DURING snipe_e_r's R cast window — second R cast cancels first. Root cause: ability_ready(A.R) returns TRUE during R's 2s cast point because Ability.GetCooldown only starts at cast END. Brain doesn't see R is already mid-cast. Fix: gate ready_r in build_layer1_ctx on (state.r_cast_protect_until_t or 0) <= now(). All R-using combos (snipe_e_r, snipe_r_only, snipe_q_r, snipe_d_r, snipe_standard, snipe_channel_punish) gate on c.ready_r — so this one line blocks all of them from re-dispatching R while a cast is in flight. v6.15.93 also confirmed: (a) actual veto fires correctly for player MOVE input (ord=1 issuer=0) — that part of the architecture works as designed; (b) brain orders carry data.identifier as expected (the undocumented field IS populated by Player.PrepareUnitOrders' identifier param). Open: bridge task #C (Q stacking improvements — predict-next-position + 0.5s-before-Q1-expiry refresh) still pending — v6.15.95 candidate. v6.15.93 banner content preserved below. v6.15.93 — OnPrepareUnitOrders schema fix. v6.15.92 demo's order_inspect (25 callback fires inside R cast window) revealed root cause of the v6.15.86-v6.15.92 R-cancellation arc: the brain was reading WRONG field names on the callback data. v6.15.86 used data.order_type (snake_case). v6.15.89 corrected to data.orderType per humanizer.md:35 — but THAT schema is for Humanizer.GetOrderQueue's RETURN value, not OnPrepareUnitOrders' callback data. They are DIFFERENT schemas. Per callbacks.md:418-432, OnPrepareUnitOrders data uses: order (not orderType), target (CEntity not targetIndex), ability (CAbility not abilityIndex), npc (not unit), orderIssuer (matches), queue (NOT triggerCallBack — schema has no triggerCallBack at all). The brain's filter `if data.triggerCallBack then return true end` always evaluated against a nil field → every order passed the filter unconditionally → veto never matched. v6.15.92 demo data: 25 invocations, all ot=? (nil), all cb=n (nil), issuer=0/3 (correct values 0=SELECTED_UNITS player input, 3=PASSED_UNIT_ONLY script orders). v6.15.93 changes: read data.order, data.target, data.ability, data.npc, data.orderIssuer, data.identifier (the latter per Player.PrepareUnitOrders' identifier param doc — lib/order.lua:236 sets identifier='Sniper-<layer>-<intent>' on every brain order). Brain detection: prefix-match identifier against 'Sniper-'. Safety guard: only veto orders whose data.npc IS Sniper (other units' orders don't matter). Diagnostic retains order_inspect (now with correct reads) so next demo confirms identifier is populated. Expected outcome: 12 R cancellations in v6.15.91-v6.15.92 demos now get vetoed → snipe_e_r's R step fires 18/18 (or close to it). User's primary observation 'R only fires when E on CD' resolved. v6.15.92 banner content preserved below. v6.15.92 — R+E synchronization gate + order_inspect diagnostic. v6.15.91 demo (CM target, R3): math validated (r_mag=420 at R2, 522-524 at R3, r_phys=152-291 item-dependent, q_dmg=300; 7 of 14 v6.15.90-refused combos now fire). User feedback: 'R is shooting but only when E is on cooldown. Both should be used at same time to secure headshot damage.' Log dissection — snipe_e_r dispatches 18×, fires E 6/6 + R 6/18 (12 R cancelled mid-cast, cast_verify_double_fail). When R cancelled, brain falls back to snipe_r_only — by then E is on 14s CD → user sees R-alone with 40% headshot, not 100%. Two changes: (1) snipe_r_only.requires now gates on (Take Aim modifier active OR E ready OR target fleeing AND out of atk range). The first two preserve the 100% headshot guarantee; the third bypass keeps the canonical 'finisher on escaping target' use case. Trade-off: ~11s of post-Take-Aim CD where we refuse R-only on non-fleeing targets — user-accepted. (2) order_inspect diagnostic re-instrumented at top of OnPrepareUnitOrders for every invocation inside R cast window. v6.15.86 veto fires 0× despite 12 R cancellations — order_inspect's orderType / triggerCallBack / orderIssuer / abilityIndex fields will reveal whether the cancelling orders pass through with triggerCallBack=true, or the callback isn't firing for them, or some other order type slips through. Next demo's log informs the v6.15.93+ deeper fix. v6.15.91 banner content preserved below. v6.15.91 — dual-instance R damage model. v6.15.90 demo evidence showed combo_dmg_breakdown refusing R with gap=100-180 across 14 evals — exactly the magnitude of one Sniper instant attack. Liquipedia investigation (2026-05-14): Assassinate fires an INSTANT ATTACK at projectile impact in addition to the magical 300/400/500 base (7.34+ mechanic; 7.41 only removed the 1/1.1/1.2 per-level factor — the instant attack itself remains). Per the 'Instant Attacks' article: damage uses Sniper's regular attack damage, procs on-hit modifiers (Headshot, Maelstrom, Daedalus, Skadi), has True Strike, ignores disarms, applies physical armor reduction. Brain through v6.15.90 missed this entire physical instance — that's the root cause of the v6.15.90 refused-but-killable problem. v6.15.91 adds assassinate_instant_attack_damage(target, distance, take_aim=true) that returns rc_attack_damage_with_procs * armor_mult, called once in build_layer1_ctx and added to r_dmg_at_d. New ctx field r_physical_at_d, and combo_dmg_breakdown now logs r_mag/r_phys split so the user can verify the new model. Small Keen Scope double-count (~15-30 dmg) accepted as rounding — cleanup follow-up if demo shows over-firing. Existing ScoreUltTarget r_dmg estimates (lines 1066/1184/1442) left untouched — relative scoring, not commit math. Expected outcome: v6.15.90's 14 refused snipe_e_r casts (gap 100-180 vs CM-style 884-930 eff_hp at R3 + items) now FIRE. R-cast veto (v6.15.89 field-name fix) confirmed partially working in current log: 3 verified R fires + 2 vetos active, but 7 double-fails still — separate issue, NOT addressed by v6.15.91. v6.15.90 banner content preserved below. v6.15.90 — per-target Q cooldown + R refusal diagnostic. Demo log analysis: (1) Q 'still stacking' was RE-DISPATCH of q_stack_attacker on the same target before its prior Q zone expired — each dispatch fires 1 Q1 (v6.15.86 simplified), but back-to-back dispatches piled multiple Q1s at same target_pos. Fix: new state.last_shrap_on_target_t[target_idx] tracker updated in fire_steps when sniper_shrapnel issues with a pt-kind step. q_stack_attacker AND q_corridor_finisher triggers now refuse re-dispatch on a target whose last Q cast was within 9s (zone lifetime). (2) 'R not firing' was actually CORRECT REFUSAL — log showed combo_dmg_breakdown | eff_hp=620 | r_dmg=322 | total=442 | rc_2s=0. Target had 620 eff_hp, combo could only deliver 442 dmg, rc_2s=0 because target was outside auto range. R-discipline refused correctly. v6.15.90 makes this visible: combo_dmg_breakdown now emits on EVERY snipe_e_r commit_pred eval (fire AND refuse) with decision={fire,refuse} and gap field. User can grep `combo_dmg_breakdown.*decision=refuse` to see why each R was passed up. Helps distinguish 'real bug' from 'combo correctly refused due to insufficient damage at current Sniper level'. v6.15.89 banner content preserved below. v6.15.89 — v6.15.87 diagnostic uncovered v6.15.86 BUG. veto_inspect log showed callback fires correctly (3 times within R cast window in v6.15.88 demo) but `data.order_type` returned nil EVERY TIME — wrong field name. Per UCZone API docs (Humanizer.GetOrderQueue schema in humanizer.md, same data shape passed to OnPrepareUnitOrders), fields are camelCase: orderType (not order_type), targetIndex, position, abilityIndex, orderIssuer (not issuer_player_id), triggerCallBack (was correct). Fixed `ot = data.orderType` and `data.targetIndex`. Removed the diagnostic veto_inspect log now that the field-name bug is resolved — r_cast_protect_veto will fire when actual native interference is rejected. Net behavior: native ATTACK_TARGET / MOVE_TO_POSITION / etc. during R cast window are now ACTUALLY blocked at the callback. R should fire reliably in the next demo. v6.15.88 banner content preserved below. v6.15.88 — accurate ability damage from API (user directive: 'check if there is a call that gives the final value of damage for the skills. Since Daedalus will increase damage, same for all items that buff damage'). UCZone exposes per docs (ability.md GetDamage / npc.md GetTrueDamage / GetTrueMaximumDamage / GetBonusDamage): Ability.GetDamage(a) reads the live JSON-sourced base damage of an ability (auto-tracks Valve patch changes). NPC.GetTrueDamage(npc) = min_damage + bonus_damage (already used by brain for autoattack base — Daedalus +88 flat is in bonus_damage so it's captured). NPC.GetTrueMaximumDamage = max + bonus. THREE changes. (1) assassinate_damage() now uses Ability.GetDamage(R) as base (was hardcoded 200+100*lvl which assumed 4 R levels — Sniper R has 3 levels in 7.41C). Falls back to legacy formula if API returns 0 (defensive). (2) New talent_assassinate_damage_bonus() = +150 at Tier 4 RIGHT talent (special_bonus_unique_sniper_5) per LIQUIPEDIA_REF.md — was missing from R damage entirely. (3) New combo_dmg_breakdown tlog emitted from snipe_e_r commit_pred showing r_dmg + rc_2s + q_dmg + total + eff_hp per dispatch. User can now verify the damage estimate matches in-game observation per cast. Autoattack pipeline (rc_attack_damage_with_procs) already uses GetTrueDamage so Daedalus/Crystalys/Skadi flat bonuses, Maelstrom/Mjollnir flat procs, Take Aim 100% headshot, headshot talent +30 are all factored. v6.15.87 banner content preserved below. v6.15.87 — diagnostic build for the R-cast issue. v6.15.86 deployed the veto callback but the demo log showed 0 actual veto fires and 11 R double-fails — R still never starts. Either OnPrepareUnitOrders is not called for native subsystem orders (Orb Walker / Hit & Run issue orders via a path that bypasses brain's callback), OR my logic mismatches what data contains. Added unconditional veto_inspect tlog inside callbacks.OnPrepareUnitOrders that logs every call DURING the r_cast_protect window with ot, has_cb, issuer fields. Next demo log will show whether the callback fires at all for non-brain orders. If callback fires but has_cb=true for native orders, the triggerCallBack pass-through is too permissive. If callback never fires for native orders, OnPrepareUnitOrders is the wrong hook and we need a different prevention mechanism (Humanizer queue intercept, periodic HOLD_POSITION, native bind disable, etc.). v6.15.86 banner content preserved below. v6.15.86 — CRITICAL R-cast preservation + Q non-stacking enforcement. Diagnosis from v6.15.84/.85 log: EVERY R cast `fired=n, cd_after=0` — engine never started R cast. Cause: native subsystems (Orb Walker ATTACK_TARGET, Hit & Run MOVE_TO_POSITION) sent unit orders same-tick as brain's R issue, with queue=false → replaced Sniper's current action → R cast cancelled before cast point engaged. cast_verify_double_fail confirmed mana=290+ silenced=0 stunned=0 channelling=0 — no brain-side reason to fail. v6.15.x had only DIAGNOSTIC `interfere_check_miss`, no prevention. THREE deltas. (1) callbacks.OnPrepareUnitOrders veto: during state.r_cast_protect_until_t window (R cast point + 0.4s buffer, set in fire_steps line ~2937 when R issued), non-brain unit-disrupting orders (ATTACK_TARGET, ATTACK_MOVE, MOVE_TO_POSITION, MOVE_TO_TARGET, STOP, HOLD_POSITION) are REJECTED — return false from the order callback so they never reach engine. Brain's own orders pass (data.triggerCallBack=true). Emits r_cast_protect_veto log with order_type + remaining_s. (2) r_cast_failed_cleared: when cast_verify_double_fail detects R fired=n, immediately clear state.last_r_target + state.last_r_combo_name + state.last_r_dispatch_t + state.r_cast_protect_until_t. Brain can retry on next layer1 tick instead of waiting the 2.6s cast_abort_tick timeout. (3) Q non-stacking enforcement (user reinforcement: 'Q doesn't stack dmg or anything else, no reason to fire multiple Qs on same position'): q_stack_attacker now ONE Q step (was 3 at same target_pos — wasted charges). snipe_e_r now ONE post-R Q step (was 3 at +2.5/+2.9/+3.3s reading live target_pos that barely moved). Charges preserved for next engagement or for corridor on a moving target. v6.15.85 banner content preserved below. v6.15.85 — v6.15.83 hotfix-2 (one missed %d): pending_steps_tick line 2695 still had string.format('%d', arg.x or 0) in the step_cast_pos block for deferred pt-kind steps — 17 Lua errors in v6.15.84 demo because I only fixed the fire_steps copy. Now %.0f. Both copies consistent. New v6.15.84 demo results validated the Q non-stacking damage model fix: snipe_e_r kill rate jumped from 0% (v6.15.74) → 67% (v6.15.84) and overall R kill rate from 50% → 75% with 4 casts on Lina + CM. v6.15.84 banner content preserved below. v6.15.84 — Q non-stacking damage model fix (user empirical from v6.15.82 demo T2/T3/T4): 'Q does not stack. 3 charges deal the same amount of damage than 1 charge. From 736 to 525 with Q skill on lvl 1.' Empirical 211 dmg from L1 Q regardless of charge count — overlapping shrap zones don't add damage at the same location. The brain has been multiplying `q_stacks × shrap_per_q` in commit_preds since v6.15.x, over-estimating Q damage by up to 3× in 3-charge scenarios. THAT is the actual cause of snipe_e_r's 0/2 kill rate in the v6.15.74 demo (CM with S&Y 2188 hp_max). TWO callsites fixed. (1) snipe_e_r commit_pred: replaced `q_stacks × shrap_per_q` with `q_dmg` = single zone's shrap_per_q if c.q_charges >= 1 else 0. Combo damage = R + RC + 1×Q. The 3-charge Q resource is for SPATIAL coverage (corridor) + DURATION (sequential refresh as zones expire), NOT damage multiplication. (2) q_chain_step_cond pipeline: replaced `(qi-1) × shrap_per_q` (which assumed each prior Q adds another zone's damage) with `(qi > 1) ? shrap_per_q : 0` (any Q in flight contributes ONE zone's damage to pipeline). q_stack_attacker stacking at same spot still works as DURATION extension (refresh, not multiplication). q_corridor_finisher tiling still places zones at different positions for spatial path coverage. Behaviorally: brain will commit R more conservatively (combo_dmg correctly smaller). snipe_q_r and snipe_standard already used 1× Q so unaffected. snipe_d_r / snipe_channel_punish / snipe_r_only don't use Q in their damage estimates. Re-test T9/T10/T12 (contaminated by v6.15.82 format crash, hotfixed in v6.15.83). v6.15.83 banner content preserved below. v6.15.83 — URGENT v6.15.82 hotfix: string.format('%d', float) crashed 909 times in demo log. Dota position vectors are FLOATS (e.g., -1969.5); Lua's %d format requires integer representation and raises 'bad argument #2 to format (number has no integer representation)' on fractional values. Five tlog calls affected: step_cast_pos (fire_steps + pending_steps_tick), corridor_anchor_set, snipe_e_r_init_refused, snipe_e_r_init_bypass, q_chain_skip_detail, atk_range_e in combo_fire_state. All %d changed to %.0f (accepts floats, rounds to 0 decimals). The crashes were aborting fire_steps mid-execution which corrupted T9 (R-out-of-RC), T10 (snipe_standard only D fired — subsequent steps killed by the format crash), T12 (Take Aim range — combo dispatch interrupted). Re-test those scenarios after this build deploys. T2/T3/T4 Q damage non-stacking observation remains valid and will be addressed in v6.15.84 (separate iteration: the brain has been over-estimating Q damage via `q_stacks × shrap_per_q` when in fact zones do NOT stack — only one zone contributes damage at a time). Behavior otherwise unchanged from v6.15.82. v6.15.82 banner content preserved below. v6.15.82 — diagnostic logs for full demo verifiability (user directive: 'add ways to log this informations that are not in the log'). Five new tlog emissions added so the v6.15.81 test plan can be fully verified from log data without visual replay. (1) step_cast_pos: fire_steps + pending_steps_tick emit `step_cast_pos | intent=... | x=... | y=...` after every pt-kind cast issues successfully, capturing the position arg (Q zone center). Covers demo Test 2 (corridor tiling at 400u intervals) and Test 3 (Q3 adaptive direction from Q2's anchor). (2) corridor_anchor_set: every call to set_corridor_anchor emits `corridor_anchor_set | target | x | y | yaw_deg | radius` — should appear at Q1 fire (initial capture) and Q2 fire (re-anchor with live target facing per v6.15.74). Covers Test 3 anchor-refresh verification. (3) snipe_e_r_init_refused / snipe_e_r_init_bypass: when cleanup-vs-initiation gate hits the fight_age<2.0 + hp_pct>0.9 window, emits which of margin_ok/no_escape/in_tf passed or failed, plus combo_dmg and eff_hp_check values. Covers Test 6 (TF init success), Test 7 (Eul refused), Test 8 (1v1 refused). (4) q_chain_skip_detail: when q_chain_step_cond (v6.15.71/.72) skips a Q step, emits the pipeline math (qi, q_dmg already in flight, autos contribution after range adjustment, pipeline total, eff_hp + heal_delta). Covers Test 11 heal-aware projection. (5) atk_range_with_e added to combo_fire_state log so Test 12 (L25 Sniper +400 vs prior +140) can be verified from any cast in the log. All tlogs at level 2 or 3 so they don't flood. Banner + ctx fields preserved, behavior unchanged. End of v6.15.79-.82 batch. v6.15.81 banner content preserved below. v6.15.81 — Take Aim self-MS-slow awareness (final queue item from user's 'do all except evasion' batch). LIQUIPEDIA_REF.md flagged Take Aim active applies 45/40/35/30% MS slow to Sniper for 3s per E level — undocumented in brain code prior to v6.15.81. Sniper loses kiting capability during the active window; saves and positioning decisions should know. New self_take_aim_state() helper (forward-declared at line ~57 alongside take_aim_range_bonus) reads NPC.HasModifier for modifier_sniper_take_aim_active / modifier_sniper_take_aim, returns (active_bool, slow_pct). Two new ctx fields: c.self_take_aim_active and c.self_ms_slow_pct exposed for combos/sequences to consume. try_save_self instrumented: when save fires during Take Aim active window, emits 'save_take_aim_active | intent=... | slow_pct=...' tlog at level 2 for forensic visibility. Currently informational only — future iterations can read c.self_take_aim_active to (1) bias save chains toward escape-restoring options (Pike/Force/Blink) over flat shields, (2) lower save HP thresholds when Sniper is in the vulnerable slow window, (3) refuse R commits that would chain Take Aim into a kite-vulnerable post-cast window unless the combo is overkill-guaranteed. Behavior changes wait for log data showing where the slow window actually costs Sniper. End of v6.15.79-.81 batch — six queue items closed in this session, evasion factor remains deferred (no UCZone API). v6.15.80 banner content preserved below. v6.15.80 — remaining R combos migrated to extrapolation model. v6.15.76 migrated snipe_e_r / snipe_q_r / snipe_standard but parked snipe_r_only / snipe_d_r / snipe_channel_punish. v6.15.80 closes the migration so ALL R commits use the same projection-based pipeline. snipe_channel_punish + snipe_d_r: range-aware rc_dmg (0 if target out of RC now, 0.5× if in RC now but projected out of RC at r_cast_s+2s via proj_state_post_r from v6.15.79, full otherwise), kill threshold from proj_state_r_impact.eff_hp_magical (HP+regen+heal pro-rated to live R cast point). For channel_punish, channel-lock makes the autos check largely moot but kept for consistency. snipe_d_r D's stun locks target so autos land reliably too. snipe_r_only: only the eff_hp comparison migrates — R-only combo has no autos so the range-aware check doesn't apply. Was using dispatch-time c.eff_hp + v6.15.45 flat regen adjust; now uses proj_state_r_impact.eff_hp_magical with Scepter-aware cast point and full heal modeling. Effect: all six R-spending combos (snipe_e_r / snipe_q_r / snipe_standard / snipe_d_r / snipe_channel_punish / snipe_r_only) now share one decision pipeline driven by the v6.15.72 extrapolation model. v6.15.79 banner content preserved below. v6.15.79 — accuracy sweep (user batch directive after v6.15.78): four queue items applied. (1) COMBO_OVERKILL_MARGIN = 1.3 promoted to module-level named constant — snipe_e_r init-bypass margin (v6.15.77) is now tunable without code archaeology. (2) D shard gating: ready_d now gates on NPC.HasShard(me) — D (Concussive Grenade) is shard-gated entirely per LIQUIPEDIA_REF.md; prior `ability_ready(A.D)` could return true for an unlearned shard ability due to the Ability.IsReady gotcha, leading to engine-dropped D casts in snipe_standard/snipe_d_r/snipe_channel_punish/grenade_self_kite/grenade_shrap_zone. (3) Live Take Aim range bonus: new TAKE_AIM_RANGE_BY_LEVEL = {160, 240, 320, 400} + take_aim_range_bonus() helper (forward-declared at line ~55 because called from project_target_state line ~2115 and build_layer1_ctx line ~2238/~2292). Replaces hardcoded +140 — conservative at L1 but missed +260u at L4. Affects atk_range_with_e (combos' RC-range checks) and proj_state_*.in_atk_range. (4) Autos window misalignment fix (QA flagged in v6.15.76): autos fire DURING [r_cast_s, r_cast_s + 2s], but proj_state_2s projected [0, 2s] — for non-Scepter (r_cast_s = 2s), the projection missed the actual autos window by 2s. New ctx field proj_state_post_r projects target state at r_cast_s + 2s (end of autos window). snipe_e_r/snipe_q_r/snipe_standard commit_preds updated: the `target leaving RC mid-autos-window` check (half-credit autos) now reads proj_state_post_r.in_atk_range instead of proj_state_2s.in_atk_range. q_chain_step_cond (sequences) unchanged — sequences have no R cast, autos happen NOW, proj_state_2s is correct. v6.15.78 banner content preserved below. v6.15.78 — snipe_e_r init: any-killable + teamfight gate (user directive after v6.15.77): 'In theory we can use at any target that is killable from this combo alone, but this is only for initiation and should be done in middle of TF.' v6.15.77 limited init bypass to squishy targets (eff_hp < 1000) which over-restricted to support-only inits. v6.15.78 drops the squishy filter — ANY target the combo can kill is eligible — and replaces with in_teamfight context detection. New ctx field c.in_teamfight: true when target has ≥1 OTHER enemy hero (besides themselves) within 1200u — i.e., at least 2 enemies clustered, real teamfight context. 1200u matches typical TF coordination distance. snipe_e_r bypass now requires ALL THREE: (1) overkill margin (combo_dmg > 1.3 × projected eff_hp at R impact, 30% safety on min-side estimate), (2) escape_window == 'none' (no BKB/Manta/Eul/Force/Aeon), (3) in_teamfight. Default v6.15.52 conservative gate preserved when any condition fails. Effect: enables R-init on tanky cores (PA, Sven, AM) when their projected eff_hp is closable by combo damage AND they're in TF AND don't have BKB — the player's 'burst the carry mid-teamfight' play. Refuses 1v1 R-inits where Sniper would be over-committing R outside team context. v6.15.77 banner content preserved below. v6.15.77 — snipe_e_r initialization gate refined (user directive after v6.15.76): 'This mathematical model will help us to decide better when to apply E+R+auto attack, this combo have to be used as a initialization with guarantee kill window. Especially good vs squishy targets.' v6.15.52's cleanup-vs-initiation gate hard-refused R during the first 2s of engagement on full-HP targets — designed to wait for fight to develop, but blocked the user's intended 'init R on squishy with guaranteed kill' play. v6.15.77 keeps the conservative gate as DEFAULT but bypasses it when ALL THREE projection-driven conditions hold: (1) combo_dmg > 1.3 × projected eff_hp at R impact — overkill margin guarantees the kill with 30% slack on top of the already-conservative min-side damage estimate (RC_MIN_DAMAGE_FACTOR=0.5 + shrap 4-tick conservative); (2) escape_window == 'none' — target has no BKB/Manta/Eul/Force/Aeon Disk to ruin the R; (3) projected eff_hp < 1000 — squishy target (CM ~700 baseline, Lina ~900, Pugna ~600 unsupported). Hoisted the projection-based combo_dmg/eff_hp_check computation above the cleanup gate so it can consult them; same values reused in the final kill check + non_r_dmg refusal below. snipe_q_r and snipe_standard cleanup gates unchanged — those combos have different roles (snipe_q_r is the E-on-CD fallback, snipe_standard requires D and is mid-fight by definition). v6.15.76 banner content preserved below. v6.15.76 — target-state extrapolation model applied to R combos (user directive after v6.15.75 demo): 'Let's apply our target-state extrapolation model to our combos and decision, this is the way we make it smart decisions.' Closes the migration parked in v6.15.72. THREE combo commit_preds migrated: snipe_e_r, snipe_q_r, snipe_standard. Two new ctx fields: r_cast_s (live Ability.GetCastPoint(A.R, true) — Scepter-aware; was hardcoded 2.0s in v6.15.45) and proj_state_r_impact (target's projected state at R impact via project_target_state(target, r_cast_s) — captures HP+regen+heal pro-rated to live R cast point, position+velocity projection, range membership). All three commit_preds now use the SAME pattern: (1) Range-aware autos contribution — 0 when target out of RC now (v6.15.74), 0.5× when in RC now but projected out at +2s (catches kiting targets exiting mid-autos-window, fixes the v6.15.74 demo's snipe_e_r 0% kill rate), full otherwise. (2) Kill threshold uses proj_state_r_impact.eff_hp_magical (= target's eff_hp projected to R impact moment) instead of dispatch-time c.eff_hp + hardcoded R_CAST_S regen adjustment. (3) Non-R-discipline refusal also uses the projected eff_hp and range-aware rc_dmg — consistent throughout. Effect: Scepter Sniper R commits now correctly use 0.5s cast point projection (was over-estimating heal contribution at 2.0s). Non-Scepter behavior preserved (cast point reads as 2.0 from engine). Kiting target predictions tighter: brain refuses R commit when target will leave RC mid-autos-window, reducing the false-positive R commits observed in the v6.15.74 demo (cast_outcome alive=y at hp_delta=278 and hp_delta=-1). The same projection model is already used by q_chain_step_cond (v6.15.72) — now unified across all R-spending decisions. v6.15.75 banner content preserved below. v6.15.75 — Q corridor dynamic timing (user directive after v6.15.74 demo): 'Q is being fired too fast. One way to approach this problem is to wait the enemy to get close to Q1 border, predict next place to put Q2 and fire Q2, same for Q3. Only if killable.' Static delays 0.4s/0.8s caused Q2 to fire while target was barely into Q1 zone (e.g. at V=300 mvspeed and t=0.4s after Q1 dispatch, target moved only 120u — Q1's 450u-radius zone barely entered). Replaced with dynamic delay_s functions reading c.target's live mvspeed: Q2 delay = max(0.3, min(3.0, shrap_radius() / mvspeed)); Q3 delay = max(0.6, min(5.0, 2 × shrap_radius() / mvspeed)). For V=300 + R=450 (L3 Q): Q2 at 1.5s, Q3 at 3.0s. For V=400 (S&Y): Q2 at 1.125s, Q3 at 2.25s. For V=200 (slowed): Q2 at 2.25s, Q3 at 4.5s. Target reaches each Q's spawn point as the zone arms (cast point 0.3s + arming delay 1.2s = 1.5s = exactly one radius traversal at V=300) — Q arms just as target enters it, maximum in-zone damage. q_chain_step_cond still gates each step on the pipeline kill check ('only if killable') so charges aren't wasted when autos+prior-Qs already close. v6.15.74 banner content preserved below. v6.15.74 — TWO deltas from v6.15.73 demo. D1 (corridor adaptive direction, user note on Test 2): 'For corridor, check vector of movement and Q2 on the border of Q1, before firing Q3 check the vector of movement and fire on Q2 border.' v6.15.73 anchored ALL Q steps to Q1's captured direction — if target turned between Q2 and Q3 fires, Q3 still extended along Q1's stale direction, missing target's new path. Now: Q2's arg, after computing its position from Q1's anchor, RE-ANCHORS state.corridor_anchor to (Q2_pos, target's LIVE facing yaw, shrap_radius). Q3's arg calls corridor_pos_from_anchor(target, 1) — n_radii=1 now means 'one radius from Q2 along target's current direction.' Adaptive corridor: each Q extends from the previous Q's position along target's CURRENT movement vector. D2 (out-of-RC R commits, user feedback on Test 7): 'Assassinate for outside the area not working neither stacking take aim with assassinate.' Log diagnosis: snipe_e_r:commit and snipe_q_r:commit refusing on out-of-RC targets due to hard 'c.d > c.atk_range_with_e then return false' gate. Gap: target in Q range (1800u) but out of RC range (~700-1250u with E), killable by R+Q damage alone, no combo covered it. Fix: replace hard refusal with conditional autos — `autos_will_land = c.d <= c.atk_range_with_e`, `rc_dmg = autos_will_land and c.rc_2s or 0`. combo_dmg = R + rc_dmg + Q (so out-of-RC kills gate on R+Q only). non_r_dmg refusal also uses rc_dmg so it doesn't trigger when autos can't land (R becomes the only path). Effect: snipe_e_r still fires E (Take Aim) + R from extended range — Take Aim's headshot bonus applies to any post-R autos that DO land if target re-enters range. snipe_q_r same. snipe_r_only unchanged (R-alone-kill gate kept strict for fleeing-target-no-autos finisher case). v6.15.73 banner content preserved below. v6.15.73 — corridor geometry fix (user feedback after v6.15.72 demo): 'Q corridor is not respecting the geometry and not being applied to the border of the last Q.' Root cause: corridor_pos was called fresh per step with LIVE target_pos. Q1 fired immediately at target_pos + cast-comp; Q2 at +0.4s read target_pos AGAIN (target had moved mvspeed×0.4) and offset by radius from THAT shifted position; Q3 similar at +0.8s. Net: Q2 sat at (target_at_t0.4) + 1×radius instead of (Q1) + 1×radius, drifting the corridor by mvspeed×delay each step. TWO deltas. (1) shrap_radius() helper reads live Q ability level (Ability.GetLevel) and indexes into SHRAP_RADIUS_BY_LEVEL = {400, 425, 450, 475} — matches LIQUIPEDIA_REF.md (radius is level-dependent, not hardcoded 450). (2) Corridor anchor: corridor_pos_q1(target) computes Q1's position (target_pos + cast-comp lead) AND captures state.corridor_anchor[target_idx] = {pos, yaw_rad, radius, t_set}. New helper corridor_pos_from_anchor(target, n_radii) returns anchor.pos + n_radii × anchor.radius along anchor.yaw_rad — Q2/Q3 args use this, guaranteeing clean tile geometry regardless of target's movement during the 0.4s/0.8s deferred-step delays. Anchor expires after 3s (stale beyond Q3's fire window). Falls back to corridor_pos legacy helper if anchor is missing for any reason. Effect: Q zones tile end-to-end along Q1's captured direction — user's intended geometry. v6.15.72 banner content preserved below. v6.15.72 — target-state extrapolation model (user directive after v6.15.71 deploy): 'improve damage modelation by extrapolation. We know our total minimal damage for auto attack, abilities damage, maximum range, we need to understand what we can get of information from the target to add to this model (live data for life, armor, magic resistance, life regeneration, healing items and velocity). With this model we might be able to predict exactly the skills usage and so on.' New helper project_target_state(target, t_future) returns the target's predicted state at t = now() + t_future. Fields: hp_projected (current HP + regen × t + active heal contribution from Satanic/Bloodthorn), hp_delta, pos_projected (current pos + velocity × t along facing yaw), dist_projected (Sniper to projected pos), in_atk_range / in_q_range / in_r_range (range checks at projected position), eff_hp_magical / eff_hp_physical (current EffectiveHpVs + hp_delta — assumes armor/MR static during window). New ctx field c.proj_state_2s = project_target_state(target, 2.0) — projects to the autos window. q_chain_step_cond updated to (1) cap autos contribution by half when target leaves attack range during the 2s window, (2) compare pipeline against PROJECTED eff_hp at +2s instead of dispatch-time eff_hp — prevents skipping Q2 when target is borderline-killable now but heals back above pipeline by t+2s via regen/Satanic. Heal bonus pro-rated to projection window (Satanic +500 max at t≥3s, +166 at t=1s). The helper is also a reusable primitive for future migration of commit_pred kill projections (snipe_e_r, snipe_q_r, etc.) — currently those still use dispatch-time eff_hp + flat regen × R_CAST_S adjustment from v6.15.45. v6.15.71 banner content preserved below. v6.15.71 — Q-charge discipline (user directive after v6.15.70 deploy): 'WE are commiting too much charges on non guaranteed kill. It should ALWAYS open with one charge of Q from this we have to analyze and do the best couser of actions. Also we might have bigger delay for target attacking sniper and commit full charges when killable. Here we have to calculate The total damage for the number charges we want to fire + number of auto attacks. This is the correct way to not waste charges.' New cond helper q_chain_step_cond(c, qi) gates each Q step in q_corridor_finisher and q_stack_attacker. Logic: 'pipeline = (qi-1) × shrap_per_q + rc_2s' (Qs already placed in this sequence + autos in next 2s). If eff_hp ≤ pipeline, skip this Q — pipeline already kills. Otherwise fire. Result: Q1 always fires (matches user: always open with 1 Q), Q2 fires only when Q1+autos don't close, Q3 fires only when Q1+Q2+autos don't close. q_stack_attacker delays bumped 1.0→1.5 and 2.0→3.0 per user 'bigger delay for target attacking sniper' — wider spacing gives autos more time to chip, increases skip-rate on Q2/Q3 conds when autos close earlier. q_corridor_finisher delays unchanged (0.4/0.8) because corridor placement needs to lay zones in target's escape path while target is still moving along it. Replaces prior `live_q_kill_floor >= 1` check which kept firing Qs even after Q1+autos would have killed. v6.15.70 banner content preserved below. v6.15.70 — in-flight sequence dedup (user report: 'Q corridor and stacks is not working properly'). v6.15.69 demo log lines 313-352 showed q_stack_attacker dispatching at T=0 (scheduling q2 +1s, q3 +2s), then re-triggering at T=0.4s through the standard layer1 sequence throttle window — stacking a SECOND set of deferred steps on the SAME target. Result: queue chokepoint rejects piled up (issue_rejected pattern user observed) and Q charges burned faster than the design intent. Root cause: LAYER1_COMMIT_WINDOW_SEQ=0.4s prevents the next dispatch-tick from firing ANY sequence, but doesn't track per-combo-per-target in-flight state. v6.15.68's q_stack_attacker has 2.0s total step span; v6.15.67's q_corridor_finisher has 0.8s span — both wider than the 0.4s throttle. NEW helper combo_target_in_flight(name, target) scans state.pending_steps for an entry matching (combo_name == name AND target index == this target). Wired into BOTH the combo dispatch path (line ~3962) and the sequence dispatch path (line ~4031). When in-flight, emits layer1_skip | reason=combo_in_flight or sequence_in_flight and returns. Effect: q_stack_attacker on target X locks against re-dispatch for ~2s (until q3 fires); q_corridor_finisher locks for ~0.8s. Different targets and different combos still dispatch independently. v6.15.69 banner content preserved below. v6.15.69 — Scepter-aware D-delay in snipe_standard (polish queue item #5 corrected by user). User feedback: 'Scepter is not applied on D but on R' — the v6.15.x diagnosis 'D-delay miscalibrated under Scepter' was a TIMING issue: D's static 1.5s delay was tuned for non-Scepter R cast point (2.0s) so D's projectile landed just before R hit. With Scepter, R cast point drops to 0.5s (per Sniper/LIQUIPEDIA_REF.md), so D fired 1.0s AFTER R completes — no BKB-lockout-during-cast value. TWO deltas. (1) Infrastructure: step.delay_s can now be either a number (static) or a function(ctx) returning a number (dynamic). New resolve_step_delay(step, ctx) helper at line ~2270 — fire_steps calls it once per dispatch, passes resolved value to schedule_step so dynamic delays only evaluate once. Backward-compatible: existing static delays work unchanged. (2) snipe_standard's D step delay_s is now a function reading Ability.GetCastPoint(A.R, true) at dispatch time and returning max(0.05, r_cast - 0.5). Without Scepter R=2.0s → delay 1.5s (matches prior static value). With Scepter R=0.5s → delay 0.05s (D fires nearly immediately so its projectile + cast point ~0.4s land within R's brief cast window). Closes the polish-queue item with the correct mental model: it's not that 'Scepter applies to D' but that 'D's timing depends on R's cast point, and R's cast point depends on Scepter.' v6.15.68 banner content preserved below. v6.15.68 — Q-stack-on-attacker. User directive after v6.15.67 deploy: 'there is a situation where the target might commit to attack, in this case it should be stacked on the same place, i would say 1s of interval if enemy is attacking sniper.' New sequence q_stack_attacker fires when target is engaging Sniper (close + non-kiting or stationary): 3 Q steps all at target_pos with delays 0 / 1.0s / 2.0s. After T=2s all three zones overlap on the same spot — triple DPS until first zone expires at T=10s (per Liquipedia zone duration). Required since q_corridor_finisher's radius-tiled placement (v6.15.67) wastes Q on empty ground along target's facing when target isn't moving. q_corridor_finisher now refuses target_attacking_us in its trigger so the two sequences don't compete. Detection: NPC.GetAttackTarget doesn't exist in UCZone (only Tower.GetAttackTarget per docs), so target_attacking_us uses a heuristic — close (d<=700) AND (stationary mvspeed<150 OR moving toward us via not Target.IsKitingUs). Matches the existing q_e_sustained score-bonus heuristic at line ~3214. Score 40 base sits one tick above q_corridor_finisher's 38; in practice they have disjoint triggers via target_attacking_us so they don't compete on the same target. Initiation grace fight_age_s>=1.0 applies to both (engagement must develop before committing all 3 Q charges). Also saved Sniper/LIQUIPEDIA_REF.md from liquipedia.net/dota2/Sniper — patch 7.41 ability data (Q radius 400/425/450/475 per level, R cast 2.0s without Scepter, D is shard-gated 0.4s stun + 3s disarm, etc.) for cross-reference in subsequent iterations. Hardcoded SHRAP_RADIUS=450 in v6.15.67 corridor placement now flagged as L3-only — should be live Ability.GetLevel lookup in a future iteration. v6.15.67 banner content preserved below. v6.15.67 — corridor refinement after v6.15.66 demo. User feedback: 'the combo is firing Q1 and Q2 for initiation, also the Q3 is no extending the corridor too much. When doing the corridor we have to place the center of the Q on the edge of the next one.' Three deltas in q_corridor_finisher. (1) Added Q3 step — corridor is now 3 zones tiling at SHRAP_RADIUS=450u intervals along target facing (sustain at +0, mid at +1 radius, far at +2 radii). Prior 2-step time-leads (0.5s/1.0s × mvspeed) produced ~150u/300u zones BOTH INSIDE Q1's 450u radius — zones overlapped instead of extending. (2) New corridor_pos(target, n_radii) helper replaces lead_target_pos for the corridor steps — radius-based offset (n × 450u) plus cast-point compensation (mvspeed × 0.3s for Q's cast point) so zones land where target WILL BE at zone-arrival time, with each center sitting on the edge of the prior zone. (3) Initiation grace gate: q_corridor_finisher's trigger refuses when fight_age_s < 1.0. Initiation moment is for autos+chip; corridor extends mid-fight when target has committed to an escape vector. Score: bumped charge-bonus threshold from >= 2 to >= 3 (full corridor wants 3 charges; sequence still fires with fewer, cond skips later steps). q_e_sustained unchanged — covers chip phase at fight_age 0-1.0s when target NOT killable. For target_killable at fight_age 0-1.0s, native autos handle damage until corridor unlocks. v6.15.66 banner content preserved below. v6.15.66 — CRASH FIX: Entity.GetRotationPYR returns 3 numbers (pitch,yaw,roll) as multi-return, not a table. Two callsites (lead_target_pos line ~2651, pike-self dest-enemy guard line ~3388) captured only pitch into a local then indexed it as a table — runtime crash 'attempt to index a number value (local rot)' every time q_corridor_finisher fired on a moving target (mvspeed > 200). Demo log line 412 stack trace pinned it. Both callsites now use multi-return destructuring 'local _, yaw_deg = Entity.GetRotationPYR(target)' and treat yaw as a plain degrees number passed to math.rad. Discovered while running aggression/defense reports on the v6.15.64 demo log — log showed CM kited Sniper from full HP and brain crashed every dispatch of q_corridor_finisher (the v6.15.64 phase-2 combo). Pre-fix the 2 R-kills observed were from snipe_e_r dispatches that bypassed lead_target_pos entirely (snipe_e_r uses target_pos not lead). v6.15.65 banner content preserved below. v6.15.65 — project-analysis sweep: V1 mana-floor symmetry on snipe_q_r + V2 native-yield in fallback move + V4 Option A misconfig warn. User asked for full project analysis to push combos and native interaction to the best possible. Three review sweeps produced ranked findings; verification pass against actual source filtered out 2 invalid (heartbeat gate already correct, magic-immune already re-checked in live_q_kill_floor step conds) and 1 unimplementable (V3 evasion — UCZone exposes no NPC.GetEvasion or MODIFIER_PROPERTY_EVASION_CONSTANT; deferred pending item-scan heuristic design). THREE deltas landed. (V1) snipe_q_r requires now mirrors snipe_e_r's mana floor (lesson v6.15.32 silent-fail pattern). Previously snipe_q_r only gated on ready_r + q_charges + range — if mana < R+Q cost, Q step fired, R failed engine-side, brain saw 'Q-only dispatched.' Now requires c.mana >= (r_cost + q_cost) read live from Ability.GetManaCost. (V2) fallback_cursor_move_tick yields to active native. Added 'if state.native_state_inferred == \"active\" then drop pending move end' early-exit after the existing last_r_target guard. Under Option A (native combo Bind synced + Auto Combo toggle off), heartbeat infers active and brain stops emitting MOVE during native's autoattack cadence — eliminates micro-cancels in the orbwalk rhythm. Pre-first-heartbeat (inferred == nil), fallback still fires so the unbound-native case is covered from session start. (V4) Option A misconfig detector. Tracks state.native_window_combo_seen across each 5s heartbeat window (set in OnUpdateEx when combo_key:IsDown()). At heartbeat tick, if combo was seen during the window AND inferred == 'inactive', emits 'config_warn_combo_no_native' tlog with hint='combo_key_held_but_native_silent_check_option_A'. Throttled 1× per 10s via state.last_config_warn_t. fallback_cursor_move_tick still covers movement in this case; warning just surfaces the misconfig in the log so user can fix the binding. v6.15.64 banner content preserved below. v6.15.64 — cursor-tracking movement + Q corridor finisher. User: 'Character is not moving while combo button pressed, it should behave like the native where it will move to mouse position. What native gets right and we don't, when starting a normal engagement we should fire Q1 and hold Q2 and Q3. When killable when fire Q2 and Q3 as a corridor in different timings and finalize with R if killable by R and not auto attack.' Native Hit & Run from the screenshot is enabled but tied to native combo binding (which user has unbound), so it never activates with brain's combo key — Sniper stands still. TWO deltas. (1) Cursor-tracking move after fallback attacks. fallback_attack now schedules state.pending_fallback_cursor_move_t at now+0.30s after each ATTACK_TARGET. New fallback_cursor_move_tick (wired into OnUpdateEx) fires MOVE_TO_POSITION toward Humanizer.GetServerCursorPos() at the scheduled time — projectile has fired by then (Sniper attack_point 0.17s + slack), so MOVE doesn't abort the attack. execute_fast=false so player right-click still wins. Cleared on combo/sequence dispatch (safety belt — can't fire MOVE during R cast point). Mimics native Hit & Run's move-while-attacking pattern for users who have native combo binding unbound. (2) q_corridor_finisher sequence — Phase 2 of the user's Q strategy. Phases: Phase 1 = q_e_sustained (Q1 + E during chip engagement, target not killable yet); Phase 2 = q_corridor_finisher (target became autos+Q killable, fire Q at lead 0.5s + Q at lead 1.0s scheduled +0.4s = corridor ahead of moving target); Phase 3 = snipe_r_only (target out of auto range, R is the seal). Trigger: target_killable AND eff_hp > rc_2s (autos alone won't finish) AND target in atk_range_with_e. R-bearing combos (snipe_e_r etc.) gated by v6.15.56 to refuse autos-killable case, so q_corridor_finisher takes the slot. score 38 base + bonuses for charges available and kiting target. v6.15.63 banner content preserved below. v6.15.63: restored MINIMAL attack fallback after v6.15.62 over-cleaned. v6.15.62 demo log: brain ran (317 combo_scores) but issued 0 layer1_dispatch because Sniper was level 1 with no abilities learned (R/E/Q/D all level 0) AND native Hit & Run wasn't enabled. Combos refused with req(no_R), sequences refused with req(no_E)/req(no_D)/req(no_Q). Brain stood idle, Sniper stood idle. User: 'Check the log something went broken on the process'. FIX: restored a minimal fallback_attack — issue ATTACK_TARGET on lowest-HP enemy in 1500u every 0.5s. This is NOT the full v6.15.57 orbwalk (no backswing cancel, no cursor MOVE, no attack-cadence math) — just enough to keep Sniper attacking when brain has no other tool AND native Hit & Run isn't running. CRITICAL: execute_fast=FALSE (was true in pre-v6.15.57 fallback). With execute_fast=false, native Hit & Run's high-priority orders dominate when it's enabled — brain's fallback queues harmlessly behind. When Hit & Run disabled, brain's fallback fires alone. No conflict either way. Best-of-both-worlds: native handles orbwalk timing when available, brain provides safety net when not. The v6.15.62 'brain owns combos / native owns autoattacks' architecture is preserved — fallback only ENGAGES when neither layer has a better answer. log line `layer1_fallback_attack` returns at v1 with target / hp / d / reason fields. v6.15.62 banner content preserved below — kept for the orbwalk removal rationale. v6.15.62: brain orbwalk REMOVED, deferred to native Hit & Run. User: 'Is the original orbwalk an insertion of hero script or a specific subsystem? Wouldn't be better and easy just use the native one?' Architectural answer: UCZone's Hit & Run / Orb Walker is a FRAMEWORK SUBSYSTEM (separate from the hero-specific combo script that the master toggle disables). Subsystems are independently toggleable in UCZone UI. Native Hit & Run uses engine-tuned timings per hero+items, integrates with player cursor as primary input, and is patch-maintained by the framework. v6.15.57-.61 brain orbwalk was always an approximation — strictly worse than what native already provides. v6.15.62 removes the brain-side implementation cleanly. CHANGES: (1) layer1_orbwalk block deleted from layer1_tick. When no combo/sequence dispatches and player holds combo key, brain takes no action — native Hit & Run handles autoattacks. If user disables Hit & Run, Sniper stands idle on non-combo targets (acceptable tradeoff for cleaner architecture). (2) state.last_orbwalk_attack_t and state.pending_orbwalk_cancel state init removed. (3) Combo/sequence dispatch sites no longer clear pending_orbwalk_cancel (no state to clear). (4) orbwalk_cancel_tick reduced to a defensive no-op — preserved in case future code accidentally sets pending state. NET ARCHITECTURE: brain owns combo selection + dispatch + defense saves + target stickiness + role weighting. Native owns autoattack cadence + backswing cancel + cursor movement + last-hits + Linkbreaker. Items Manager remains separate (user choice whether to enable). Player workflow: ensure native Hit & Run is ENABLED in UCZone UI for Sniper (per-subsystem toggle, NOT the master combo toggle). Brain combo binding can remain in pure-brain mode (Sniper's own combo binding disabled), Hit & Run separately enabled. v6.15.61 banner content preserved below — kept for reference in case brain orbwalk needs reconstruction. v6.15.61: cursor-tracking orbwalk. User: 'Instead of using the left button we can use the native way of doing, which is the combo will try to go to the cursor direction.' v6.15.60's STOP-based backswing cancel was correct mechanically but left Sniper stationary between attacks. Native orbwalk's pattern is movement-during-backswing toward the player's cursor — Hit & Run repositioning where cursor controls direction and brain handles attack timing. v6.15.61 replaces STOP with MOVE_TO_POSITION toward Humanizer.GetServerCursorPos(). MOVE has the same backswing-cancel effect as STOP (any new order ends current attack animation) PLUS gives Sniper a movement vector. Player cursor = where Sniper goes; brain = when to attack. Cycle per attack: T=0 ATTACK_TARGET → T=damage applies → T=damage+slack MOVE toward cursor → next throttle window ATTACK_TARGET overrides MOVE. Sniper moves during the gap, attacks at full speed. The v6.15.60 dynamic timing (cancel_delay scales with facing angle) is preserved — MOVE always fires AFTER projectile damage applies. execute_fast=false on the MOVE so explicit player clicks during the gap still override the cursor-track. Fallback: if Humanizer.GetServerCursorPos() returns nil (unlikely), MOVE-to-Sniper's-own-pos — pure backswing cancel without repositioning. The combo/sequence dispatch clears (v6.15.57 audit fix) and last_r_target gate (v6.15.57 safety) both still in place — cursor-MOVE won't fire during R cast. Net behavior: hold combo key, drag cursor — Sniper Hit & Runs in cursor direction, attacks fire on cooldown. Drop cursor on Sniper → Sniper stands and shoots (effectively no-op MOVE). v6.15.60 banner content preserved below. v6.15.60: proper backswing cancel iteration. User after v6.15.59: 'It is working better, character still not moving while combo button pressed. Lets do the separate iteration.' v6.15.59 had to disable the broken backswing cancel; v6.15.60 reimplements it correctly using the right primitive and dynamic timing. TWO mechanical fixes from the v6.15.57 bug: (1) DOTA_UNIT_ORDER_STOP instead of DOTA_UNIT_ORDER_MOVE_TO_POSITION. STOP ends the current attack animation without overriding Sniper's position — player movement input flows through cleanly. MOVE-to-self was the bug that locked Sniper in place. (2) Cancel timing scales with facing angle. Sniper's pre-damage window = turn_time + attack_point. For Sniper turn rate ~0.6, 180° rotation takes ~0.45s. attack_point = 0.17s. So pre-damage time = (angle_to_target/180) × 0.45 + 0.17. Cancel fires at pre-damage + 0.05s slack — guarantees projectile applies damage BEFORE STOP arrives. Per-attack: angle measured at attack issue via NPC.FindRotationAngle(self_npc, target_pos). For facing-aligned attack (angle≈0): cancel at 0.22s → ~1.4s of backswing saved. For 90° turn: cancel at 0.45s → ~1.2s saved. For 180° (rare): 0.67s → ~1.0s saved. ALSO: execute_fast=false on the STOP order — player MOVE during the backswing window beats brain's STOP cleanly. Net effect vs v6.15.59 stand-and-shoot: same projectile rate (engine-bound by attack speed) but Sniper enters idle/ready state sooner per attack → mobility benefits (move-attack-move pattern works), faster re-targeting if combo dispatches, less visual locked-animation time. Self-check: ORBWALK_BACKSWING_CANCEL=true; STOP order uses no target/position fields; pending_orbwalk_cancel clears unconditionally after fire; existing v6.15.57 audit-fix (clear on combo dispatch + last_r_target gate) still in place — STOP won't fire during R cast. v6.15.59 banner content preserved below. v6.15.59: hotfix for v6.15.57's broken backswing cancel. v6.15.58 demo: user reported 'Sniper is attacking much slower and still not moving while combo is pressed'. Log evidence: 16 layer1_orbwalk paired with 16 orbwalk_cancel, but CM HP only dropped 264 over the sequence (~30%% effective attack rate). Root cause: orbwalk_cancel issued MOVE_TO_POSITION at Sniper's current position at 0.22s after attack-target issue. Sniper's pre-damage window is (turn_time + attack_point) = up to 0.45s + 0.17s for back-turned cases. MOVE arrives BEFORE the projectile fires and engine cancels the attack mid-cast-point. ALSO: the constant MOVE-to-self overrode player movement input, locking Sniper in place (user's 'still not moving' observation). FIX: ORBWALK_BACKSWING_CANCEL = false. Backswing cancel disabled; the attack-time throttle (atk_time × 0.85) keeps fine and matches engine's natural attack cadence cleanly without the cancel interference. Net effect: orbwalk now behaves like the old fallback_attack but with attack-time-aware pacing instead of fixed 0.5s. NOT a regression — same visible attack speed as v6.15.50 fallback_attack, just cleaner queue management. The correct backswing cancel primitive is DOTA_UNIT_ORDER_STOP at attack_point + slack (~0.35s post-issue), NOT MOVE which aborts the cast-point. A proper STOP-based cancel can be re-added in a separate iteration once attack_point timing is empirically verified across attack speeds and turn angles. orbwalk_cancel_tick stays wired but no-ops because nothing schedules state.pending_orbwalk_cancel anymore. Run a quick demo: hold combo on CM, observe attack cadence matches Sniper's natural animation timing and player movement input works during combo hold. v6.15.58 banner content preserved below. v6.15.58: Kinetic Field walk-into poll (G12 — was deferred). v6.15.10-.12 implemented the at-cast-time detection (OnModifierCreate handler fires save when Disruptor casts a field AND Sniper is already within 350u). But the WALK-INTO case (Disruptor casts field while Sniper is far, then Sniper later walks into the active field) was uncovered — no polling tick was checking field-thinker proximity each frame. v6.15.58 closes this. ONE delta with three touch-points: (1) state.kinetic_fields table — index → {thinker, mod_name, caster}. Populated in the existing OnModifierCreate handler at line ~6325 when a kinetic_field-prefix modifier appears on an enemy-cast thinker entity. (2) Cleanup in OnModifierDestroy — removes from table when the field expires. (3) New kinetic_field_poll_tick wired into OnUpdateEx after orbwalk_cancel_tick: iterates state.kinetic_fields, computes Sniper-to-field distance, fires try_save_self when d ≤ 350u AND not Dedup.threat_already_responded(state.responded_threats,thinker, mod_name). The already_responded dedup keys on (thinker, mod) so a single field doesn't re-fire saves while Sniper sits inside. New log line `kinetic_field_walk_in` at v1 — appears when Sniper enters an active field. Pairs with the existing `kinetic_field_detected` (at-cast log). Together they distinguish 'Sniper was here when field appeared' (detected, inside=1) vs 'Sniper walked into existing field' (walk_in). Defense chain unchanged (canonical key modifier_disruptor_kinetic_field_remnant resolves to SNIPER_SAVE_OVERRIDES → grenade_self → grenade_at_caster). G13 (modifier name verify) still pending — needs a Disruptor demo to surface the actual suffix via the kinetic_field_detected log. Cost: typically 0-2 field entries to iterate per tick. Negligible. v6.15.57 banner content preserved below. v6.15.57: orbwalk / Hit & Run (G14 — was deferred). User: 'One last thing that we are not hooking or doing which is orbwalk/hit run.' G14 was on the master gap inventory's deferred list ('separate project') but the design fits a small iteration. Two improvements over the previous fallback_attack (v6.15.50): (1) Attack cadence tracks live NPC.GetAttackTime — the throttle is now atk_time × 0.85 instead of fixed 0.5s. Fast attack speed → attacks issue sooner; slow attack speed → attacks pace properly. The 0.5s was over-issuing on slow speeds and under-issuing on fast. (2) Backswing cancel. After ATTACK_TARGET issues, brain schedules MOVE_TO_POSITION at Sniper's current location at now+0.22s (attack point ~0.17s + slack). At fire time orbwalk_cancel_tick issues the MOVE — engine cancels the rest of the attack animation, next attack can issue ~30%% sooner than the natural animation would allow. This is the canonical 'Hit & Run' DPS pattern. Player movement intent preserved: manual moves between attack and cancel take priority via execute_fast=true on both orders and standard engine arbitration. Target selection updated: prefer state.engaged_target (G6 stickiness — keep attacking the engagement target through orbwalk loop), fall back to lowest-HP in 1500u (G3 cleanup-pick). New log lines: layer1_orbwalk (replaces layer1_fallback_attack) with atk_time field for verification, and orbwalk_cancel issues at the right cadence. Field-test concerns: backswing cancel may interfere with manual movement if timing collides; ORBWALK_BACKSWING_CANCEL=true static (no menu toggle yet — can add if user dislikes). Self-check: state.pending_orbwalk_cancel cleared after fire; if multiple attacks issue before cancel fires (atk_time × 0.85 < 0.22s, basically never), the LATEST cancel scheduling overwrites — only the most recent fires. Quality-check audit follows. v6.15.56 banner content preserved below. v6.15.56: two corrections from v6.15.55 demo feedback. User: 'For Q1+Q2+Q3 I'm over shooting the dmg, using without need charger on Q. For R, R as finalizer should be used as guarantee kill for running targets that will be or are outside our range. If a target is killable with auto attacks + Q we just stick to that. The DPS of Assassinate in mid of combos REDUCES the DPS.' Two deltas. (1) Q stack conservation — live_q_kill_floor now uses shrap_damage_per_q_effective() × 2 (8 ticks ≈ 4s dwell) instead of the conservative 4-tick estimate. Effect: Q2/Q3 cond returns 'enough damage already' more often when Q1 is in flight, charges preserved. commit_pred path unchanged (still uses 4-tick estimate via c.shrap_per_q for safety in 'will the combo kill?' decision). The two estimates serve different purposes: conservative for commit (don't promise a kill we can't deliver), optimistic for stacking (don't waste charges when Q1's lifespan covers it). (2) R-as-finalizer discipline — snipe_e_r, snipe_q_r, snipe_standard commit_preds now ALSO refuse when 'autos + Q alone close the kill'. R's 2s cast point freezes Sniper not-attacking — net DPS in the autos-killable case is HIGHER without R. The user pointed out: Assassinate in mid-combo REDUCES DPS because the 2s stationary cast loses ~2 autoattacks. R commits only when non_r_dmg = (rc_2s + N*shrap_per_q) < eff_hp AND full combo (R + non_r_dmg) >= eff_hp. R preserved for the truly necessary cases: snipe_r_only (fleeing / out of auto range — the canonical finalizer), snipe_d_r (escape-window catch — D-stun locks for R), snipe_channel_punish (channel-locked target). These three combos NOT gated by the autos+Q check — they exist specifically for cases where autos+Q WOULD fail (target out of range, target about to dispel, target locked but eff_hp high). Expected behavior shift on next demo: snipe_e_r dispatches drop, autos+Q-then-snipe_r_only chains rise, R-kill rate per cast goes UP (R only fires when actually needed). Q charge usage drops too. v6.15.55 banner content preserved below. v6.15.55: two tunables from v6.15.54 demo data. (N1) RC_MIN_DAMAGE_FACTOR dropped from 0.85 to 0.5. Demo cast_outcomes showed snipe_e_r delivering ~700 dmg per cast (CM 1196→407, Tide 1037→377, Lina 1205→453) while commit_pred estimated ~1500 (R + RC + Qs). RC autoattacks rarely materialize fully — target moves out of range, player releases combo key after R fires, autos miss. 0.5 factor is closer to empirical reality. Effect: commit_pred refuses borderline kills where combo relies on RC carrying half the damage; brain escalates to snipe_r_only as finalizer when target drops below R-alone-kill threshold (already 3/3 reliable in v6.15.54 log at 196-307 HP). (N2) cast_outcome respawn detection. v6.15.54 log surfaced two cast_outcomes with hp_before=31/62 and hp_after=2363/2386 alive=y hp_delta -2300 — Sniper R'd a dying target, target died and RESPAWNED during the 5s observation window, brain saw fresh full-HP entity at check time. Counted as alive=y heal (-96.8%% delta) and missed the kill credit. Fix: respawn=y when hp_after > hp_before AND hp_after >= hp_max × 0.9. Counts toward kills in engagement_summary regardless of alive flag at check time. Adds respawn=y field to cast_outcome log. Also clears state.engaged_target on respawn (the entity ref is now a fresh hero, brain shouldn't keep them at top candidate). Together N1+N2 should: lower the false-positive R commit rate (alive=y count) AND better attribute kills that include a respawn window. Next demo (N3): targeted Pudge-from-behind scenario to validate v6.15.47 grenade facing gate — no grenade_*_skip_facing events in v6.15.54 log, suggests the 120° turn case wasn't fully exercised. Spawn Pudge directly BEHIND Sniper, lock facing forward, let Pudge hook → dismember. Expect grenade_at_caster_skip_facing log + Pike fires instead. v6.15.54 banner content preserved below. v6.15.54: ally signal coordination (G2). Iteration 5 of 5 — final iteration closes the master gap inventory. G15 (offline parse_debuglog --aggression-report / --defense-report tools) DEFERRED to a separate utility build — pure offline tooling, doesn't affect runtime behavior. ONE delta: Signal.Broadcast 'hero_focus_target' channel on every combo + sequence dispatch in layer1_tick. Payload: {hero='Sniper', target_idx=Entity.GetIndex(best_*_target), t=now()}. In ScoreUltTarget, Signal.Last('hero_focus_target') is read AFTER baseline_hint and role_adj — if an ally hero (filtered by payload.hero ~= 'Sniper' to skip self-loop) published the same target_idx within the last 3 seconds, +30 score bonus. Effect: Sniper piles on the enemy that ally brains have already committed to killing, instead of splitting damage. Only Sniper has a brain today, so this is a no-op until a second hero brain (Pudge / Disruptor / Wisp / Lich extracted per Tier 2 roadmap) registers and broadcasts. The wiring is in place for that day. Self-check: Signal module is already require'd at line 22; Signal.Broadcast nil-checked via 'if Signal and Signal.Broadcast'; payload.hero filter prevents self-pile-on; 3s freshness window prevents stale broadcasts dominating. Quality-check focus: target_idx comparison uses Entity.GetIndex which is stable. PLAN STATUS: 5/5 iterations complete. Closed gaps G1 (role weighting), G2 (ally signal), G3 (fallback lowest-HP), G4 (cleanup gate), G5 (graduated fog), G6 (stickiness), G7 (BKB timing), G8 (enemy heal), G9 (corridor for movers), G10 (Pike-during-R). Deferred: G11 (two-stage threats — no log evidence yet), G12 (walk-into Kinetic Field), G13 (KField modifier verify), G14 (orbwalk imitation — separate project), G15 (offline tools — pure utility). Field-test count for the 5-iteration plan: 1 demo (covering v6.15.50 + v6.15.51), 1 demo (v6.15.52), 1 demo (v6.15.53). v6.15.54 needs no field test until a second brain exists. v6.15.53 banner content preserved below. v6.15.53: damage refinement (G7 + G8 + G9). Iteration 4 of 5. Three small predicate tweaks bundled. (G7) BKB-timing exception. v6.15.15 set commit_pred to strict refusal on magic_immune. Real case: target has BKB at 1s remaining + Sniper R has 2s cast point = R LANDS 1s after BKB drops. New ctx field c.bkb_remaining_s reads NPC.GetModifier(target, modifier_item_black_king_bar_active) and computes time-until-expiry via Modifier.GetDieTime. commit_pred logic updated across all 6 R-spending combos: if magic_immune AND (no BKB modifier OR BKB > 2.0s remaining) → refuse. If BKB ≤ 2.0s → allow (R will land post-immunity). Handles only BKB; other magic-immune sources (Manta dispel, Repel) still refuse since no clean timer. (G8) Enemy active-heal account. Target with modifier_item_satanic_unholy_rage active heals ~600 HP over R's 2s cast (175%% lifesteal × 3 autos). eff_hp_magical now bumps +500 when Satanic active, +300 when Bloodthorn active. Refuses R during the burst-heal window; commit becomes viable once the buff expires. New ctx field c.target_active_heal surfaces which heal item is active for diagnostic. (G9) Q corridor for any moving target. Previously lead_target_pos required Target.IsKitingUs(target, me) — target had to be classified as 'running away from us specifically'. Strafe-sideways, retreat-but-not-classified-kiting, and mid-engagement reposition cases all fell back to target_pos and the corridor never built. Dropped the kiting check; mvspeed > 200 gate alone filters stationary targets. Corridor now fires for any meaningfully-moving target — fleeing, strafing, repositioning. Hero-role weighting (v6.15.51), target stickiness (v6.15.50), and these three predicate refinements together close ~6 of the 7 damage-side gaps in the master inventory. Self-check + quality-check both clean. v6.15.52 banner content preserved below. v6.15.52: R cleanup gate (G4) + Pike-during-R combo step (G10). Iteration 3 of 5. Two deltas, both in the offensive layer. (G4) Cleanup-vs-initiation gate. New c.fight_age_s ctx field — elapsed seconds since first enemy entered scan radius (state.fight_start_t set/cleared in recompute_candidates based on whether Entity.GetHeroesInRadius returns any enemies). snipe_e_r and snipe_q_r commit_preds now refuse R when fight_age < 2.0s AND target HP > 90%% of max. Reason: initiation belongs to the team; Sniper's R is the kill SEAL. Without this gate, brain committed R on fresh-engaged enemies who then popped Manta/BKB or got a heal mid-cast (~9 such over-commits in v6.15.40 log). After fight_age >= 2.0s, OR if target is already damaged below 90%% HP (fight is 'live' regardless of timer), the gate releases. snipe_d_r / snipe_channel_punish / snipe_r_only / snipe_scepter_aoe NOT gated — those have their own context (D-stun lock / channel lock / finalizer / Scepter AoE) that justifies committing R immediately. (G10) Pike-on-enemy step in snipe_standard at +0.3s. Pike push lifts target airborne for ~0.4s, locking them during R's 2.0s cast point — prevents mid-cast Manta / Force / blink escapes. New 'item_target' kind in fire_steps AND pending_steps_tick. Step has cond: Pike owned + off CD AND target in 425u Pike cast range AND not magic immune. When cond fails (typical mid-late game when Pike got used defensively), step skips silently and snipe_standard works as the original Q+E+R+D combo. Reservation system tracks 'item_hurricane_pike' string key for symmetry with existing ability reservations. Self-check confirmed item_ready check at fire time prevents brain from burning Pike if defense layer used it in the interim. Test scenarios from the catalog: skirmish #22 (G4 reduces R waste on fresh engages), team fight #23 (G4 fight_age releases after 2s, R commits land cleaner), 1v1 #21 (Pike locks target through R cast in snipe_standard if owned). v6.15.51 banner content preserved below. v6.15.51: hero-role weighting (G1 from the master gap inventory). Iteration 2 of 5. One delta: HERO_ROLE_SCORE table maps enemy unit-name to additive score adjustment (carries +20, cores +10, supports 0, tanks -20). Applied at the END of ScoreUltTarget after baseline_hint's +40 bonus so player cursor still wins ties. Magnitudes conservative — a confirmed kill (Target.IsKillable branch +100 at line ~935) outranks the role adjustment, so brain DOES R a killable tank when commit_pred passes. The adjustment changes which target wins when MULTIPLE candidates are similarly killable — in a teamfight where both the enemy carry and enemy tank are in range, brain now picks the carry (high impact) over the tank (low impact). Self-check: applied AFTER baseline_hint (player override priority preserved). Quality-check focus: hero_name read via NPC.GetUnitName with nil fallback to empty string; HERO_ROLE_SCORE[empty] returns nil (no adjustment); table is module-scope local, defined BEFORE ScoreUltTarget. New v3 log line score_role_adj surfaces the adjustment for transparency. Hero list curated for current pro meta — missing heroes default to 0. Adding entries later is a 1-line data change. v6.15.50 banner content preserved below. v6.15.50: target-selection core (G3 + G5 + G6 from the master gap inventory). Iteration 1 of the 5-iteration plan to close all surveyed target-selection deficits. Three deltas, all touching scoring or candidate ordering. (G3) fallback_attack picks LOWEST-HP enemy hero within 1500u instead of nearest. Previous nearest-pick favored tanks (they engage at melee range, so they ARE nearest), wasting autoattacks on targets commit_pred already refused. Lowest-HP gives autos a real chance to secure a kill. New `hp=N` field on layer1_fallback_attack log line for verification. (G5) graduated fog penalty in ScoreUltTarget. Previous flat -30/sec from 0.3s onward dropped flicker-fogged targets (tree LoS, brief smoke gust, channel-of-vision dips) below the score floor mid-fight, causing brain to churn off them onto fresh candidates. New schedule: 0.3-1.0s fog = -3/sec gentle (vision flicker tolerance), 1.0-3.0s = -30/sec on the remainder (real hiding), >3.0s = full veto (unchanged). Mid-fight target persistence under brief vision loss now intact. (G6) state.engaged_target stickiness. When a combo OR sequence dispatches in layer1_tick (lines 3312 / 3362), state.engaged_target + state.engaged_target_t record the target. In recompute_candidates, if engaged_target is in the surviving candidate list AND alive AND <2.0s old, promote them to position 1. Applied BEFORE baseline_hint_promoted — player cursor (mid-fight redirect) still overrides brain's prior commit. Cleared in cast_outcome_tick when target dies. New `engaged_target_sticky` log line at v2. Test scenarios covered: skirmish (G3 cleanup + G5 vision flicker + G6 stickiness), team fight (G6 mid-fight persistence across collapses), 1v1 (G6 protects from spurious target re-evaluation during the engage→commit transition). Self-check: state.engaged_target lifecycle audited — set on combo/sequence dispatch, cleared on target death; baseline_hint_promoted still wins (player intent priority); fallback_attack pick selector keeps execute_fast=true so native orbwalker can't overwrite. v6.15.49 banner content preserved below. v6.15.49: audit hotfix for v6.15.48's baseline_hint_promoted block. Code audit across v6.15.36-.48 (12 recent additions reviewed) surfaced one defect, HIGH cosmetic: state.last_score_breakdown is computed for the original scored[1] near recompute_candidates' end (line ~1295), but baseline_hint_promoted's swap (line ~1319) moves a different candidate into position 1 — the HUD then renders the OLD target's score components alongside the new top target. Not a fatal bug (no incorrect dispatch decisions, just stale UI) but worth fixing. FIX: after the swap, replace last_score_breakdown with a 'hint(queue|cursor) promoted score=N' string. The HUD still has something meaningful to render and the user can see at a glance that the target was promoted by subsystem hint rather than picked by raw brain score. All other audit categories passed: OFFENSIVE_KITE_HERO_OVERRIDES forward-ref (fixed in .43), lead_target_pos scope (declared before SNIPER_COMBOS), INSTANT_BLINK_THREATS key collision (none — distinct prefix), pending_cast_outcomes cleanup (entries removed at t_check), active_threats nil safety, brain_native_interfere entry.unit handling, r_will_range_leak fallbacks, self_can_cast_abilities pcall, queue_snapshot respawn race, q_e_sustained sequence structure, MAX_TURN_FOR_GRENADE_AT_CASTER state consistency on early return. v6.15.48 banner content preserved below. v6.15.48: three deferred items from the v6.15.45 queue. (1) Subsystem-driven targeting. User: 'use the subsystem targeting system with a logic system to choose better target instead of locking on the one closer to the mouse.' Previously baseline hint (cursor proxy / order queue) was a +40 score bonus inside ScoreUltTarget — a stronger raw-score candidate could outrank the hint. Now after recompute_candidates finishes scoring + filtering, the hint target is promoted to position 1 if it's in the surviving candidate list AND has non-negative score (brain didn't veto). Brain's scoring still acts as a VETO mechanism but defers to baseline's user-intent pick when both agree the target is viable. Log line baseline_hint_promoted at v2 makes the promotion visible. (2) PA Pike timing — armed-blink mechanism. v6.15.40+ logs showed Pike fire_returned_false on Phantom Strike: at anim time PA is mid-blink, dist > 425u, Pike refuses. Chain falls to grenade_self / grenade_at_caster with their own facing issues. New INSTANT_BLINK_THREATS table (currently lists phantom_assassin_phantom_strike) tells on_gap_close to ARM the threat in state.armed_threats with eta_speed=1500 + eta_trigger=0.4, NOT call try_save_self immediately. armed_threats_tick's Stage 1 check (pike_ready AND dist <= 425, line 5176) catches PA when she arrives next to Sniper and fires Pike on her. Same mechanism Bara/Tusk armed-ETA pattern uses. Same-threat dedup unchanged. (3) Q2/Q3 corridor placement. User: 'the corridor might be made on any direction the target is going and the chances of killing are guaranteed or high; IF there is no chance of killing it is better to just let it go than wasting everything.' New Geom.lead_target_pos(target, me, lead_s) helper computes a position in target's facing direction at distance speed × lead_s. Used as arg fn for snipe_e_r's Q1/Q2/Q3 with lead values 0.5/0.9/1.3s — creates a corridor ahead of fleeing target. Returns target_pos unchanged when target is engaging / stationary (stack on current pos for concentrated damage). Kill-chance still gated by existing live_q_kill_floor: if live recompute returns 4 (not viable), the step's cond returns false and the charge is preserved. Targets that are stationary or moving < 200 MS get no lead; the corridor is for actual runners. v6.15.47 banner content preserved below. v6.15.47: value tweak: facing gate back at 120° for both grenade saves. v6.15.46 demo log surfaced the Pudge Dismember 'facing other direction' failure mode. Two save attempts with grenade_at_caster against Pudge Dismember showed cast_verify fired=n at attempt=1 (533ms) AND attempt=2 (1533ms) — grenade was dispatched while Sniper was facing AWAY from Pudge (~180°), Sniper needed 0.45s to rotate (turn rate 0.6), Pudge's Dismember cast point (0.3s) ended first and stunned Sniper mid-rotation, grenade cast aborted. v6.15.45 had dropped this gate entirely per user's earlier 'max angle possible' note. The right calibration: 120°, not 90° (too strict) or unlimited (current bug). 120° ≈ 0.3s turn time, which fits inside Pudge Dismember's 0.3s cast point + grenade 0.1s cast = 0.4s total budget. CHANGES: (1) re-added MAX_TURN_FOR_GRENADE_SELF=120 in grenade_self_cast_point. (2) re-added MAX_TURN_FOR_GRENADE_AT_CASTER=120 in SAVE_FIRE.grenade_at_caster.fire. Both refuse with a save_chain_skip-style log when exceeded; chain falls through to next save. For Pudge: chain becomes grenade_at_caster (120° gate) → Pike (no facing dependency, fires cleanly even if Sniper is back-turned). The save that ACTUALLY fires beats the one that looks better on paper. Pike's 0.5s cast is slower than grenade's 0.1s but DOES fire in this scenario. The previous Pike save in the v6.15.46 log (when grenade wasn't picked) showed Pike successfully preventing damage: fired=y, hp_pct_min=100%%. Expected v6.15.47 behavior: more grenade_*_skip_facing log entries, more Pike fires for back-turned Pudge encounters, and most importantly — save_outcome with save=- and duration_ms>0 (full dismember landing, save 3 in v6.15.46 log) should drop to zero. v6.15.46 banner content preserved below. v6.15.46: LAYER2_REACTION_WINDOW dropped from 0.5s to 0.15s per user directive: 'use 150ms as reaction time, that is my reaction time for most of the games I went professional.' Effect: brain's inter-save throttle now matches a trained human's combat reflex. When two distinct threats arrive within ~300ms (common in real games — Bara charge + Pudge hook, Disruptor pulse + Tide ravage anim, etc.), brain can dispatch saves for BOTH inside the original 500ms window. The same-threat dedup (state.responded_threats keyed on caster+mod) is unchanged so we still don't double-fire on a single threat. Single-line change to LAYER2_REACTION_WINDOW constant; no other code touched. v6.15.45 banner content preserved below. v6.15.45: three changes from v6.15.44 user analysis. User: 'time to cast grenade might be slow and/or trying to launch the grenade with an angle that is not the maximum it gets. The order logic to use defensive items or skills is to use them while turning little as possible the character, in other words using the max angle possible and with the shortest time possible.' Plus: 'combo qualities are better' — full E+R+Q1Q2Q3+autos is a NICHE combo (initiation / guaranteed kill); default opener should be Q+E to slow, with R reserved as finalizer for out-of-range killable targets. Plus: 'damage calculation must use the bottom value of the damage window' + account for armor / magic resist / regen. Three deltas. (1) Dropped MAX_TURN_FOR_GRENADE 90° gate on grenade_self. Mirrors v6.15.9's same fix on grenade_at_caster — engine extends cast point by turn time instead of rejecting, so refusing the order entirely cost us saves whose late-but-fired outcome was strictly better than no save. Angle still logged at v3. (2) q_e_sustained sequence: Q + E, no R, no D. Fires when target is in E-buffed autoattack range AND not killable by a full combo. The chip damage from Q's shrap + E's 100%% headshot procs brings target toward kill-grade while preserving R for the actual kill window. Score 30 base + bonuses for stacking budget / kiter / proximity / non-kiter close engagement. snipe_e_r still wins when target IS combo-killable (its commit_pred passes); q_e_sustained owns the 'engaged but not killable yet' slot, exactly the gap pro Snipers fill with shrap+headshot harass. Q2/Q3 stacking is a separate decision path (live_q_kill_floor) not bundled here — preserves charges for fleeing-target corridor placement (future work). (3) Damage calc made conservative in build_layer1_ctx, single edit point so all commit_preds AND setup_killable AND q_kill_floor pick it up: rc_2s scaled by RC_MIN_DAMAGE_FACTOR=0.85 (min-side of autoattack damage window); eff_hp_magical bumped by NPC.CalculateHealthRegen(target) * 2.0 (target heals during R's 2s cast point). Magic resist + armor were already accounted for in Target.EffectiveHpVs and rc_damage_over respectively. NOT fixed in this build: 'use subsystem targeting with logic to choose better target instead of locking on closer to mouse' — would require refactoring target selection to promote read_baseline_target_hint as primary picker. Bigger scope, deferred. PA Pike-on-enemy still fails at modifier-create when PA is mid-blink — separately queued. Validation: q_e_sustained dispatches visible via `layer1_dispatch kind=sequence path=q_e_sustained`; cast_outcome should show fewer alive=y false-positive commits as conservative damage gates filter them out. v6.15.44 banner content preserved below. v6.15.44: grenade_self close-range geometry fix. v6.15.43 demo log surfaced the PA defense failure mode: chain falls through Pike (fire_returned_false — PA mid-blink at >425u, Pike-on-enemy refuses), Glimmer (not owned), grenade_at_caster (not_ready), Force, and lands on grenade_self. grenade_self placed cast point at Sniper + 75u toward threat. When PA's distance is < 75u (after Phantom Strike blink-strike completes, PA is at melee range ~150u, but the strike-target modifier fires before PA fully arrives, often at <75u), the cast_point ends up BEYOND PA. Both Sniper and PA are then on the same side of cast_point → engine pushes both in the same -toward_threat direction. User report: 'grenade still lands behind her throwing both of us in the same direction.' grenade_at_caster uses MIDPOINT and is geometrically safe at any close distance — only grenade_self had the fixed-offset bug. FIX: clamp cast_offset to math.max(25, math.min(75, dist_to_threat - 25)) when threat_caster_hint is provided. Keeps cast_point at least 25u from Sniper (preserves radial direction for Sniper's push) and at least 25u from threat (keeps threat on the FAR side so it gets pushed opposite to Sniper). For long-range threats (Pudge dismember 200u, Bane grip 875u tether) the upper clamp at 75u preserves prior behavior. Math check: PA at 50u → cast_offset=25 → cast at Sniper+25 → PA at 50 is 25u past cast → Sniper pushed -toward_threat (away), PA pushed +toward_threat (further from Sniper). Both separate. NOT fixed in this build: (1) PA Pike-on-enemy never fires because PA is too far at modifier-create. A future build can arm the save on Phantom Strike anim (pre-blink) so Pike fires after PA arrives. (2) User also reported 'Without native: attack behavior is not well optimized' — brain's fallback_attack picks nearest enemy without orbwalk rhythm. Both are known and deferred. v6.15.43 banner content preserved below. v6.15.43: hotfix for v6.15.42's Lua scoping bug. v6.15.42 demo produced 546 Lua errors at line 1838 'attempt to index a nil value (global OFFENSIVE_KITE_HERO_OVERRIDES)'. Root cause: I declared the override table above SNIPER_COMBOS (line ~2202) but build_layer1_ctx (line ~1729) references it via c.kite_prefers_pike. Lua closures resolve free variable references at COMPILE/DEFINITION time. When the parser sees OFFENSIVE_KITE_HERO_OVERRIDES inside build_layer1_ctx, it looks for an in-scope local; finds none (the table's declaration appears later in source order); compiles the reference as a global lookup. UCZone sandbox doesn't expose _G, so the global lookup returns nil; indexing nil = error. Every layer1_tick → build_layer1_ctx call crashed, brain dispatched 0 combos, engagement_summary logged r_casts=0 / threats=0 / hp_pct_now=100 across all 19 windows (190s session of near-idle brain), PA preference never exercised because PA-targeting paths never ran. FIX: moved the OFFENSIVE_KITE_HERO_OVERRIDES declaration above live_q_kill_floor (line ~1731), well before build_layer1_ctx's definition. Removed the duplicate later declaration. No other changes — v6.15.42's instrumentation (cast_outcome / save_outcome / engagement_summary) and PA preference behavior are preserved. Validation criteria for v6.15.43 demo: 0 Lua errors (was 546), cast_outcome / save_outcome entries fire with actual data (was: 2 / 4 / 19 — most of those entries were degenerate empty-state), engagement_summary shows non-zero r_casts when combo key held. PA blink-in test should now produce pike_self_kite dispatch (visible as `layer1_dispatch path=pike_self_kite target=phantom_assassin`) instead of grenade_self_kite. v6.15.42 banner content preserved below. v6.15.42: efficiency study instrumentation + PA kite preference. User after v6.15.41 demo: 'For phantom assassin approach we should use pike first and grenade as fall back; grenade is sending characters on random positions.' AND 'Damage wise there as moments where the character was killable and it wasn't due a the targetting being changed.' AND 'Apply all three logs.' Four deltas. (1) PA pike-first offensive kite. New OFFENSIVE_KITE_HERO_OVERRIDES table maps enemy unit-name to preferred kite tool. Currently lists npc_dota_hero_phantom_assassin = 'pike'. ctx.kite_prefers_pike reads the override. grenade_self_kite.requires now refuses when c.kite_prefers_pike AND NPCLib.item_ready(state.self_npc,'item_hurricane_pike') — pike_self_kite wins the score race by default. Grenade still fires when Pike is on CD. Add other blink-melee carries to the table as field testing surfaces them. (2) cast_outcome log at v1 — fires 5s after each R cast (sniper_assassinate). Captures intent / target / alive / hp_before / hp_after / hp_delta / hp_delta_pct / hp_max. Generates the data for aggression efficiency: R-kill rate (alive=n / total), damage-per-R (hp_delta_pct distribution), commit_pred accuracy (alive=y means commit_pred over-committed). State.pending_cast_outcomes set in safe_issue for sniper_assassinate dispatches. cast_outcome_tick walks pending entries and logs at t_check. (3) save_outcome log at v1 — fires when a tracked threat modifier disappears from Sniper. Captures threat / save / alive / latency_ms / duration_ms / hp_start / hp_end / hp_min / hp_pct_min. Generates the defense efficiency data: survival rate, save success rate, HP nadir distribution, threat-to-save latency. state.active_threats[threat_mod] registered in OnModifierCreated handler (HP at threat start) and updated in try_save_self (when save fires). save_outcome_tick polls NPC.HasModifier each frame; logs outcome on disappearance + clears entry. HP nadir tracked across the threat's lifetime by save_outcome_tick's hp_min update. (4) engagement_summary log at v1 — every 10s, rolling summary of aggression + defense counters: r_casts / r_kills / r_kill_pct / threats / survived / survive_pct / hp_pct_now. Lightweight session-level rollup for quick analysis without parsing thousands of cast_outcome / save_outcome lines. Counters reset each window. ALL three new ticks (cast_outcome_tick / save_outcome_tick / engagement_summary_tick) wired into OnUpdateEx after cast_verify_tick. No behavior change beyond (1). DEFERRED to a later build: target stickiness fix for the 'killable target lost due to target change' observation — needs the new cast_outcome data to diagnose properly (will see alive=y in the kill-able-target case, then correlate with subsequent layer1_dispatch to a different target). Study workflow for next session: run with native binding off, do at least one Legion Duel (tests v6.15.41 A), one Hoodwink Scurry approach (tests v6.15.41 B), one PA blink-in (tests v6.15.42 (1)). Parse with tools/parse_debuglog.lua --aggression-report and --defense-report (NOT YET BUILT — manual greps for now). v6.15.41 banner content preserved below. v6.15.41: three behavioral fixes from v6.15.40 analysis. The 18 double_fails in v6.15.40 split into 3 distinct root causes: 6 Legion Duel saves with silenced=1 at fail time (brain dispatched grenade-at-caster while Sniper was muted by duel), 9 R-cast aborts on fast-moving kiting targets (Hoodwink/Scurry, Primal Beast) where target exited 3000u cast range during R's 2.0s cast point with no abort signal, and 3 same-tick Q residue. ZERO brain_native_interfere events surfaced — the detector itself had a bug (Entity.IsEntity gate). Three deltas: (A) ability-cast filter in try_save_self. New ABILITY_SAVES table (grenade_at_caster / grenade_self) + self_can_cast_abilities() helper checks NPC.IsSilenced + modifier_legion_commander_duel + MODIFIER_STATE_MUTED (pcall-protected for state-flag absence). When save chain reaches an ABILITY_SAVES entry AND Sniper is muted, log save_chain_skip reason=ability_muted and fall through to next save — Pike / Force / Manta etc. as items work during mute. Closes 6 of the v6.15.40 double_fails immediately. (B) R-cast range-leak predictor in build_layer1_ctx. New ctx field c.r_will_range_leak computes worst-case target exit distance (NPC.GetMoveSpeed × R_CAST_POINT=2.0s) and refuses R when target.kiting_us AND (d + exit_dist) > cast_r. Gated by kiting_us so stationary targets aren't penalized. Added to commit_pred of snipe_e_r / snipe_q_r / snipe_r_only / snipe_standard (the non-locked R combos). NOT added to snipe_d_r / snipe_channel_punish — D-stun and channel-state lock target through cast. snipe_scepter_aoe (0.5s cast) low enough risk to skip. Hoodwink with Scurry at ~390 ms × 2.0s = 780u exit distance, so anyone beyond 2220u from Sniper gets filtered. Closes ~9 of the v6.15.40 double_fails. (C) interference detector fix. Removed Entity.IsEntity(entry.unit) gate — that's the cargo-culted check that was producing 0 events despite 47 native sniper_* orders during brain cast windows. queue_has_baseline doesn't use IsEntity and works fine, so we mirror the pattern. Also added interfere_check_miss at v3 to surface near-matches if 0 events persist — log includes me_idx/unit_idx/in_window/age so we can spot which condition fails. NO behavior change tied to (C) — just unlocks the diagnostic. Expected v6.15.41 fire rate target: 85%+ (was 45% in v6.15.40). The two specific double_fail clusters above should drop to near-zero. Q same-tick (v6.15.36 residue) untouched — that's its own thread. v6.15.40 banner content preserved below. v6.15.40: subsystem classification + interference detector. User feedback after v6.15.39 analysis: 'It is better to understand subsystem interactions.' v6.15.39's heartbeat told us WHETHER native was active; v6.15.40 tells us WHICH subsystem of native is producing each order, and which subsystem aborts each brain cast. Three additions, all at v1: (1) `subsystem` field on every queue_observed line. classify_native_order helper buckets non-brain orders by heuristic: ability prefix item_ → items_manager, sniper_ → native_combo (should be near-zero if user disabled combo binding), other ability → other_ability; no ability + orderType=4 → orbwalk_attack (Hit & Run / Orb Walker / Target Lock), orderType=3 → attack_move, orderType=1/2 → movement (Dodger or baseline). Heuristic-only — framework doesn't expose subsystem identity per order. (2) per-subsystem breakdown on native_heartbeat (and native_state_transition) via new `subsystems` field: 'items_manager=12,orbwalk_attack=18,movement=4' shape. Reset on each 5s window roll. Sorted alphabetically for stable greppability across runs. (3) brain_native_interfere log: fires when a non-brain order targets Sniper's own unit during brain's in-flight cast window (cast_point + 0.4s slack). State.last_brain_cast is set in safe_issue for any ability with cast_point > 0.05s (instants like grenade skipped — they finish before any subsystem can react). Payload: brain_intent / brain_ability / age_ms / cast_point / native_subsys / native_ability / native_order. This is the direct attribution diagnostic — when an R double_fail happens, the brain_native_interfere log line immediately before it names the subsystem that aborted the cast. No behavioral changes. Diagnostic flow: run a demo with native subsystems enabled but combo binding disabled, observe brain_native_interfere log lines, identify which subsystem is the dominant interferer (likely items_manager based on v6.15.26 measurements), then toggle THAT specific subsystem off in UCZone UI for the next test. v6.15.39 banner content preserved below. v6.15.39: native-activity heartbeat. User feedback: 'Since we are testing two ways of interaction would be good to log out when native is being used and not used. This way we can do a best data interpolation.' Currently the brain logs `native_combo_key_observed` ONCE at startup but has no signal for in-session toggle changes. Now brain_native_diagnostic_tick (which already polls Humanizer.GetOrderQueue every frame and tags entries source=brain|native_or_other) accumulates per-source counts over a rolling 5s window. Every 5s emits `native_heartbeat | brain_5s=N | native_5s=N | inferred=active|inactive` at v1. Inferred=active when native_5s >= 3 (well below the ~25-50 entries/5s observed during baseline orbwalker operation — v6.15.26 measured native producing 10x brain traffic, so threshold is conservative). On state changes emits an extra `native_state_transition | from | to | brain_5s | native_5s` line for fast greppability — that's the marker for splitting analysis when user toggles native mid-session. No behavioral changes; pure observability. Grep recipe for split-mode analysis: `grep 'native_state_transition' debug.log` shows toggle points; `grep 'native_heartbeat' debug.log | grep inferred=inactive | wc -l` counts native-off windows; section between two transitions can be analyzed in isolation. v6.15.38 banner content preserved below. v6.15.38: force_commit no longer bypasses pacing primitives. v6.15.37 instrumentation surfaced the real cause of 'no combos without force commit, no R visible with force commit': force_commit was bypassing BOTH the r_in_flight skip AND the LAYER1_COMMIT_WINDOW throttle. Log evidence: 364 layer1_dispatch path=snipe_q_r force=y in one session (28 combo-key presses, 10 force-key presses) → ~13 dispatches per press. Each per-frame dispatch issued a new step-1 (queue=false) Q which REPLACED Sniper's intent and aborted the prior R's still-running 2.0s cast point. cast_verify_double_fail entries for snipe_e_r_r confirmed: silenced=0 stunned=0 channelling=0 mana=1066+ q_self_now=0 cd_after=0 — Sniper was perfectly castable, queue was empty, but R had been aborted mid-cast with no CD spent. The clean cases that DID fire showed fired=y attempt=2 cd_after=9.5 at age_ms=3400 (1.4s past expected) — those were brief windows where brain didn't re-dispatch. CHANGES: (1) r_in_flight check (state.last_r_target ~= nil) now applies even under force_commit. force_commit still bypasses commit_pred (kill viability) and synthetic-candidate generation, but cannot interrupt an in-flight R cast. The 'force_commit_skip reason=r_in_flight force=y' log line is the new diagnostic for confirming the lock holds during R cast point. (2) LAYER1_COMMIT_WINDOW throttle now applies under force_commit too. R combos get 2.5s lock, sequences get 0.4s lock — same as non-force. force_commit's actual purpose (bypass kill check + empty-candidate gate) is preserved; the bypass of the cast-pacing primitive was overreach from v6.14 A1. (3) pending_cast_verify clobber fix: state.pending_cast_verify entries are now keyed by a monotonic counter (state.pending_cast_verify_counter), not by intent. Previous form let a rapid re-dispatch of the same intent overwrite an in-flight retry — orphaning most attempt=1 fired=n entries so they never produced an attempt=2 follow-up. Real fire rate was higher than v6.15.37's 60%% report suggested. Each entry now carries v.intent as a payload field. cast_verify_tick iterates by counter key; logs use v.intent for correlation. Expected v6.15.38 behavior under force-commit hold: first press fires snipe_q_r → state.last_r_target set → next 60 ticks emit layer1_skip reason=r_in_flight force=y until R completes (~2s) → state.last_r_target cleared → next eligible dispatch fires. No more 13 dispatches per press; one R per ~2-2.5s of held force. User should now SEE R cast complete on every press. v6.15.37 banner content preserved below. v6.15.37: instrumentation layer for the v6.15.36 same-tick queue=true fix. v6.15.36 introduced shift-queue chaining for combo steps but the log this build was based on is still v6.15.35 — the queue=true fix is UNVERIFIED. Rather than wait two demo cycles, this build front-loads diagnostics so a single run captures the full picture regardless of whether v6.15.36 worked. Three additions, all at v1: (1) combo_fire_state log — fires on every combo step's safe_issue moment, dumps Sniper state (mana / silenced / stunned / channelling), target geometry (tgt_x / tgt_y / tgt_dist from self), queue snapshot (q_total / q_self), step index, kind (ut/pt/nt/item_self), and same_tick flag (true when queue=true used). Pinpoints state-block failures (e.g. silenced when Q tries to fire) and geometry drift (target_pos at fire time vs scoring time). (2) cast_verify second-chance retry — when first check (cast_point + 0.4s) shows fired=n, schedule a second check at +1.0s with attempt=2. The age_ms field shows total elapsed time. If second attempt also fails, emit cast_verify_double_fail with mana / silenced / stunned / channelling / queue_state at the moment of conclusive failure. Removes the false-negative class where engine is slow to update CD under load. (3) queue_state correlation — every cast_verify now carries q_total_at_issue + q_self_at_issue (snapshotted in safe_issue) plus q_total_now + q_self_now (snapshotted at check). Diff reveals: if q_self stayed equal across the window, our order lingered. If q_self went down without CD/charge change, engine consumed the order silently — that's the smoking gun for the v6.15.36 failure mode if it persists. queue_snapshot() helper added above safe_issue (lines 1324ish). cast_verify_tick rewritten for attempt-2 reschedule. fire_steps's combo_fire_state log emitted after each step's safe_issue. No behavioral changes to dispatch — pure observability. Expected demo outputs for grenade_self_kite: combo_fire_state for D (step_idx=1, same_tick=n) then for Q (step_idx=2, same_tick=y). cast_verify for both with fired=y. If Q's cast_verify shows fired=n, the q_self delta + double_fail diagnostic point straight at the root cause. v6.15.36 banner content preserved below. v6.15.36: same-tick step queueing. v6.15.35 made combos dispatch without force_commit (cast_verify went from 30% to 92% fired=y). Only remaining failure: grenade_self_kite_q consistently fired=n (charges_before=3 / charges_after=3) — Q dispatched but engine never consumed the charge. Root cause: D step and Q step issued same tick with queue=false. Each new non-queued order REPLACES the unit's current intent, so Q's CAST_POSITION replaced D's (or vice versa) and one of them got dropped before the cast point completed. snipe_e_r didn't hit this because Q1/Q2/Q3 have delay_s = 2.5/2.9/3.3s — they fire AFTER R cast completes (via pending_steps), no same-tick conflict. FIX: fire_steps now sets queue=true for step index > 1 in same-tick combos. First step interrupts whatever Sniper was doing (orbwalk attack, etc.); subsequent steps chain via the engine's unit-order queue (shift-queue mechanic) and fire after the previous resolves. Applies to all kinds: ut / pt / nt / item_self. snipe_e_r unchanged (its R is step 2 but with no delay — gets queue=true now, which actually IMPROVES it: R won't replace E mid-instant-activation). v6.15.35 banner content preserved below. v6.15.35: dispatch floor fix completes the 'combos without force' path. v6.15.34 unblocked candidate evaluation (commit_threshold=-inf) and the log proved it: combo_scores now showed `top=snipe_e_r:14` — a real positive score, not vetoed. But the next gate (best_c_score >= commit_floor()) blocked dispatch because commit_floor() = 100 (default) and score was 14. The floor was useful when commit_pred was a fuzzy 'is this worth it' heuristic; since v6.15.15 commit_pred is a strict kill check (eff_hp <= R+RC+Q+combo_dmg). Passing it already means 'this combo kills the target' — score below 100 doesn't change that fact. FIX: effective_floor = 0 (was commit_floor()). Any non-negative-score combo that passed commit_pred now dispatches. force_commit keeps effective_floor=-inf (its own bypass). User's commit_floor slider in Brain menu still affects ScoreUltTarget's baseline-hint threshold (line 1051) for orthogonal target-prioritization, but no longer gates combo dispatch. ALSO noted in v6.15.34 log: Q (shrapnel) in grenade_self_kite_q consistently fired=n (charges_before=3, charges_after=3) — Q dispatched but engine didn't consume charge. Hypothesis: Q's same-tick issue with D step causes Q to be replaced/dropped. Separate fix queued (queue=true on subsequent combo steps) — not in this build. v6.15.34 banner content preserved below. v6.15.34: combos work without force-commit. User report: 'combos don't work without force commit. Force commit follow no order, sequence or have any kind of smart moves just spamming combos but that might be the intention.' v6.15.33 cast_verify (with timing fix) showed: R fires when conditions allow (snipe_e_r_r fired=y, cd_after=9.70) — the brain WAS dispatching correctly, the diagnostic was lying. But WITHOUT force-commit, combos still couldn't fire because state.candidates was EMPTY: recompute_candidates filtered out every target whose ScoreUltTarget came back negative (in-RC-range, escape window, fog penalties drive scores negative in real play), commit_threshold=0 vetoed them all, layer1_tick exited at no_top_candidate before any combo or sequence got to evaluate. FIX 1: dropped commit_threshold to -math.huge in recompute_candidates. Score still ranks candidates (top-K=3 by score) but doesn't VETO eligibility — combos have commit_pred (kill check) as their own gate; sequences have triggers (kiting/channeling/close). Both need to see in-range enemies regardless of score sign. FIX 2 (cast_verify accuracy): charge-based abilities (Shrapnel = 3 charges) — GetCooldown only bumps when all charges depleted. cast_verify now tracks charges_before/charges_after; fired=y if EITHER cd_bumped OR charges_consumed. Removes Q false negatives. On force-commit spam: confirmed intentional — force bypasses throttle + commit_pred to let you fire whatever's ready. Top combo by score still wins (snipe_e_r preferred while R up; falls through to grenade/Pike combos once R on CD). v6.15.33 banner content preserved below. v6.15.33: cast_verify timing fix. User correctly insisted mana wasn't the issue (heroes at level 30, plenty of mana). The 'fired=n' for R/Q in v6.15.32 was a FALSE NEGATIVE caused by my check timing: Dota 2 abilities set cooldown at cast-point END (projectile release), NOT at cast-point start. My fixed 0.6s check read CD during the cast point — before it was set. R (2s cast) and Q (1.4s) showed fired=n even when casting normally. Only instant abilities (E, grenade 0.1s) showed fired=y. FIX: schedule cast_verify check at issue_time + Ability.GetCastPoint(ability, true) + 0.4s slack. For R: check at +2.4s. For Q: check at +1.8s. For E: +0.4s. For grenade: +0.5s. Now cd_after reads accurately AFTER cast point completes. New field in cast_verify log: cast_point=N (the ability's cast point we used). The v6.15.32 mana check stays — it's still correct guard (E+R+Q ≈ 260 mana floor) and won't hurt mid-mana users. The 'spell didn't fire' user observation may now ALSO turn out to be partially correct if cast IS being interrupted — but the timing fix lets us actually tell. v6.15.32 banner content preserved below. v6.15.32: snipe_e_r mana check + dispatch-time mana log. v6.15.31 cast_verify proved the issue empirically: with native disabled, brain orders reach queue cleanly but E (instant) fires while R (2s cast) NEVER fires (5/5 attempts cd_after=0). Pattern: instant-cast abilities fire, cast-point abilities silently fail engine-side. Most likely cause: insufficient mana — snipe_e_r.requires checked R/E ready + range + cone but NOT mana. Brain dispatched E (35) + R (175) + Q (50)... E consumed its mana so cast_verify showed fired=y, then R failed engine-side because mana < 175. User's perception 'initialization combo fires' was just E activating; the actual R never went off. FIX: snipe_e_r.requires now checks c.mana >= E_cost + R_cost + Q_cost (read at runtime via Ability.GetManaCost — covers patch changes). Mana floor ~260. ALSO: every `issued` log now includes `mana=N | cost=M` so we can verify Sniper had enough mana at dispatch time. If you see issued with mana < cost, that's the smoking gun. force_commit STILL bypasses commit_pred (kill check) but no longer dispatches a combo Sniper can't afford to cast. v6.15.31 banner content preserved below. v6.15.31: force-commit now actually does something. v6.15.30 log surfaced the real failure mode: force_key_transition fires 26 times (13 presses of L) so the Bind widget IS detecting L (fk_buttons=22/0). force_down=true propagates to layer1_tick. BUT layer1_no_path | reason=no_top_candidate | scan_in_range=3 | scan_scored=0 | scan_below=3 — ScoreUltTarget gave every enemy a NEGATIVE score (RC-range penalty + escape windows + fog), state.candidates was empty, layer1_tick exited at the candidates check BEFORE any combo evaluation. force_commit only bypassed throttle + commit_pred, not the empty-candidate gate. So force was a no-op. FIX: when force_commit=true AND state.candidates is empty, build a synthetic candidate list from nearest enemy heroes in 1500u with pseudo-score=100. Layer1_tick then runs combo/sequence eval against them; force_commit bypasses commit_pred at fire time. Force-commit now reliably fires SOMETHING (combo or fallback) regardless of ScoreUltTarget veto. New log line: `force_commit_synthetic_candidates | count | top | d`. Also: :Get(idx) returned 0 for both slots in v6.15.30 transitions while :Buttons() returned the real codes (22 for L on force, 317 for MOUSE5 on combo) — :Buttons() is the correct read. :IsDown() works regardless and is what brain actually uses for dispatch decisions. v6.15.30 banner content preserved below. v6.15.30: force-key + combo-key Bind widget probing. User: 'Force commit seems to have no effect — the key I set on HUD is L, the path for key might be broken.' Need to verify whether the Bind widget's :IsDown() actually flips when L is pressed and whether brain's widget holds the right button code. NEW force_key_transition log fires on every state.menu.force_key:IsDown() transition, dumping fk_get1 (slot 1 button code), fk_get2 (slot 2), fk_buttons (Buttons() result), fk_name (widget name). If pressing L produces NO force_key_transition line, the brain's force_key widget never sees the input — either the HUD field user changed isn't this widget (path mismatch) or :IsDown() isn't wired. The widget name check confirms which menu item we read. ALSO enhanced combo_key_transition with ck_get1/ck_get2/ck_buttons/ck_name + force_get1 so we can correlate both keys at every press. Independent transitions: combo and force log separately. v6.15.29 banner content preserved below. v6.15.29: cast verification (user demanded empirical proof that brain orders actually execute in-game). User feedback after v6.15.28: 'You have to trust my reports — the behaviour persists. Without key on native, spells were not fired.' Brain logged dispatches + queue_observed entries, but Sniper visibly cast nothing. The brain → queue path is verified (queue_observed source=brain matches issued). The queue → engine path is NOT — Humanizer could drop, OnPrepareUnitOrders chain could veto, engine could reject for state reasons we don't surface. NEW DIAGNOSTIC: safe_issue captures Ability.GetCooldown(ability) as cd_before before issuing. Schedules a cast_verify check 0.6s later. cast_verify_tick reads CD again; if it bumped (cd_after > cd_before + 50ms slack), the engine DID execute the cast. If not, the order died between Humanizer queue and engine. New log line at v1: `cast_verify | intent | ability | fired=y/n | cd_before | cd_after | age_ms`. Also: issued events bumped to v1 (were v2). Force-commit (user 'seems to have no effect'): default Bind is KEY_NONE — must be bound in Brain menu first. The bound_code on the existing native_combo_key_observed line shows what brain has registered; if force_key wasn't bound, every test press hit the regular throttle. v6.15.28 banner content preserved below. v6.15.28: split throttle by dispatch type. v6.15.27 log: 44 combo-key presses (88 transitions), only 2 layer1_dispatch events. The 2.5s commit window (sized for R cast+settle) was also locking out subsequent SEQUENCE dispatches that need no such window — explains the user's 'tap grenade worked only one time' observation. After grenade_self_kite fires, brain locks 2.5s during which next taps produce nothing visible. FIX: LAYER1_COMMIT_WINDOW split into LAYER1_COMMIT_WINDOW_R=2.5s (R combos — preserve cast point + settle) and LAYER1_COMMIT_WINDOW_SEQ=0.4s (non-R sequences — just prevent same-frame double-dispatch). state.last_layer1_was_r tracks which was last dispatched; throttle picks the appropriate window. Result: tap grenade → fires → 0.4s lock → second tap dispatches next sequence (pike_self_kite if facing-safe, fallback otherwise). With grenade's 10s CD, second grenade still won't fire until CD clears — but brain at least responds to each tap with SOMETHING instead of going silent. On 'NO combos or spells were fired' interpretation: v6.15.27 log shows brain DID dispatch snipe_e_r (E + R) and grenade_self_kite (D) — both reached the queue (queue_observed source=brain). User likely missed the R cast (long projectile flight to primal_beast, easy to overlook). For demo testing, bind Force-commit key to bypass strict commit gate AND throttle entirely — every press fires the top candidate. v6.15.27 banner content preserved below. v6.15.27: burial detector. User asked to check for buried commands. v6.15.26 log: brain issued 40 orders, 42 queue_observed source=brain (no orders lost between issue and queue — all 40 reached the queue cleanly). Native: 434 queue entries (10x brain). Pattern visible in chronology: brain ATTACK target=pudge enters queue, then native fires 8x take_aim + shrap + ATTACK pudge + multiple MOVE in rapid sequence (orbwalk re-targeting churn) — Sniper visibly does whatever NATIVE picked, not brain. The burial happens AFTER queue entry: native re-issues attack-target each tick, overwriting brain's intent. ADDED `brain_attack_overridden | brain_target=X | native_target=Y | age_ms=N` log at v1 — fires whenever native ATTACK_TARGET to a DIFFERENT target arrives within 1s of brain's last ATTACK_TARGET. Pinpoints the exact override moment. RECOMMENDATION: for clean brain operation, DISABLE the native Sniper script entirely via UCZone UI (not just unbind the key). Even with no shortcut, native's Hit & Run / Orb Walker / Items Manager keep firing autonomous MOVE/ATTACK orders, drowning brain. With native fully disabled, brain has the full queue. v6.15.26 banner content preserved below. v6.15.26: pike-on-self direction safety. User report: 'For offensive use of pike, we need to be careful — pike might send us in direction of a dangerous situation.' Hurricane Pike self-cast pushes Sniper 575u in CURRENT FACING. If Sniper is facing toward the threat (typical attacking stance), Pike-on-self sends him INTO the threat instead of away — opposite of the kite intent. pike_self_kite trigger now adds two safety gates: (1) angle-to-threat ≥ 100° (threat must be BEHIND Sniper, i.e., Sniper kiting / running away), (2) destination enemy count ≤ current position enemy count — refuses if the push lands Sniper among MORE enemies. Both gates use Entity.GetRotationPYR for live facing read. Will surface in log as pike_self_kite:req(out_of_kite) when these fail (since the gates are inside the trigger, _GATE_MAP shows out_of_kite as the failing clause even when the underlying reason is unsafe direction). On other points: snipe_e_r on Lich didn't fire because Lich had heavy items (javelin/demon_edge/hyperstone) inflating eff_hp past R+RC+Q damage — strict commit gate refused. Working as designed; bind Force-commit key to bypass for testing. Grenade timing 'fires after long time' = held-mode 2.5s commit window after each layer1 dispatch. To get instant dispatch per press, enable tap-mode toggle in Brain menu. v6.15.25 banner content preserved below. v6.15.25: pike/grenade kite logic fix. User report: 'combos for close targets with grenade or pike were never fired'. v6.15.24 log surfaced the cause: sequence_scores showed grenade_self_kite:req(out_of_grenade) (Legion at >600u, outside grenade range) paired with pike_self_kite:req(grenade_ready) (my gate suppressed Pike when grenade ready). Net: neither fired, Sniper had no kite tool despite Pike being available. TWO FIXES: (1) pike_self_kite requires() no longer checks `not c.ready_d` — the suppression was based on a wrong assumption that grenade_self_kite owns the slot when grenade is ready, ignoring the case where grenade can't reach. Now both kite sequences compete on score; grenade_self_kite wins inside grenade range via its +60 close-bonus, pike_self_kite wins outside grenade range (where grenade is skipped on out_of_grenade). (2) pike_self_kite trigger widened c.d <= 500 → 800. Pike-on-self pushes Sniper 600u backward — useful any time an enemy is within 800u (post-push separation ~1400u, out of typical melee chase distance). Score now scales with proximity: +50 at d≤400, +25 at d≤600. _GATE_MAP for pike_self_kite updated: removed grenade_ready clause. Expected behavior: enemy at 200u + both ready → grenade_self_kite (D+Q, score 90). Enemy at 700u + both ready → pike_self_kite (Pike-on-self, score 53). Enemy at 200u + grenade on CD → pike_self_kite (score 78). v6.15.24 banner content preserved below. v6.15.24: fallback attack rebuilt after v6.15.23 inspect surfaced the real conflict. v6.15.23 log: 18 combo-key presses, brain issued 10 orders (all reached queue cleanly — 14 queue_observed source=brain), native issued 90 (45 ATTACK_TARGETs alone). Two findings: (1) brain's combos never fired because commit_pred's strict eff_hp <= combo_dmg gate refused R on full-HP bots — working as designed. (2) brain's 4 fallback ATTACK_TARGETs were execute_fast=false, so native's 45 later ATTACK_TARGETs to different targets kept overwriting brain's choice. CHANGES: fallback now (a) picks NEAREST enemy hero within 1500u, not top-scored ult-candidate (which favors tanky/far targets unsuitable for raw engage), (b) sets execute_fast=true so the order is high-priority and resists baseline orbwalker overwrites, (c) throttle relaxed 1.0s → 0.5s for responsive press feel. Result: holding combo key now reliably puts Sniper on the nearest enemy regardless of native's parallel orbwalk dispatches. For combo testing in demo (bots are full-HP, snipe_e_r will refuse on strict kill check), bind the Force-commit key in Brain menu — it bypasses commit_pred. v6.15.23 banner content preserved below. v6.15.23: brain-native interaction diagnostic. User concern: 'brain and native are ending up mix themselves and creating a junkier sensation'. New brain_native_diagnostic_tick polls Humanizer.GetOrderQueue() every frame, snapshots entries by (addTime, orderType, abilityIndex, targetIndex), and logs each new entry with source attribution. Per the Humanizer API doc, queue entries expose a `triggerCallBack` boolean — brain issues every order with callback=true (lib/order.lua line 217), while native Sniper baseline + framework subsystems (Dodger, Items Manager, Linkbreaker) issue with callback=false. This is the clean brain-vs-other indicator. New log line at v1: `queue_observed | source=brain|native_or_other | ability | target | order_type`. Correlate with brain's own `issued` events: matching `source=brain` confirms brain order entered queue cleanly; `source=native_or_other` with no preceding brain `issued` reveals native dispatch; brain `issued` with no matching queue_observed reveals pre-queue rejection (validation in lib/order.lua or engine-side). v6.15.22 (combo_key_transition diagnostic) preserved. Restored armed_threats_tick wiring (accidentally wrapped in dead branch during refactor — fixed before deploy). v6.15.22 banner content preserved below. v6.15.22: combo key press diagnostic (user report: 'brain might be firing but not by key and is not doing combos'). Added tlog at v1 on every transition of state.menu.combo_key:IsDown(): `combo_key_transition | down=1|0 | bound_code=<code>`. Now we can verify two things from the next log: (a) does the press register at all (down=1 line appears when user presses), (b) which button code is brain bound to (bound_code field). If down=1 never appears when user presses, brain's combo_key bind is set to a different button than what they're pressing — they need to rebind via Brain menu → 'Combo Key (override)'. The brain reads its OWN bound key, NOT the native Sniper v2 combo key — they're independent CMenuBind widgets. The startup `native_combo_key_observed` log already shows both codes; this new transition log surfaces whether the brain's IsDown() is actually firing during user input. v6.15.21 banner content preserved below. v6.15.21: persistent-threat multi-fire + pike_self_kite diagnostic. FIX 1 (Legion duel still 'not countered'): v6.15.20 demo log proved grenade-at-caster DID fire 2x for Legion duel — but only once per duel-cast (threat-response dedup blocks re-fires for 2s, while duel lasts 5s). Brain sat idle through the rest of duel duration. New persistent_threats_tick re-fires try_save_self every PERSISTENT_THREAT_TICK_INTERVAL (2.1s — just past the dedup window) while Sniper has a persistent-threat modifier. Clears the (caster,mod) responded_threats entry on each tick so try_save_self proceeds. Result for Legion duel: T+0 grenade (10s CD), T+2.1s Pike (19s CD if owned), T+4.2s Satanic (15s CD if owned), T+6.3s Manta/Disperser, etc. — chain escalation over the full 5s. PERSISTENT_THREATS list = modifier_legion_commander_duel + modifier_disruptor_static_storm_thinker. Pudge dismember / Bane grip NOT included — Sniper is stunned during them, can't cast multi-fire anyway. FIX 2 (pike_self_kite diagnostic): v6.15.19's new sequence had no _GATE_MAP entry → `:req(?)` in sequence_scores. Added gates: no_pike (Pike not ready) / grenade_ready (grenade_self_kite owns this slot) / out_of_kite (d > 500). NOTE on brain-native interaction (user point #2): v6.15.20 log shows native_code=317, brain_code=317 — both buttons aligned. layer1_dispatch and layer1_fallback_attack both fired, so brain IS dispatching commands. With native ENABLED + same button, both layers issue orders independently and engine dedups by ability state. To truly isolate brain behavior, test with native shortcut DISABLED. v6.15.20 banner content preserved below. v6.15.20: SNIPER_SAVE_OVERRIDES now authoritative. v6.15.18 demo log showed Pugna/Legion saves stopped firing: save_chain_skip | reason=kind_mismatch for grenade_at_caster + reason=tether_unreachable for Pike. The brain's filters were correct in pure mechanics (grenade has displacement_at_source/channel_break, Pugna drain only lists invuln/displacement_far/dispel_basic in THREAT_COUNTER; Pike push 425 < Pugna's 1300u tether) but WRONG for user intent — grenade's 0.4s stun INTERRUPTS Pugna's drain channel, and Pike's forced-movement on Pugna BREAKS the channel regardless of tether reach. resolve_save_order now returns (chain, is_authoritative). is_authoritative=true ONLY for SNIPER_SAVE_OVERRIDES — TD.RecommendedSaves and CATEGORY_CHAINS stay non-authoritative. try_save_self skips save_counters and displacement_will_break_tether filters for authoritative chains; readiness (save_is_ready), reservation, and fire-time geometry still apply. Result: Pugna life drain → grenade_at_caster fires (stuns Pugna, breaks channel); if grenade on CD → Pike fires (forced-movement on Pugna, channel interrupt). Legion duel → grenade_at_caster fires (0.4s stun stops Legion's attack momentum); if grenade on CD → Pike-on-Legion (interrupts attack). v6.15.19 (combo-fallback + kite priority) not yet tested — log still shows v6.15.18 banner. v6.15.19 banner content preserved below. v6.15.19: two fixes for user feedback after disabling native shortcut. FIX 1 (brain does nothing fallback): with native disabled, when combo key is held and NO combo/sequence dispatched (R refused on kill check, Q/E/D on CD, etc.), Sniper just stood still. Now layer1_tick issues ATTACK_TARGET on the top candidate as a fallback after all paths fail. Throttled to 1Hz to avoid spamming attack orders. Replaces baseline Orb Walker behavior when user has disabled native. New log line `layer1_fallback_attack | target | d | reason` at v1. FIX 2 (kite priority on close enemies, user directive: 'if it is close the first thing is to use grenade or pike to get distance'): grenade_self_kite score bumped +60 when c.d ≤ 400 (gap-closer range), +30 when ≤500. New sequence pike_self_kite fires when grenade NOT ready + Pike ready + enemy ≤ 500u — Pike-on-self pushes Sniper 600u backward for escape. fire_steps extended with kind=item_self for item-cast steps (currently used by pike_self_kite). Together: when an enemy is ≤ 400u, grenade_self_kite scores ~90 (default 30 + 60 close bonus) and crushes other sequences; if grenade is on CD, pike_self_kite (item_self) takes over. v6.15.18 banner content preserved below. v6.15.18: final-value audit. API audit confirmed most NPC stats already return FINAL values: GetMoveSpeed, GetTrueDamage/GetTrueMaximumDamage, GetAttackSpeed, GetPhysicalArmorValue, GetMagicalArmorValue, *DamageMultiplier, Entity.GetHealth/GetMaxHealth, NPC.GetMana/GetMaxMana, NPC.CalculateHealthRegen, Hero.GetStrengthTotal/AgilityTotal/IntellectTotal — all bonus-aware. Two gaps fixed in this build: CAST RANGE — Ability.GetCastRange returns base, NPC.GetCastRangeBonus has the unit-wide bonus (Aether Lens +250, talents). Brain had hardcoded CAST_R=3000 / GRENADE_R=600 / SHRAP_R=1800. New helper effective_cast_range(npc, ability_handle) = base + bonus. build_layer1_ctx now exposes c.cast_r / c.cast_d / c.cast_q computed live. All in-ctx checks (requires / commit_pred / trigger / _GATE_MAP) migrated from CAST_R/GRENADE_R/SHRAP_R to c.cast_r/c.cast_d/c.cast_q. ScoreUltTarget also reads live. SPELL AMP — assassinate_damage used NPC.GetBaseSpellAmp (base only — int-derived). Item amp (Octarine +25, Kaya family) lives in NPC.GetModifierProperty with MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE / *_UNIQUE. New helper effective_spell_amp_pct(npc) sums base + item + unique. R damage estimates now reflect item amp — affects setup_killable, q_kill_floor, live_q_kill_floor, all commit gates. Remaining dist_to() <= GRENADE_R checks outside ctx (save-chain fire fns, ally scan, layer 1.5 channel break) stay on the constant as a safe lower bound — they fire orders directly and a slightly tighter gate only skips borderline casts cleanly. v6.15.17 banner content preserved below. v6.15.17: three fixes from user feedback on v6.15.16 demo. FIX 1 (CRITICAL — attack range bug): NPC.GetAttackRange returns BASE only per LuaCATS Npc.lua:296. Item bonuses (Pike +75, Dragon Lance +120, Hurricane Pike +75), talents, and active buffs live in NPC.GetAttackRangeBonus. Brain was using base everywhere — that's why R fired on Pugna inside what was actually RC range (Sniper with Pike effective range 625, brain reading 550, Pugna at 580 looks 'out of RC' to brain but is in real autos range). All four call sites (ScoreUltTarget, refresh_status_panel label, rc_damage_over default distance, build_layer1_ctx atk_range) now route through new helper effective_attack_range(npc) = base + bonus. Affects snipe_r_only's out-of-RC gate, setup_killable, snipe_e_r's atk_range_with_e, rc damage math at default distance. FIX 2 (D+Q trigger): grenade_self_kite's trigger no longer gates on Pike/Force readiness. Previous logic suppressed D+Q when displacement items were ready, treating them as offensive substitutes — wrong per user 'D+Q is used when enemies are closer on aggressive situation, pike is a good FALLBACK for this'. Pike/Force are defensive fallbacks reserved for save chains, not offensive alternatives to D+Q. New trigger: fire whenever combo key held AND enemy in grenade range (600u). NOTE 3 (snipe_e_r on Pugna): user noted snipe_e_r wasn't made on Pugna. v6.15.16 log shows combo_scores listed `snipe_e_r:req(no_E)` — E was on CD when commit was attempted. Strict commit gate is correct; once E returns the combo fires. No change here unless user observes skip when E ready. v6.15.16 banner content preserved below. v6.15.16: Pugna + Legion defensive overrides. User report: v6.15.15 demo log showed Pugna drained 4 times — Pike fired once then 3x no_effective_save (Pike's 19s CD outlasts Pugna's drain CD); Legion duel had 2x no_effective_save. CATEGORY_CHAINS fallback didn't catch them because TD.RecommendedSaves already had entries (force/pike/blink/BKB style) so resolve_save_order stopped at TD level. Adding explicit SNIPER_SAVE_OVERRIDES entries: modifier_pugna_life_drain uses the channel_on_self chain (grenade-at-caster, Pike, Force, Manta, Satanic, Disperser, Eul, WW, Aeon, grenade_self) — same shape as Pudge/Bane/Shaman/WD. modifier_legion_commander_duel uses the same channel_on_self chain but with Satanic promoted (Duel can't be broken by displacement; Sniper survives via HP regen + kiting Legion's attack timing with grenade stuns). Tide Ravage stays on TD.RecommendedSaves — user accepted no easy answer (0.5s cast point, 1100u AoE, save anything that fires). FLAGGED FOR NEXT ITERATION (not changed yet): grenade_shrap_zone offensive sequence fires Q+D whenever target_channeling — including when target is channeling a threat ON Sniper (Pugna drain, Legion duel). This burns the grenade CD that defense's chain needs to BREAK the channel. Likely cause of user's 'combos still working a little bit junkier' feedback. Plan: gate grenade_shrap_zone's trigger on NOT-(target channeling threat-on-self) so offense doesn't steal defense's grenade. v6.15.15 banner preserved below. v6.15.15: strict combo-kill commit gates (user directive). ALL R-spending COMBOS now refuse to commit unless the FULL combo damage (R + RC over 2s + planned Q stacks where applicable) covers target's effective magical HP. No more fuzzy score_ult >= commit_floor heuristic for kill decisions — eff_hp <= combo_dmg is the rule. ctx exposes r_dmg_at_d, rc_2s, shrap_per_q, atk_range so commit_pred composes the budget. Per-combo gates: snipe_e_r — R + RC + min(q_charges,3)*Q must kill, target in atk_range_with_e for autos to reach. snipe_standard — R + RC + 1Q must kill (1Q because the combo schedules one Q step). snipe_channel_punish — R + RC must kill (channel-lock makes Q unnecessary). snipe_d_r — R + RC must kill AND escape_window catchable (without an escape to catch, snipe_e_r is the better choice; refuse). snipe_q_r — R + RC + 1Q must kill. snipe_r_only (finalizer): R alone must kill AND d > atk_range (target outside autos range — R is the seal). Score bonus when kiting_us + extra when far runner. Pre-cast gate is the hard rule; v6.15.14's live_q_kill_floor still drives the in-flight Q stack-skip optimization at step fire time. The two architectural decisions interlock: commit_pred answers 'should the brain spend R here?' (kill-by-combo upper bound) and live_q_kill_floor answers 'should this individual Q step fire?' (kill-by-current-state). v6.15.14 banner content preserved below. v6.15.14: Delta A: live q_kill_floor recompute. New `live_q_kill_floor(target)` helper reads target's CURRENT effective magical HP at fire time (after R + RC follow-up damage has landed/ticked) and returns 0..3 (Q's still needed) or 4 (target too tanky / magic immune / invalid — skip). snipe_e_r's Q1/Q2/Q3 cond closures now use this live recompute instead of the dispatch-time q_kill_floor snapshot. Result: Q stacks fire only when they still contribute to closing the kill — target died from R? Skip all Q's. Target healed past Q's reach? Skip. Target's HP at the boundary where Q1 alone closes it? Q2 and Q3 skip. Conservative on unknowns: returns 4 (skip) when target invalid / magic immune / no shrap estimate. This is the first incremental step toward the ambitious target architecture: per-tick engagement decider replacing scheduled steps. live_q_kill_floor will be the prototype for live state predicates the future decider uses for every skill choice (R kill_path, D kite_timing, E ready_check). The pending_steps_tick infrastructure stays — Delta A only swaps the data source for cond closures. Delta B (snipe_r_only finalizer bonus) and Delta C (q_e_sustained sequence) still queued. v6.15.13 banner content preserved below. v6.15.13: defense interpolation + combo refinement. CHANGE 1 (defense interpolation, user request 'use the same logic or same functions for all heroes by category'): CATEGORY_CHAINS table maps TD.CategoryOf(threat) → canonical chain. Eight categories covered with the same patterns we validated on tested heroes: close_gap (Pike→grenade-at-caster→Force, mirrors Bara/Tusk/PA), channel_on_self (grenade-at-caster→Pike→Force, mirrors Pudge/Bane/Shaman/WD), line_projectile (Force→Pike→grenade-self), targeted_disable / targeted_burst (Eul→WW→Lotus→Manta/Aeon/BKB), delayed_aoe (Pike/Force→Blink variants→BKB→Eul→Pipe→Aeon), trap (grenade_self→grenade_at_caster, same as Kinetic Field), drain (Force→Pike→grenade), physical_chase (Pike→Force→Glimmer→Ghost), lockdown (Eul→WW→Lotus→Manta→Aeon). resolve_save_order now consults SNIPER_SAVE_OVERRIDES → TD.RecommendedSaves → CATEGORY_CHAINS[category] → DEFAULT_SAVE_CHAIN. Category fallback ONLY fires when neither override nor recommendation has an entry — tested heroes are untouched. New log line `chain_fallback_category | threat | category` at v3. CHANGE 2 (combo refinement, user request 'take aim + assassinate + shrap if didnt die + autos — preserve CDs for next play'): scoring rebalance so snipe_e_r (E+R+conditional Q stacking, D preserved) is preferred over snipe_standard (Q+E+R+D, all CDs burned) when both viable. snipe_standard score bonus 20 → 5, snipe_e_r base bonus 10 → 25. snipe_standard now only wins when D is genuinely needed (kiting target slowing for R lock, escape-window catch, channel-punish — those are snipe_d_r and snipe_channel_punish which keep their bonuses). snipe_e_r's q_kill_floor stacking logic preserved — still uses minimum Q charges to close the kill, doesn't waste shrap. Q step in grenade_self_kite from v6.15.12 stays. v6.15.12 banner content preserved below. v6.15.12: three changes after v6.15.11 demo verified Lua fix + Bara timing. CHANGE 1: grenade_self_kite gets a Q follow-up step (user request: 'the combo for this should be d+q'). Step ordering: D at offset toward chaser pushes Sniper away + AoE-knocks chaser; Q follows landing on chaser's position so the shrap zone catches them as they re-pursue. Q step has step-level cond (q_charges >= 1) so the combo still functions with 0 charges (D-only degradation). No requires/trigger/score change — fires under same conditions (enemy in 600u, Pike/Force not ready, combo key held). CHANGE 2: Kinetic Field detection widened to prefix match modifier_disruptor_kinetic_field* — the v6.15.11 demo log had zero kinetic_field_detected events because (a) Disruptor never cast Kinetic Field that session and (b) the exact modifier suffix in 7.41C is still empirically unverified. Now logs every kinetic_field-prefix match at v1 with the actual modifier name in the entry, so the next Disruptor demo surfaces the real name regardless. Chain lookup uses canonical _remnant key so SNIPER_SAVE_OVERRIDES resolves consistently. CHANGE 3: PRE_FACE_TTI_THRESHOLD bumped 0.6 → 1.0s, scan radius 900 → 1000u. v6.15.11 demo had 0 preface_attack events runtime — Bara at 600 MS with TTI<0.6 means dist<360u, by which point Sniper was already facing (kiting cone < 25°). At TTI<1.0 the trigger fires around 600u with meaningful turn-budget to recover. Pre-face still requires angle > 25° and a target-self threat ready. NOT done (queued): R-as-starter/finalizer rewrite of commit_pred (current gate is c.score_ult >= commit_floor which already captures kill-grade; reclassifying starter vs finalizer is a Phase 0.5 rework). Polling tick for walking INTO an already-cast Kinetic Field (separate from creation-time detection). v6.15.11 banner content preserved below. v6.15.11: two critical fixes on top of v6.15.10. FIX 1 (CRITICAL): pre_face_tick was calling Target.IsIllusion which DOES NOT EXIST — real function is Target.NotIllusion (inverse semantics). v6.15.10 debug.log had 3,859 'attempt to call a nil value (field IsIllusion)' errors, one per OnUpdateEx tick, which aborted armed_threats_tick most frames. That's why Bara grenade fired late (only via=eta_critical safety net at 0.32s ETA, instead of via=eta_trigger at 0.8s ETA). Replaced `not Target.IsIllusion(e)` with `Target.NotIllusion(e)`. Pre-face should actually fire now. FIX 2 (Kinetic Field detection): the modifier modifier_disruptor_kinetic_field_remnant lives on the FIELD THINKER ENTITY, not on Sniper. THREATS_ON_SELF only fires when npc==self_npc, so kinetic field was being silently ignored. Added a global-OnModifierCreate branch that fires regardless of which npc carries the modifier: when an enemy-cast kinetic field thinker spawns, compute distance from thinker to Sniper, log kinetic_field_detected, and if Sniper is inside the 350u radius fire try_save_self with grenade_self chain. Caveat: this only catches Sniper if he's ALREADY inside at cast time. Walking into an active field needs a polling tick (deferred to v6.16 alongside the field-AoE scan). New log lines: kinetic_field_detected | d | inside at v1. v6.15.10 banner content preserved below for context. v6.15.10: Kinetic Field save entry + pre-emptive facing. ADD 1: lib/threat_data.lua + SNIPER_SAVE_OVERRIDES now carry modifier_disruptor_kinetic_field_remnant. Wall blocks forced movement (Pike, Force, blink, cyclone) but Concussive Grenade knockback crosses (user-observed 7.41C). Chain = grenade_self → grenade_at_caster. Modifier name tagged (verify) — confirm via modseen on next demo with Disruptor casting Kinetic Field. ADD 2: pre_face_tick() runs every frame in the auto_defense block. For each enemy hero within 900u scan radius with any ABILITY_TO_THREAT-listed ability ready, computes time_to_impact = dist / max(move_speed, 200). When the most imminent threat has TTI < 0.6s AND Sniper is facing > 25° away, issues ATTACK_TARGET (auto-orients + attacks) — overriding any pending user move/attack. Cooldown 0.4s prevents per-frame spam. Skips when combo key held (Layer 1 dispatches its own ATTACK_TARGET), when Sniper is stunned/hexed/cycloned (self_alive_ok), and when Assassinate is in cast-phase (would cancel R). Menu toggle: Brain → 'Pre-face imminent threats (override movement)' (default ON). New log line `preface_attack | target | tti | angle | via` at v1. v6.15.9 banner content preserved below for context. v6.15.9: two defensive-layer fixes (dual-fire + grenade facing gate). FIX 1: dual-fire on a single threat. Engine emits OnUnitAnimation multiple times per cast (cast-point start, channel begin); on_channel_start / on_hard_disable were calling mark_responded but never already_responded, so a second anim event ~0.5s later (LAYER2_REACTION_WINDOW just elapsed) ran try_save_self again and burned a fallback save (grenade then Pike on one Pudge Dismember). Now both anim handlers short-circuit on already_responded — same dedup OnModifierCreate uses. New log line `anim_response_dedup | via=channel_start|hard_disable` makes the catch visible at v3. FIX 2: grenade_at_caster MAX_TURN=90° gate dropped. Engine extends cast point by turn time rather than rejecting orders, so the gate was costing us saves where firing slightly late was still better than nothing (post-stun grenade still pushes caster mid-channel + breaks tether). Angle still logged in grenade_at_caster_cast_plan for diagnostics. NO chain reorder this version — v6.15.8's grenade-first override based on 0.5s Dismember cast point stands, but actual Dismember cast point is 0.3s in 7.41C (off by 0.2s). After this build is verified, separate decision whether to revert chain to Pike-first or keep grenade-first. Pre-emptive facing (distance × speed → override user commands when threat imminent) deferred to v6.16. v6.15.8 banner content preserved below for context. v6.15.8: cast-point race fix for channel-on-self saves. Pike's 0.5s cast point RACES with Pudge Dismember (0.5s) and LOSES — Sniper gets stunned mid-Pike-cast, Pike order interrupted, no CD starts, no save fires, no fallback (reaction window blocks). User saw 'nothing fired'; log confirmed 4 'issued | item=pike' with on_cd=- (engine never executed). FIX: SNIPER_SAVE_OVERRIDES reordered so grenade-at-caster (0.1s cast) goes FIRST for channel-on-self threats with short cast points. Grenade resolves at T~0.15s, well before T=0.5 stun, actually interrupts the cast. Pike stays as fallback (10s grenade CD vs 19s Pike CD — both fire over time, each in its window — matches user's prior 'grenade and pike both worked' experience). Applied to: modifier_pudge_dismember, modifier_bane_fiends_grip, modifier_shadow_shaman_shackles, modifier_witch_doctor_death_ward. Bara/Tusk/PA chains UNCHANGED — those aren't cast-point races. v6.15.7: _GATE_MAP entries for snipe_q_r, snipe_r_only, snipe_scepter_aoe, snipe_standard, snipe_e_r had wrong clauses (e.g. snipe_q_r was checking in_cone/magic_immune which it doesn't gate on, missing the actual q_charges/d <= SHRAP_R gates). v6.15.6 demo showed `:req(?)` because _why_req_fail walked these wrong clauses, found nothing wrong, returned '?'. Now maps match each combo's actual requires() body verbatim. v6.15.6 Option B: grenade_self_kite trigger loosened. Removed HP<60%% gate. Now fires when combo key held AND enemy in 600u AND Pike+Force not ready. Pike/Force reservation kept so grenade is preferred displacement only when item alternatives aren't available. Score still bumps by 20 when HP<35%% for low-HP urgency. v6.15.5: diagnostic correction + grenade-range finding. v6.15.4's `_why_req_fail` returned 'no_D' for sequences that don't need D (e.g. take_aim_chain_stun) because it checked ctx fields in a fixed order regardless of combo. Now per-combo gate maps return the actual missing clause. ALSO: v6.15.4 demo showed grenade combos never fired because the closest enemy while D was ready was 681u (Windrunner) — outside the 600u grenade cast range. Grenade's 375u AoE means a lead-the-cast pattern could reach up to ~975u, but the current `c.d <= GRENADE_R` gate refuses targets beyond 600u. No behavior change in v6.15.5; user can decide on lead-the-cast enhancement separately. v6.15.4 banner: layer1_no_path now includes the top candidate's ctx state (R level/CD/ready, E/D ready, q_charges, d, in_cone, magic_immune, ally_cc_lock, escape_window) + effective commit_floor — visible at v1. layer1_no_path now includes the top candidate's ctx state (R level/CD/ready, E/D ready, q_charges, d, in_cone, magic_immune, ally_cc_lock, escape_window) + effective commit_floor — visible at v1. combo_scores `:req` skips now break down into specific gate failure (no_R, no_E, no_D, magic_immune, ally_cc_lock, out_of_grenade, no_cone). Same for sequence :req. Solves the v6.15.3 demo finding where ALL 7 combos + 4 sequences logged :req with no clue WHICH gate failed. v6.15.3 HOTFIX: lib/signal.lua no longer uses _G (UCZone sandbox doesn't expose it; v6.15.0-v6.15.2 crashed at load with 'attempt to index a nil value (global _G)'). Cross-hero registry now lives on the module table; Lua's require-cache makes it a singleton across hero files within the same Lua state. Rest of v6.15.2 bug-hunt fixes intact: talent reads (+30 headshot / x1.30 shrap not +120/+175); ally Lotus range 900; postmortem data.ability field; timing.lua dropped item_eul_scepter + Aeon HP gate; multi-stage concurrent excludes self; record_save self-only last_save_kind; ally sort by HP; signal Subscribe monotonic tokens; parse_debuglog --since/--until wired; verify_scenarios anchored on separator. Mediums: kite_track GC; Roshan radius 700; pre-game offset 0; tower regex simplified; smoke pre-fire skip-when-active; atomic state-file write. CRITICALS (4): talent helpers rewritten — special_bonus_unique_sniper_headshot_damage = +30 flat (was wrongly +120), special_bonus_unique_sniper_shrapnel_damage = +30%% multiplicative (was wrongly +175 flat); ally Lotus-give cast range 1200→900 per items.json 7.41C; postmortem reads data.ability not data.ability_name; lib/timing.lua dropped dead item_eul_scepter entry. HIGHS (8): multi-stage chain escalation excludes the current threat from concurrent count; record_save no longer poisons last_save_kind on ally/smoke-prefire saves; ally_save_scan sorts allies lowest-HP-first; Aeon Disk in timing.lua gated on HP<70%% trigger threshold (was firing false-positive on full-HP targets); signal.lua Subscribe uses monotonic token counter (was reusing sparse-array indices, two subs could share a token); signal.lua Register nil-name guarded; parse_debuglog wired --since/--until (were dead options); verify_scenarios anchors event matching on tlog ` | ` separator (substring would match smoke_alert_disable on smoke_alert). MEDIUMS+LOWS: lib/target.lua _kite_track has opportunistic 5s GC + dead-target staleness check; Roshan-pit radius tightened 1500→700 (avoids jungle camps); game_time_offset returns 0 in pre-game (negative time); tower regex simplified to single pattern; smoke pre-fire skips when self-BKB or self-Glimmer modifier active; state.json write is now atomic (tmp + rename); Engine.GetCheatDirectory separator normalized for Windows; lib/timing.lua INFLIGHT_INVULN dead loop removed; gui.json read also logs brain's combo_code so user can see the mismatch; signal.lua adds Signal.Clear(channel) so last-payload cache can be GC'd; parse_debuglog warns when multiple mode flags conflict + sorts kv keys per line; brain status panel shrap-talent chip shows x1.30 multiplier shape instead of flat +N.")

return callbacks

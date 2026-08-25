# Combo pattern - Layer 1 aggressive dispatcher for any hero

Last updated: 2026-05-12 (Sniper v6.12 baseline).

> **⚠ ARCHITECTURE SUPERSEDED ON SNIPER (v6.15.118+).** The score-ranked
> combo/sequence CATALOG described below was replaced on Sniper by the
> **adaptive-engagement combo-key model**: a runtime tap/hold classifier that
> dispatches one of three ARCHETYPES (Heavy Starter on TAP; a per-tick Starter
> appraisal loop or Team Fight mode on HOLD) instead of score-ranking a fixed
> catalog of pre-authored combos. The per-tick re-evaluation is the state
> machine. The legacy `SNIPER_COMBOS`/`SNIPER_SEQUENCES` catalog + `layer1_tick`
> are being retired. The dispatch *primitives* below
> (`fire_steps`, step kinds, `commit_pred`, the throttle, cast verification)
> are still in use and still correct - only the catalog-vs-archetype top
> layer changed.

This is the **combo / sequence dispatch** pattern, the offensive analog to `DEFENSE_PATTERN.md`. Battle-tested on Sniper. Captures the v6.8 → v6.12 architecture as it stabilized after multiple iterations.

## Core distinction

| | COMBO | SEQUENCE |
|---|---|---|
| Intent | Multi-spell COMMITMENT. Burns a high-CD resource (typically R). Aborting halfway = wasted mana + CD. | OPPORTUNISTIC. One or two cheap casts. No major resource cost if it doesn't connect. |
| Gate | `commit_pred(ctx)` - kill-grade / setup-killable / stack-killable / channeling. | `trigger(ctx)` - situational (kiting, channeling, in-range, etc.). |
| Floor | `COMBO_COMMIT_FLOOR = 100` (matches kill-grade score). | `SEQUENCE_FLOOR = 1` (any positive utility). |
| Example | Sniper E+R, Pudge Hook+R, Lion Hex+Finger. | Sniper grenade_shrap_zone, Pudge Rot self-toggle, Lion Hex-on-channeler. |

A COMBO fires once and the fight is decided (or the cooldown is gone). A SEQUENCE may fire dozens of times per game.

## Dispatcher flow (`layer1_tick`)

```
1. Commit-window throttle (LAYER1_COMMIT_WINDOW = 2.5s)
   → if last dispatch <2.5s ago, return early.
2. Iterate top-K (default 3) candidates from state.candidates.
   for each candidate:
     ctx = build_layer1_ctx(target, score)
     for each COMBO:   if requires + commit_pred: score → track best (target, combo)
     for each SEQUENCE: if requires + trigger:    score → track best (target, sequence)
3. If best COMBO ≥ COMMIT_FLOOR: fire it (combo wins regardless of sequence score)
4. Else if best SEQUENCE ≥ SEQUENCE_FLOOR: fire it
5. Else fog-R fallback if toggle on
6. Else layer1_no_path (with scan stats for diagnostics)
```

**Top-K matters.** Single-candidate dispatch misses the "kill-grade target X AND fleeing target Y both viable" scenario. K=3 with combos × sequences is cheap (predicates are mostly table lookups).

## Schema

### Step

```lua
{
    ability = A.Q,                            -- ability slot
    kind    = "pt",                           -- "ut" (unit-target), "pt" (point), "nt" (no-target)
    short   = "q1",                           -- log identifier
    arg     = function(ctx) return ... end,   -- entity (ut) | Vector (pt) | nil (nt)
    cond    = function(ctx) return true end,  -- OPTIONAL: skip step if returns false
    delay_s = 1.5,                            -- OPTIONAL: defer to pending_steps_tick (live ctx re-eval)
}
```

### COMBO

```lua
{
    name = "snipe_e_r",
    steps = { ... },
    requires    = function(ctx) return ... end,  -- hard preconditions (ability ready, mana, range, cone)
    commit_pred = function(ctx) return ... end,  -- "is this worth burning R?"
    score       = function(ctx) return ... end,  -- higher wins
}
```

### SEQUENCE

```lua
{
    name = "shrap_chase",
    steps = { ... },
    requires = function(ctx) return ... end,
    trigger  = function(ctx) return ... end,  -- situational applicability
    score    = function(ctx) return ... end,
}
```

## Per-tick context (`build_layer1_ctx`)

Compute target state ONCE per dispatch, pass to every closure. Reduces redundant introspection. Example fields (Sniper):

```lua
{
    me, target, target_pos, d,
    score_ult,                       -- from ScoreUltTarget (full safety + bonus math)
    in_cone, mana,
    ready_r, ready_e, ready_d, q_charges,
    magic_immune,                    -- target currently BKB'd
    target_killable,                 -- valid target (alive, not invuln)
    target_channeling,               -- in ENEMY_CHANNEL_MODIFIERS
    has_escape_item,                 -- back-compat boolean
    escape_window,                   -- "ready"/"soon"/"long"/"active"/"none" (v6.12)
    kiting_us,                       -- running away (Target.IsKitingUs)
    eff_hp,                          -- magical eff_hp (for setup-kill math)
    setup_killable,                  -- R + RC kills, in atk_range_with_e, no escape window threat
    q_kill_floor,                    -- min charges needed to close kill (0-3, or 4=not viable)
    atk_range_with_e,                -- atk_range + 140 (Take Aim bonus)
    cluster_count, cluster_worth_aoe, -- for Scepter AoE R (Sniper-specific)
    bkb_active,                      -- target magic-immune RIGHT NOW
    ally_cc_lock,                    -- target stunned + ally near (don't grenade-knock out)
}
```

For a new hero: identify the analog fields. Most carry over (in_cone, mana, ready_*, eff_hp, target_channeling, etc.). Replace hero-specific (`q_charges`, `q_kill_floor`, `cluster_*`) with the hero's equivalents.

## Step scheduler (v6.11)

For combos where steps need to fire at specific times relative to dispatch (not back-to-back), use `delay_s`:

- **Schedule:** `fire_steps` pushes the step to `state.pending_steps` with `fire_at = now() + delay_s`.
- **Fire:** `pending_steps_tick` polls every OnUpdateEx tick. When `now >= fire_at`:
  - Aborts gracefully if target died/became invalid.
  - Rebuilds live ctx (overrides `target_pos`, `q_charges` with current values; keeps everything else from dispatch snapshot).
  - Re-evaluates `cond_fn` and `arg_fn` against live ctx.
  - Issues the order.

**Use cases observed on Sniper:**
- **Grenade-during-R-cast** (`snipe_standard` D step, `delay_s = 1.5`): R cast point 2.0s, D fires 1.5s in, lands ~0.5s before R impact → prevents target BKB pop.
- **Q follow-up after R lands** (`snipe_e_r` Q1/Q2/Q3 steps, `delay_s = 2.5/2.9/3.3`): live `target_pos` keeps shrap zones on target's current position post-R, not where they were 2.5s ago.

**Critical invariant:** preserve no-waste discipline. Q2/Q3 cond uses `q_kill_floor` from dispatch snapshot (recomputing eff_hp at fire time is expensive). Live `q_charges` is checked so we don't try to fire a Q that's been spent in another path.

## Scoring patterns

### `ScoreUltTarget` (target valuation)

Centralizes per-target score with safety vetoes + bonus stacks. Returns `nil` to veto (target unsafe / unkillable / out of range), or a score number.

Veto guards (all → `nil`):
- Not valid / not alive / not enemy / illusion / Meepo clone.
- Will be invuln at impact (`Target.WillBeInvulnIn(target, cast_window_ms)`).
- Has ready Linkens / has ready Lotus.
- Last visible time `nil` with no actual fog history - **TREAT AS FRESH** (fog_age = 0). DON'T VETO. (Critical bug from v6.8.4.)
- Fog age > 3s.
- Distance > CAST_R.

Score additions (sample, from Sniper):
- `+100` if `IsKillable AND R damage >= eff_hp` (kill-grade).
- `+200` if target channeling, `+50` extra if `modifier_teleporting`.
- `+40` if baseline target-selection hint matches (queue-attack-target or cursor proxy).
- **Tactical position adjustments:**
  - `−40` (`−10` with Scepter) if target in our attack range AND not kiting (RC faster than R cast).
  - `+30` if target kiting (R as finisher).
  - `+20` if target far (`d > atk_range * 1.5`) AND (kills_with_R OR ally_near OR `d ≤ 1500`).
- **Escape-window penalty** (replaces binary `has_escape_item`):
  - `−50` if `escape_window == "ready"`.
  - `−25` if `escape_window == "soon"`.
  - `0` for `"long"` / `"none"`.
- `−75` if Aegis active.

### Combo `score(ctx)`

Adds path-specific bonus on top of `ctx.score_ult`. Examples:
- `snipe_standard`: `+20` (richest combo, prefer when all 4 abilities applicable).
- `snipe_e_r`: `+10` base, `+25` if `setup_killable`, `+5` if Q charge available, `+15/+12/+8` for q_kill_floor 1/2/3 stacks.
- `snipe_d_r`: `+30` if `escape_window in {"ready","soon"}` (we're interrupting the dispel cast), else `+5`.
- `snipe_r_only`: `+0` (baseline minimum).

### Sequence `score(ctx)`

Independent of `score_ult` (sequences don't require kill-grade). Examples:
- `grenade_shrap_zone`: `25 + 15 kiting + 30 channeling`.
- `shrap_chase`: `25 + 10 killable + 10 far-runner`.
- `take_aim_chain_stun`: `20 + 25 channeling + 10 kiting`.
- `grenade_self_kite`: `30 + 20 if HP <35%`.

## Commit predicates (the heart of pro-grade R discipline)

Three commit paths in `snipe_e_r` (the richest example):

```lua
commit_pred = function(c)
    if c.bkb_active then return false end  -- never R into magic-immune target

    -- (a) Kill-grade: R alone kills (score_ult has +100 killable or +200 channel)
    if c.score_ult >= COMBO_COMMIT_FLOOR then return true end

    -- Escape-window veto: target will dispel/immune DURING our cast
    if c.escape_window == "ready" or c.escape_window == "soon" then return false end

    -- (b) Setup-killable: R + RC follow-up within RC range finishes
    if c.setup_killable then return true end

    -- (c) Stack-killable: R + N stacked Q + RC kills, AND we have N charges
    if c.q_kill_floor <= c.q_charges and c.q_kill_floor <= 3
       and c.d <= c.atk_range_with_e then
        return true
    end

    return false
end
```

For other heroes, the predicates shift:
- A pure-burst hero (Lion) has only (a) plus "stack debuffs" path.
- A reset hero (Tinker, Refresher) might commit aggressively because R isn't a once-per-fight resource.
- A teamfight hero (Magnus, Tide) commits on cluster size rather than HP threshold.

## R-cast abort (v6.12)

For abilities with meaningful cast points (Sniper R 2.0s, Pudge Dismember 0.3s, Lion Finger 0.3s, etc.), the brain should monitor for target state changes mid-cast and issue `DOTA_UNIT_ORDER_STOP` if target becomes unhitable.

**Dota engine semantics:** STOP during cast point **refunds mana**, **does NOT trigger cooldown**. CD starts on cast completion, not cast start. So aborting saves the entire CD (~110s for Sniper R).

**Pattern:**
```lua
-- In fire_steps when issuing an R unit-target step:
if step.ability == A.R and step.kind == "ut" then
    state.last_r_target     = arg
    state.last_r_combo_name = combo_name
end

-- In OnUpdateEx, BEFORE pending_steps_tick:
local function r_abort_tick()
    if not state.last_r_target then return end
    local r = ability(A.R)
    if not r or not Ability.IsInAbilityPhase(r) then return end  -- not casting → no-op

    local abort, reason
    -- Same condition table as commit_pred refusals:
    if not Target.IsAlive(target) then abort, reason = true, "dead"
    elseif NPC.HasState(target, MS.MODIFIER_STATE_MAGIC_IMMUNE) then abort, reason = true, "bkb"
    elseif NPC.HasState(target, MS.MODIFIER_STATE_INVULNERABLE) then abort, reason = true, "invuln"
    elseif Target.HasReadyLinkens(target) then abort, reason = true, "linkens"
    elseif Target.HasReadyLotus(target) then abort, reason = true, "lotus"
    end

    if abort then
        safe_issue { order_type = UO.DOTA_UNIT_ORDER_STOP, unit = state.self_npc, ... }
        -- Sweep pending_steps for this combo's deferred steps
        -- Reset commit window so brain can immediately re-evaluate
        -- Clear tracking state
    end
end
```

## Top-K candidate iteration (v6.11)

For a top-K loop in `layer1_tick`:

```lua
local K = 3
for k = 1, math.min(K, #state.candidates) do
    local cand = state.candidates[k]
    local ctx = build_layer1_ctx(cand.target, cand.score)
    -- evaluate every COMBO against this ctx, track best (target, combo, score)
    -- evaluate every SEQUENCE against this ctx, track best (target, sequence, score)
end
-- fire best COMBO if it clears COMBO_COMMIT_FLOOR; else best SEQUENCE
```

Cost: 3 candidates × 7 combos × 2 sequences ≈ 27 predicate evaluations per tick. Cheap.

The chain fires the best (target, combo) pair regardless of which candidate it came from. The brain commits R on Lina (kill-grade) AND fires a separate dispatch's shrap_chase on the kiting Pudge happens on the next tick after the commit window expires.

## Commit window (v6.8.5)

After a dispatch fires, suppress re-dispatch for `LAYER1_COMMIT_WINDOW = 2.5s`. Prevents per-tick re-evaluation while the combo is executing. Without this, 8000+ dispatches in a single bot match (observed in v6.8.1 testing - combo key held continuously).

Reset to 0 on R-abort so the brain can immediately pick a fresh combo.

## Verification methodology

For the next hero, replicate Sniper's diagnostic surface:

| Log event | Verbosity | What it proves |
|---|---|---|
| `layer1_dispatch path kind target score` | 1 | What fired |
| `layer1_no_path reason scan_*` | 1 | What didn't fire and why (in_range, vetoed, vetoed_sample) |
| `combo_scores top runner skipped cands_k hint` | 2 | Why the winner won, why others lost |
| `sequence_scores top skipped ctx_flags` | 2 | Sequence selection + key context flags |
| `score_baseline_hint` | 3 | When baseline-target hint applied |
| `step_fire combo step kind ok` | 3 | Per-step result + deferred markers |
| `scheduled_step combo step kind ok` | 3 | When scheduled step actually fired |
| `r_abort target reason combo` | 1 | When mid-cast abort triggered |

**Throttle high-frequency logs.** `layer1_no_path` is rate-limited to 1Hz (otherwise 60Hz × 40min = 144000 events).

## What stays per-hero vs lib

**Stays per-hero forever:**
- `<HERO>_COMBOS` and `<HERO>_SEQUENCES` tables - these are the whole point.
- Hero-specific step functions (e.g., Sniper's `grenade_self_cast_point` directional cast, Pudge's `hook_lead_position` predictor).
- `ScoreUltTarget` semantic (every hero scores its own target axis differently).
- Layer 1 dispatcher body (calls into shared helpers but has hero-specific weight).
- Per-hero anim map / matchup data.

**Stays in lib forever:**
- `lib/order.lua` - order discipline, queue dedup, ability-level gating.
- `lib/target.lua` - universal predicates (`HasReadyEscapeItem`, `IsKitingUs`, `IsRightClicking`, `EscapeItemWindowState`, `HasReadyLinkens`, `HasReadyLotus`, `HasAegis`, `EffectiveHpVs`).
- `lib/threat_data.lua` - threat / save kind catalog.
- `lib/damage.lua` - damage feed normalizer.
- `lib/anim.lua` - animation→ability dispatcher.

**Candidate for extraction when hero #2 lands (per two-hero rule):**
- Step scheduler (`schedule_step`, `pending_steps_tick`, `fire_steps`) → `lib/combat.lua`.
- Top-K candidate iteration loop in `layer1_tick` → `lib/combat.lua`.
- Generic R-abort tick → `lib/combat.lua` (or `lib/defense.lua` if it joins the save chain).
- The combo dispatcher skeleton (build_ctx → score COMBOS → score SEQUENCES → fire) → `lib/combat.lua`.

The combo data tables themselves (per-hero) never extract; they are the hero.

## Hard-won lessons (from Sniper v6.x)

1. **Ability.IsReady returns true for unlearned abilities.** Always gate on `Ability.GetLevel(a) > 0` in any custom ability_ready helper.

2. **Hero.GetLastVisibleTime returns nil for never-fogged heroes.** Don't veto on nil - treat as `fog_age = 0`. This single bug caused 8400+ no-op dispatches in a 40-minute match.

3. **commit_threshold gates SEQUENCE evaluation.** Set to `0` (or negative with Scepter taper) so non-kill candidates make it into `state.candidates` and SEQUENCES can evaluate them.

4. **Layer 1 commit window prevents per-tick spam.** Without it, 60Hz dispatch × held key = log spam + redundant chain runs. `LAYER1_COMMIT_WINDOW = 2.5s` matches typical R cast point + slack.

5. **target_pos snapshot at dispatch is stale for delayed steps.** Use the step scheduler with live arg/cond re-evaluation.

6. **No-waste discipline for charged abilities.** Q2/Q3 conditional on `q_kill_floor` ≥ N - don't burn charges that aren't needed.

7. **Headshot proc in DPS estimate.** 40% baseline → 100% with Take Aim active. Was missing from setup-kill math; brain refused commits that pro plays close.

8. **Item procs in DPS estimate.** Maelstrom, Mjollnir, Daedalus, Crystalys, Skadi, Brooch. Otherwise setup-kill math under-estimates and brain over-refuses.

9. **D-after-R for BKB lockout.** Schedule grenade `delay_s = 1.5` so it lands during R's cast point. Prevents target BKB pop.

10. **Windowed escape detection beats binary.** `"ready"/"soon"` veto R commit. `"long"`/`"none"` no penalty. Refresher hedge + stale-fog defense built in.

11. **R-cast abort via STOP refunds mana, no CD.** Massive efficiency win for mid-cast target dispels.

12. **JSON staleness - always cross-check Liquipedia.** Patch-edge values may not be in items.json / npc_abilities.json. Especially: push distances, cast ranges, CDs, item removals (Eternal Shroud 7.41), shard/scepter grant status.

13. **Baseline subsystems run in parallel.** Frame "substitute and improve" as a sidecar pattern: share the combo key (read from gui.json), use queue dedup, let baseline run.

14. **Single-target focus misses opportunities.** Iterate top-K candidates and pick the best (target, combo/sequence) pair across all.

15. **Diagnostic stats in no-op events.** When the brain does nothing, log WHY (in_range, scored, vetoed, vetoed_sample, top, score, reason). Saves hours of debugging.

# Defense pattern - how to plug a new hero into the threat / save framework

Last updated: 2026-05-11 (Sniper v6.6 baseline - Pike-first chain, two-stage armed-trigger, level-gated ability_ready).

This is the **smart save selection** pattern. Each hero gets per-threat optimal
saves with hero-specific overrides, automatic reserve-the-good-stuff penalties
for high-CD items vs low-severity threats, and timing-aware dispatch (pre-cast
vs at-impact vs reactive). Built and battle-tested on Sniper; will graduate to
`lib/defense.lua` once a second hero confirms the API.

## What `lib/threat_data.lua` already does for every hero

The shared module owns universal data:

- `SAVE_KIND`         - save → list of effect kinds (`invuln`, `magic_immune`, `displacement_far`, etc.)
- `THREAT_COUNTER`    - threat → list of kinds that counter it
- `SAVE_PUSH_DISTANCE` - Pike 500, Force 500, Grenade-self 475
- `THREAT_TETHER_RANGE` - Fiend Grip 875, Dismember 200, etc.
- `THREATS_ON_SELF`   - modifier → {role, save} metadata for dispatch
- `LOTUS_WORTHY_INCOMING` - single-target enemy ults Lotus reflects
- `ENEMY_CHANNEL_MODIFIERS` - Layer 1.5 channel-punish / TP-interrupt triggers
- `ABILITY_TO_THREAT` - anim ability name → modifier name
- `RECOMMENDED_SAVES` - **best-to-worst save list PER threat** (universal optimum)
- `THREAT_TIMING`     - pre_cast / at_impact / mid_channel / reactive / prophylactic
- `THREAT_SEVERITY`   - low / medium / high (drives reserve penalty)
- `SAVE_COOLDOWN_TIER` - low / medium / high (Pike=low, BKB=high)

Plus pure helpers:

- `TD.SaveCounters(save_name, threat_mod)`        → bool, kinds intersect
- `TD.WillTetherBreak(save_name, threat_mod, dist)` → bool, geometry
- `TD.RecommendedSaves(threat_mod)`               → list or nil
- `TD.TimingFor(threat_mod)`                      → string
- `TD.SeverityOf(threat_mod)`                     → string
- `TD.SaveReservePenalty(save_name, threat_mod)`  → number (−25 to 0)

## What stays per-hero (template)

Every hero file declares three things:

### 1. `SAVE_FIRE` - how to fire each save (item OR ability)

Most saves are item-self-casts and look identical across heroes. Items work
straight from the shared map. Hero-specific saves (Sniper grenade-self,
Bristleback Quill Spray, Centaur Stampede) need a custom `fire` closure:

```lua
local SAVE_FIRE = {
    -- Standard item self-casts - same shape for every hero
    item_cyclone        = { short = "eul",      fire = function(intent) return issue_item_self(intent, "def", item("item_cyclone")) end },
    item_hurricane_pike = { short = "pike",     fire = function(intent) return issue_item_self(intent, "def", item("item_hurricane_pike")) end },
    item_black_king_bar = { short = "bkb",      fire = function(intent) return issue_item_self(intent, "def", item("item_black_king_bar")) end },
    -- ... etc.

    -- HERO-SPECIFIC save: Sniper's Concussive Grenade self-push.
    grenade_self        = {
        short = "grenade_self",
        fire  = function(intent, threat_caster)
            local cast_point = grenade_self_cast_point(threat_caster)
            if not cast_point then return false end
            return issue_item_position(intent, "def", ability(A.D), cast_point)
        end,
    },
}
```

Hero-specific saves are **also registered in `lib/threat_data.lua`'s
`SAVE_KIND` table** so the kind-intersection filter works. For Sniper:

```lua
-- in lib/threat_data.lua
ThreatData.SAVE_KIND = {
    ...
    grenade_self = { "displacement_perp" },
    ...
}
ThreatData.SAVE_PUSH_DISTANCE = { ..., grenade_self = 475, ... }
ThreatData.SAVE_COOLDOWN_TIER = { ..., grenade_self = "low", ... }
```

A new hero with `bristleback_quill_spray_active` would add an entry to each
of these in threat_data.lua and a `fire` closure in their hero file.

### 2. `DEFAULT_SAVE_CHAIN` - fallback order for unknown threats

```lua
local DEFAULT_SAVE_CHAIN = {
    "item_cyclone", "item_lotus_orb", "item_manta", "item_satanic",
    "item_glimmer_cape", "item_hurricane_pike", "item_force_staff",
    "grenade_self", "item_black_king_bar", "item_aeon_disk",
}
```

This is the chain consulted when the threat has no `RECOMMENDED_SAVES` entry.

### 3. `<HERO>_SAVE_OVERRIDES` - per-threat custom orders for this hero

```lua
local SNIPER_SAVE_OVERRIDES = {
    -- Pudge Dismember: Sniper prefers grenade-self (free, AOE, pushes Pudge too)
    -- over Pike (item slot but reliable). Universal recommendation has Eul
    -- first; Sniper's preference is different.
    modifier_pudge_dismember = {
        "grenade_self", "item_hurricane_pike", "item_force_staff",
        "item_cyclone", "item_manta",
    },
}
```

When `threat_mod` matches an entry, the hero override replaces
`TD.RecommendedSaves`. The reserve-penalty / tether-check / readiness checks
still apply.

## How `try_save_self` resolves the order

```
1. If threat_mod has hero override → use it
2. Else if threat_mod has TD recommendation → use it
3. Else → use DEFAULT_SAVE_CHAIN

For each save in resolved order:
   - SaveCounters(save, threat) == true  (kinds intersect)
   - WillTetherBreak(save, threat, dist) == true  (geometry OK)
   - save_is_ready(save) == true  (off CD)
   - SaveReservePenalty(save, threat) > -20  (reserve threshold)
→ fire it, mark layer2 fired, return true

If nothing fires → log `no_effective_save_for_threat` and let the threat land.
```

## Timing dispatch (already in Sniper.lua)

- **pre_cast threats** - Sniper's anim subscribers (`on_hard_disable`,
  `on_channel_start`) fire during the cast point.
- **at_impact threats** - Sniper's `armed_threats_tick` + `state.armed_threats`
  fires when `dist/eta_speed < eta_trigger`. Add new armed threats to the
  arming logic in `OnModifierCreate` for new homing threats.
- **mid_channel / reactive threats** - fire from `OnModifierCreate`
  (`threat_on_self` path). The threat-response dedup prevents stacking.
- **prophylactic** - currently no dispatch path; rare.

## Minimum surface a new hero adds

1. Copy Sniper's anim handler / OnModifierCreate / armed-threats scaffolding.
2. Declare the hero's abilities (`A = {Q, W, E, ...}`).
3. Add the hero's save_fire entries (most are item-self; one or two hero-
   specific saves).
4. Register hero-specific saves' kinds / push / CD tier in `lib/threat_data.lua`.
5. Add `<HERO>_SAVE_OVERRIDES` for the 1-3 threats where this hero's preference
   differs from the universal recommendation.
6. Decline to write everything else - the lib does it.

For a melee carry like Ursa or Centaur, expect:
- Hero-specific saves: `centaur_stampede` (team invuln), `ursa_enrage` (damage block)
- `<HERO>_SAVE_OVERRIDES`: prefer hero-specific save over Eul/BKB for most threats
- Same anim / modifier dispatch scaffolding

## Where to look in Sniper.lua for examples

- `SAVE_FIRE` table near `try_save_self`
- `SNIPER_SAVE_OVERRIDES` immediately after
- `grenade_self_cast_point()` for the hero-specific directional cast helper
- `try_save_self` for the dispatch logic (40 lines)

---

## Sniper v6.x lessons (consume these before authoring a new hero)

### Chain order beats runtime cross-save dedup
If two saves can both fire against the same threat (e.g. Pike + grenade vs Bara Charge), the user's preference becomes the **first entry in the override list**. The chain stops at the first successful fire - the second save is never considered. Don't try to enforce "only one" via runtime checks like `is_other_save_pending` - race conditions with baseline (Linkbreaker, Items Manager) make those backstops, not solutions. See `Sniper.lua` `SNIPER_SAVE_OVERRIDES` for the canonical pattern (Pike → grenade → Force → ... for Pudge/Bane/Bara).

### Ability readiness - gate on `Ability.GetLevel(a) > 0`
`Ability.IsReady` returns `true` for an unlearned ability slot (no CD, no mana gate). For shard-granted abilities present in `npc_heroes.json` but not actually owned by the player, this looks "ready" - the chain dispatches an order on the unlearned ability, Humanizer accepts it, the chain reports success, and the in-game cast silently fails. Pike fallback never gets tried. **Always check level > 0** in any custom `ability_ready` helper. See Sniper v6.2 fix.

### Two-stage trigger for homing close_gap threats
`armed_threats_tick` should not naively fire at a single `eta_trigger`. For threats where a hero has multiple viable saves at different ranges (Pike at 425u radius, grenade-at-caster at 600u radius, etc.), use:

1. **Pike-in-range fire** - at any tick, if preferred save is ready AND charger is already in its cast range: fire chain immediately.
2. **eta_trigger with defer** - at `eta <= eta_trigger`, check if preferred save will become viable within `eta_speed * 0.15`. If yes, defer. Otherwise fire chain.
3. **eta_critical safety net** - at `eta <= 0.35` (or similar tight threshold), force-fire regardless of deferred state. Prevents the deferral from pushing past impact.

Result: brain pre-empts baseline by firing the preferred save when it actually becomes viable. Pre-emption puts the save on CD so baseline can't double-fire. See Sniper v6.5 `armed_threats_tick`.

### Self-displacement is useless against homing threats
For `close_gap` categories that re-target (Bara Charge, Tusk Snowball, PA Phantom Strike, Slark Pounce in some configs): **don't put `grenade_self` / `item_force_staff` self-cast in the override chain**. They consume the CD without breaking the threat. Pike's fire entry should also skip its self-fallback for these threats (return false instead of casting Pike-on-self) so the chain falls through to in-range options. See Sniper v6.4-v6.6 fix for the close_gap category-aware Pike behavior.

### Pike and Force don't push the same way
- **Hurricane Pike** - both caster and target are pushed **radially outward from each other**. Pike-on-Pudge during Dismember pushes Pudge directly away from Sniper, reliably breaks the 200u tether.
- **Force Staff** - pushes target **in target's facing direction**. Force on a unit channeling toward Sniper pushes the channeler **toward Sniper** (bad). Force-on-self pushes Sniper in Sniper's facing.

Earlier Sniper revisions had these swapped, leading to incorrect chain ordering for several threats. Read Liquipedia rather than trusting "common knowledge" or stale comments.

### Liquipedia is the source of truth for save geometry, not JSON
On-disk JSON values can be stale across patch boundaries. Confirmed wrong-or-stale in 7.41C:
- `IsGrantedByShard` flag on `sniper_concussive_grenade` IS honored (shard-only) but the `Ability4` slot listing in `npc_heroes.json` makes it look base.
- `items.json` Pike push reflected pre-7.41 value (450u) - actual is 425u in 7.41+.
- `item_eternal_shroud` was REMOVED in 7.41 but may still appear in the JSON.
- Sniper Take Aim does NOT root in 7.41C despite old wiki snippets.

**When authoring a new hero**: cross-check every item/ability that affects save geometry against Liquipedia. Update `lib/threat_data.lua` if discrepancies are found.

### Brain Layer 2 fires don't equal in-game cast success
A fire closure returning `true` means the order was queued, not that the engine accepted it. Out-of-range, unlearned, silenced, or channeling-locked casts silently fail. The chain has no callback for "did this cast resolve" - design the chain so range gates are correct. Don't queue Pike on enemy at 450u when Pike's enemy cast range is 425u.

### Per-threat-category Pike behavior
Pass `threat_mod` to the Pike fire closure so it can vary by `TD.CategoryOf(threat_mod)`:
- `close_gap` (homing): Pike-on-enemy if in range; **no self-fallback** (return false, let chain fall through).
- All other categories: Pike-on-enemy if in range, else Pike-on-self.

This generalizes to any save where the self-fallback is useless against a specific category.

### Tier 2 extraction roadmap - `lib/defense.lua`

The two-hero rule says extract a Tier 2 module only when a second hero's inline implementation matches the first hero's. The 2026-05-11 audit of `Sniper.lua` identified the candidates that will move when Hero #2 lands. **Pre-listing them here** so extraction is mechanical when triggered.

**Already extractable today (lift to `lib/order.lua` extensions or `lib/threat_data.lua`):**
- `save_item_pending_on_target(target)` → `Order.SaveItemPendingOnTarget`
- `queue_has_baseline(order_type, unit_idx, ability_idx, target_idx)` → `Order.QueueHasBaseline`
- `find_ability(name)` multi-slot scan + `ability_ready(name)` level-gate → `Order.FindAbility` / `Order.AbilityReady` (the v6.2 fix applies to every shard-granted ability across all heroes)
- `SAVE_ITEMS_TO_CHECK` constant → `ThreatData.SAVE_ITEM_NAMES`

**Waiting for Hero #2 → `lib/defense.lua` (≈600 LOC):**
- Threat-response dedup (`already_responded`, `mark_responded`, dedup window, table)
- Layer 2 reaction window (`layer2_can_fire`, `mark_layer2_fired`, last-save timestamp)
- `record_save` telemetry stub (logger injected by hero)
- `try_save_self(intent, threat_mod, threat_caster)` chain dispatcher
- `resolve_save_order(threat_mod)` (hero override → TD recommendation → default chain)
- `save_is_ready(save_name)` with hero-provided `ability_backed_saves` map
- `save_channel_on_self(caster, threat_mod)` with `last_resort_fire` hook
- `armed_threats_tick()` two-stage trigger (Pike-in-range / eta_trigger-with-defer / eta_critical safety net)
- Save-fire helpers: `issue_item_self`, `issue_item_target`, `issue_item_position`, `issue_item_no_target`, `issue_cast_position`, `issue_cast_notarget`, `issue_cast_target`, `safe_issue` (probably extend `lib/order.lua` instead)
- The standard item entries in `SAVE_FIRE` (Pike, Force, BKB, Glimmer, Eul, Wind Waker, Lotus, Manta, Satanic, Disperser, Diffusal, Solar Crest, Pipe, Crimson Guard, Blade Mail, Ghost, Aeon Disk, Phase Boots, Blink variants) → `Defense.BASE_SAVE_FIRE` table; hero merges its own entries
- `try_save_lotus_first(intent)`, `damage_rate_panic_check()`, `save_bane_nightmare()`
- Inventory snapshot logger (`saves_inventory` log path)
- `OnModifierCreate` threat-on-self dispatch skeleton (THREATS_ON_SELF / LOTUS_WORTHY_INCOMING / ENEMY_CHANNEL_MODIFIERS triple-branch)
- `OnModifierDestroy` armed-threat clearing
- `OnLinearProjectileCreate` hook intercept (Pudge hook math; "Pudge" is universal threat)
- `blink_escape_position`, `SafePushDestination` (universal escape geometry)
- `displacement_will_break_tether` adapter

**Stays hero-specific:**
- `HERO_KEY`, `CAST_R`, `GRENADE_R`, `SHRAP_R`, ability constants (`A` table)
- `grenade_self_cast_point()` (Concussive Grenade radial-push geometry)
- `SAVE_FIRE.grenade_self`, `SAVE_FIRE.grenade_at_caster` (cast-point math is grenade-specific)
- `SNIPER_SAVE_OVERRIDES` (the whole point of this table is hero preference)
- Assassinate kill-math (`assassinate_damage`, `ScoreUltTarget`, `CanCommitFullCombo`, `full_combo_cost`)
- Fog-snipe candidate logic
- Layer 1 combo dispatcher (`snipe_standard`, `take_aim_chase`, `layer1_tick`)
- Layer 1.5 channel-punish / TP-interrupt logic
- `reactive_take_aim`
- Anim subscribers wrappers (`on_gap_close`, `on_hard_disable`, `on_channel_start`) - skeleton is universal but action functions are Sniper-specific
- Bara/Tusk `bara_charge_armed` / `tusk_snowball_armed` handlers - pattern moves to lib but the per-threat numbers (eta_speed/eta_trigger tuned against Sniper's reaction) stay here
- Menu + status panel
- Telemetry wrappers (`LOG`, `tlog`, `uname`, `v_level`, `anim_log_throttled`)

**The mechanical extraction API:**
```lua
local Defense = require("lib.defense")

local spec = {
    hero            = "Sniper",
    save_fire       = SAVE_FIRE,            -- merged: BASE + hero-specific
    save_overrides  = SNIPER_SAVE_OVERRIDES,
    default_chain   = DEFAULT_SAVE_CHAIN,
    ability_backed_saves = { grenade_self = A.D, grenade_at_caster = A.D },
    telemetry_fn    = tlog,
}

Defense.TrySaveSelf(spec, intent, threat_mod, threat_caster)
Defense.Tick(spec)                          -- runs armed_threats_tick + damage_rate_panic + saves_inventory
Defense.OnModifierCreate(spec, npc, modifier)
Defense.OnModifierDestroy(spec, npc, modifier)
Defense.ArmThreat(spec, key, data)
```

If after extracting, Sniper.lua doesn't shrink by ≈600 LOC, the interface is wrong.

### Document each save closure's cast geometry
For every hero-specific save closure, write a comment specifying:
- Cast mode: target-cast (auto-orient), self-cast (uses Sniper's facing), or position-cast (cast point).
- Push direction: target-relative, caster-relative, or radial-from-cast-point.
- Push magnitude in units.

Wrong assumptions about geometry caused multiple Sniper revisions. The comment is cheaper than a v-bump.

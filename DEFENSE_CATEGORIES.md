# Defense categories - analysis of "separate anti-close-gap vs threat-stopper sections"

Date: 2026-05-11
Status: Categorization implemented in data; code-path separation deferred.

## What the user asked

> "Analyze if it is good to do a separate section for anti close gap and threat stopper"

Two distinct response profiles:

- **Anti-close-gap** - prevent the threat from connecting. Example: cancel Bara Charge before he reaches Sniper.
- **Threat-stopper** - end an active threat. Example: break Pudge Dismember mid-channel.

These differ in TIMING (when the save fires) and INTENT (prevent vs interrupt).

## What I built (v5.4)

`ThreatData.THREAT_CATEGORY` - 9-value classification per threat:

| Category | Examples | Best response | Save-fire path |
| --- | --- | --- | --- |
| `close_gap` | Bara Charge, Tusk Snowball, PA Strike (chase), Slark Pounce | cancel-on-caster (grenade-at-caster, Pike-on-enemy) | `armed_threats_tick` for homing, `anim` for projectile-based |
| `channel_on_self` | Pudge Dismember, Bane Fiend Grip, Shaman Shackles, WD Death Ward | `ROOT_DISABLES` break (grenade-at-caster) or self-dispel | `anim_channel_start` (pre-cast) + `OnModifierCreate` (mid-channel) |
| `targeted_disable` | Bane Nightmare, Lion Hex, Naga Ensnare, Doom | invuln/immune during cast point | `anim_hard_disable` + `OnModifierCreate` |
| `targeted_burst` | Lion Finger, Lina Laguna | invuln / magic_barrier / reflect | same as above |
| `delayed_aoe` | Lina LSA, Enigma BH, CM Freezing Field | displacement (Pike, Force, Blink, grenade-self) | `OnModifierCreate` |
| `line_projectile` | Pudge Hook, Slark Pounce, Tusk Ice Shards, Mirana Arrow | perpendicular displacement | `OnLinearProjectileCreate` for typed, `anim` for others |
| `physical_chase` | PA Phantom Strike, Ursa Overpower | invis (Glimmer) / damage_block / physical_immune / damage_return | `OnModifierCreate` |
| `drain` | Razor Static Link, Lion Mana Drain | dispel or displacement out of tether range | `OnModifierCreate` |
| `lockdown` | Legion Duel, Berserker's Call | Satanic lifesteal-through, Blade Mail return | `OnModifierCreate` |

This is **data-level separation** - the brain logs the category alongside every save, and per-threat overrides (`SNIPER_SAVE_OVERRIDES[mod]`) express category-appropriate preferences.

## What I did NOT build (and why)

**Code-path separation** - dedicated handlers per category - was deferred.

If the brain had separate handlers:
```lua
local function on_close_gap_threat(caster, mod) ... end
local function on_channel_on_self(caster, mod) ... end
local function on_targeted_disable(caster, mod) ... end
-- etc., 9 functions
```

…then OnModifierCreate would dispatch to the right one based on category. Each handler could have category-specific logic (different reaction window, different fallback strategy, custom telemetry).

**Tradeoffs vs the current unified `try_save_self`:**

| Pro of separation | Pro of unified |
| --- | --- |
| Clearer code intent | Single decision flow easy to reason about |
| Per-category tuning (reaction window, fallback) | Per-threat tuning via the override table already does this |
| Better debugging (less code path to trace) | One place to fix bugs |
| Different telemetry per category | Telemetry already includes `category` via record_save |

**Verdict:** the unified dispatcher with per-threat overrides + the new `THREAT_CATEGORY` field provides ~90% of the benefit at 0% of the refactor cost. The remaining 10% (per-category-tuned reaction windows, dedicated fallback chains) can be added incrementally when a real case demands it.

## When to revisit

Promote to code-level separation if any of these become true:

1. **Per-category reaction windows differ meaningfully.** Currently `LAYER2_REACTION_WINDOW = 0.8s` applies uniformly. If close-gap saves need 0.3s windows (faster reactions for short-cast threats) while channel saves can tolerate 1.5s, separate dispatchers would express that cleanly.
2. **Category-specific fallback chains diverge significantly.** Right now SNIPER_SAVE_OVERRIDES handles this per-threat. If many threats in the same category share a fallback chain (e.g., all channels fall back to Manta then BKB), promoting it to category-level reduces duplication.
3. **Telemetry needs differ.** Currently `record_save` logs `category=...`. If we need separate metrics (close-gap save success rate vs channel save success rate), the dispatchers naturally compute these.
4. **Hero #2 requests category-specific behavior** that doesn't fit the universal pattern.

## How a hero would use this today

The categorization is mostly **documentation** at this point - the brain reads `THREAT_CATEGORY` only for logging. But hero scripts can already react to it:

```lua
-- Hypothetical: a hero that wants a tighter reaction window for close_gap
local function reaction_window_for(threat_mod)
    if TD.CategoryOf(threat_mod) == "close_gap" then return 0.3 end
    return 0.8  -- default
end
```

For Sniper v5.4 specifically: every override list is already CATEGORY-AWARE in its ordering. `modifier_pudge_dismember` (channel_on_self) prioritizes `grenade_at_caster` + self-dispels. `modifier_spirit_breaker_charge_of_darkness` (close_gap) prioritizes `grenade_at_caster` + Pike-on-enemy forced-movement. The data does what the user asked.

## Summary

- **Implemented**: THREAT_CATEGORY as a 9-value classification, logged in every layer2_save line, available as `TD.CategoryOf(mod)` for any hero code that needs it.
- **Deferred**: separate code paths per category. Not needed yet - the per-threat override table already expresses category-appropriate preferences.
- **Re-evaluate when**: per-category reaction windows / fallback chains / telemetry diverge meaningfully.

# Sniper — Liquipedia ability reference

**Source:** https://liquipedia.net/dota2/Sniper
**Fetched:** 2026-05-13
**Patch:** 7.41

This file is the cross-reference for brain code that depends on Sniper ability mechanics. Update when patch notes change Sniper. Keys to check: Q radius (level-dependent!), R cast point (Scepter cuts it), D is shard-gated.

---

## Shrapnel (Q)

| Field | Value |
|---|---|
| Cast animation | 0.3s + 0s backswing |
| Cast range | 1800u (affected by cast range bonuses) |
| **Effect radius** | **400 / 425 / 450 / 475** (level 1/2/3/4) |
| Effect delay (zone arms after) | 1.2s |
| Damage per second | 30 / 45 / 60 / 75 |
| Total damage over 10s | 330 / 495 / 660 / 825 |
| Movement speed slow | 12% / 18% / 24% / 30% |
| Zone duration | 10s |
| Charge replenish | 35s |
| Number of charges | 3 |
| Mana cost | 75 |
| Cooldown | 0 (charge-based) |

**Brain implications:**
- Corridor placement must use **live Q radius** by level — `Ability.GetLevel(A.Q)` indexed into `{400,425,450,475}`.
- The v6.15.67 hardcoded `SHRAP_RADIUS=450` is correct only at level 3. v6.15.69+ should derive live.
- Zone *arming* delay of 1.2s means Q damage doesn't start until 1.2s after cast resolves — corridor lead math should account for this when timing kills.

---

## Headshot (W)

| Field | Value |
|---|---|
| Type | Passive |
| Proc chance | 40% |
| Bonus damage | 20 / 50 / 80 / 110 |
| Max knockback distance | 50u |
| Knockback duration | 0.033s |
| MS slow on proc | 100% |
| AS slow on proc | 100 |
| Slow duration on proc | 0.2 / 0.3 / 0.4 / 0.5s |

**Brain implications:**
- `rc_2s` calc already accounts for headshot damage when Take Aim active (100% proc).
- The 100% MS slow on proc is short (≤0.5s) but recurring — chains keep target slow during sustained autos.

---

## Take Aim (E)

| Field | Value |
|---|---|
| Cast animation | Instant (0 + 0) |
| Cooldown | 20 / 18 / 16 / 14 |
| Mana cost | 50 |
| Duration | 3s |
| Passive attack range bonus | 160 / 240 / 320 / 400 |
| Active attack range | 785 / 940 / 1095 / 1250 |
| **MS slow while active** | **45% / 40% / 35% / 30%** *(see KV note below)* |
| Vision bonus | 500 / 750 / 1000 / 1250 |
| Guaranteed headshot while active | 100% |

**Brain implications:**
- **KV CORRECTION (v6.15.168, 2026-05-18):** the live KV
  (`assets/data/npc_abilities.json`, `sniper_take_aim` AbilityValues `slow`)
  gives a **flat 65%** self-MS-slow — NOT the per-level 45/40/35/30 the
  Liquipedia page above lists. Valve appears to have reworked it; the KV
  data is authoritative for the live game. The brain reads it live via
  `Ability.GetLevelSpecialValueFor(E, "slow")` (fallback 65), so it
  self-corrects regardless. Treat the table value above as stale.
- Take Aim **slows Sniper's own movement** while active — Sniper is more
  vulnerable to ganks during the 3s active window.
- The +140 attack range used in `atk_range_with_e` is approximate — actual passive bonus is 160 (L1) → 400 (L4). Code constant is too conservative late game.
- Active attack range jumps to 785-1250 — this is the BURST range during Take Aim's 3s window.
- **MODIFIER NAMES (v6.15.147, user-confirmed):** Take Aim has TWO modifiers.
  `modifier_sniper_take_aim` is the **always-on PASSIVE** (the attack-range
  bonus) — present every tick once E is leveled. `modifier_sniper_take_aim_active`
  is the **3s ACTIVE buff**. An "is Take Aim active" check MUST test only
  `_active` — testing the bare name is permanently true (it broke
  `self_take_aim_state` — the Team Fight E never fired).

---

## Concussive Grenade (D) — **Shard ability**

| Field | Value |
|---|---|
| Cast animation | 0.1s + 0.8s backswing |
| Cast range | 600u |
| Effect radius | 375u |
| Damage | 200 (magical) |
| Knockback distance | 475u |
| Knockback duration | 0.4s |
| **Stun duration** | **0.4s** |
| MS slow post-knockback | 50% |
| **Disarm duration** | **3s** |
| Cooldown | 10s |
| Mana cost | 50 |
| Projectile speed | 2500u/s |

**Brain implications:**
- D is **shard-gated** — `NPC.HasShard(me)` check is the gate for D-using combos (`snipe_standard`, `snipe_d_r`, `snipe_channel_punish`, `grenade_self_kite`, `grenade_shrap_zone`).
- Stun is only **0.4s** — the LONG-DURATION effect is the 3s disarm. For locking target during R cast, the 3s disarm matters more than the 0.4s stun.
- Projectile travel time at 600u (max cast range) = 600 / 2500 = 0.24s. At 200u close range = 0.08s.
- Cast point 0.1s + projectile travel ≈ 0.18-0.34s for D to land on target after dispatch.

---

## Assassinate (R)

| Field | Value |
|---|---|
| Cast animation (baseline) | **2.0s + 1.6s backswing** |
| Cast animation (with Scepter) | **0.5s + 1.47s backswing** (user-verified 2026-05-13) |
| Cast range | Affected by cast range sources |
| Damage type | Magical + instant attack (physical, dual instance) |
| Keen Scope bonus | 1.08× factor applied |
| **Scepter effect** | **Reduces cast point (2.0 → 0.5) + 1.47s backswing + adds stun on target impact** |

**Source note:** Initial fetch missed the Scepter cast-animation specifics. User supplied verbatim from Liquipedia 2026-05-13: *"Aghanim's Scepter Upgrade — Assassinate now fires quicker and stuns the enemy target. Reduces cast point. Cast Animation: 0.5 + 1.47"*. The 0.5s value happens to match the existing brain code comment in `snipe_scepter_aoe` (line ~2748), but that match is coincidence — the code constant should be sourced from `Ability.GetCastPoint(A.R, true)` at runtime, not from doc-side guesses.

**Brain implications:**
- `R_CAST_S = 2.0` constant in `build_layer1_ctx` is correct without Scepter.
- With Scepter, R cast = 0.5s. `eff_hp_magical += target_regen × R_CAST_S` should use the live cast point.
- **User correction (2026-05-13):** Scepter affects **R**, not D. D's timing/properties are unchanged by Scepter.
- `snipe_standard`'s D delay (currently fixed 1.5s) was tuned for non-Scepter R (2.0s cast). Under Scepter (0.5s cast), D fires LATE — R has already landed by the time D arrives. v6.15.69 fix: derive D's delay from live R cast point.

**v6.15.91 (2026-05-14) — DUAL-INSTANCE DAMAGE RESOLVED.**
- Damage Type field says "Spell/Magical + Instant Attack/Physical (dual instance)" — both components active in current 7.41.
- Investigation via Liquipedia changelog (Sniper/Changelogs, fetched 2026-05-14):
  - 7.34: `CHANGED damage from a fixed 320/510/700 to 250/350/450 + 1 * InstantAttackDamage` — dual-instance mechanic introduced.
  - 7.40: `Increased instant attack damage factor from 1 on each level to 1/1.1/1.2`.
  - 7.41: `No longer has a 1/1.1/1.2 instant attack factor.` + `Now applies Keen Scope of its corresponding level upon projectile impact.`
- The 7.41 line removes only the per-level scaling factor; the instant attack itself remains at factor 1.0 (one regular-attack-equivalent). Confirmed by the present-tense "Instant Attack / Physical" entry still listed under Damage Types on the main Sniper page (fetched 2026-05-14).
- Per Liquipedia's "Instant Attacks" article (linked from the global mechanics page): instant attacks use the hero's regular attack damage values, proc on-hit modifiers (Headshot, Maelstrom, Daedalus, Skadi), have True Strike (no evasion check), ignore disarms, apply physical armor reduction.
- **Brain fix (v6.15.91):** new `assassinate_instant_attack_damage(target, distance, take_aim_active)` returns `rc_attack_damage_with_procs(take_aim, d) * NPC.GetArmorDamageMultiplier(target)`. Wired into `build_layer1_ctx` at line 2292 — `r_dmg_at_d = magical + physical`. `combo_dmg_breakdown` now logs `r_mag` and `r_phys` split. Take Aim flag = `true` for snipe_e_r since E fires before R.
- **Pending follow-up:** `ScoreUltTarget`'s R-damage estimates (lines 1066/1184/1442) still use magical-only. Relative scoring, not commit math — won't false-fire, but may slightly under-rate kill targets. Defer until commit-side fix is empirically validated.
- **Keen Scope formula bug (separate):** brain's `keen_scope_bonus(d) = floor(d/100) * 1.5` is a flat 1.5 per 100u. Liquipedia formula is `AtkDmg × (1.5% + 0.05% × SelfLvl) × ⌈distance/100⌉` — a % of attack damage, not flat. Magnitude at 1500u, level 16: brain returns ~22; real value with 120 base damage is ~42. Small discrepancy at typical R distance; revisit if demos show systematic mis-estimation.

---

## Talents

| Tier | Left | Right |
|---|---|---|
| 10 | +30 Headshot Damage | +50 Take Aim Attack Range |
| 15 | −30s Shrapnel Restore Time | +45 Take Aim Active Attack Speed |
| 20 | +30% Shrapnel Damage | +2s Take Aim Duration |
| 25 | +50 Max Headshot Knock Distance | +150 Assassinate Damage |

**Brain implications:**
- Tier 15 LEFT (-30s Shrapnel restore) cuts charge replenish from 35s → 5s — massive Q uptime. Corridor pacing assumptions should account for talent.
- Tier 20 LEFT (+30% Shrap damage) — `shrap_damage_per_q_effective` should query `NPC.GetTalent(...)` for this if not already.
- Tier 25 RIGHT (+150 R damage) — `assassinate_damage()` needs talent check.

---

## Aghanim's upgrades

- **Scepter (Assassinate):** Reduced cast point + adds stun on target impact.
- **Shard (Concussive Grenade):** Unlocks D entirely. Without shard, D doesn't exist on Sniper.

---

## Brain code constants to cross-reference

| Code | Liquipedia value | Status |
|---|---|---|
| `SHRAP_RADIUS = 450` (v6.15.67) | Level-dependent: 400/425/450/475 | **Hardcoded at L3 value** — should be live `Ability.GetLevel(A.Q)` lookup |
| `R_CAST_S = 2.0` (build_layer1_ctx) | 2.0s no-scepter, ~0.5s with scepter | Correct without Scepter; should use live `Ability.GetCastPoint(A.R)` |
| `snipe_standard` D `delay_s = 1.5` | Aligned to 2.0s R; wrong under Scepter | **Fix in v6.15.69** |
| `atk_range + 140` (v6.11 setup_killable) | Take Aim passive: 160/240/320/400 | Conservative (correct only at L1); higher levels give MORE range |
| D ability availability | Shard-gated only | Verify `NPC.HasShard(me)` is gate, not just ready_d |

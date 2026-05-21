# Dota 2 Hero Brain Upgrade Project — UCZone Lua

Bolt-on intelligence over outdated built-in hero scripts. Per-hero, hero-specific-logic-heavy. **Brain work, not plumbing — the API does the introspection.**

## Stack

- **API:** UCZone (Lua 5.4)
- **API source documentation (canonical reference for every prompt):** `C:\Users\arcos\uczone-api-v2.0`
- **Project root / source / working area:** `C:\Users\arcos\dota-hero-brains` — one subfolder per hero
- **Reference comparison docs:** `C:\Users\arcos\melonity-api-docs` (Melonity, kept for cross-reference only — project standardizes on UCZone)
- **Runtime install:** `%cheat_dir%/scripts/` (resolve actual path with `Engine.GetCheatDirectory()` at runtime). Deploy by copy or symlink from the source area

## Information level — Stage 2

Brain logic assumes **Stage 2 information level** is active (the framework exposes this as the "Stage 2" toggle in Settings → Security). At Stage 2 the following are available; without it they are not:

- `OnEntityHurt(data)` — typed damage feed (source, target, ability, damage)
- `OnEntityKilled(data)` — typed kill feed
- `OnFireEventClient(data)` — generic game-event fallback
- `Event.AddListener(name)` — custom game-event subscription
- `Entity.GetRoshanHealth()` — Roshan combat decisions
- Various `CMenuBind:Unsafe(true)` widgets surface Stage 2 features in the UI

**With Stage 2 ON (project default):** Layer 2's "incoming damage rate exceeds survival threshold in next 0.8-1.5s" trigger reads from the typed feed directly. Cheap, precise, attributed.

**Without Stage 2 (fallback):** Poll `Entity.GetHealth(local_hero)` in `OnUpdateEx` each tick, maintain rolling ~1.5s damage window. Predict incoming damage via `OnProjectile` + `OnLinearProjectileCreate` (both always available — they carry source, projectile speed, isAttack). DoT modifiers tracked via `OnModifierCreate` + estimated per-tick damage. ~30% noisier, higher CPU, loses precise damage attribution to source.

The Stage-2-vs-fallback choice is abstracted behind `lib/damage.lua` (see Shared library plan) so hero code reads `Damage.GetRecentDamage(npc)` without knowing which path is live.

## Why UCZone over Melonity

For brain-only, hero-specific-logic-heavy work at 124-hero scope, UCZone's introspection floor saves ~30-40% per-hero plumbing. Key wins:
- `NPC.GetModifierProperty(npc, Enum.ModifierFunction.MODIFIER_PROPERTY_X)` — aggregated modifier value reads (the enum table is `Enum.ModifierFunction`, but its values use `MODIFIER_PROPERTY_*` prefix)
- `NPC.GetStatesDuration({...})` — CC/immunity durations table at predicted impact
- `Hero.GetLastMaphackPos` / `GetLastVisibleTime` — fog tracking built-in
- `NPC.GetAttackAnimPoint` / `GetAttackProjectileSpeed` — orbwalk primitives on every NPC
- Typed `OnEntityHurt` / `OnEntityKilled` callbacks
- `Humanizer.GetOrderQueue()` — order-queue introspection
- `Player.PrepareUnitOrders` with `identifier`, `callback` (boolean — route through OnPrepareUnitOrders; named `push` on the sibling `AttackTarget`/`HoldPosition`), `execute_fast`, `force_minimap` flags

Melonity's edges (TS types, `OnScriptPrepareUnitOrders(order, caller)`, generic `MemoryAccessor.GetProperty<T>`) matter more for typed cross-hero engines — not this workload.

## Architectural principle — two independent layers

Every hero brain has two distinct control layers that share order discipline but trigger independently:

### Layer 1 — Aggressive combos (key-activated)

- Bound to user hotkeys via `CMenuBind`. Hero key pressed → brain executes the named combo.
- Includes **integrated defensive item usage as combo steps** — the brain Pikes itself mid-Assassinate if an enemy gap-closed during the cast. "Commit safely" is part of the offense, not a separate concern.
- Pre-conditions checked before firing: mana budget, cooldown set, target validity, target reachability, target predicted state at impact safe, no own-CC active blocking the combo.
- One combo per meaningful intent (burst, push-clear, save-ally, anti-channel, etc.). Don't overload a single key with conditional branching the user can't predict.

### Layer 2 — Defensive mechanics (always-on, no key)

- Fire continuously from threat detection. Never wait for user input.
- Trigger on: incoming damage rate exceeds survival threshold in next 0.8-1.5s, enemy gap-close animation committed (read via `OnUnitAnimation`), enemy ult cast on self detected mid-animation, fog ambush detected (multiple dormant enemies + missing ward + nearby), predictable lethal in next ~1.5s.
- Auto-fire save items: Force Staff, Hurricane Pike, Glimmer Cape, Ghost Scepter, Eul's, BKB, Lotus, Aeon Disk, Manta dispel, item dispels.
- Chains: when first defense expires with threat still active, second is already queued. Minimum 0.8s reaction window between two self-cast items.
- Hero-specific defensive abilities count here too (Bristleback turn, PA Blur on, Treant Living Armor self, Necro Ghost Shroud, Lifestealer Rage, etc.).
- User overrides: a single "disable auto-defense" toggle for the edge cases where you want full manual control. Default ON.

Both layers route through `lib/order.lua` which self-dedups against an internal pending-registry mirror (the humanizer queue doesn't expose our identifier field per the UCZone v2.0 docs, so registry-mirror is the working mechanism — TTL 2.5s). If a defensive auto-fire happens during a user's aggressive combo, both orders land in the humanizer queue with distinct identifiers and the lib handles non-stomping.

## The seven decision axes

Inventory per hero. Pick the 2-3 highest-leverage axes given the combo enumeration (Phase 0.5) — don't spread thin.

1. **Threat assessment** — who can kill me in the next 2s? Visible + fog + dormant + missing-ward + enemy ult readiness.
2. **Resource accounting** — HP/mana/cooldowns/charges/TP/buyback gold. Cast when worth more than the alternative use.
3. **Target valuation** — lowest effective HP after armor + my damage stack + active amps, illusions/clones filtered, target value weighted.
4. **Cast windows** — predict target state at impact tick, not at keypress. Anti-Linkens / anti-Lotus / anti-BKB / anti-disjoint.
5. **Skill sequencing** — dispel before stun, slow before nuke, silence before save, channel after commit. Applies equally to defensive item chaining.
6. **Itemization-conditional posture** — same hero plays differently with vs without BKB / Blink / Linkens / Aghs / Refresher / Shard. Track enemy items too.
7. **Map awareness** — Roshan timer, rune timer, ally TP cooldowns, lane equilibrium, neutral spawn windows, day/night.

The axes are **coverage requirements over the rule set**, not category buckets to fill. Verify every focused axis has at least one rule from Phase 0.5 contributing to it.

## Phase 0.5 — Combo & situation enumeration

**Combo discovery must precede axis scoring.** Don't use template categories — they're Sniper-shaped and miss hero-specific vocabularies (Pudge ally-hook saves, Io tether-relocate baits, Meepo per-clone state, Earth Spirit boulder rolls, Rubick stolen-spell tracking, Invoker orb management).

Six discovery sweeps derive the combo list from the actual kit. Output: flat list of 12-30 named combos + named negative-combos with abilities/items and trigger conditions.

**A. Per-ability sweep**
For every ability (including sub-abilities, toggle states, facet variants, shard upgrades, scepter upgrades, talent modifiers, stolen-ability slots, invoked slots, sub-unit abilities, primary attribute morph), list:
- What it combos INTO (abilities/items it sets up)
- What it combos OUT OF (what sets it up)
- Self-target / self-cast uses
- Anti-enemy-action uses (interrupts, dispels, breaks, silences)
- Timing-critical uses (disjoint windows, channel-cover, animation cancels, day/night gates, aegis interactions)

**B. Per-item sweep**
Top 5-10 items by pickrate this patch. For each:
- Defensive self-cast roles
- Offensive target-cast roles
- Combo-step roles (initiator / amplifier / finisher / disengage / reset / dispel)
- Cooldown windows that gate posture changes

**C. Per-scenario sweep**
For each scenario, list which abilities + items + positioning combine:
- Lane phase (harass, sustain, deny, last-hit, pull/stack, rune)
- Rotations / gank setup / counter-gank / smoke participation
- Mid-game pickoff (solo, 2v1, fog plays)
- Teamfight (initiator / follower / cleanup / save)
- Push / siege / high-ground / barracks dive
- Defense / split-push / smoke gank avoidance
- Roshan (take / contest / dive-with-aegis)
- Late-game throne race / buyback economy

**D. Per-counter sweep**
What does this hero counter / get countered by? Combos specifically against:
- Magic-immune / pierce-immunity sources
- High-armor / Solar Crest / Halberd targets
- Heavily-illusioned lineups (CK, PL, Naga, Arc, Manta)
- Enemy channeled spells this hero must interrupt
- This hero's own channels — what breaks them, what protects them
- Global-presence enemies (Spectre/Tinker/NP/Furion TP responses)
- Vision-dependent enemies (Riki/BH/Treant/Clinkz invis windows)

**D output also produces a per-matchup animation→ability map** that lives in this hero's `notes.md`. For every enemy hero this hero plausibly faces (start with the 10 most common per-position; expand as needed), map each *cast-relevant* animation/activity to the ability it represents and the brain-trigger role:

```
enemy_hero:
  activity_or_sequence_signature:
    ability: <ability_name>
    role: <gap_close | hard_disable | ult_burst | channel_start | dispel | save>
    response: <name of Layer 2 rule or Layer 1 abort condition that fires>
```

This map is what `OnUnitAnimation(data)` indexes into. Without it, the callback gives us a unit + activity number and no semantic meaning. With it, "Slark started Pounce on me" becomes a one-table-lookup decision instead of per-firing inference. Build the map from in-game observation + cross-reference with the activity enums (see `cheats-types-and-callbacks/enums.md` for `Enum.GameActivity` values).

**E. Per-conditional sweep**
Combos that only exist with:
- Specific facet picks
- Specific talents at 15/20/25
- Specific aghs/shard upgrades
- Specific allied heroes (synergy combos)

**F. Negative-combo sweep — things the hero must NEVER do**
- Universal: ult on illusion / Meepo clone / Tempest Double
- Channel-into-known-CC
- Hero-specific traps. Derive from the kit:
  - Earth Spirit kicking own ally accidentally
  - Pudge hooking own ally INTO enemy team (vs to safety)
  - Tinker rearm during silence
  - Invoker switching orb during own ult
  - Morphling morph-strength while needing to dish damage
  - Arc Warden tempest double cancelling on enemy purge
  - Meepo using ult while clones are split

## Three upgrade patterns

**Pattern A — Augmentation.** *Default.* **Baseline stays enabled.** Brain runs as a companion script that adds intelligence the baseline can't supply — pro-play decision overrides, multi-spell combo sequencing with anti-dispel ordering, predictive skillshots, anti-dodge precognition (abort combo if enemy will Eul/Manta/Lotus within predicted impact), fog-of-war pickoffs at `Hero.GetLastMaphackPos`, mana-economy across multi-spell combos, stack-tracking for Slark/OD/Lina/Sniper-headshot. Baseline keeps handling: Items Usage (5-tier prioritized with conditions + support predicates), Kill Stealer, Hit & Run, Orb Walker, Target Selection, Units Controller, Linkbreaker, plus framework-global Dodger / Ward Helper / Auto Buy / Auto Stacker / MMR Tracker / per-hero auto-features.

We do **not** intercept baseline orders (the API doesn't support it — `Player.PrepareUnitOrders` defaults `callback=false`, baseline orders bypass `OnPrepareUnitOrders` in companion scripts). We only **issue additional orders** for cases the baseline can't decide. The two layers coexist on the same humanizer queue. Read `Humanizer.GetOrderQueue()` before every issue — never duplicate baseline's pending orders, only add complementary ones.

A/B testing means toggling our brain on/off; baseline runs either way.

**Pattern B — Replacement.** Disable the built-in baseline hero script via UCZone's per-script UI toggle. Brain runs as the only hero script for that hero. Owns everything the baseline did — Items Usage, Kill Stealer, Orb Walker, Hit & Run, Target Selection, Units Controller, plus the hero-specific Main Settings sub-panels (Sniper Auto Grenade, Alchemist Concoction Settings, Arc Warden's five-panel rich baseline, etc.). Use only when the baseline is **demonstrably broken** for a hero and augmentation can't recover. Expect 3-5× the LOC of an augmentation brain. Candidates: heroes with rich baselines where the baseline's specific decisions are systematically wrong vs pro play. Probably never used in practice.

**Pattern C — Inline source edit.** When baseline source is readable and editable. Harden predicates in place inside the baseline file. Lose A/B-toggle convenience entirely; gain in-place patching. Use case is rare — baseline source isn't typically readable, and even when it is, augmentation gives most of the value with less risk.

**Default for every new hero: Pattern A (Augmentation).** Pattern B is escalation when augmentation hits an obstacle.

## Eleven-item quality gate

A hero brain is done when it survives this in 10 demo games and 5 real games:

1. Never casts an ability the target dodges via predictable invuln window.
2. Never wastes ult on illusion / Meepo clone / summoned unit.
3. Never double-issues an order while one is in `Humanizer.GetOrderQueue()`.
4. Never engages with mana below the minimum-combo threshold.
5. Below 30% HP with TP off cooldown and no fight in progress → TPs out.
6. Last-hit rate ≥ baseline's rate.
7. Deaths/min ≤ baseline.
8. Combo activation rate ≥ baseline.
9. Never triggers high-cost casts on fog data older than 3 seconds.
10. Bottle / regen / clarities used proactively before HP/mana crisis.
11. **Never dies with usable defensive items in inventory when death was predictable ≥0.8s in advance.** Layer 2 must have fired.

## Per-hero pro-play research process

30-60 minutes before any code. Not optional.

1. Three recent high-MMR / pro VODs. Note: facet, lane assignment, level 1-3 skill order, first 3 item slots, when they leave lane, what fights they initiate vs avoid.
2. Stratz / Dotabuff item-timing percentiles this patch. Median first core item, median ult-rank-2, median Aghs/Shard.
3. Two worst lane matchups → brain needs explicit "lane is lost, play passive" mode.
4. Two signature decisions pros get right average players don't. These are the highest-value upgrade targets.

## Order discipline

Every outgoing order:
- `Player.PrepareUnitOrders(player, type, target, pos, ability, issuer, issuer_npc, queue, show_effects, callback=true, execute_fast=<bool>, identifier="{hero}-{layer}-{intent}", force_minimap=true)` — **note:** the flag is named `callback` on `PrepareUnitOrders` and `push` on the sibling `AttackTarget`/`HoldPosition` (UCZone API inconsistency, same semantics)
- Identifier format: `"<hero>-<layer>-<intent>"`. Layer is `agg` or `def`. Examples: `"sniper-agg-burst"`, `"sniper-def-pike-out"`, `"pudge-agg-hook-combo"`, `"pudge-def-aeon-self"`.
- **Self-dedup** (don't reissue our own pending orders): `lib/order.lua` maintains an internal pending-registry mirror keyed by identifier with a 2.5s TTL — `Humanizer.GetOrderQueue()` does NOT expose the `identifier` field per the UCZone v2.0 API docs, so identifier-based dedup runs against this mirror, not the queue itself. Callers don't need to do anything special; `Order.Issue` checks the registry transparently.
- **Baseline-dedup** (don't issue redundant orders while baseline has its own pending): hero scripts inspect `Humanizer.GetOrderQueue()` for entries with same `unit`/`orderType`/`abilityIndex`/`targetIndex` before issuing complementary orders. The queue does carry these fields. `Order.Issue` doesn't automatically check this — it's a hero-specific concern (baseline might be auto-attacking the same target you want to combo on — that's fine; baseline might be casting the same ability you want to combo with — skip).
- `execute_fast=true` only for defensive layer (survival > humanizer) or for confirmed-impact offense. Default false.

## Per-hero file layout

Each hero gets a subfolder under `C:\Users\arcos\dota-hero-brains\`:

```
{hero}/
├── {hero}.lua            ← the brain (single file, registers callbacks)
├── notes.md              ← Phase 0 baseline + Phase 0.5 enumeration + pro reference
└── changelog.md          ← what was upgraded vs baseline, patch-by-patch
```

Shared helpers (used by 3+ heroes) graduate to `C:\Users\arcos\dota-hero-brains\lib\`.

## Implication of augmentation pattern — scope

Pattern A (Augmentation) means baseline keeps doing its job. Per-hero brain code stays small (target: 100-300 lines per hero) and concentrates on decisions the baseline can't make:

| What baseline handles | What brain adds |
|---|---|
| Items Usage (5-tier priority + conditions + support predicates) | Override item-usage timing inside a multi-spell combo sequence |
| Kill Stealer (auto-finisher on killable target) | Anti-dodge precognition — don't fire finisher if target will be invuln at impact |
| Orb Walker (anim-cancel + reset) | Predicted-position attacks for Take-Aim/orbwalk-at-max-range styles |
| Hit & Run (kiting + keep-distance) | Path-aware retreat direction when GridNav matters |
| Target Selection (style + range + includes) | Override target priority in specific game states (low HP escape vs full HP burst) |
| Units Controller (multi-unit basics) | Per-clone coordination for Meepo earthbind chains, LD bear positioning |
| Linkbreaker | Sequence Linkens-pop *into* the main combo when timing matters |
| Dodger (reactive evasion) | Layer 2 follow-up chain after Dodger fires (Pike → Force → Glimmer) |
| Auto Buy / Auto Stacker / Ward Helper / MMR Tracker | — |
| Per-hero auto-features (Sniper Auto Grenade, etc.) | Conditional disable of baseline auto-fire when our combo needs it |

If a baseline behavior is **demonstrably wrong** for a hero (not just suboptimal), the brain can issue a corrective order to override — but never tries to *prevent* the baseline order (API doesn't support cancellation).

What we explicitly **don't** rebuild: framework-global subsystems (ward tracking, smoke detection, Dodger, Auto Buy, MMR Tracker — see Base subsystems), HUD/visual indicators (deliberately out of scope), per-hero baseline behaviors that work fine.

## Base subsystems — already provided by the framework, DO NOT duplicate

The framework ships background subsystems that run alongside hero scripts and expose environment data. The brain **consumes** these, never replicates them. Hero scripts focus on hero-specific decision-making — anything that's pure environmental awareness is likely already a base subsystem.

Confirmed base subsystems (do not build a `lib/` module for these):

- **Ward tracking** — enemy observer/sentry ward detection and placement memory. Brain queries the existing subsystem; never wires its own `OnEntityCreate` filter on ward classes.
- **Smoke of Deceit detection** — enemy-team smoke usage. Brain reacts to the existing signal; never wires its own `modifier_smoke_of_deceit` watcher.
- **Dodger** — reactive Layer-2-style auto-dodge subsystem. Pre-classified danger value per ability stored in `<cheat_dir>/db.json` under `db.dodger.dangerous_values.<ability>.value` (0 = safe, 2 = dangerous), plus `db.dodger.dodges_values.*` (abilities usable as dodge sources like Lifestealer Rage/Infest), plus `db.dodger.global_priority.<n>` (ordered priority). Brain consumes the Dodger's behavior; **`lib/defense.lua` chains *after* Dodger fires** (Pike-out → Force-out → Glimmer after Dodger evaded the initial threat). Do not duplicate the danger classification.
- **Dormancy timestamp tracker** — `<cheat_dir>/db.json` has `db.__dormant_time_cache.<entity_id>: <timestamp>` for last-seen dormancy per entity, persisted across sessions. `lib/fog.lua` should read this cache rather than build a parallel state from `OnSetDormant`. The `OnSetDormant` callback is still useful for *real-time* reactions; the cache provides *historical* state.
- **Auto-pick / Auto-ban** — pre-game hero selection automation (`db.auto_pick.*` keys). Not brain-side.
- **MMR tracker** — `db.mmr_tracker.last_pts` + steamid. Already a feature.
- **Pro-shop / pro-build tracker** — `db.protracker_shop.npc_dota_hero_*` per-hero pro item-build cache. Strongly suggests our planned `lib/build.lua` is a base-subsystem duplication; verify before any extraction.
- **Domain tracker** — `db.protracker_domain.last_used_domain_idx`. Pre-game / lobby feature.

**Likely base subsystems (verify before extracting any module that overlaps):**

- Roshan timer / aegis tracker
- Rune timer + spawn predictions
- Lane creep wave / equilibrium
- Auto-TP-out under threat thresholds
- ~~Item-build / quick-buy automation~~ → **confirmed via `db.protracker_shop.*` — base subsystem.** Don't build `lib/build.lua`.
- Hero-grid switching by matchup

## Framework state files (read-only from our perspective)

Beyond `assets/data/*.json` (game data), the framework writes per-installation state to:

- **`<cheat_dir>/db.json`** — flat dot-notation KV store. Per-feature persistent state including Dodger danger values, dormancy timestamps, MMR tracker, auto-pick lists, hero-script caches (`db.<HeroName>.<cache_key>`). **The native hero scripts persist their per-hero runtime state here** under namespaced keys (`db.Morphling.cache_*`, `db.invoker.invoker_cold_snap`, `db.rubick.*`, `db.stealer.*`, `db.kunkka_camps`, `db.meepo.pos`, etc.). **Our brain scripts should persist runtime state to `db.json` using the same `db.<Hero>.*` namespacing convention**, beyond what `CMenuBind` widget state and `Config.Read*`/`Write*` handle.
- **`<cheat_dir>/local_cache.json`** — minimal server-region preference (`{"server": {"de": 0}}`). Not brain-relevant.
- **`<cheat_dir>/inventory.json`** — player cosmetic-item inventory cache mapping Steam item IDs → `[hero_id, slot_index, style_index, is_equipped]`. Cosmetics don't affect gameplay; not brain-relevant.
- **`<cheat_dir>/dota.be`** — opaque encrypted binary (~19 MB, no readable magic). Framework's internal runtime cache. Not brain-readable, not brain-relevant.

When Phase 1 of `TIER2_PROMPT.md` runs, the very first check is: **does the framework already provide this as a base subsystem?** If yes, abort the extraction and consume the existing API. The brain reads from what's there; it doesn't rebuild infrastructure.

How to discover existing subsystems: check the framework's loaded-script list (UI), look for documented APIs that look like read-only state queries (e.g., if there's an `EnemyWards.GetAll()` or `Roshan.GetRespawnTime()` in the docs, the subsystem already exists). When in doubt, ask before building.

## Shared library plan — `lib/` — three tiers

The framework provides primitives, not subsystems. We build a thin layer. **Build only what's earned**, in three tiers based on universality.

### Tier 1 — Built day one (used by every hero brain in augmentation mode)

Built before any hero work begins, via **`TIER1_BOOTSTRAP.md`**. Pure infrastructure — no brain logic, no hero research. Four modules under augmentation (was five under replacement; `lib/item.lua` demoted to Tier 2 because the baseline's Items Usage handles most cases).

| Module | Purpose |
|---|---|
| `lib/order.lua` | Single chokepoint for `Player.PrepareUnitOrders`. Identifier discipline (`<hero>-<layer>-<intent>`), `Humanizer.GetOrderQueue()` pre-check that includes detecting baseline's own pending orders to avoid duplication, double-stack guard, fail-loud on untagged orders. Every brain issues orders through this. |
| `lib/damage.lua` | Damage feed normalizer. Abstracts Stage 2 ON (`OnEntityHurt`) vs OFF (polling + projectile prediction + DoT estimation). Hero code reads `Damage.GetRecentDamage(npc, window)` without knowing which path is live. Feeds Layer 2 follow-up-chain triggers. |
| `lib/anim.lua` | Animation→ability map dispatcher. Heroes register per-matchup maps (now populated from `npc_abilities.json` `AbilityCastAnimation` field — no demo observation needed); dispatcher routes raw `OnUnitAnimation` into semantic events ("gap_close" / "hard_disable" / "ult_burst") for anti-dodge precognition and pre-emptive defensive triggers. |
| `lib/target.lua` | Predicate helpers used by every Phase 2 override rule. **No `Pick()` function — baseline Target Selection does the picking.** Brain uses predicates to *validate* the baseline's choice or to evaluate specific override candidates. `IsValid`, `IsAlive`, `IsEnemyHero` (uses `Entity.IsSameTeam`), `IsAllyHero`, `NotIllusion`, `NotMeepoClone`, `InRange`, `IsKillable`, `IsLinkensProtected` (wraps `NPC.IsLinkensProtected`), `IsMirrorProtected`, `HasAegis`, `HasState`, `WillBeInvulnIn`, `IsSafeTarget` (wraps `Humanizer.IsSafeTarget`), `EffectiveHpVs` (composes armor mult + magic resist + bonus damage stack). Heroes compose inline. |

These four are universal. Built once, tested in demo, forgotten.

### Tier 2 — Extracted when a second hero validates the pattern (shared mechanism, per-hero data)

Built one-at-a-time via **`TIER2_PROMPT.md`** template when the same mechanism appears in two hero brains. The mechanism becomes a `lib/` module; the data stays per-hero. Under augmentation the catalog is **much smaller** than under replacement — most baseline-overlapping modules are dropped. ~9 candidates remain.

#### Brain-side combat & cast logic

| Module | Shared mechanism | Per-hero data |
|---|---|---|
| `lib/threat.lua` | "Can-kill-me in N seconds" scanner; subscribes to damage/anim/projectile feeds, ranks per-target threat. **Two-channel projectile detection:** subscribe to `OnProjectile`/`OnLinearProjectileCreate` (event-driven) AND poll `TargetProjectiles.GetAll()` / `LinearProjectiles.GetAll()` each tick (recovery-aware). Robust to brain reloads. **Accepts `team` parameter — same module serves enemy-threat (default) and friendly-threat (save-hero ally scanning).** | Thresholds, which signals this hero cares about, which team to scan |
| `lib/defense.lua` | Layer 2 chain executor with 0.8s reaction-window discipline between self-casts. **Chains AFTER the framework Dodger fires** — read `db.dodger.dangerous_values.<ability>.value` to know what Dodger considers dangerous; don't duplicate the classification. Our chain handles post-evade survival (Pike-out → Force-out → Glimmer) that Dodger doesn't ladder. | Hero-specific ordered list of qualifying items/abilities + per-step `when()` predicates |
| `lib/timing.lua` | Cast-point + projectile travel + impact-tick math. Pairs with `prediction.lua`; feeds anti-dodge precognition (predict target state at impact, abort cast if invuln window opens in flight). | Per-ability parameters fed in |
| `lib/prediction.lua` | Skillshot lead math (target velocity + cast point + proj speed → impact pos). Foundational for any predictive override (Mirana arrow, Pudge hook, Skywrath ult, Storm ball-lightning, Sniper Assassinate at predicted target). | Per-ability confidence thresholds, abort conditions |
| `lib/ability_dmg.lua` | Estimated damage from MY ability against a target: `Ability.GetDamage` / `GetLevelSpecialValueFor` × `NPC.GetBaseSpellAmp` × bonus-amp modifiers (`Enum.ModifierFunction.MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE`). Pairs with `target.lua`'s `EffectiveHpVs` for kill-confirm in combo-sequencing overrides. | Per-hero stack-based damage extensions (Lina passive, Slark essence shift, OD Arcane Orb), per-ability special-value name |
| `lib/defense.lua` | **Defensive follow-up chain — always-on, no key, no user activation.** Fires AFTER the framework Dodger has done its work. Reads `db.dodger.dangerous_values.<ability>.value` for classifications; never duplicates them. Executes hero's ordered list of qualifying self-cast items/abilities (Force, Pike, Glimmer, Eul, BKB, Lotus on self, Aeon, plus hero-specific defensive abilities like Bristleback turn / PA Blur / Treant Living Armor self / Necro Ghost Shroud) with 0.8s reaction-window discipline. Aborts when threat clears. **The defensive layer is the project's default behavior — never gated behind a hotkey.** | Hero-specific ordered list + per-step `when()` predicates. Heroes that share the same chain shape graduate to extraction. |
| `lib/threat.lua` | Layer 2 follow-up trigger — "I'm taking damage Dodger didn't fully neutralize, defensive chain should fire." Subscribes to `OnEntityHurt`/`OnUnitAnimation`/`OnProjectile`. Two-channel detection (callback + poll via `TargetProjectiles.GetAll()`/`LinearProjectiles.GetAll()`) for robustness to brain reloads. | Per-hero threshold for "chain should fire," which signals matter for this hero |

#### Brain-side awareness

| Module | Shared mechanism | Per-hero data |
|---|---|---|
| `lib/self.lua` | Self-state aggregator: HP%/mana%/CC-on-self/combo-ready/vulnerable. Used by combo override predicates and defensive chain triggers. | Combo-readiness thresholds per hero |

#### Brain-side infrastructure

| Module | Shared mechanism | Per-hero data |
|---|---|---|
| `lib/data.lua` | **Lazy-loaded** cache over the five `C:\Umbrella\assets\data\*.json` files. Exposes `Data.Ability(name)`, `Data.Hero(unit_name)`, `Data.Unit(unit_name)`, `Data.Item(name)`, `Data.Neutral(tier)` returning parsed KV tables. Single parse per file via `io.open` + `JSON:decode` from Friedl's pure-Lua `JSON.lua` (loaded as `require('assets.JSON')`). **Lazy is mandatory** — parsing `npc_abilities.json` (1.4 MB) via pure Lua costs ~300-1000 ms. Cross-script cache via `_G.HeroBrains.data`. **High-leverage** — eliminates KV-name guessing for damage scaling, lookup of `AbilityCastAnimation` for animation map, recipe components for item-build verification, lane creep base stats for last-hit-related decisions. | Per-hero list of which data files to pre-load on init |
| `lib/signal.lua` | Formalizes `_G.HeroBrains` global table — signals/threats/intents pub-sub for cross-hero coordination. | Per-hero subscriptions and publications |
| `lib/menu.lua` | Hero menu factory: Tab → Section → key-binds for Layer 1 aggressive combos (combo, alt-combo, push-clear, save-ally, anti-channel) + single toggle for Layer 2 defensive layer enable/disable (default ON, no per-step keys) + threshold sliders. | Per-hero combo names, threshold slider ranges |
| `lib/item.lua` (demoted from Tier 1) | Item state queries — `HasReady`/`HasAnyReady`/`CooldownRemaining`/`GetCharges`. Mostly redundant with baseline Items Usage; needed only where the brain inspects item state directly (e.g., "is my Refresher ready before I commit a multi-spell combo?"). | — |

#### Dropped from previous catalog (baseline handles)

| Module | Why dropped |
|---|---|
| ~~`lib/combo.lua`~~ | Baseline Hero Settings + Items Settings handles routine combo firing |
| ~~`lib/killsecure.lua`~~ | Baseline Kill Stealer |
| ~~`lib/target_pick.lua`~~ | Baseline Target Selection (Style modes, Search Range, Include Units, Unsafe Selection) |
| ~~`lib/orbwalk.lua`~~ | Baseline Orb Walker |
| ~~`lib/hitrun.lua`~~ | Baseline Hit & Run (kiting, keep-distance, move-style, can't-attack-fallback) |
| ~~`lib/units.lua`~~ | Baseline Units Controller (multi-unit support) |
| ~~`lib/linkens.lua`~~ | Baseline Linkbreaker Items (per-hero popper list configured in `gui.json`) |
| ~~`lib/support.lua`~~ | Baseline Support Settings (4-condition ally predicates) |
| ~~`lib/build.lua`~~ | Framework Auto Buy + `db.protracker_shop.*` |
| ~~`lib/escape.lua`~~ | Baseline Hit & Run includes flee patterns; brain adds path-aware override inline only if needed |
| ~~`lib/tp.lua`~~ | Likely baseline; verify per-hero |
| ~~`lib/fog.lua`~~ | `Hero.GetLastMaphackPos` + `db.__dormant_time_cache.*` is sufficient; no wrapper needed |
| ~~`lib/phase.lua`~~ | Inline `GameRules.GetGameTime()` thresholding in heroes; not enough scope for a module |
| ~~`lib/lane.lua`~~ | Likely baseline (laning isn't the brain's leverage point) |
| ~~`lib/roshan.lua`~~ | Likely baseline |
| ~~`lib/rune.lua`~~ | Likely baseline |
| ~~`lib/event.lua`~~ | Inline `OnFireEventClient` subscriptions per hero; rarely needed |
| ~~`lib/consumables.lua`~~ | Baseline Items Usage handles Tango/Salve/Faerie via Items Conditions HP gates |
| ~~`lib/log.lua`~~ | `Log.Write` direct usage is fine; no per-hero verbosity wrapper needed yet |
| ~~`lib/mod.lua`~~ | Modifier-read-cache is a perf optimization to defer until profile shows a hit |
| ~~`lib/config.lua`~~ | `CMenuBind` widget auto-persistence + direct writes to `db.<HeroName>.<key>` cover persistence needs |

**The 3-use threshold means "two heroes whose inline code is already near-identical," not "two heroes solving similar-looking problems."** Resist extracting until the mechanism is genuinely shared. First hero inlines. Second hero matches → extract. Third hero confirms by adopting cleanly.

### Tier 3 — Stays inline (too hero-specific to share)

These never become full `lib/` modules. The *building-block predicates* may live in `lib/` as helpers (`IsValid`, `IsAlive`, `NotIllusion`, `InRange`, `EffectiveHpAfter`, `LinkensProtected` — composed by heroes inline), but no monolithic shared function.

| What | Why per-hero |
|---|---|
| Target picking | "Best target for Sniper" ≠ "best target for Pudge" ≠ "best target for Wisp" (an *ally*) ≠ "best target for Meepo" (different per clone). No single picker works. |
| Skill sequencing | Definitionally hero-specific — Phase 0.5/A output. |
| Combo viability predicates | Per-hero combo specs from Phase 2. |
| Item-build priority | Per-hero meta. |

### Workflow

1. **Before any hero:** run `TIER1_BOOTSTRAP.md` → produces `lib/order.lua`, `lib/damage.lua`, `lib/anim.lua`. One conversation, ~3-5 hours of focused infrastructure work.
2. **First hero:** uses Tier 1 modules. Everything else inline. Note where logic feels obviously universal but resist extraction.
3. **Second hero:** uses Tier 1. Where a pattern matches the first hero's inline code exactly, run `TIER2_PROMPT.md` with `{MODULE_NAME}` filled in → extract to `lib/`. Both heroes refactor to call the new module.
4. **Third hero onward:** `lib/` grows slowly. Most extractions happen by hero 10. After that, additions are rare.

## Cross-hero coordination — Lua global pattern

No framework script-to-script messaging. Use a single global table:

```lua
_G.HeroBrains = _G.HeroBrains or {
  signals  = {},  -- ring buffer of recent cross-hero events
  threats  = {},  -- shared threat assessments  
  intents  = {}, -- declared upcoming actions (e.g., "sniper-assassinate-imminent")
}
```

Hero scripts publish to `signals`/`intents`, read from `threats`. Document the schema in this file once 3+ heroes use it. Until then, ad-hoc.

## Additional framework primitives worth knowing

- **`GridNav.BuildPath(start, end, ignoreTrees, npc_map)`** + **`CreateNpcMap`** — A* pathing. Layer 2 escape planning ranks candidate destinations and force-pushes self *toward the best path*, not just any direction.
- **`GridNav.IsTraversableFromTo(a, b, ignoreTrees, npc_map)`** — cheap line-of-traversal check without full path. Use before committing a combo to confirm target is actually reachable.
- **`FogOfWar.IsPointVisible(pos)`** — direct vision check at any world point. Cleaner than reasoning from per-entity `IsVisible` for non-hero objects (wards, neutral camps, dropped items).
- **`World.GetGroundZ(x, y)`** — synthesize valid 3D vectors from 2D plans without Z-snap issues.
- **`Event.AddListener(name)`** — custom game-event subscription. Stage 2 required.
- **`Engine.SetQuickBuy(item_name, reset)`** — programmatic item-build push. Drive from Phase 0 Stratz reference (median item timings this patch).
- **`OnProjectile` / `OnLinearProjectileCreate`** (always available, no Stage 2 gate) — often a *better* trigger than animation for incoming enemy spells. Projectile carries explicit source + target + impact-time. Use these as primary; animation as fallback for instant-cast or channeled abilities.
- **`Particle.OnParticleCreate`** with particle name string — some enemy abilities are most reliably detected by particle signature (Bloodseeker Rupture, Doom ult cast, Roshan aggro). Per-matchup `notes.md` should list particle signatures for hard-to-detect casts alongside the animation→ability map.
- **`Modifier`** introspection: `GetStackCount`, `GetRemainingTime`, `GetDuration`, `GetAbility` (the ability that applied it), `GetCaster`, aura inspection. Combo timing reads remaining-debuff-time directly instead of guessing.
- **`Ability.GetLevelSpecialValueFor(name, level)`** — read ability KV values (damage, slow %, etc.) at current level. Don't hardcode.
- **`Chronos`** — sub-tick timing if needed. `GlobalVars.GetCurTime` is usually enough.
- **`Tracy`** — profiling instrumentation if per-tick CPU budget gets tight.

## API reference

The canonical raw-API source is `C:\Users\arcos\uczone-api-v2.0`. The **curated brain-task-organized reference** is **`API_REFERENCE.md`** at project root.

The VS Code extension that powers in-editor autocomplete (`ILKA.umbrella-vscode`) is documented at **`C:\Users\arcos\uczone-api-v2.0\UMBRELLA_VSCODE_EXTENSION.md`** — installation, runtime behavior, library coverage, configuration, preprocessor, troubleshooting, and reusable per-project `.vscode/settings.json` baseline. That doc lives alongside the raw API so any future UCZone project can reference it.

`API_REFERENCE.md` covers:
- Curated subsets of the big enums (`ModifierState` 64 entries → ~25 relevant; `ModifierFunction` 175 entries → ~22 relevant; `UnitOrder` 41 entries → all relevant with field requirements; `AbilityBehavior`, `DispellableTypes`, `DamageTypes`, `ImmunityTypes`)
- The four channels for enemy-intent detection (animation, projectile, particle, modifier) with latency/confidence tradeoffs
- Damage-calc order of operations
- Dota-mechanic gotchas the API exposes primitives for but doesn't explain (Linkens cooldown, Lotus reflection rules, magic vs debuff immunity, dispel categories, Aegis interaction, Refresher refresh timing, illusion/clone identification)
- Animation activity reference seed (universal codes + per-hero discovery method)
- Brain-task → API quick index

The Umbrella VS Code extension (`ILKA.umbrella-vscode`) covers the in-editor autocomplete side. `API_REFERENCE.md` is the equivalent for working outside the editor.

## UCZone API quick reference for brain work

| Need | Call |
|---|---|
| State / immunity duration at impact | `NPC.GetStatesDuration({STATE_INVULNERABLE=true, STATE_MAGIC_IMMUNE=true, ...})` |
| Aggregated modifier property | `NPC.GetModifierProperty(npc, Enum.ModifierFunction.X)` |
| Batch modifier check | `NPC.HasAnyModifier(npc, {mod_a=true, mod_b=true})` |
| Fog last-known position | `Hero.GetLastMaphackPos(hero)` + `GetLastVisibleTime(hero)` |
| Attack timing | `NPC.GetAttackAnimPoint`, `GetAttackProjectileSpeed`, `GetSecondsPerAttack` |
| Projectile spawn | `NPC.GetAttachment(npc, "attach_hitloc")` |
| Damage-vs-target math | `NPC.GetArmorDamageMultiplier`, `GetMagicalArmorDamageMultiplier`, `GetPhysicalDamageReduction` |
| Issue order with tag | `Player.PrepareUnitOrders(..., identifier="...", callback=true)` (note: `callback` on this function, `push` on `AttackTarget`/`HoldPosition`) |
| Read pending orders | `Humanizer.GetOrderQueue()` |
| Damage / kill feed (typed) | `OnEntityHurt`, `OnEntityKilled` |
| Enemy cast intent | `OnUnitAnimation` |
| Fog dormancy tracking | `OnSetDormant(npc, type)` |
| Hero list / radius | `Heroes.InRadius(pos, radius, teamNum, teamType, omitIllusions, omitDormant)` |

## Hard-won lessons from Sniper v6.x (2026-05-11)

The first hero brain (Sniper) surfaced several pitfalls that apply across every hero. Document them here so each new hero brain consumes them upfront rather than rediscovering them.

### Cross-check Liquipedia for save-relevant values
The on-disk `npc_abilities.json` / `items.json` / `npc_heroes.json` are reliable for ability VALUES but unreliable for:
- **Base kit vs shard/scepter-granted.** `npc_heroes.json` lists every ability slot, but a slot may be empty (unlearned, level 0) without the Aghs Shard / Scepter that grants it. Example confirmed in 7.41C: `sniper_concussive_grenade` is `Ability4` in the KV but is **shard-only**. `IsGrantedByShard: 1` on the ability KV is the truth signal.
- **Patch-edge item values.** The 7.41 patch reduced Hurricane Pike enemy cast range and push from 450 → 425; `items.json` may still show the old value. Cross-check Liquipedia for every save-relevant item (Pike, Force, Eul, Wind Waker, BKB, Lotus, Manta, Glimmer, Aeon, Blink variants, Ghost, Crimson Guard, Blade Mail, Solar Crest, Pipe of Insight, Satanic, Disperser, Diffusal). The 2026-05-11 audit found ~10 discrepancies including: **Eternal Shroud was removed entirely in 7.41**, Arcane Blink push was 1200→1400, Wind Waker CD was 60s→19s (tier was wrong), Blade Mail CD was 16s→25s (tier was wrong), Razor Static Link tether 900→800, Lion Mana Drain tether 850→1000, WD Death Ward tether 1100→650.

### `Ability.IsReady` returns true for unlearned abilities
`NPC.GetAbility(npc, "name")` returns a handle if the slot exists in the hero's `Ability1..6` list, **even if the ability is unlearned** (level 0 — common for shard-granted abilities when shard isn't owned). `Ability.IsReady` on that handle returns `true` (no CD on unlearned). The brain dispatches a cast, Humanizer accepts the order, the chain reports success, and the in-game cast silently fails. **Always gate on `Ability.GetLevel(a) > 0`** in any custom `ability_ready` helper. This is the v6.2 root cause of "Pike doesn't fire without shard."

### Chain order beats runtime cross-save dedup
For threats where two saves are both viable (Pike + grenade vs Bara Charge), put the preferred save **first in the override list**. The chain stops at the first successful fire, so the second save is never considered. Runtime checks like "is the other save pending?" are race-prone: brain fires first, baseline queues a different save a tick later, and the dedup check fired too early. Chain order is structural and eliminates the race.

### Brain Layer 2 must pre-empt baseline for the preferred save
Baseline framework subsystems (Linkbreaker, Items Manager, framework Dodger) fire saves independently. If both brain and baseline want to fire Pike on Bara, the only reliable way to enforce "only one Pike" is to make brain fire Pike FIRST — baseline then finds Pike on CD and can't fire its own. This requires **firing at the moment the preferred save becomes viable** (e.g., when Bara enters Pike's 425u range), not at a generic `eta_trigger`. Use a two-stage trigger pattern in `armed_threats_tick`:
1. Fire immediately when preferred save is in range and ready.
2. At `eta_trigger`, if preferred save will be in range within `eta_speed * 0.15`, defer; else fire chain.
3. Safety net at `eta <= 0.35s` force-fires regardless.

### Self-displacement is useless against homing threats
For homing close_gap threats (Bara, Tusk Snowball), the charger re-targets. `grenade_self` / `Pike-on-self` / `Force-on-self` consume the save CD without breaking the threat. **Remove these from the override chain** for close_gap homing categories; for Pike, the fire entry should refuse the self-fallback for close_gap and let the chain fall through to in-range alternatives.

### Pike pushes radially outward; Force pushes target's facing
- **Hurricane Pike** — both caster and target pushed **radially outward from each other**. Pike-on-Pudge during Dismember pushes Pudge directly away from Sniper. Reliably breaks tethers within Pike's push magnitude.
- **Force Staff** — pushes target in **target's facing**. A unit channeling toward Sniper gets pushed **toward** Sniper (bad). Force-on-self pushes Sniper in Sniper's facing.

Don't confuse the two. Earlier brain code had these swapped, leading to wrong chain ordering against tether channels.

### Fire-closure success != in-game cast success
A SAVE_FIRE closure returning `true` means the order was queued via Humanizer, not that the engine accepted it. Out-of-range, unlearned, silenced, or channeling-locked casts silently fail. The chain has no callback for "did this cast resolve." Design the chain so range gates are correct (don't queue Pike-on-enemy at 450u when Pike's cast range is 425u — that "fires" successfully from the chain's POV but the engine rejects it, and the chain has already stopped).

### Each save closure must document its cast geometry
Inline-comment every hero-specific save closure with:
- Cast mode: target-cast (auto-orient), self-cast (uses caster's facing), or position-cast (cast point geometry).
- Push direction: target-relative, caster-relative, or radial-from-cast-point.
- Push magnitude in units.

Wrong-geometry assumptions caused multiple Sniper revisions (v5.3-v5.7 on grenade-at-caster cast point, v6.4-v6.6 on Pike direction). A comment is cheaper than a version bump.

### Threat coverage extrapolation (2026-05-11 audit)
The original Sniper override covered ~22 threats. The 2026-05-11 extrapolation pass added ~14 more that fit existing categories: Magnus Skewer / Reverse Polarity, Sven Storm Bolt, Shadow Shaman Voodoo (Hex), Zeus Lightning Bolt / Thundergod's Wrath, Tide Hunter Ravage, Earthshaker Echo Slam, Disruptor Static Storm, Treant Overgrowth, Earth Spirit Rolling Boulder, Lifestealer Open Wounds, Pugna Life Drain. Modifier names marked `(verify)` in `lib/threat_data.lua` need empirical confirmation via `:FindAllModifiers()` print in a bot match before relying on the exact suffix.

Pitfalls flagged during extrapolation:
- **Magnus Skewer timing** = `pre_cast`, not `at_impact`. Once grabbed, perp-displacement is useless.
- **Reverse Polarity radius = 1700u** — only Blink (1200/1400) reliably escapes; Pike (425) / Force (600) fail.
- **Bristleback / Troll Battle Trance** — buffs on the enemy, not debuffs on Sniper. `OnModifierCreate`-on-self won't catch them. Need a separate "enemy-buff observed" entry point.
- **Bloodseeker Rupture** — punish-movement debuff; doesn't fit the save-on-cast model. Don't add.

## Hard-won lessons from Sniper v6.7–v6.12 (combo system)

After the defensive layer stabilized at v6.7 (see prior section), the offensive layer iterated through v6.8 → v6.12 to nail down the combo / sequence dispatch pattern. The architecture is now durable; full spec lives in `COMBO_PATTERN.md`. Critical additional discoveries since v6.6:

### Architecture

- **Two-table model: COMBOS vs SEQUENCES.** COMBOS are R-spending commitments gated by `commit_pred` (kill-grade / setup-killable / stack-killable / channeling). SEQUENCES are opportunistic no-R paths gated by `trigger`. Single combo key dispatches both — COMBO wins if any clears `COMBO_COMMIT_FLOOR = 100`; else best SEQUENCE fires.
- **Per-tick context (`build_layer1_ctx`).** Compute target state ONCE per dispatch and pass to every closure. ~20 fields including kill-predicate flags, position state, kiting/channeling, escape window, BKB status, ally-CC-lock.
- **Step schema with `delay_s` + step-level `cond`.** A combo's steps are a flat list; conditional follow-ups (Q stacking) live as `cond=function(c)...` closures. Delayed steps go through `pending_steps_tick` with live arg/cond re-evaluation at fire time. Critical for multi-step combos where target moves between steps.
- **Top-K candidate iteration.** `layer1_tick` evaluates COMBOS and SEQUENCES against `state.candidates[1..K=3]` and picks the best (target, path) pair. Solves "kill-grade target X AND fleeing target Y both viable" — old single-candidate dispatch missed Y entirely.
- **Commit window (`LAYER1_COMMIT_WINDOW = 2.5s`).** After a dispatch fires, suppress re-dispatch for 2.5s. Prevents per-frame re-evaluation while combo executes. Without it: 8000+ dispatches per held-key match.
- **R-cast abort (`r_abort_tick`).** Monitor `Ability.IsInAbilityPhase(R)` each tick; if target dispels / dies / Manta-pops, issue `DOTA_UNIT_ORDER_STOP`. **Engine refunds mana + no CD** (CD starts on cast completion). Saves ~110s per spurious commit.

### Critical bug patterns discovered (must consume on next hero)

- **`Ability.IsReady` returns true for unlearned abilities.** Always gate on `Ability.GetLevel(a) > 0` in any `ability_ready` helper. v6.2 fix.
- **`Hero.GetLastVisibleTime` returns nil for never-fogged heroes.** Treat as fresh visible (`fog_age = 0`). Do NOT veto. v6.8.4 fix — caused 8400+ no-op dispatches before being caught.
- **Step `arg` evaluated at dispatch is stale for delayed steps.** Use step scheduler with live re-evaluation. v6.11 Tier 2 fix.
- **JSON staleness — cross-check Liquipedia.** Items.json / npc_abilities.json values may be patch-old. Confirmed for 7.41C: Pike push 450→425, Eternal Shroud removed, Wind Waker CD 60s→19s, Blade Mail CD 16s→25s. Shard-granted abilities listed in `Ability1..6` slots but actually unlearned without shard. v6.2 / v6.7 fix.
- **Baseline framework has separate per-hero subsystem.** "Sniper v2" tree in gui.json with own combo hotkey + 90 config entries. Brain's combo_key bind must align (read from gui.json key code, e.g. 318 for Sniper).
- **CMenuBind stores raw button codes (e.g. 317/318), not Enum.ButtonCode (e.g. 123).** Different code spaces. Read gui.json for stored values.
- **Single-target dispatch (`top_candidate` alone) misses concurrent opportunities.** Iterate top-K.
- **DPS estimate without item procs + Headshot under-estimates kill budget.** Brain over-refuses commits. Include Daedalus/Crystalys (crit mult), Maelstrom/Mjollnir/Brooch (magic procs), Skadi (cold flat), Headshot 40%/100%.

### Anti-combos to suppress in `commit_pred`

- R into BKB / Manta / Aeon-active (`bkb_active` check).
- R into target with ready escape item that'll pop during cast (`escape_window in {"ready","soon"}`).
- D-using combos when target stunned + ally near (`ally_cc_lock` — don't drag out of ally chain).
- R-fish on full-HP carries (gate on kill-grade / setup-killable / stack-killable, not just "killable").
- R on far chip targets without follow-up (far bonus requires kills_with_R OR ally_near OR `d ≤ 1500`).

### Diagnostic methodology

- **Multi-level verbosity (1/2/3).** v1 = dispatch + no-path. v2 = scoring traces (combo_scores / sequence_scores with winner + runner + skipped + ctx_flags). v3 = step-by-step.
- **No-op events include scan stats.** When brain decides nothing, the log says WHY: `scan_in_range`, `scan_scored`, `scan_vetoed`, `vetoed_sample` (first 3 hero names), `top`, `score`, `reason`.
- **Throttle high-frequency logs.** `layer1_no_path` rate-limited to 1Hz; otherwise per-frame events flood the log to 100k+ entries per match.
- **R-abort traces.** v1 log `r_abort | target | reason | combo` on every successful mid-cast cancel.

### What stays per-hero vs lib (combo side)

**Per-hero forever:** `<HERO>_COMBOS` table, `<HERO>_SEQUENCES` table, hero-specific step `arg_fn` closures (cast geometry helpers), `ScoreUltTarget` (per-hero target valuation), the Layer 1 dispatcher body, the per-matchup anim map, hero-specific item-proc DPS estimation.

**Ready for `lib/combat.lua` extraction when hero #2 lands** (two-hero rule): step scheduler (`schedule_step`, `pending_steps_tick`), `fire_steps`, top-K iteration loop, generic R-abort tick, the dispatch skeleton (build_ctx → score COMBOS → score SEQUENCES → fire).

**Already in lib (`lib/target.lua`):** `HasReadyEscapeItem`, `IsKitingUs`, `IsRightClicking`, `EscapeItemWindowState` (windowed v6.12), `HasReadyLinkens`, `HasReadyLotus`, `HasAegis`, `WillBeInvulnIn`, `EffectiveHpVs`.

See `COMBO_PATTERN.md` for the full architecture, schemas, scoring patterns, and a 15-item "hard-won lessons" list.

## Constraints (apply across all heroes)

- Replacement by default; baseline disabled in UCZone UI. Pure companion-sidecar is not viable on UCZone (orders bypass `OnPrepareUnitOrders` with `callback=false` default; no queued-order-cancel API).
- Stage 2 ON is the project default. Document the polling fallback in `notes.md` if OFF.
- `OnUnitAnimation` routes through the per-matchup animation→ability map (Phase 0.5/D output) — never act on a raw activity number.
- **Vector math in hot paths uses zero-allocation methods.** `OnUpdateEx` runs at ~30Hz with potentially dozens of vector ops per call. Prefer `v:AddInPlace` / `v:Extend2D` / `v:DistanceSqr2D` / `v:IsInRange2D` / `v:Clone` over operator metamethods (which allocate new vectors per call). The operator forms (`a + b`, `a * 2`) are marked `@deprecated` in the LuaCATS library for this reason.
- **Particle matching uses integer IDs**, not strings. Use `Utils.ResourceIdFromName(path)` at registration time and compare `data.particleNameIndex` integers in `OnParticleCreate`. String comparison on every particle is wasteful given firehose rate.
- No menu options for decisions the brain should make automatically.
- No hardcoded hero/item/modifier name tables that the API can read directly. Exception: ability/item names are strings the API takes — those are fine.
- No high-cost casts on fog data older than 3 seconds.
- Tag every order with identifier; route through `OnPrepareUnitOrders` for sanity-check.
- Mana budget enforced on every aggressive cast.
- Aggressive layer: key-activated, integrates defensive items as combo steps.
- Defensive layer: always-on, no key, can fire mid-combo if threat detected.
- No new abstractions unless used 3+ times.
- No comments explaining WHAT the code does. Only comments explaining non-obvious WHY (cite pro pattern, API edge case, hero-specific quirk).

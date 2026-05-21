# lib/ — changelog

## threat_data.lua — SAVE_PUSH_DISTANCE KV-derivation — 2026-05-20 (v6.15.208)

KV-generalization initiative. `SAVE_PUSH_DISTANCE`'s six item entries
(Pike / Force Staff / the four Blink variants) were hand-literal values
that duplicated `item_data.SAVE_GEOMETRY` — the generated table whose
docstring explicitly designates it as the grounding source for
`SAVE_PUSH_DISTANCE`. Duplication is drift risk.

`threat_data.lua` now `require`s `lib.item_data` and derives the six via
a new `sg(name, field, fallback)` helper: displacement items take
`enemy_push`, blink items take `range`. Each call carries the prior
literal as a patch-stable fallback (used only if `SAVE_GEOMETRY` ever
drops the item). `grenade_self` stays literal — it is a Sniper ability
(`npc_abilities` KV), not an item, so `SAVE_GEOMETRY` has no entry.

`item_data` is a pure data module that requires nothing back, so the new
`require` introduces no cycle and no load-order risk. Runtime-verified
outside the game: all six derive to 425 / 600 / 1200 / 1200 / 1400 /
1200, `grenade_self` unchanged at 475 — behaviour-neutral. Also fixed
two stale `500u` Pike references in the module docstring (drift). Deploy
lib-only; brain unchanged at v6.15.208.

## threat_data.lua — Axe Berserker's Call comment alignment (D5) — 2026-05-20

Round-3 audit's D5 finding: the catalog had three entries for
`modifier_axe_berserkers_call` whose comments contradicted reality.
THREAT_COUNTER's "BKB or Blade Mail (forced attacks return damage)" and
RECOMMENDED_SAVES's "BKB ignores taunt; Blade Mail returns forced-attack
damage" both imply effective counters — but Berserker's Call PIERCES
spell immunity (so BKB does nothing), and Blade Mail returns Sniper's
own armor-mitigated attack damage at FULL strength against Sniper's
armor (a net loss). The authoritative entry is THREATS_ON_SELF
`save="informational"`, which the v6.15.202 (round-3 D1) dispatcher
catch-all correctly no-ops on.

Updated comments in THREAT_COUNTER and RECOMMENDED_SAVES to explain
why neither item actually counters, and to note that the dispatcher
already skips these (informational save) — the catalog entries are
documentation / future-use only. No data change; deploy lib-only.

D15 (the audit-proposed `(verify)`-tag cleanup for 10 modifier names)
was found to be misframed on inspection: the 10 harvest-confirmed
names were added to the catalog in v6.15.198 already tagged
"harvested" (not "(verify)"), and the 41 actual `(verify)`-tagged
entries are on heroes that haven't appeared in any modseen log yet
(Earth Shaker, Magnus, Zeus, Pugna, Tide, Treant, Sven, Shadow
Shaman, Kez, Disruptor, Life Stealer). No removals applicable at
this time.

## threat_data.lua — bot-match harvest (13 modifier names) — 2026-05-20

Three bot matches across v6.15.194-.197 surfaced 13 `(verify)`-class
modifier names via `threat_unrecognized`. All are HARVESTED (observed in
real logs), not guessed. Added to `THREATS_ON_SELF` so the recognition
loop stops re-flagging them; added 10 `ABILITY_TO_THREAT` lines mapping
the casting ability name to the primary on-Sniper modifier (where one
ability lands multiple modifiers, the primary is the actively-debuffing
one — see Viper Nethertoxin → `_mute` variant, SK Reincarnation →
`_reincarnate_slow` variant).

Most entries carry `save = "informational"` because the user's defensive
chain is now mostly live-API-driven (`NPC.GetChannellingAbility`,
`Target.HasAegis`, etc.) — the catalog's residual job is recognition,
not save dispatch. The two genuine R-blockers get real save mappings:
**`modifier_oracle_fortunes_end_channel_target`** (channel-on-me) and
**`modifier_viper_nethertoxin_mute`** (silence-on-me) both route to
`bkb_or_dispel`.

Per-entry harvest source (match → modifier name → role / save):

| Match | Modifier | Role | Save |
|---|---|---|---|
| .194→.195 | `modifier_phantom_assassin_stiflingdagger` | light_slow | informational |
| .194→.195 | `modifier_drow_ranger_frost_arrows_slow` | kiting_slow | bkb_or_dispel |
| .195→.196 | `modifier_oracle_fortunes_end_channel_target` | channel_on_me | bkb_or_dispel |
| .195→.196 | `modifier_oracle_fortunes_end_purge` | dispel_on_me | informational |
| .195→.196 | `modifier_oracle_purifying_flames` | dot | informational |
| .195→.196 | `modifier_skeleton_king_reincarnate_slow` | aura_slow | informational |
| .195→.196 | `modifier_skeleton_king_reincarnation_spawn_skeletons` | aux | informational |
| .195→.196 | `modifier_viper_corrosive_skin_slow` | attacker_slow | informational |
| .195→.196 | `modifier_viper_nethertoxin` | zone_dot | informational |
| .195→.196 | `modifier_viper_nethertoxin_mute` | silence_on_me | bkb_or_dispel |
| .195→.196 | `modifier_viper_poison_attack_slow` | kiting_slow | bkb_or_dispel |
| .197 | `modifier_necrolyte_heartstopper_aura_effect` | aura_dot | informational |
| .197 | `modifier_vengefulspirit_retribution_tracker` | tracker | informational |

Generic `modifier_stunned` from the .195→.196 harvest is NOT added — it's
already covered by the brain's `MODIFIER_STATE_STUNNED` state checks at
the API layer, and adding it would shadow real hero-specific stuns in
the catalog. Lua syntax-checked + exec-tested (entries load, expected
role/save fields present). Deployed lib-only, no Sniper version bump.

Largest harvest pass since v6.15.162-.164's catalog refresh (~30 names).
Cumulative `threat_data.lua` is now ~95 catalog entries covering the
post-2018 hero pool plus the bot-match harvest tail.

## threat_data.lua — Dismember second modifier — 2026-05-19

Field test showed Pudge Dismember puts TWO modifiers on the victim:
`modifier_pudge_dismember` AND `modifier_pudge_dismember_pull`. The earlier
harvest fix renamed the catalog from the first to the second, so the first
then logged `threat_unrecognized` — harmless (the save still fired off
`_pull`) but noisy and a false harvest signal. Added a load-time loop that
mirrors every `_pull`-keyed table entry onto the bare name, so either
modifier landing is recognised. Deployed lib-only.

## geometry.lua — Distance2D micro-optimisation — 2026-05-19

`dist_between` swapped `(pa - pb):Length2D()` for `pa:Distance2D(pb)`: one
native call instead of a native subtraction (which allocates a throwaway
Vector) plus a length call. Behaviour-neutral — the Sniper brain's
`apicheck_dist` field diagnostic confirmed native `Distance2D` matches the
manual component calc. Deployed with Sniper v6.15.187.

## threat_data.lua — Dismember modifier-name fix — 2026-05-19

Field-test harvest correction. The catalog guessed Pudge Dismember lands
`modifier_pudge_dismember`; an in-game `threat_unrecognized` log showed the
real modifier on the victim is `modifier_pudge_dismember_pull`. With the
wrong name the defense layer never recognised an incoming Dismember, so it
triggered no save. Corrected across all 9 entries (counter kinds, tether
range, `THREATS_ON_SELF`, `ABILITY_TO_THREAT`, category / severity /
timing). Syntax-checked, deployed lib-only.

## hero_data.lua — new KV-data lib — 2026-05-18

New pure-data Tier 2 module. Static hero reference generated from
`C:\Umbrella\assets\data\npc_heroes.json`. Completes the KV-data lib set:
**item / ability / unit / hero**. Surfaced by a maintenance scan for
hardcoded values that mirror Valve KV fields — `npc_heroes.json` was the one
KV file with no lib, so any hero base-stat a brain wants had nowhere to read
it from.

Owns:

- `HEROES` — all 128 heroes, keyed by full unit name (`npc_dota_hero_sniper`):
  `id`, `role`, `complexity`, `abilities` (base kit), `talents`, `facets`,
  `attack_type`, `attack_min` / `attack_max`, `attack_rate`, `attack_point`,
  `attack_range`, `acquisition_range`, `projectile_speed`, `armor`,
  `primary_attribute`, `str_base` / `str_gain` / `agi_base` / `agi_gain` /
  `int_base` / `int_gain`, `move_speed`, `turn_rate`, `vision_day` /
  `vision_night`.
- Pure helpers: `Get`, `HasAbility`, `Talents`, `Facets`,
  `PrimaryAttribute`, `AttributeAt` (base + gain·(level-1)), `AvgAttackDamage`.

All stats are BASE values (level 1, no items/talents). `attack_min/max` is the
white damage before the primary attribute; `armor` is before the agility
bonus. Health and mana are deliberately absent — they derive from
strength/intelligence by per-patch constants, so read them live or compute
from `str_base`/`int_base` with the current patch's multipliers (hardcoding a
HP-per-strength constant would be the exact rot this lib avoids).

Generated by `tools/gen_hero_data.py`. Re-run after a patch.

### Verified

- `lua.exe` syntax check passes (source + deployed copy).
- Helper exec-test: 128 heroes; Sniper id 35, agi primary, 13-19 base attack,
  550 range, 285 move speed, 6 abilities, 8 talents, 2 facets;
  `AttributeAt(sniper, agi, 25)` = 103.8 (27 + 3.2·24); `PrimaryAttribute`,
  `HasAbility`, `AvgAttackDamage` all correct.
- Deployed lib-only — no consuming brain references it yet, no version bump.

## save_select.lua — new threat-vs-save selection lib — 2026-05-18

New pure-logic Tier 2 module. Given a threat (its modifier name) and the save
items a hero has available, it ranks which saves actually counter the threat
and picks the best one. This is the reusable, hero-agnostic version of the
save-selection logic that currently lives inline in the Sniper brain
(`resolve_save_order` / `try_save_self`).

Pure logic — no API calls, no callbacks, no side effects (same discipline as
`threat_data.lua` / `item_data.lua`). The caller decides which save items are
available/ready and passes them in; this module only classifies and ranks.

Bridges the two data libs:

- `threat_data.lua` — `SaveCounters` (does the save's effect counter the
  threat), `WillTetherBreak` (tether geometry), `RecommendedSaves` (the
  hand-tuned per-threat priority), `CategoryOf` / `SeverityOf` / `TimingFor`.
- `item_data.lua` — `SaveGeometry` for the precise per-item cooldown (used as
  a mild tiebreak: a shorter-cooldown save is cheaper to spend).

API:

- `Effective(save, threat_mod, ctx)` — true if the save genuinely neutralises
  the threat: it must counter the effect kind AND, for a tether/channel
  threat, its displacement must clear the tether from `ctx.distance`.
- `ScoreSave(save, threat_mod, ctx)` — heuristic score (nil if the save does
  not counter the threat at all). A counter whose push is too short for a
  tether scores low rather than nil, so the caller still sees it ranked last.
- `RankSaves(threat_mod, available, ctx)` — every available save ranked best
  first, as `{ save, score, reason }` rows.
- `BestSave(threat_mod, available, ctx)` — the single top pick.
- `ThreatBrief(threat_mod)` — bundles the threat's category / severity /
  timing / tether range / recommended list.

`available` accepts a string array or a hash set; all save items use the
canonical `item_*` names (the keys shared by `threat_data.SAVE_KIND` /
`RECOMMENDED_SAVES` and `item_data.SAVE_GEOMETRY`). Scoring weights are in one
`W` table at the top, tunable.

### Verified

- Loads in plain `lua.exe` (pure — requires only `threat_data` + `item_data`,
  both pure). Exec-test: Bane Nightmare ranks Eul (recommended #1) above BKB
  (#5) and correctly drops Hurricane Pike (displacement does not counter a
  sleep); Fiends Grip (tether 875) ranks Blink above Pike at 300u distance
  (Pike's 425 push is too short: 300+425 < 875) and near-level at 500u (both
  clear); `Effective` / `ThreatBrief` return correct values.

### Status

Standalone — nothing consumes it yet. Built so save-selection can be adopted
per hero without disturbing an existing inline implementation. Adopting it in
Sniper (replacing the inline `resolve_save_order`) is a separate, later
decision; deployed lib-only, no consuming brain changed.

## unit_data.lua — new KV-data lib — 2026-05-17

New pure-data Tier 2 module — KV-lib build-out task #4, the last build-out
task. Static non-hero unit reference generated from
`C:\Umbrella\assets\data\npc_units.json`. Data-only, no API calls / callbacks.

Covers lane / neutral creeps, summons, wards, buildings and Roshan —
everything that is a unit but not a hero. Useful for last-hit / clear logic
and for summon-vs-illusion awareness.

Owns:

- `UNITS` — all 342 unit entries: `base_class`, `level`, `health` /
  `health_regen`, `mana` / `mana_regen`, `armor`, `magic_resist`,
  `attack_type` (melee / ranged / none), `attack_min` / `attack_max`,
  `attack_rate`, `attack_range`, `attack_point`, `acquisition_range`,
  `damage_type`, `projectile_speed`, `move_type` (ground / fly / none),
  `move_speed`, `turn_rate`, `vision_day` / `vision_night`, `bounty_gold_min`
  / `bounty_gold_max`, `bounty_xp`, `team`, `relationship` (default / ward /
  building / barracks / siege / tower), `bounds_hull`, `ring_radius`,
  `abilities` (real ability names, talent slots dropped), and the boolean
  flags `summoned` / `ancient` / `neutral` / `considered_hero` /
  `has_inventory` / `roshan`.
- Pure helpers: `Get`, `HasAbility`, `IsSummon`, `IsAncient`, `IsNeutral`,
  `IsWard`, `IsBuilding`, `AvgAttackDamage`.

Summon-vs-illusion note: an illusion is a hero copy and is NOT in this table.
A true summon (Furion treant, Warlock golem, forged spirit, necronomicon
unit) carries `summoned = true` (48 such units). The Lone Druid Spirit Bear
is a hero-grade pet — the KV data flags it `considered_hero`, not
`IsSummoned`, so `IsSummon` returns false for it; check `considered_hero` for
that case.

Generated by `tools/gen_unit_data.py` — the generator is the single source of
truth (it carries the helpers as a literal). Re-run after a Dota patch.

### Verified

- `lua.exe` syntax check passes (source + deployed copy).
- Helper exec-test: `UNITS` has 342 entries; badguy melee creep hp 550 /
  armor 2 / 19-23 dmg / 34-39 gold / 57 xp; `AvgAttackDamage` 21; Spirit Bear
  hp 1500 + 6 abilities + `considered_hero` (and correctly `IsSummon` false);
  `IsWard` true for observer + sentry; `IsNeutral` true for kobold; Roshan
  hp 6000 / `ancient`; `HasAbility` resolves; flag counts summoned 48 /
  ancient 47 / neutral 65 / wards 69.
- Deployed lib-only — no consuming brain references it yet, so no brain code
  change and no version bump.

This completes the KV-lib build-out (item / ability / unit). Remaining KV-lib
work is task #1 — the ongoing `threat_data.lua` modifier-name harvest, which
is blocked on in-game `threat_unrecognized` data.

## ability_data.lua — new KV-data lib — 2026-05-17

New pure-data Tier 2 module — KV-lib build-out task #3. Static ability
reference generated from `C:\Umbrella\assets\data\npc_abilities.json`.
Data-only, no API calls / callbacks. A static reference + fallback for the
live `Ability.GetDamage` path (the engine applies talent / facet / Aghanim
bonuses at runtime — prefer the live API when a handle is available; this lib
answers when it is not).

Owns:

- `ABILITIES` — all 1949 ability entries: `id`, `type` (basic / ultimate /
  attributes / hidden), `behavior` (short flags), `active`, `cooldown`,
  `cast_point`, `cast_range`, `mana`, `damage`, `damage_type`, `channel_time`,
  `duration`, `max_level`, `target_team` / `target_type`, `spell_immunity`,
  `dispellable`, `has_scepter` / `has_shard`, `innate`, `breakable`, and
  `values` (the AbilityValues, BASE magnitudes only).
- Pure helpers: `Get`, `HasBehavior`, `IsActive`, `AtLevel` (per-level array
  indexing, 1-based, clamped), `Damage`, `Cooldown`, `CastPoint`, `CastRange`,
  `Mana`, `Duration`, `Value` (a base AbilityValues key at a level).

Key generation decisions:

- **Base values only.** Talent (`special_bonus_*`) and facet bonuses are
  dropped from `values`; `{value=...}` wrappers are flattened past their
  metadata (`affected_by_aoe_increase`, `CalculateSpellDamageTooltip`, etc.).
  So the lib reports un-upgraded magnitudes — the live API is authoritative
  for the upgraded number.
- **Embedded canonical fields promoted.** Modern KV often nests
  `AbilityCooldown` / `AbilityCastRange` / `AbilityCastPoint` / `AbilityDamage`
  inside `AbilityValues` (e.g. Pudge Meat Hook's cast range, Laguna Blade's
  cooldown). The generator promotes those to top-level entry fields, sourcing
  the top-level `Ability<X>` first and the `AbilityValues` entry as fallback.
- Per-level values stay as `{l1, l2, l3, ...}` arrays; `AtLevel` / the typed
  accessors index them.

Generated by `tools/gen_ability_data.py` — the generator is the single source
of truth (it carries the helpers as a literal). Re-run after a Dota patch.

### Verified

- `lua.exe` syntax check passes (source + deployed copy).
- Helper exec-test: `ABILITIES` has 1949 entries; Laguna Blade damage
  380/565/750 and cooldown 70/60/50 by level (cooldown correctly promoted out
  of `AbilityValues`, talent bonus stripped); Finger of Death cooldown
  110/70/30, damage L2 725; Assassinate damage 300→500, cast point 2;
  Shrapnel `radius` 400→475 (metadata stripped) and `shrapnel_damage` L4 75;
  Meat Hook `damage` promoted (360 at L4), `cast_range` 1300 (promoted from
  `AbilityValues`); `AtLevel` clamps; `HasBehavior` / `IsActive` / `type` /
  `damage_type` correct.
- Deployed lib-only — no consuming brain references it yet, so no brain code
  change and no version bump.

### Next (KV-lib build-out)

- Task #4 — unit data from `npc_units.json` (last remaining build-out task).

## item_data.lua — new KV-data lib — 2026-05-17

New pure-data Tier 2 module — KV-lib build-out task #2. Static item reference
generated from `C:\Umbrella\assets\data\items.json` + `neutral_items.json`.
Data-only, no API calls / callbacks (same discipline as `threat_data.lua`).

Owns:

- `ITEMS` — all 544 item entries: `id`, `cost`, `quality`, `behavior` (short
  flag list), `active` (has a manual cast), `cooldown` / `mana` / `cast_range`
  / `cast_point` (a number, or a per-level `{a,b,c}` array), `shared_cooldown`,
  `damage_type`, `target_team` / `target_type`, `tags`, `recipe` (alternative
  build sets), `is_recipe` / `result`, `neutral_tier`, and `values` (the full
  `AbilityValues`, numeric strings coerced, `{value=...}` wrappers flattened).
- `NEUTRAL_TIERS` — tiers 1-5: `start_time`, `craft_cost`, `items`.
- `SAVE_GEOMETRY` — 20 curated save items with hand-verified geometry (push
  distances, durations, cast ranges, cooldowns). Pike pushes the caster 600u
  but an enemy only 425u (`self_push` vs `enemy_push`); Force pushes any
  target 600u. This is the data `threat_data.lua`'s hand-maintained
  `SAVE_PUSH_DISTANCE` / `SAVE_KIND` can be grounded against.
- Pure helpers: `Get`, `HasBehavior`, `IsActive`, `NeutralTier`,
  `Components` (recursive leaf ingredients), `BuildCost` (recursive leaf-cost
  sum), `SaveGeometry`.

Generated by `tools/gen_item_data.py` — the generator is the single source of
truth (it carries the `SAVE_GEOMETRY` table + the helpers as literals).
Re-run it after a Dota patch; do not hand-edit the generated lib.

### Verified

- `lua.exe` syntax check passes (source + deployed copy).
- Helper exec-test: `ITEMS` has 544 entries; `BuildCost` matches the `cost`
  field for 122/125 recipe items — the 3 exceptions are explained (eternal
  shroud is a 100g KV cost quirk; iron talon / medallion are now neutral
  items with shop-cost 0). `Components` resolves deep recipes (Guardian
  Greaves → 10 leaves). `SAVE_GEOMETRY` / `NEUTRAL_TIERS` / `IsActive` /
  `HasBehavior` / `NeutralTier` all return correct values.
- Deployed lib-only — no consuming brain references it yet, so no brain code
  change and no version bump (same convention as the threat-catalog batches).

### Next (KV-lib build-out)

- Task #3 — `lib/ability_data.lua` from `npc_abilities.json`.
- Task #4 — unit data from `npc_units.json`.
- `threat_data.lua`'s `SAVE_PUSH_DISTANCE` / `SAVE_KIND` can now be re-grounded
  against `item_data.SAVE_GEOMETRY` when a brain next consumes the lib.

## threat_data.lua — defense threat-catalog refresh — 2026-05-17

Roster-wide refresh. The original tables (2026-05-11) covered ~22 threats,
weighted to classic heroes — the entire post-2018 hero pool was uncovered
(surfaced by a Sniper bug: Kez Grappling Claw triggered no save). Source: a
full enumeration of the current 155-entry KV data (`npc_heroes.json` /
`npc_abilities.json`).

- **Kez Grappling Claw** — added across all 7 tables (with Sniper v6.15.162).
- **Batch 1** (Sniper v6.15.163) — 12 modern heroes: Ringmaster, Marci,
  Muerta, Primal Beast, Dawnbreaker, Hoodwink, Snapfire, Void Spirit, Mars,
  Grimstroke, Pangolier, Dark Willow.
- **Batch 2** (Sniper v6.15.164) — 10 older-hero kidnaps / gap-closes:
  Faceless Void Chronosphere, Batrider Lasso, Tiny Toss, Vengeful Spirit
  Nether Swap, Chaos Knight Reality Rift, Clockwerk Hookshot, Spirit Breaker
  Nether Strike (promoted from a `nil` `ABILITY_TO_THREAT` entry), Huskar
  Life Break, Sand King Burrowstrike, Nyx Impale.
- Each threat is wired into the 5 core tables — `ABILITY_TO_THREAT`,
  `THREATS_ON_SELF`, `THREAT_CATEGORY`, `THREAT_SEVERITY`, `THREAT_TIMING`.
  Per-threat `THREAT_COUNTER` / `RECOMMENDED_SAVES` are left to the consumer's
  category-chain fallback.
- **Modifier names** are best-effort `modifier_<ability>` — the KV data
  exposes no modifier names. All marked `(verify)`. The consuming brain logs
  `threat_unrecognized` for any unrecognized modifier landing on self, so the
  guessed names get corrected from real games.
- **Batches 3-4** — 36 more threats (executes, targeted disables, channels,
  delayed-AoE / traps, gap-close secondaries): Necrophos Reaper's Scythe,
  OD Sanity Eclipse + Astral Imprisonment, Lich Chain Frost + Sinister Gaze,
  Skywrath Mystic Flare + Ancient Seal, Mars God's Rebuke + Arena, Snapfire
  Scatterblast, Bloodseeker Rupture, Chaos Bolt, Beastmaster Primal Roar,
  Shadow Demon Disruption + Demonic Purge, Winter's Curse, Enigma Malefice,
  Shackleshot, Morphling Adaptive Strike, Puck Dream Coil + Waning Rift,
  Leshrac Split Earth, Jakiro Ice Path, Sand King Epicenter, Templar Psionic
  Trap, Naga Song, Dark Willow Terrorize + Bramble Maze, Ringmaster The Box +
  Wheel, Kez Raptor Dance, Primal Beast Pulverize, Grimstroke Soul Chain,
  Void Spirit Astral Step, Pangolier Gyroshell, Nyx Vendetta.
- The catalog now covers ~80 threats (was ~22). Deployed lib-only — no
  consuming brain needed a code change. Enemy-buff threats (Marci Unleash,
  Muerta Pierce the Veil, Windranger Focus Fire) are NOT in scope here — they
  belong in each brain's own `ENEMY_BUFF_THREATS` table, not the lib.

## threat_data.lua — Tier 2 (data-only) — 2026-05-11

First Tier 2 module. Extracted from `Sniper/Sniper.lua` v4.2 once the threat / save classification data became substantial enough to be worth reusing across heroes. **Data only** — no behavior, no event handlers, no side effects. Logic that consumes these tables (save chain, armed-ETA timing, anim log dedup) stays inline per the project's "two-hero rule" until a second hero proves the API shape.

Owns:

- `SAVE_KIND` — save item / ability → list of effect kinds (`invuln`, `dispel_basic`, `magic_immune`, `reflect_target`, `invis`, `displacement_perp`, `displacement_far`)
- `THREAT_COUNTER` — threat-modifier-name → list of kinds that counter it (22 threats across 7 categories: entity-targeted spells, channel-tethers, homing charges, delayed AoEs, line projectiles, physical chase, drain, lockdown)
- `SAVE_PUSH_DISTANCE` — Pike/Force = 500, Grenade-self = 475
- `THREAT_TETHER_RANGE` — Fiend Grip 875, Dismember 200, Shackles 800, Static Link 900, Mana Drain 850, Death Ward 1100
- `THREATS_ON_SELF` — modifier → `{role, save}` metadata for Layer 2 dispatch
- `LOTUS_WORTHY_INCOMING` — single-target enemy ults Lotus reflects (Lina Laguna, Lion Finger)
- `ENEMY_CHANNEL_MODIFIERS` — Layer 1.5 channel-punish / TP-interrupt triggers
- `ABILITY_TO_THREAT` — ability name from anim events → threat modifier name

Plus two pure helpers:

- `SaveCounters(save_name, threat_mod) → bool` — set intersection over kinds
- `WillTetherBreak(save_name, threat_mod, distance) → bool` — pure geometry: `(distance + push) > tether_range`

Hero scripts re-bind the tables locally for terse call sites; the helpers can be called directly or wrapped in a hero-side adapter (Sniper turns a caster entity into a distance via its own `dist_to`).

### Verified

- API-clean (no entity introspection, no GlobalVars, no callbacks).
- Sniper v4.3 refactored to use it without behavior change — 1,602 → 1,437 LOC in Sniper.lua (-165 lines).
- Cross-checked against UCZone canonical docs: no API calls in this module, so nothing to break.

### Next steps (deferred)

- `lib/defense.lua` (logic extraction — save chain executor, armed-threats system, anim log dedup) — gated on a second hero whose inline save logic matches Sniper's. Project memory: "two heroes whose inline implementations are already near-identical, not 'feels universal' — resist premature extraction."

## Tier 1 Bootstrap — 2026-05-11

- Built `lib/order.lua`, `lib/damage.lua`, `lib/anim.lua`, `lib/target.lua`.
- `lib/item.lua` specced in `TIER1_BOOTSTRAP.md` but deferred to Tier 2 under the
  augmentation pattern — baseline Items Usage handles most cases; build only
  when 2+ heroes need direct item-state queries baseline doesn't expose.

### Verified

- **API cross-check (2026-05-11):** all 4 modules verified against
  `C:\Users\arcos\uczone-api-v2.0\` (canonical GitBook mirror) and the
  LuaCATS library at `ILKA.umbrella-vscode/plugin/library/natives/umbrella/`.
  Zero hard defects — every function name, parameter order, enum value, and
  callback `data` field shape used in the libs matches the documented API.
  Two ambiguities resolved by hardening the affected sites:
  - `Hero.GetLastHurtTime` time base unstated relative to
    `GlobalVars.GetCurTime`. Hardened `damage.lua` to keep two cursors per
    buffer (`last_hurt_t` in wall-time, `last_hurt_framework` in framework
    time) so the poll-path dedup compares like-with-like and every pushed
    entry stores `now()` regardless of source path.
  - `NPC.FindRotationAngle` degrees-vs-radians unstated. Documented the
    degrees assumption in `anim.lua` and noted the radians-fallback failure
    mode (gate degrades to always-pass → over-fires Layer 2 = safe-side
    bias). Confirm units empirically when wiring the first hero.

### Verified in demo
*(Pending — run the spec's per-module verification cases once a hero brain is
wired up and able to drive demo orders.)*

### Known limitations / carried-forward TODOs

**`lib/order.lua`**
- `Humanizer.GetOrderQueue()` does NOT expose the order `identifier` field per
  the UCZone v2.0 API docs. Duplicate detection runs against an internal
  pending-registry mirror with a 2.5s TTL, not against the humanizer queue
  itself. If the queue ever surfaces identifiers, swap to direct query and
  drop the mirror.
- `OnPrepareUnitOrders_handler` is currently a passthrough (returns true).
  Reserved for future arbitration (e.g., yielding to baseline orders on a
  shared cooldown, or self-cancelling stale brain orders).
- `STRICT = true` triggers `error()` on missing-required-field; flip to false
  for production builds where fail-quiet is preferred.

**`lib/damage.lua`**
- Stage 2 OFF polling uses `Hero.GetLastHurtTime` + `GetHurtAmount` for heroes
  only. Non-hero NPC damage tracking in the fallback path is not implemented
  (rare for brain needs — heroes are what we care about).
- `OnProjectile` / `OnLinearProjectileCreate` speculative-push paths are stubbed.
  Per-hero damage estimation (basic-attack true damage, ability estimates)
  pairs better with `lib/ability_dmg.lua` (Tier 2) than with the generic
  damage feed.
- `OnModifierCreate` DoT-tick estimation is stubbed. Requires hero-side
  knowledge of which modifier names are DoT and at what rate; revisit when the
  first hero brain demands DoT-aware Layer 2 triggers.
- Source attribution via `GetRecentDamageBySource` returns 0 when Stage 2 is
  off (no callback → no `source` field). Documented limitation, matches spec.

**`lib/anim.lua`**
- Stolen abilities (Rubick) and invoked-slot abilities (Invoker) are not yet
  routed — when Anim resolves `data.unit` to a hero name it looks up that
  hero's map. Rubick casting a stolen Pudge hook plays a Rubick activity, not
  Pudge's; the v1 dispatcher won't fire the `gap_close`/`hard_disable` event.
  Add when the first such hero needs it (likely Rubick brain).
- Animation events for sub-units (Lone Druid bear, Visage familiars, Beastmaster
  hawks) require registering the sub-unit's unit-name as a separate map key.
  No special handling beyond that.
- `target_self` uses a 30° facing threshold and 1200u default range when the
  hero-provided map doesn't carry a range hint. Per-entry ability-range
  override is a Tier 2 enhancement.

**`lib/target.lua`**
- `WillBeInvulnIn(entity, ms)` v1 reads only currently-active state durations
  via `NPC.GetStatesDuration`. It does not yet predict invuln windows opened
  by self-cast Eul / Manta dispel-into-invuln / etc. Tier 2 candidate
  (`lib/timing.lua`) folds cast-window prediction in.
- `EffectiveHpVs` does not subtract flat damage-block / Pipe-style soak
  (`MODIFIER_PROPERTY_AVOID_DAMAGE`). Hero brains compose the subtraction
  inline when they need it. Promote to Tier 2 if 3+ heroes need it.
- `HasReadyLinkens` / `HasReadyLotus` use framework-aware
  `NPC.IsLinkensProtected` / `NPC.IsMirrorProtected` instead of the
  `has-item + IsReady` composition the original spec described. Per
  `BRAIN_PROJECT.md`'s audit-corrected protection-check conventions this is
  the better truth source.

### Cross-cutting design notes

- **Callback wiring.** Each lib exposes `<Lib>.Wire(callbacks)` to chain its
  handlers into a script-returned callbacks table. Handlers are frame-deduped
  internally so multiple wirings are safe but wasteful — prefer wiring once
  from a single bootstrap script and have hero scripts only call the lib's
  public APIs (`Order.Issue`, `Anim.Subscribe`, `Damage.GetRecentDamage`,
  `Target.*`).
- **Idempotent `Init`.** Each module's `Init()` is safe to call multiple
  times. Module-level state is shared across all `require()` callers (Lua's
  package cache).
- **Logging discipline.** Modules call `Log.Write` only on actual anomalies
  (Stage 2 transition, unmapped activity, particle-id resolve failure,
  subscriber error). No verbose "running" logs in production paths.

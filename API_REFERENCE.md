# UCZone API Reference for Brain Work

**Purpose:** brain-task-organized quick reference. Not a re-export of the canonical docs — a curated index from the brain's perspective.

**Sources of truth:**
- **Raw API signatures:** the UCZone API v2.0 docs (canonical, 16k lines)
- **In-editor autocomplete:** Umbrella VS Code extension (`ILKA.umbrella-vscode`) — 97 LuaCATS definition files
- **This file:** brain-task → API mapping, curated enum subsets, Dota-mechanics gotchas

A high-density quick reference for working without the VS Code extension visible, alongside the raw docs.

---

## Detecting target state (Layer 1 cast-window, Layer 2 anti-dodge)

All checks go through `lib/target.lua` predicates, which compose these primitives.

### Boolean state check (instant)
```lua
NPC.HasState(target, Enum.ModifierState.MODIFIER_STATE_X)
```

### Remaining duration of state (predict at impact tick)
```lua
local d = NPC.GetStatesDuration(target, {
  [Enum.ModifierState.MODIFIER_STATE_INVULNERABLE] = true,
  [Enum.ModifierState.MODIFIER_STATE_OUT_OF_GAME]  = true,
  [Enum.ModifierState.MODIFIER_STATE_MAGIC_IMMUNE] = true,
})
-- d[Enum.ModifierState.MODIFIER_STATE_X] returns remaining seconds (0 if not active)
```

### Key `Enum.ModifierState` values for brain work

| State | Meaning | Brain use |
|---|---|---|
| `MODIFIER_STATE_STUNNED` | Cannot act, cannot move, cannot turn | Threat assessment (can target retaliate?) |
| `MODIFIER_STATE_SILENCED` | Cannot cast abilities, can attack/move | Combo-window check (can enemy still cast escape/save?) |
| `MODIFIER_STATE_HEXED` | Forced into critter form, cannot cast, cannot attack | Same as stunned for our purposes |
| `MODIFIER_STATE_ROOTED` | Cannot move, can attack/cast | Pin-down detection |
| `MODIFIER_STATE_DISARMED` | Cannot attack, can move/cast | Right-click hero check |
| `MODIFIER_STATE_MUTED` | Cannot use items | Item-Pike check on enemy |
| `MODIFIER_STATE_INVULNERABLE` | Immune to all damage and most spells | **Hard kill-confirm abort** |
| `MODIFIER_STATE_OUT_OF_GAME` | Eul / Cyclone / similar — invuln + untargetable | **Hard kill-confirm abort** |
| `MODIFIER_STATE_MAGIC_IMMUNE` | BKB / Repel — blocks single-target magic | Magic combo abort |
| `MODIFIER_STATE_ATTACK_IMMUNE` | Ethereal — blocks basic attacks | Orbwalk abort |
| `MODIFIER_STATE_INVISIBLE` | Hidden unless True Sight | Vision gate |
| `MODIFIER_STATE_TRUESIGHT_IMMUNE` | Stays invisible even under True Sight (Riki ult) | Special-case detection |
| `MODIFIER_STATE_UNTARGETABLE` | Cannot be targeted by spells | Single-target spell abort |
| `MODIFIER_STATE_DEBUFF_IMMUNE` | Lotus / Aphotic Shield strong dispel | Debuff combo abort |
| `MODIFIER_STATE_PASSIVES_DISABLED` | Doom / Silver Edge break | Crit/proc spell abort |
| `MODIFIER_STATE_ROOTED` | Cannot move, can attack/cast | Engage opportunity |
| `MODIFIER_STATE_TETHERED` | Wisp tether active | Combo-trigger signal |
| `MODIFIER_STATE_TAUNTED` / `MODIFIER_STATE_FEARED` | Forced to attack/run | Threat-window math |
| `MODIFIER_STATE_NIGHTMARED` | Bane Nightmare — wakes on damage | Damage-first decision |
| `MODIFIER_STATE_FROZEN` | Special freeze (rare) | Edge case |

Full list: the UCZone API v2.0 docs, `cheats-types-and-callbacks/enums.md` § Enum.ModifierState (64 entries, lines 229-296).

---

## Reading aggregated stats (own or enemy)

```lua
local val = NPC.GetModifierProperty(npc, Enum.ModifierFunction.MODIFIER_PROPERTY_X)
```

### Key `Enum.ModifierFunction` properties for brain work

| Property | Returns | Brain use |
|---|---|---|
| `MODIFIER_PROPERTY_MOVESPEED_BONUS_PERCENTAGE` | % move-speed bonus | Chase/flee math |
| `MODIFIER_PROPERTY_MOVESPEED_BONUS_CONSTANT` | flat MS bonus | Total speed calc |
| `MODIFIER_PROPERTY_ATTACK_SPEED_PERCENTAGE` | % AS bonus | Orbwalk timing |
| `MODIFIER_PROPERTY_ATTACKSPEED_BONUS_CONSTANT` | flat AS bonus | Same |
| `MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE` | % spell amp | Damage estimation (own) |
| `MODIFIER_PROPERTY_STATUS_RESISTANCE` | % status resist | Predict effective CC duration on target |
| `MODIFIER_PROPERTY_CAST_RANGE_BONUS` | flat cast range bonus | Engage decision |
| `MODIFIER_PROPERTY_ATTACK_RANGE_BONUS` | flat attack range bonus | Orbwalk + Hit & Run |
| `MODIFIER_PROPERTY_INCOMING_DAMAGE_PERCENTAGE` | % incoming damage taken | Kill-confirm math |
| `MODIFIER_PROPERTY_INCOMING_PHYSICAL_DAMAGE_PERCENTAGE` | % incoming physical | Same |
| `MODIFIER_PROPERTY_TOTALDAMAGEOUTGOING_PERCENTAGE` | % outgoing total | Damage estimation (own) |
| `MODIFIER_PROPERTY_BONUSDAMAGEOUTGOING_PERCENTAGE` | % outgoing bonus | Same |
| `MODIFIER_PROPERTY_PHYSICAL_ARMOR_BONUS` | flat armor bonus | EffectiveHpVs math |
| `MODIFIER_PROPERTY_MAGICAL_RESISTANCE_BONUS` | % magic resist bonus | Same |
| `MODIFIER_PROPERTY_HEALTH_REGEN_CONSTANT` | flat HP regen | Stall window calc |
| `MODIFIER_PROPERTY_MANA_REGEN_CONSTANT` | flat mana regen | Mana budget timing |
| `MODIFIER_PROPERTY_EVASION_CONSTANT` | % evasion | Hit prediction |
| `MODIFIER_PROPERTY_NEGATIVE_EVASION_CONSTANT` | reduces evasion | Solar Crest, MKB |
| `MODIFIER_PROPERTY_AVOID_DAMAGE` | block-X-damage absorbers | Predict effective HP |
| `MODIFIER_PROPERTY_COOLDOWN_PERCENTAGE` | % cooldown reduction | Aether Lens, Octarine math |
| `MODIFIER_PROPERTY_MANACOST_PERCENTAGE` | % mana cost reduction | Mana budget |

Use `NPC.GetModifierPropertyHighest` instead of `GetModifierProperty` when multiple items don't stack (e.g., Kaya stacking rules) — returns highest single contributor instead of sum.

Full list: enums.md § Enum.ModifierFunction (~175 entries, lines 1081-1255).

---

## Issuing orders

All orders go through `lib/order.lua`. The `order_type` field maps to `Enum.UnitOrder`.

### Key `Enum.UnitOrder` values

| Order | Takes | Brain use |
|---|---|---|
| `DOTA_UNIT_ORDER_MOVE_TO_POSITION` | position | Repositioning, escape destination |
| `DOTA_UNIT_ORDER_MOVE_TO_TARGET` | target | Chase a unit |
| `DOTA_UNIT_ORDER_ATTACK_MOVE` | position | A-click to clear creeps / find target |
| `DOTA_UNIT_ORDER_ATTACK_TARGET` | target | Last-hit, focus enemy hero, orbwalk |
| `DOTA_UNIT_ORDER_CAST_POSITION` | position, ability | Skillshot / AoE point cast (Arrow, Hook, Shrapnel) |
| `DOTA_UNIT_ORDER_CAST_TARGET` | target, ability | Single-target spell (Hex, Frost, Laser) |
| `DOTA_UNIT_ORDER_CAST_TARGET_TREE` | target_tree_id, ability | Tango, NP Teleport, Timbersaw Whirling Death anchor |
| `DOTA_UNIT_ORDER_CAST_NO_TARGET` | ability | Instant ult (Mirana Leap, Sven Rage, BKB self, Glimmer self) |
| `DOTA_UNIT_ORDER_CAST_TOGGLE` | ability | Rot, Sun Ray, Madness, Bloodrage on self |
| `DOTA_UNIT_ORDER_CAST_TOGGLE_AUTO` | ability | Autocast toggle (Lich Sacrifice, OD Astral Imprisonment auto) |
| `DOTA_UNIT_ORDER_HOLD_POSITION` | — | Stop and face — used by some channels |
| `DOTA_UNIT_ORDER_STOP` | — | Cancel current order / channel |
| `DOTA_UNIT_ORDER_TRAIN_ABILITY` | ability | Spend skill point |
| `DOTA_UNIT_ORDER_PICKUP_RUNE` | rune entity | Rune pickup |
| `DOTA_UNIT_ORDER_PURCHASE_ITEM` | — (uses ability=item_id) | Buy from shop |
| `DOTA_UNIT_ORDER_BUYBACK` | — | Buyback on death |
| `DOTA_UNIT_ORDER_GLYPH` | — | Activate Glyph |
| `DOTA_UNIT_ORDER_MOVE_TO_DIRECTION` | position | Move toward direction without specific destination |
| `DOTA_UNIT_ORDER_CAST_RUNE` | rune entity, ability | Cast bottle-stored rune |

`Enum.PlayerOrderIssuer` for `issuer` field:
- `DOTA_ORDER_ISSUER_SELECTED_UNITS` — affects all selected
- `DOTA_ORDER_ISSUER_CURRENT_UNIT_ONLY` — only the explicitly-passed unit
- `DOTA_ORDER_ISSUER_HERO_ONLY` — own hero only
- `DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY` — for multi-unit heroes; only the named unit acts

Full list: enums.md § Enum.UnitOrder (lines 596-641).

---

## Detecting enemy intent

Brain has four channels for "the enemy is about to do X." Each has different latency and confidence.

### Channel 1 — Animation (highest latency, most predictive)
`OnUnitAnimation(data)` fires when the unit begins an animation. Data includes:
- `unit` — the caster
- `activity` — `Enum.GameActivity` value (e.g., `ACT_DOTA_CAST_ABILITY_1`)
- `sequenceName` — string name of the animation sequence
- `castpoint` — time from start to the cast point in seconds
- `playbackRate` — animation speed scalar

Use the per-matchup animation→ability map (Phase 0.5/D) to translate `activity` → semantic role. Confidence: medium (animation can be cancelled). Latency: earliest signal, before projectile.

### Channel 2 — Projectile spawn (mid latency, high confidence)
`OnProjectile(data)` for target-tracking projectiles (Sniper auto, Mirana arrow target-bind variants). `OnLinearProjectileCreate(data)` for fixed-trajectory (Pudge hook, Mirana arrow, Witch Doctor stun).
- Data has typed `source`, `target` (for target-projectiles), `velocity`, `expireTime`, `maxImpactTime`
- Available always — no Stage 2 gate
- Confidence: high — the cast has already committed

### Channel 3 — Particle spawn (when animation+activity isn't reliable)
`OnParticleCreate(data)` with `name` matching a known signature.
- Some abilities are most reliably detected by particle (Bloodseeker Rupture start, Doom ult cast, Roshan aggro, smoke-of-deceit application)
- Add to hero `notes.md` particle catalog alongside the animation→ability map

### Channel 4 — Modifier appearance (lowest latency, hard confirm)
`OnModifierCreate(target_npc, modifier)` fires when a debuff lands.
- Useful for: "the cast landed; I am now hexed/silenced/stunned" — Layer 2 reaction trigger
- The modifier's `GetName()` identifies the ability
- For DoTs: `GetRemainingTime`, `GetStackCount` give the ongoing damage profile

---

## Damage estimation (kill-confirm math)

```lua
local target_eff_hp = Target.EffectiveHpVs(target, self, dmg_type)  -- target side
local my_dmg       = AbilityDmg.Estimate(ability, self, target)     -- source side
local kill         = my_dmg >= target_eff_hp
```

### Damage type resolution

| `Enum.DamageTypes` | What blocks it |
|---|---|
| `DAMAGE_TYPE_PHYSICAL` | Armor (multiplicative), `MODIFIER_STATE_ATTACK_IMMUNE` (full block), Evasion (% miss) |
| `DAMAGE_TYPE_MAGICAL` | Magic resist (multiplicative), `MODIFIER_STATE_MAGIC_IMMUNE` (full block), spell pierce ignores immunity |
| `DAMAGE_TYPE_PURE` | Nothing except `MODIFIER_STATE_INVULNERABLE` and `MODIFIER_STATE_DEBUFF_IMMUNE` (Lotus) |

### Pierce / bypass rules
Some abilities pierce magic immunity (per-ability KV: `SpellImmunityType`). Treat as data — read `Ability.GetImmunityType` (see `Enum.ImmunityTypes`):
- `SPELL_IMMUNITY_ENEMIES_NO` — blocked by enemy BKB (default for most magic)
- `SPELL_IMMUNITY_ENEMIES_YES` — pierces BKB
- `SPELL_IMMUNITY_ALLIES_YES` / `NO` — same but for ally buffs

### Damage-calc order of operations
1. Raw damage from `Ability.GetDamage` or `Ability.GetLevelSpecialValueFor("damage", level)`
2. × outgoing damage modifiers (`MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE`, `TOTALDAMAGEOUTGOING_PERCENTAGE`)
3. × incoming damage modifiers (`MODIFIER_PROPERTY_INCOMING_DAMAGE_PERCENTAGE`, type-specific incoming)
4. × armor mult (physical) OR magic resist mult (magical) — read via `NPC.GetArmorDamageMultiplier` / `GetMagicalArmorDamageMultiplier`
5. − flat block (`MODIFIER_PROPERTY_AVOID_DAMAGE`, Pipe, Crimson, Vanguard)
6. = effective damage

### Barriers (treat as additional HP)
`NPC.GetBarriers(npc)` returns `{physical={current,total}, magic={current,total}, all={current,total}}`. Add to effective HP before subtracting damage.

---

## Ability behavior introspection

```lua
local b = Ability.GetBehavior(ability)
-- b is a bitmask, AND with Enum.AbilityBehavior values
local is_no_target  = (b & Enum.AbilityBehavior.DOTA_ABILITY_BEHAVIOR_NO_TARGET) ~= 0
local is_unit_target= (b & Enum.AbilityBehavior.DOTA_ABILITY_BEHAVIOR_UNIT_TARGET) ~= 0
local is_point      = (b & Enum.AbilityBehavior.DOTA_ABILITY_BEHAVIOR_POINT) ~= 0
local is_channeled  = (b & Enum.AbilityBehavior.DOTA_ABILITY_BEHAVIOR_CHANNELLED) ~= 0
```

### Brain-relevant `Enum.AbilityBehavior` bits

| Bit | Meaning | Brain use |
|---|---|---|
| `DOTA_ABILITY_BEHAVIOR_HIDDEN` | Hidden ability | Skip in iteration |
| `DOTA_ABILITY_BEHAVIOR_PASSIVE` | Never cast | Filter from combo planner |
| `DOTA_ABILITY_BEHAVIOR_NO_TARGET` | Instant self-cast | `DOTA_UNIT_ORDER_CAST_NO_TARGET` |
| `DOTA_ABILITY_BEHAVIOR_UNIT_TARGET` | Target a unit | `DOTA_UNIT_ORDER_CAST_TARGET` |
| `DOTA_ABILITY_BEHAVIOR_POINT` | Target a position | `DOTA_UNIT_ORDER_CAST_POSITION` |
| `DOTA_ABILITY_BEHAVIOR_AOE` | Area-of-effect | Read radius via `Ability.GetLevelSpecialValueFor("radius", level)` (the specific KV value name varies per ability — common: `radius`, `aoe`, `splash_radius`) |
| `DOTA_ABILITY_BEHAVIOR_NOT_LEARNABLE` | Talent or sub-ability | Filter from level-up planner |
| `DOTA_ABILITY_BEHAVIOR_CHANNELLED` | Channeled — interrupted by CC | Channel-cover combo planning |
| `DOTA_ABILITY_BEHAVIOR_ITEM` | This is an item, not an ability | Different cooldown semantics |
| `DOTA_ABILITY_BEHAVIOR_TOGGLE` | On/off (Rot, Sun Ray, Madness) | Use `DOTA_UNIT_ORDER_CAST_TOGGLE` |
| `DOTA_ABILITY_BEHAVIOR_AUTOCAST` | Can be set to autofire | Use `DOTA_UNIT_ORDER_CAST_TOGGLE_AUTO` |
| `DOTA_ABILITY_BEHAVIOR_INSTANT_CAST` | No cast point | Predict impact at current tick |

`Enum.TargetTeam` (values prefix `DOTA_UNIT_TARGET_TEAM_*`): `_NONE` (0), `_FRIENDLY` (1), `_ENEMY` (2), `_BOTH` (3), `_CUSTOM` (4)
`Enum.TargetType` (values prefix `DOTA_UNIT_TARGET_*`): `_NONE` (0), `_HERO` (1), `_CREEP` (2), `_BUILDING` (4), `_COURIER` (16), `_OTHER` (32), `_TREE` (64), `_CUSTOM` (128), `_SELF` (256), plus composite values `_BASIC` (18 = CREEP|COURIER), `_HEROES_AND_CREEPS` (19), `_ALL` (55)
`Enum.TargetFlags`: bit-mask combining filters (read raw enum at `cheats-types-and-callbacks/enums.md` lines 100-126)

---

## Dispels and protection

### `Enum.DispellableTypes`
| Value | Meaning |
|---|---|
| `SPELL_DISPELLABLE_YES` | Basic dispel removes (Manta, Diffusal active, etc.) |
| `SPELL_DISPELLABLE_YES_STRONG` | Only strong dispel removes (Lotus, Aphotic Shield, Anti-Mage manaburst, etc.) |
| `SPELL_DISPELLABLE_NO` | Cannot be dispelled |

Brain implications:
- Casting a `DISPELLABLE_YES` debuff on a target with Manta/Diffusal → about to be removed
- Casting a `DISPELLABLE_YES_STRONG` debuff on a target with Lotus → reflected
- `DISPELLABLE_NO` (most hard-CC stuns) → committed once landed

### Protection sources (consult before single-target casts)
- **Linkens Sphere** — absorbs one single-target enemy spell. Check via `NPC.IsLinkensProtected(target)` (framework tracks item-owned + off-cooldown). **Pop with cheap spell first** (lib/linkens.lua).
- **Lotus Orb** — reflects one single-target spell. Check via `NPC.IsMirrorProtected(target)` (framework-aware). **Reflection rules:** the reflected spell uses your stats against you. If your kill spell would kill the target, it kills you instead.
- **BKB** (Black King Bar) — duration-based magic immunity + status resist. Read via `Target.HasState(MODIFIER_STATE_MAGIC_IMMUNE)` and `GetStatesDuration({MAGIC_IMMUNE})`.
- **Repel** (Omniknight) — basic dispel + magic immune.
- **Glimmer Cape** — magic resist + invisibility. Magic resist contributes to `GetMagicalArmorDamageMultiplier`.
- **Aegis** — `NPC.HasAegis(target)`. ~5s effective "another life." Don't burn ult if target has aegis unless you can kill twice or strip via dive.

---

## Channel mechanics

### What cancels enemy channels (you cast on them)
- Any damaging spell with `bChannelCancel` flag (most do)
- Stun, hex, silence, mute, taunt, fear, knockback, force-move, polymorph
- Some non-damaging effects: Lion Hex, Cyclone, Eul, Force Staff

### What protects your channels
- BKB (removes silence + magic-immune)
- `NPC.HasState(npc, Enum.ModifierState.MODIFIER_STATE_CASTS_IGNORE_CHANNELING)` — state flag that lets the unit cast while channeling another ability (rare passive)
- Channel-on-self abilities (Bloodseeker Bloodbath, etc.) sometimes have built-in protection

### Detecting active channel
```lua
NPC.IsChannellingAbility(npc)  -- true if any
local a = NPC.GetChannellingAbility(npc)  -- the actual ability
```

---

## Game phase, time, day/night

```lua
GameRules.GetGameTime()         -- seconds since horn
GameRules.IsDayTime()           -- boolean
GameRules.GetGameState()        -- Enum.GameState
GameRules.IsPaused()
GlobalVars.GetCurTime()         -- alternate clock for frame math
GlobalVars.GetFrameCount()      -- monotonic frame counter
```

### Brain-relevant `Enum.GameState`
- `DOTA_GAMERULES_STATE_HERO_SELECTION`
- `DOTA_GAMERULES_STATE_STRATEGY_TIME`
- `DOTA_GAMERULES_STATE_PRE_GAME`
- `DOTA_GAMERULES_STATE_GAME_IN_PROGRESS` ← brain only runs here
- `DOTA_GAMERULES_STATE_POST_GAME`

### Day/night
- Day cycle: ~5 min day, ~5 min night
- Night Stalker, Luna, Mirana ult timing — check `IsDayTime()`
- Vision range shrinks at night for most heroes (`NPC.GetNightTimeVisionRange` vs `GetDayTimeVisionRange`)

---

## Common Dota mechanics not obvious from the API

These are game-knowledge facts the API exposes primitives for but never explains. Brain needs them to make correct decisions.

### Status resistance
Reduces stun/silence/hex/root **duration**, not whether they apply. `MODIFIER_PROPERTY_STATUS_RESISTANCE` returns the multiplier. A target with 30% status resist takes 70% of stun durations.

### Magic immunity vs debuff immunity
- **Magic immunity** (BKB): blocks new magic spells, blocks ongoing magic damage, does NOT dispel existing debuffs. Pure damage still passes.
- **Debuff immunity** (Lotus, Aphotic Shield strong dispel applied): cannot receive new debuffs and strips current debuffs. Damage still applies.

### Dispel categories
- **Basic dispel**: Manta active, Diffusal Blade active, items like Eul self-cast on landing
- **Strong dispel**: Lotus Orb proc, Aphotic Shield removal, Anti-Mage Mana Void, Spirit Breaker Charge of Darkness arrival, etc.
- **Always-dispels-everything**: Death (most debuffs clear), Aegis revival

### Linkens cooldown timing
- Linkens cooldown is 14s after consuming a spell
- The brain can predict "their Linkens will be down in N seconds" by tracking `OnModifierCreate(modifier_item_linkens_sphere_target)` or equivalent consumption signal

### Lotus Orb reflection
- 100% reflection — your spell is cast on YOU by the target
- If your spell would kill the target (kill-confirm passed), the reflection might kill you instead
- Brain should NOT cast nukes on a Lotus target if your own HP < your_spell_damage_to_self

### Aegis interaction
- `NPC.HasAegis(target)` returns true if held
- On lethal damage with aegis: target revives at full HP after ~5 seconds
- Brain implication: don't burn ult on aegis holder unless you can kill twice OR the dive is worth it strategically

### Refresher Orb / Shard
- Refresher Orb refreshes ALL abilities and items (3-min cooldown)
- Refresher Shard refreshes ONE ability (single-charge consumable)
- After refresh, `Ability.IsReady` returns true on next frame — brain should re-poll

### Aghs / Shard detection
Use `NPC.HasScepter(npc)` and `NPC.HasShard(npc)` — both work for consumed Aghs (the modifier persists) and held Aghs Blessing.

### Hero pseudo-talents
Some heroes have hidden talents enabled by facets or specific items. The brain reads the active modifiers + `Hero.GetFacetID(hero)` to detect facet-conditional behavior.

### Tempest Double, Meepo clones, illusions
- `NPC.IsIllusion` — generic illusion check
- `NPC.IsMeepoClone` — Meepo-specific
- `Hero.GetReplicatingOtherHeroModel(hero)` returns the original hero if this is a clone/illusion of someone — useful for "Arc Tempest of Sniper" detection
- Tempest Double has `modifier_arc_warden_tempest_double` — check via `NPC.HasModifier`

### Spell pierce list (per patch)
This list changes each patch. Read `Ability.GetImmunityType(ability)` at runtime instead of hardcoding. `SPELL_IMMUNITY_ENEMIES_YES` means the spell pierces enemy BKB.

---

## Animation activity reference seed

`Enum.GameActivity` has ~270 values. The high-value ones for hero brain work:

### Universal
- `ACT_DOTA_ATTACK` — basic attack
- `ACT_DOTA_ATTACK2` — secondary attack animation (some heroes alternate)
- `ACT_DOTA_RUN` — moving
- `ACT_DOTA_IDLE` — standing still
- `ACT_DOTA_DIE` — death animation
- `ACT_DOTA_FLINCH` — taking damage stagger
- `ACT_DOTA_DISABLED` — stunned/hexed
- `ACT_DOTA_TELEPORT` / `ACT_DOTA_TELEPORT_END` — TP scroll
- `ACT_DOTA_VICTORY` / `ACT_DOTA_DEFEAT` — game-end

### Ability casts (slot-based)
- `ACT_DOTA_CAST_ABILITY_1` through `ACT_DOTA_CAST_ABILITY_6` — slots 1-4 + ult + 6
- `ACT_DOTA_CAST_ABILITY_INSTANT_1` through `_6` — instant variants
- `ACT_DOTA_CAST_ABILITY_4_END` and similar — channel-end animations

### Item activations
- `ACT_DOTA_USE_BOTTLE`, `ACT_DOTA_USE_ITEM`, etc.

### Per-hero unique sequences
Most heroes have hero-specific activity codes (e.g., `ACT_DOTA_SLARK_POUNCE`, `ACT_DOTA_PUDGE_DISMEMBER_END`). Phase 0.5/D enumeration discovers these from in-game observation using a debug script (see `README-source.md` for the debug template that logs every animation).

Full list: enums.md § Enum.GameActivity (lines 298-566).

---

## ButtonCode quick map (CMenuBind hotkey defaults)

| Code | Key |
|---|---|
| `MOUSE_X1` / `MOUSE_X2` | Side mouse buttons (M4 / M5) |
| `MOUSE_LEFT` / `MOUSE_RIGHT` / `MOUSE_MIDDLE` | Standard mouse |
| `KEY_LSHIFT` / `KEY_LALT` / `KEY_LCONTROL` | Modifiers |
| `KEY_F1` ... `KEY_F12` | Function keys |
| `KEY_A` ... `KEY_Z` | Letters |
| `KEY_1` ... `KEY_0` | Top-row numbers |
| `KEY_SPACE`, `KEY_TAB`, `KEY_ENTER`, `KEY_ESCAPE` | Common |

Full list: enums.md § Enum.ButtonCode (lines 729-861).

---

## Brain-task → API quick index

| I want to... | Use |
|---|---|
| Find enemies in range | `Heroes.InRadius(pos, r, team, type, omitIllusions, omitDormant)` |
| Find any units in range | `NPCs.InRadius(pos, r, team, type, omitIllusions, omitDormant)` (general), `Entity.GetHeroesInRadius` / `GetUnitsInRadius` / `GetTreesInRadius` / `GetTempTreesInRadius` (entity-relative) |
| Check if target is killable | `Target.EffectiveHpVs(target, self, dmg_type) < my_damage` AND `NPC.IsKillable(target)` |
| Check if target will dodge | `NPC.GetStatesDuration(target, {INVULNERABLE=true, OUT_OF_GAME=true, MAGIC_IMMUNE=true})` at predicted impact tick |
| Check if combo is mana-feasible | sum `Ability.GetManaCost` × `(1 - mana_cost_reduction)` ≤ `NPC.GetMana(self)` |
| Predict impact position (skillshot) | `lib/prediction.lua` — target velocity + projectile speed + cast point |
| Predict escape route | `GridNav.BuildPath(self_pos, candidate, ignoreTrees, npc_map)` ranked by distance + threat |
| Detect enemy gap-close imminent | `OnUnitAnimation` filtered through animation→ability map |
| Detect enemy projectile inbound | `OnProjectile` / `OnLinearProjectileCreate` with `target == self` |
| Track fog last-known | `Hero.GetLastMaphackPos(enemy)` + `GetLastVisibleTime(enemy)` |
| Time a self-cast chain (Layer 2) | `lib/defense.lua` with 0.8s min reaction window between casts |
| Issue an order | `lib/order.lua` with identifier tag |
| Check item cooldown | `Item.HasReady(npc, name)` from `lib/item.lua` |
| Read hero phase (laning/mid/late) | `GameRules.GetGameTime()` thresholded |
| React to taking damage | `Damage.GetRecentDamage(self, 1.5)` from `lib/damage.lua` |
| Detect enemy smoke | **Base subsystem — consume framework state, don't build** |
| Detect enemy wards | **Base subsystem — consume framework state, don't build** |

---

## Primitives the raw docs miss — extension-only or under-documented

These surface only via the Umbrella VS Code extension's LuaCATS library. The raw GitBook docs either omit them entirely or document them sparsely.

### Vector — zero-allocation math (used heavily in hot paths)

The raw docs treat `Vector` as a basic class. The LuaCATS library reveals a full math library. Prefer these over hand-rolled math in `lib/prediction.lua`, `lib/escape.lua`, `lib/target_pick.lua`, `lib/orbwalk.lua`.

**Zero-allocation mutation** (critical in 30Hz hot paths — avoid GC pressure):
```lua
v:AddInPlace(other)   v:SubInPlace(other)   v:MulInPlace(other)   v:DivInPlace(other)
v:Set(x,y,z)          v:CopyFrom(other)     v:Negate()            v:Normalize()
v:Scale(s)            v:Rotate(angle)       v:LerpInPlace(b,t)    v:SetGroundZ()
```

**Single-allocation helpers** (avoid intermediate vectors):
```lua
v:DirectionTo(other, [dist])   -- normalized dir × scale in one alloc
v:Extend2D(target, distance)   -- "move me toward target by N" in one alloc
v:Extrapolate(direction, scalar) -- self + dir * scalar (position prediction)
v:Perpendicular2D()            -- (-y, x, z)
```

**Cheap range/distance** (no sqrt — use for comparisons):
```lua
v:DistanceSqr2D(other)         -- squared 2D distance
v:IsInRange2D(other, range)    -- single-call range check
v:Length2DSqr()                -- squared 2D length
```

**Geometry / facing**:
```lua
v:Rotated(angle)               -- CCW rotation in XY (returns new)
v:MoveForward(angle, distance) -- move by Angle + distance
v:AngleBetween2D(middle, p3)   -- angle at vertex in triangle (anti-flank checks)
v:ClosestToPoint(entities)     -- returns (closest, distance) — saves a loop
v:Clone()                      -- explicit copy
v:ToAngle()                    -- vector → angle
v:ToScreen()                   -- (screenPos, isVisible)
```

`Angle` adds: `GetForward()` (forward vector), `GetVectors()` (forward, right, up triple), `Set`, `CopyFrom`, `Clone`, `IsZero`.

**Top-level `VectorCenter(points)`** computes centroid of a mixed array of Vectors and Entities. Use for AoE-target positioning (Tide Ravage center, Earthshaker Echo, Magnus RP).

### Resource hashing & identification (`Utils` + `KV` + `KeyValues`)

```lua
Utils.MurmurHash(str, seed)     -- fast string hash (integer)
Utils.ResourceIdFromName(name)  -- resource path → integer ID
```

`ResourceIdFromName` is **critical for `lib/anim.lua` particle signature dispatch**. Match particles by integer ID at registration time instead of string comparison on every `OnParticleCreate`:

```lua
local rupture_id = Utils.ResourceIdFromName("particles/units/heroes/hero_bloodseeker/bloodseeker_rupture_start.vpcf")
Callbacks.OnParticleCreate = function(p)
  if p.particleNameIndex == rupture_id then  -- integer compare, not string
    -- ...
  end
end
```

`KV` global + `KeyValues` class — general-purpose KV parsing:
```lua
local kv = KV.KeysPersonal()  -- user's personal keybinds (from Steam path)
local node = kv:FindKey("bind_a")
local action = node and node:GetString("action") or ""
```

`KeyValues` has: `GetName`, `GetFirstTrueSubKey`/`GetNextTrueSubKey`, `GetFirstSubKey`/`GetNextKey`, `FindKey(name, [create])`, `GetDataType(name)`, `GetInt(key, [def])`, `GetFloat`, `GetUint64`, `GetString`. Use for hero/item/ability KV files beyond what `Ability.GetLevelSpecialValueFor` exposes.

### Polling alternatives to projectile callbacks

Raw docs document `OnProjectile` and `OnLinearProjectileCreate` callbacks. The extension reveals **polled list access**:

```lua
TargetProjectiles.GetAll()  -- array of {handle, speed, current_position, dodgeable, source, target, ability, target_position, expire_time, max_impact_time, ...}
LinearProjectiles.GetAll()  -- array of {handle, max_speed, start_position, position, velocity, original_velocity, acceleration, fow_radius, source}
```

For `lib/threat.lua`: two-channel detection (callback subscription + per-tick poll) makes Layer 2 robust to late-joining brains and callback misses. The callback path catches new projectiles; the poll path re-establishes state for projectiles already in flight when the brain reloads.

### Rune spawn prediction (`RuneSpawner` + `RuneSpawners`)

`Rune`/`Runes` (raw docs) covers **active** runes. The extension reveals static **spawn-point** entities:

```lua
local spawners = RuneSpawners.GetAll()         -- always present, regardless of spawn state
for _, sp in ipairs(spawners) do
  local pos  = Entity.GetAbsOrigin(sp)
  local kind = RuneSpawner.GetType(sp)         -- Enum.RuneType
  local next_spawn = predict_next(kind, GameRules.GetGameTime())
  -- ...
end
```

This makes `lib/rune.lua` not just react-to-rune but **predict next rune spawn** (bounty every 3 min, power every 2 min, water at specific times). Confirms `lib/rune.lua` is not a base subsystem — build it yourself on top of these primitives.

### Humanizer extras (not in raw doc surface I covered)

```lua
Humanizer.IsSafeTarget(entity)        -- framework-aware "is this safe to target?" check
Humanizer.ForceUserOrderByMinimap()   -- inside OnPrepareUnitOrders, force the current order through minimap dispatch
```

**Fold `IsSafeTarget` into `lib/target.lua`** as a `Target.IsSafeTarget(entity)` predicate — framework-aware truth beats hand-rolled safety checks.

`ForceUserOrderByMinimap` is the tool to use when a baseline order is in flight and we want to flip it without abandoning the order entirely.

## Game data assets — `C:\Umbrella\assets\data\*.json`

Five JSON files ship with the framework, providing **static game-state truth** independent of runtime API calls. They are the source for ability KV values (`Ability.GetLevelSpecialValueFor` reads from these), hero base stats, creep stats, item KVs, and the neutral-item tier system. Total ~3.2 MB on disk.

Loaded at runtime via Lua's `io.open(path, "r")` + `JSON:decode(...)` where `JSON` is **Jeffrey Friedl's pure-Lua JSON library** shipped at `<cheat_dir>/assets/JSON.lua` (version 20170927.26, CC-BY licensed). Load it via `local JSON = require('assets.JSON')`. **Note: method-call syntax with colon** (`JSON:decode(raw)`, not `JSON.decode(raw)`). Cache parsed tables; files don't change between game starts. The Umbrella extension's `library/runtime/json.lua` LuaCATS annotation references lua-rapidjson — that's inherited from the FiveM fork and is misleading; the actual asset is Friedl's pure-Lua implementation.

| File | Top-level key | Brain uses |
|---|---|---|
| `npc_abilities.json` | `DOTAAbilities` | Phase 0.5/A enumeration, animation→ability map (Phase 0.5/D), `lib/ability_dmg.lua` damage math, `lib/timing.lua` cast-point lookups, Linkens-pop decisions (read `SpellImmunityType` + `SpellDispellableType`) |
| `npc_heroes.json` | `DOTAHeroes` | Phase 0 baseline (which abilities + talents + facets the hero has), `lib/orbwalk.lua` base attack-anim-point + projectile speed, hero-grid / build module |
| `npc_units.json` | `DOTAUnits` | Last-hit prediction (lane creep `AttackDamageMin/Max` + `ArmorPhysical` + `StatusHealth` + `BountyGoldMin/Max`), tower aggro / dive math, summon awareness (Spirit Bear, familiars, etc.) |
| `items.json` | `DOTAAbilities` | Item-build automation, item cooldown/mana lookups, **`AbilitySharedCooldown`** (Force Staff + Pike share "force"; Refresher chains; etc.), shop tags for category-based filtering |
| `neutral_items.json` | `neutral_items` | Tier unlock timings (Tier 1@0:00, T2@15:00, T3@25:00, T4@35:00, T5@60:00; madstone limit@70:00), per-tier item list, enhancements split by attribute pool (strength / agility / intelligence / universal / global) |

### High-leverage fields per file

**`npc_abilities.json`** (every ability has):
- `AbilityType` (`ABILITY_TYPE_BASIC` / `ULTIMATE` / `ATTRIBUTES`)
- `AbilityBehavior` (pipe-separated string: `"DOTA_ABILITY_BEHAVIOR_UNIT_TARGET | DOTA_ABILITY_BEHAVIOR_NORMAL_WHEN_STOLEN"`)
- `AbilityUnitTargetTeam` / `AbilityUnitTargetType` / `AbilityUnitTargetFlags`
- `SpellDispellableType` / `SpellImmunityType` / `AbilityUnitDamageType`
- `AbilityCastAnimation` — **the activity code for OnUnitAnimation matching** (e.g., `ACT_DOTA_CAST_ABILITY_4`)
- `AbilityCastRange`, `AbilityCastRangeBuffer`, `AbilityCastPoint`, `AbilityChannelTime`
- `AbilityCooldown` (string of per-level values: `"20 15 10"`)
- `AbilityManaCost`
- `AbilityValues` (per-level damage + special-value-name keys, plus talent/scepter/shard nested values via `special_bonus_unique_*`, `special_bonus_scepter`, `special_bonus_shard`)
- `HasScepterUpgrade` flag
- `AbilityDraftExtraAbilities` (shard adds X ability)
- `ID` (numeric ability ID — useful for cross-file references)

**`npc_heroes.json`** (every hero has):
- `Ability1..6` — slot order matches `NPC.GetAbilityByIndex` (1-based)
- `Ability10..17` — talents (standard mapping: 13/17 = lv10, 12/16 = lv15, 11/15 = lv20, 10/14 = lv25 — verify per-hero by checking talent names)
- `Facets` — facet definitions with `Icon`, `Color`, `Deprecated` flag
- `AttackCapabilities` (`DOTA_UNIT_CAP_RANGED_ATTACK` / `MELEE`)
- `AttackDamageMin`, `AttackDamageMax`, `AttackRate`, `AttackAnimationPoint`
- `ArmorPhysical`, `MagicalResistance`
- `AttributePrimary`, `AttributeBaseStrength`/`Agility`/`Intelligence` + `*Gain`
- `StatusHealth`, `StatusMana`, `StatusHealthRegen`, `StatusManaRegen`
- `VisionDaytimeRange`, `VisionNighttimeRange`
- `MovementSpeed`, `MovementTurnRate`, `BoundsHullName`, `RingRadius`
- `ProjectileModel`, `ProjectileSpeed`
- `HeroID`, `Role`, `Complexity`

**`npc_units.json`** (lane creeps, towers, summons, neutrals):
- All hero-shared fields above
- `BountyXP`, `BountyGoldMin`, `BountyGoldMax` — **last-hit reward math**
- `BaseClass` (`npc_dota_creep_lane` / `npc_dota_tower` / `npc_dota_neutral_*` / etc.)
- `Level` for the unit's effective level
- `TeamName` (`DOTA_TEAM_GOODGUYS` / `DOTA_TEAM_BADGUYS` / `DOTA_TEAM_NEUTRALS`)

**`items.json`** (every item):
- `ItemCost`, `ItemShopTags` (semicolon-separated: `"int;damage;mobility;escape;save"`)
- `ItemQuality` (`rare` / `epic` / `artifact` / `legendary` / `consumable` / `component`)
- `AbilityBehavior`, `AbilityCastRange`, `AbilityCooldown`, `AbilityManaCost`
- **`AbilitySharedCooldown`** (group name, e.g., `"force"` for Force Staff / Hurricane Pike)
- `AbilityValues` (effect parameters: push_length, slow_duration, etc.)
- `ItemRequirements` (for recipes, lists component item IDs)
- `ItemDeclarations` (announces purchase to allies/spectators)

**`neutral_items.json`** (tier system):
- Per-tier `start_time` (string `"15:00"`), `trinket_options`, `enhancement_options`, `craft_cost`, `xp_bonus`
- Per-tier `items` table (item names mapped to drop weight)
- Per-tier `enhancements` table split by attribute pool

### How to load in a hero script

```lua
local JSON = require('assets.JSON')  -- Jeffrey Friedl's pure-Lua JSON.lua, CC-BY licensed

local function load_data(filename)
  local path = Engine.GetCheatDirectory() .. "/assets/data/" .. filename
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  return JSON:decode(raw)  -- colon-syntax method call; JSON.decode would error
end

-- Cache once, query many
local ABIL = load_data("npc_abilities.json").DOTAAbilities
local HERO = load_data("npc_heroes.json").DOTAHeroes
local UNIT = load_data("npc_units.json").DOTAUnits
local ITEM = load_data("items.json").DOTAAbilities  -- items also live under DOTAAbilities key

-- Then:
local sniper = HERO["npc_dota_hero_sniper"]
local assassinate = ABIL[sniper.Ability6]
local cast_anim = assassinate.AbilityCastAnimation     -- "ACT_DOTA_CAST_ABILITY_4"
local cast_range = tonumber(assassinate.AbilityCastRange)  -- 3000
local cd_per_level = {}
for v in assassinate.AbilityCooldown:gmatch("%S+") do table.insert(cd_per_level, tonumber(v)) end
-- cd_per_level = {20, 15, 10}
```

### Performance considerations (pure-Lua parser, large files)

Friedl's JSON.lua is pure Lua — no C backing. It uses `..` string concatenation in inner loops, which is O(n²) on string accumulation. Realistic parse times on the asset files:

| File | Size | Estimated parse time |
|---|---|---|
| `neutral_items.json` | 6.5 KB | <10 ms |
| `items.json` | 314 KB | ~50-150 ms |
| `npc_units.json` | 456 KB | ~80-250 ms |
| `npc_heroes.json` | 1.0 MB | ~200-600 ms |
| `npc_abilities.json` | 1.4 MB | ~300-1000 ms |

Parsing all five at script load is ~1-2 seconds. Significant for hot-reload workflows (F-key reloads). Mitigations in order of complexity:

1. **Lazy-load** (recommended for `lib/data.lua`): parse each file only on first access. Sniper-only brain probably touches `npc_heroes.json` and `npc_abilities.json` only; `items.json` and `npc_units.json` load when those modules need them.
2. **Cache aggressively** across hero scripts: store the parsed tables in `_G.HeroBrains.data = {}` so multiple hero scripts share the parse cost.
3. **Per-patch precompile** (advanced): write a one-shot Lua tool that reads each JSON file via Friedl's parser and writes a `return { ... }` Lua module to `assets/data/npc_abilities.lua`. Then hero scripts `require('assets.data.npc_abilities')` which Lua's bytecode-loader handles in <50 ms regardless of size. Re-run the precompiler whenever the JSON files change (every patch).

For the project's scale (hero #1 through ~hero #10), lazy-load + cross-script cache is sufficient. Precompile is an optimization to revisit if reload friction becomes painful.

### Precision options for large integer IDs

Some Dota IDs (especially ability `ID` and item `ID` fields) approach uint32 range. Lua 5.4 handles 64-bit integers natively, but Friedl's parser converts JSON numbers to Lua numbers via `tonumber()` which may lose precision for values > 2^53 (the JS Number max). For the asset files this is rarely a problem (Dota IDs fit in 32 bits), but if you parse other data with huge integers, set the option:

```lua
JSON.decodeIntegerStringificationLength = 16  -- keep integers ≥16 digits as strings
```

before calling `JSON:decode`. The library documents three precision modes (`decodeNumbersAsObjects`, `decodeIntegerStringificationLength`, `decodeDecimalStringificationLength`) at the top of `JSON.lua`.

### Why this is foundational for Phase 0.5

Phase 0.5/A (per-ability enumeration) and Phase 0.5/D (animation→ability map) reduce from "observe in demo, write down findings" to "load JSON, walk the hero's ability list, read each ability's fields." For each ability you get:
- Behavior bits → infer combo categorization (NO_TARGET / UNIT_TARGET / POINT / CHANNELLED / TOGGLE / PASSIVE)
- `AbilityCastAnimation` → directly the activity code for the animation map
- `AbilityCooldown` per level → know exactly when it's available
- `AbilityValues.damage` → base damage at each level, plus talent/scepter bonuses
- `SpellImmunityType` → does it pierce BKB?
- `SpellDispellableType` → can the debuff it applies be dispelled?

**This is the single biggest leverage gain in the project.** Brain authors should consult these files first, then verify behavior in-demo only for edge cases (status interactions, channel-cancel rules, hard-coded engine quirks).

## Framework state files at `<cheat_dir>\*.json`

In addition to game data assets at `assets/data/`, the framework writes per-installation state directly in the cheat root directory. Three files matter, one is opaque:

### `db.json` — flat KV state store (29k+ lines)

Per-feature persistent state, keyed in dot-notation (`db.<feature>.<sub>.<sub>`). Read with the same JSON.lua pipeline:

```lua
local function load_db()
  local f = io.open(Engine.GetCheatDirectory() .. "/db.json", "r")
  local raw = f:read("*a"); f:close()
  return JSON:decode(raw)
end
```

Categories the brain cares about:

**`db.dodger.*` — pre-classified ability danger values (BASE SUBSYSTEM data, do not duplicate)**
- `db.dodger.dangerous_values.<ability_name>.value` → 0 (safe to ignore) or 2 (dangerous, must dodge)
- `db.dodger.dodges_values.<ability_name>.value` → 0/2 (abilities usable as dodge sources, e.g., Lifestealer Rage)
- `db.dodger.global_priority.<n>` → ordered string list of priority assignments

Read this to know which incoming enemy abilities the framework's own Dodger already treats as dangerous. Brain's Layer 2 chain (Pike → Force → Glimmer) fires *after* Dodger has done its work — not as a parallel danger evaluator.

**`db.__dormant_time_cache.<entity_id>` — historical dormancy timestamps (BASE SUBSYSTEM data)**
- Maps entity IDs → seconds (last-seen-dormant time)
- Persisted across sessions
- `lib/fog.lua` reads from here for historical state; uses `OnSetDormant` callback only for real-time transitions

**`db.__match_id_cache` — current match ID**
- Useful for clearing per-match caches without a callback

**`db.<HeroName>.*` — per-hero script state (project convention)**
- Native hero scripts persist runtime cache here: `db.Morphling.cache_check`, `db.Morphling.cache_hp_target`, `db.invoker.invoker_cold_snap.<settings>`, `db.rubick.*`, `db.stealer.*`, `db.kunkka_camps`, `db.meepo.pos`
- **Our brain hero scripts use the same namespacing convention** — write to `db.<Hero>.<key>` for state that should survive reloads (e.g., learned matchup behavior, last-fight timestamp, mana-budget tuning per session)
- Use this beyond `CMenuBind` widget state and `Config.Read*`/`Write*` flat keys

**Other categories visible (mostly base-subsystem, read-only for the brain):**
- `db.auto_pick.{ban,pick}.*` — pre-game pick/ban automation
- `db.mmr_tracker.last_pts`, `db.mmr_tracker.steamid` — MMR tracker
- `db.protracker_shop.npc_dota_hero_*` — per-hero pro item-build cache (suggests `lib/build.lua` would duplicate a base subsystem)
- `db.protracker_domain.last_used_domain_idx` — domain (Sanctus) tracker
- `db.ic.*` — info-card UI panel state (`full_open`, `hide`, `map_open`, `position_percent`, `last_resolution`)
- `db.radius_info`, `db.immortal_info.p_*` — UI/Dota-Plus state
- `db.<HeroName>_autosave_<ability>.pos.*` — per-hero auto-save widget positions (Ringmaster_autosave_ringmaster_the_box, Marci_bodyguard, etc.)

### `inventory.json` — Steam cosmetic inventory cache

~760 lines. Maps Steam cosmetic item IDs → `[scope, slot_index, style_index, is_equipped]` where `scope` is either a hero ID (resolves via `npc_heroes.json` HeroID field) or the sentinel `1000` for universal cosmetics (couriers, wards, HUD skins, music kits, taunts, announcer packs). Example: `"22309": [45, 1, 0, true]` = item 22309 belongs to hero ID 45 (Pugna), slot 1, default style, currently equipped. Style sentinel `255` = "no special variant."

**Brain relevance: minimal.** Cosmetics don't affect gameplay. Document existence; don't depend on it.

### `local_cache.json` — server region preference

4 lines, `{"server": {"de": 0}}`. Trivial. Not brain-relevant.

### `dota.be` — opaque encrypted binary

~19 MB, no recognizable magic bytes (first 16: `01 3b 0b 90 1c 48 bc 79 b6 36 c1 28 59 69 e2 74`), high-entropy content. Framework's internal runtime cache (modules, signatures, anti-tamper state). **Not brain-readable.** No tooling can decode this without the framework's encryption scheme. Skip entirely.

## How this file grows

Add entries as you build heroes:

- A new mechanic surfaced in a hero's Phase 0.5 that wasn't obvious from the docs → add to "Common Dota mechanics" section
- A new enum value used repeatedly → add to the relevant curated table
- A new "brain-task → API" pattern → add to the quick index

Don't dump full enum lists. Those live in the UCZone API v2.0 docs (`cheats-types-and-callbacks/enums.md`). This file is the curated subset that matters for brain work.

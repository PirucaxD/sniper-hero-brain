---
name: UCZone Lua API gotchas (doc-verified additions)
description: Surprising API contracts in UCZone Lua (the Dota 2 hero-brain framework) that contradict their own docs, return inverted semantics, or are silently broken — saved 2026-05-12 after a sweep of the 101-file API tree. Consult before assuming an API behaves as named.
type: reference
originSessionId: 6b3b3286-2889-47eb-8cbe-f66c9ced0fb8
---
The canonical hero-brain project memory (`project_dota_hero_brains.md`) already lists ~20 framework quirks. This file captures **new findings from the 2026-05-12 sweep of `C:\Users\arcos\uczone-api-v2.0\`** plus the LuaCATS library at `C:\Users\arcos\.vscode\extensions\ilka.umbrella-vscode-1.2.1\plugin\library\natives\umbrella\`.

**Why:** the v6.12 Sniper crash on `NPC.GetAttackDamage` (a real-looking but non-existent API) exposed a class of bug — assuming a name. The fixes below catch the others before they bite.

**How to apply:** when about to call one of these APIs in any UCZone Lua file, check this list first. Don't trust the intuitive name; the docs lie in specific ways.

---

## API names that look right but don't exist

- **`NPC.GetAttackDamage`** — does NOT exist. Real APIs in `npc.md`: `GetMinDamage` (base only), `GetBonusDamage` (items/buffs delta), `GetTrueDamage` (min+bonus), `GetTrueMaximumDamage` (max+bonus). For DPS expectation: `(GetTrueDamage + GetTrueMaximumDamage) / 2`. Caused v6.12 brain crash.

- **`Ability.GetSpecialValueFor`** — does NOT exist. Real function is **`Ability.GetLevelSpecialValueFor(ability, name, [lvl])`** despite the doc page literally saying "WRONG API FIX ME IT MUST BE GetSpecialValueFor". That comment is the doc author's editorial wish, not a runtime bug — the LuaCATS library at `Ability.lua:98` defines the function exactly as documented. Use the longer name.

## Inverted / surprising return semantics

- **`Ability.CanBeExecuted(a)`** returns `Enum.AbilityCastResult` enum, and **returns `-1` when OK to cast** (any other value = some block). In Lua, `-1` is truthy, so `if Ability.CanBeExecuted(a) then ... end` passes regardless of cast eligibility. Always compare explicitly: `if Ability.CanBeExecuted(a) == -1 then`. Source: `ability.md:311-319`.

- **`Player.GetName(player)`** returns **TWO** strings: `(nickname, proname|nil)`. Naive `local name = Player.GetName(p)` silently drops the proname. Use `local nick, pro = Player.GetName(p)`. Source: `player.md:90-98`.

- **`Hero.GetLastVisibleTime`** returns `nil` for never-fogged heroes (demo bots, freshly spawned, never seen). Nil ≠ veto — treat as "fresh visible" (`fog_age = 0`). Already in project memory; included here for completeness because it's still the highest-cost gotcha (8400+ no-op dispatches in one match).

## Broken methods (per the docs themselves)

- **`Modifier.GetModifierAura(mod)`** — always returns empty string. Doc: "Should return the name of the modifier's aura, but instead, it returns an empty string in all the cases I have tested." Source: `modifier.md:25-38`.

- **`Modifier.GetSerialNumber(mod)`** / **`Modifier.GetStringIndex(mod)`** — always return 0. Internal state never exposed. Source: `modifier.md:40-68`.

- **`Hero.GetPainFactor`** / **`Hero.GetTargetPainFactor`** — purpose is "Not sure what it is" per the doc itself. Source: `hero.md:151-169`.

- **`Item.CastsOnPickup`** — doc says "No idea what this function does." Avoid. Source: `item.md:137-145`.

- **All `OnModifierAura*` callbacks / Modifier aura methods** are marked `@deprecated`. The aura API is partially dead — query game state directly.

## Edge-case bugs

- **`NPC.GetAngleDiff`** doesn't work for creeps — returns garbage values for non-hero NPCs. Heroes only. Source: `npc.md:722-734`.

- **`NPC.FindRotationAngle(npc, pos)` returns RADIANS, not degrees.** The doc (`npc.md:763-772`) only says "Returns the rotation angle" with no unit. It is radians: `math.abs(...)` caps at π (~3.14). Any threshold written in degrees is silently wrong — `if angle > 30` / `if angle > 120` can NEVER be true, so a degrees-assuming facing gate degrades to always-pass. Confirmed empirically (Sniper v6.15.215): a 30°-assumed Pike facing gate logged `angle=0..3` and never once exceeded it, so Sniper never turned. Always `math.deg()` the result before comparing to a degree threshold (or use `math.rad()` on the threshold). NOTE: several Sniper gates pre-dating this finding still assume degrees (`grenade_self` / `grenade_at_caster` 120, `pre_face_tick`, `anim.lua` `compute_target_self` 30) — they are degraded to always-pass and need a deliberate sweep.

- **`GridNav.CreateNpcMap()`** allocates a map handle that **must be released with `GridNav.ReleaseNpcMap(map)`** or it leaks memory. Pair them in the same code block. Source: `gridnav.md:5-29`.

- **`Entity.GetAbsOrigin(e)`** allocates a fresh Vector each call. For hot loops use **`Entity.GetAbsOriginXYZ(e)`** which returns `(x, y, z)` as three numbers — zero allocation. Source: `entity.md:197-205`.

- **`Entity.GetAbsOrigin(e)` is NILABLE** — it returns nil for a dead, mid-respawn, or just-destroyed entity, even one that passed `Entity.IsEntity(e)` a line earlier (the entity handle is still valid; the unit just has no world position). Any `pos.x` / arithmetic / `:Distance2D(pos)` immediately after a `GetAbsOrigin` needs a `if pos then` guard. Common crash shapes: a target dying mid-tick between `Target.IsAlive` and the pos read; the local hero mid-respawn; a particle/field thinker destroyed between `IsEntity` and `GetAbsOrigin`. A round-3 nil-safety audit of Sniper found 8 such unguarded sites. v6.15.201.

- **`Ability.IsCastable(ability, mana)`** takes a `mana` parameter — you pass the mana budget you have and it returns whether the ability is castable at that mana. Not `IsCastable(ability)` as the name might suggest. Source: `ability.md:151`.

## Callback data shapes that surprise

Verified against `cheats-types-and-callbacks/callbacks.md`:

- **`OnProjectile data`** has `target_loc: Vector` independent of `target: CNPC`. When the projectile is in flight without a tracked entity target, `target_loc` is your impact point. Useful fields beyond the obvious: `expireTime`, `maxImpactTime`, `launch_tick`, `moveSpeed`, `original_move_speed` — enough for full lead/dodge math without polling. Source: `callbacks.md:180-205`.

- **`OnLinearProjectileCreate data.velocity` is a `Vector`, not a scalar** speed. For direction use `velocity:Normalized()`; for speed use `velocity:Length()`. Has no `target` field (it's linear — use `origin + velocity * t` for prediction). Also exposes `acceleration: Vector`, `maxSpeed: number`, `distance: number`. Source: `callbacks.md:231-251`.

- **`OnParticleCreate data.entity` and `data.entityForModifiers` are both nilable** (marked `[?]` default nil) — world particles and pre-cast warning particles often have no owner. Always guard. The `entity_id: integer` and `entity_for_modifiers_id: integer` companions are non-nil and useful for raw matching. `particleNameIndex: integer` is the hashed name for fast compare (use `Utils.ResourceIdFromName` to build the lookup key — already in project memory). Source: `callbacks.md:264-282`.

## Base-only stats that look final (must combine with bonus)

- **`NPC.GetAttackRange(npc)` returns BASE attack range only.** Item bonuses (Pike +75, Dragon Lance +120, Hurricane Pike +75), talents, and active buffs live in **`NPC.GetAttackRangeBonus(npc)`**. Combine: `effective = base + bonus`. The brain previously used base everywhere — Sniper with Pike (effective 625u) was treated as 550u, R fired on targets inside actual autos range. Source: LuaCATS `Npc.lua:293` ("Returns the base attack range"). v6.15.17.

- **`Ability.GetCastRange(ability)` returns the level-specific BASE cast range.** Aether Lens (+250), talents, and other unit-wide cast-range bonuses live in **`NPC.GetCastRangeBonus(npc)`**. Combine: `effective_cast_range(npc, ability) = Ability.GetCastRange(ability) + NPC.GetCastRangeBonus(npc)`. Sniper with Aether Lens has effective R range 3250u; hardcoded `CAST_R = 3000` constants refused R commits beyond the base. v6.15.18.

- **`NPC.GetBaseSpellAmp(npc)` is int-derived only.** Item spell amp lives in `NPC.GetModifierProperty(npc, Enum.ModifierFunction.MODIFIER_PROPERTY_SPELL_AMPLIFY_PERCENTAGE)` and the unique-amp slot `*_PERCENTAGE_UNIQUE` (Kaya, Yasha-Kaya, Octarine). Combine additively (`base + item + unique`) as a close-enough approximation of Dota's multiplicative-with-unique stack for kill-budget math. R damage estimates that miss Octarine's +25% under-call kills on tanky targets. v6.15.18.

**The opposite case** — stats that already return FINAL bonus-aware values (do NOT combine): `NPC.GetMoveSpeed`, `GetTrueDamage`/`GetTrueMaximumDamage`, `GetAttackSpeed`, `GetPhysicalArmorValue`, `GetMagicalArmorValue`, `*DamageMultiplier`, `Entity.GetHealth`/`GetMaxHealth`, `NPC.GetMana`/`GetMaxMana`, `CalculateHealthRegen`, `Hero.GetStrengthTotal`/`GetAgilityTotal`/`GetIntellectTotal`. Don't accidentally double-count.

## Engine timing semantics that surprised

- **Cooldown starts at cast-point END, not start.** `Ability.GetCooldown(ability)` returns 0 during the cast point — the engine sets cooldown when the projectile releases (cast completes). A cast verification that reads cooldown at `issue_time + 0.6s` reports `fired=n` for any ability with a meaningful cast point (R 2s, Q 1.4s) — false negative. Schedule the verify at `issue_time + Ability.GetCastPoint(ability, true) + 0.4s slack`. v6.15.33.

- **Charge-based abilities: `GetCooldown` only bumps when all charges depleted.** Sniper Shrapnel has 3 charges + ~12s charge-refresh timer. After firing 1 of 3, `GetCooldown` may still return 0 because the unit still has charges available. To verify a charge ability fired, compare `Ability.GetCurrentCharges` before/after instead. Generalizes to Tinker Rearm, WD shard Death Ward, etc. v6.15.34.

- **Same-tick CAST orders REPLACE each other unless `queue=true`.** Issuing E + R + Q in the same frame with `queue=false` (the default) — each new non-queued order replaces the unit's current intent. One or more casts get dropped before completing. Engine's unit-order queue (the shift-queue mechanic) chains them properly when `queue=true` is set on the 2nd+ step. Brain pattern: first step `queue=false` (interrupts orbwalk/baseline), subsequent same-tick steps `queue=true`. v6.15.36.

## Diagnostic readouts that need composition

- **`Humanizer.GetOrderQueue()` exposes `triggerCallBack` per entry.** Brain `Order.Issue` sets `callback=true`; native baseline + framework subsystems issue with `callback=false`. The `triggerCallBack` boolean cleanly attributes each queued order. Diff snapshots across frames to log new entries with `source=brain|native_or_other`. Pairs with brain's own `issued` log to prove the order pipeline reaches the queue cleanly. v6.15.23.

- **`CMenuBind:Get(idx)` returns 0 unreliably; `:Buttons()` returns the real codes.** A bind widget with L bound shows `:Get(1)=0, :Get(2)=0, :Buttons()=22/0` (22 = L). `:IsDown()` works regardless and is what brain uses for dispatch decisions; only the readout-for-display path needs `:Buttons()`. v6.15.30.

## Predicate name traps

- **`Target.NotIllusion(e)` is the predicate name (returns true when NOT an illusion).** Writing `not Target.IsIllusion(e)` LOOKS right, compiles, fails at runtime with `attempt to call a nil value (field 'IsIllusion')`. The crash propagates through whatever function called it (in v6.15.10 it disabled pre_face_tick AND armed_threats_tick every frame; 3,859 errors in one match). Same applies to `Target.NotClone`, `Target.NotMeepoClone`, `Target.NotSummon` — all `Not*` predicates, never `Is*`. v6.15.11.

## Stat values that are not what their name implies

- **`NPC.GetMoveSpeed` is a move-speed STAT, not a velocity.** It returns the unit's move-speed *attribute* (~285-330 for any hero) — NON-ZERO while the unit stands perfectly still. Projecting `GetMoveSpeed × facing` to predict a target's future position therefore flings a STATIONARY target's prediction ~`speed × lead` units off-centre (it "predicts" motion for things that aren't moving). For a true velocity vector — direction *and* speed of the unit's *actual* current motion, ~zero when idle — read **`Entity.GetField(target, "m_vecVelocity")`** (the standard Source 2 networked velocity var; undocumented by UCZone, so `pcall`-guard it). `NPC.IsMoving` / `NPC.IsRunning` are the documented "is it actually moving" booleans. Pattern proven by the `Windranger 2.lua` third-party script. v6.15.125-.127.

- **`Ability.GetDamage(ability)` is a STATIC-KV read, not a live computed value.** Despite the name, it returns the `npc_abilities.json` `AbilityDamage` field for the ability — `0.0` if the ability has no static `damage` KV — and does NOT reflect talents / Aghanim / facet bonuses or anything computed at runtime. For a live, level-aware ability value use **`Ability.GetLevelSpecialValueFor(ability, "<key>")`** (the documented long name; the doc page's "WRONG API FIX ME" note is an editorial wish, not a bug — the function works). `GetLevelSpecialValueFor` returns `0` when called on a *talent* handle — talent magnitudes live in the parent ability's `AbilityValues`, so a talent value must be read from the parent (or, if that fails, hardcoded with a comment, as Sniper does). Audit, v6.15.165.

## Useful APIs that replace fragile hand-maintained data

- **`NPC.GetChannellingAbility(npc)` is the modifier-name-free channel detector.** It returns the `CAbility` handle the unit is currently channelling (nil if not channelling); `Ability.GetName` on it gives a reliable ability name. This is far more robust than a hand-maintained `modifier_*` catalog for "is this enemy channelling" — the KV exposes ability names but never modifier names (see below), so any modifier-keyed channel list is a guess that rots. Use `GetChannellingAbility` as the primary; fall back to a modifier check only where a SPECIFIC modifier is needed (e.g. `modifier_teleporting` to single out a TP). Sniper v6.15.189 / .197 / .199.

- **`npc_abilities.json` has ability names + behaviors but NO `modifier_*` names.** The KV exposes `AbilityBehavior`, `AbilityType`, damage, cooldown, cast range, `AbilityValues`, and the ability NAME — but the names of the modifiers an ability applies are NOT in the data (only `SpecialBonusIntrinsic` talent modifiers). So a threat / debuff catalog keyed on modifier names cannot be data-derived; `modifier_<ability>` is a convention guess that must be harvested from an in-game "unrecognized modifier" log. Anything keyed on ABILITY names, behaviors, or cast-activity slots IS fully KV-derivable. Prefer ability-keyed designs.

- **Cast-activity slots are derivable.** `ACT_DOTA_CAST_ABILITY_N` (the cast-animation activity) is the unit's spell-bar slot — Q=1, W=2, E=3, R=4 — NOT the raw index in the hero's KV ability array (which is padded with `generic_hidden`, innate, and hidden entries). Derive the slot: walk the hero's `Ability1..N` list, skip `generic_hidden` / `Innate=1` / `HIDDEN`/`NOT_LEARNABLE` behavior / pure-passive / `ABILITY_TYPE_ATTRIBUTES`; the `ABILITY_TYPE_ULTIMATE` ability is AB4, the first three remaining castables are AB1/AB2/AB3. Sniper v6.15.206 / `tools/gen_anim_maps.py`.

## Behaviors that surprise in bot matches

- **`NPC.IsAttacking(ally)` is unreliable for ALLIED bots.** A heuristic that counts "how many allies are attacking enemy E" by polling `NPC.IsAttacking` on each ally can read `false` for an ally that is visibly attacking — across whole bot matches in some ally-mixes. It DOES report correctly in other matches. Treat any allied-bot `IsAttacking` heuristic as best-effort; instrument it (log allies-found vs allies-attacking) and keep a fallback that doesn't depend on it. Sniper v6.15.190 / .192.

- **The engine silently drops the FIRST cast of a freshly-acquired item.** Confirmed on Hurricane Pike (Sniper v6.15.221 log): the brain issues a valid item cast (`NPC.GetItem` resolved the handle from an active slot with `isReal=true`, `Ability.IsReady` true, target in range, mana fine, caster not disabled), the order reaches `ExecuteOrder` intact, but the item never casts: cooldown stays 0, no effect. The SECOND and every later cast of that item work normally. One cast "breaks the item in"; most likely the engine has not resolved the item's slot / cast state until it is commanded once. A freshly-bought save item cannot be relied on for its first save. Mitigation (Sniper v6.15.222): PRIME the item with one throwaway cast when safe, and DOUBLE-ISSUE (re-issue the order one frame later) so the second, landing cast covers the save.

## How this list grows

Add an entry whenever a UCZone API call surprises you in any of these ways:
- Function name doesn't exist or is differently named
- Return value semantics are inverted vs the type signature
- Doc text admits the function is broken / unknown
- Callback table has nilable fields that crash on access
- Same conceptual flag has different names across sibling functions

Don't add entries for: normal-but-undocumented behavior (those go in `project_dota_hero_brains.md`'s framework-quirks section), or for things that any reader would catch by re-reading the doc page.

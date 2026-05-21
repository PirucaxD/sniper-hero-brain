# Tier 1 Bootstrap — Build the four foundation `lib/` modules (augmentation default)

API: **UCZone Lua 5.4**
API source documentation: `C:\Users\arcos\uczone-api-v2.0` — canonical reference. Every API call signature, callback shape, and enum value comes from this directory.
Project root: `C:\Users\arcos\dota-hero-brains`. Reference: `BRAIN_PROJECT.md` § Shared library plan — three tiers.

**This is pure infrastructure work.** No brain logic. No hero research. No pro VODs. Four small modules that every hero will depend on under the augmentation pattern. Build them once, test in demo, move on.

Output files (all in `C:\Users\arcos\dota-hero-brains\lib\`):
- `order.lua`
- `damage.lua`
- `anim.lua`
- `target.lua`

(Note: `item.lua` was previously Tier 1 under the replacement pattern. Under augmentation it's demoted to Tier 2 — baseline Items Usage handles most cases; build `item.lua` only when 2+ heroes need direct item-state queries that baseline doesn't expose. The `Item.lua` Module 5 section below is preserved in this doc for reference but **do not build during Tier 1 bootstrap**; treat it as a Tier 2 spec.)

Build sequence: `order.lua` first (the others may eventually depend on it), then `damage.lua`, `anim.lua`, `target.lua`. Each module is self-contained — no dependencies between them at this stage.

Stage 2 information level (framework's "unsafe mode" toggle) is assumed ON by project default. `damage.lua` must handle the OFF case as a fallback path.

---

## Module 1 — `lib/order.lua`

**Purpose:** single chokepoint for all order issuance. Enforces identifier discipline, prevents double-stacking, fails loud on untagged orders.

### Interface

```lua
local Order = require("lib.order")

-- Issue an order. Returns true if dispatched, false if skipped (duplicate, invalid, etc.)
Order.Issue({
  hero        = "sniper",       -- string, lowercased hero short name
  layer       = "agg" or "def", -- string, aggressive combo or defensive mechanic
  intent      = "burst",        -- string, what this order is for (free-form, kept short)
  order_type  = Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_TARGET,
  target      = some_npc,       -- CEntity or nil
  position    = some_vector,    -- Vector or nil
  ability     = some_ability,   -- CAbility or nil
  unit        = local_hero,     -- CNPC (the issuer)
  queue       = false,          -- optional, default false
  show_effects= false,          -- optional, default false
  execute_fast= false,          -- optional, default false (forced true for layer=="def")
  force_minimap=true,           -- optional, default true
})

-- Check whether an order with a given identifier prefix is already pending in the
-- humanizer queue. Hero brains call this before computing a new order to avoid
-- redundant work.
Order.IsPending("sniper-agg-")  -- prefix match against the identifier of any queued order

-- Build a canonical identifier string. Order.Issue does this internally, but it's
-- exposed for tooling/logging.
Order.Identifier("sniper", "agg", "burst")  -- returns "sniper-agg-burst"
```

### Implementation requirements

- Always sets the callback-route flag on the underlying API call so our own `OnPrepareUnitOrders` handler can self-arbitrate. **The flag's parameter name differs across the three Player order functions**: `callback` (boolean) on `Player.PrepareUnitOrders`, `push` (boolean) on `Player.HoldPosition` and `Player.AttackTarget`. Same semantics ("route this order through `OnPrepareUnitOrders`"); use whichever name the called function expects. The `Order.Issue` wrapper handles this internally — callers just pass `spec` without naming the underlying flag.
- `force_minimap` defaults to true; spec can override.
- `execute_fast` forced to `true` when `spec.layer == "def"` (defensive layer needs to beat humanizer). Otherwise honors spec.
- **Validation:**
  - `hero`, `layer`, `intent`, `order_type`, `unit` are required. Missing → `error()` during dev (assert), fail-quiet (return false + log) when project-level `STRICT=false`.
  - `layer` must be `"agg"` or `"def"`. Other values → fail loud.
  - `unit` must satisfy `Entity.IsAlive` and not be dormant. If not, return false.
  - For target-required order types: `target` must be valid (alive or destroyable). Skip if invalid.
  - For position-required order types: `position` must not be nil.
- **Duplicate detection:**
  - Read `Humanizer.GetOrderQueue()` before issuing.
  - Iterate pending orders; if any pending order has the same identifier (full match, not prefix), skip and return false.
  - If a pending order has the same `hero-layer` prefix but a different intent, still issue (different intents within a layer are allowed simultaneously).
- Build the identifier string as `"<hero>-<layer>-<intent>"` (lowercase, hyphens, no spaces).

### Edge cases

- Local player not in game / `Players.GetLocal()` returns nil → return false silently (script is idle).
- Order type doesn't take a target but spec provided one → strip the target before passing to `PrepareUnitOrders` (defensive, but log a warning during dev).
- `Humanizer.GetOrderQueue()` returns empty / nil → treat as no pending orders.
- Ability is on cooldown / unable to cast (mana, silence) → caller should check before calling `Order.Issue`, but as a safety net: if `ability` is provided and `Ability.IsReady(ability)` returns false, return false.

### Verification (run in demo)

1. Call `Order.Issue` without `identifier` fields → asserts (or returns false + logs error).
2. Call `Order.Issue` twice rapidly with same spec → second call returns false. Confirm via `Humanizer.GetOrderQueue()` — only one entry.
3. Call from `OnUpdateEx` with valid spec → order appears in queue with correct identifier.
4. Layer="def" + execute_fast omitted → confirm `triggerCallBack` and execute_fast behavior in the queued entry.

---

## Module 2 — `lib/damage.lua`

**Purpose:** damage feed abstraction. Hero code reads recent damage without knowing whether Stage 2 typed feed or polling fallback is live.

### Interface

```lua
local Damage = require("lib.damage")

Damage.Init()  -- called once at script load. Detects Stage 2 state, wires the right path.

-- Total damage taken by `npc` in the last `window_seconds` (default 1.5).
Damage.GetRecentDamage(npc, window_seconds)  -- → number

-- Total damage from a specific source in the window. Stage 2 OFF returns 0 (no attribution).
Damage.GetRecentDamageBySource(npc, source_npc, window_seconds)  -- → number

-- Damage rate (per second). Useful for Layer 2 threshold checks.
Damage.GetDamageRate(npc, window_seconds)  -- → number

-- Cleanup hook called on entity destroy (the module subscribes internally; exposed for tests).
Damage.Forget(npc)
```

### Implementation requirements — Stage 2 ON

- Subscribe to `OnEntityHurt` callback.
- Maintain a table keyed by entity handle. Each value is a ring buffer of entries `{time, source_handle, ability_handle, damage}`.
- Buffer size: 64 entries per entity OR auto-GC entries older than 3 seconds, whichever drops first.
- On `OnEntityDestroy`, clean up the buffer for that entity.
- `GetRecentDamage` walks the buffer, sums entries where `time >= now - window`.

### Implementation requirements — Stage 2 OFF (fallback)

- In `OnUpdateEx`, poll `Entity.GetHealth(local_hero)`. Compute `delta = previous - current`. If delta > 0, push entry with `source=nil, ability=nil, damage=delta`.
- For *incoming* damage prediction, subscribe to `OnProjectile` and `OnLinearProjectileCreate`. When a projectile targets the local hero, push a *speculative* entry with `time=expected_impact, source=projectile.source, damage=estimated`. (Estimation: for basic attacks use `source:GetTrueDamage()` × armor mult from `target:GetArmorDamageMultiplier()`. For abilities, the brain may pass damage estimates via a separate API in v2.)
- For DoT, subscribe to `OnModifierCreate`. If the modifier is a known DoT (name pattern matching `*_damage`, `*_burn`, `*_poison`), push estimated per-tick entries at the modifier's tick interval.
- Caveat: source attribution is `nil` in fallback mode. `GetRecentDamageBySource` returns 0.

### Edge cases

- Stage 2 toggled mid-game (rare): detect by trying to register `OnEntityHurt` at init. If callback never fires after first damage event, switch to polling. Log the transition.
- Local hero death/respawn: clear the local hero's buffer on death (so post-respawn damage starts fresh).
- Morphling stat swap, hero replication: buffer is keyed on handle; if handle changes, treat as new entity.

### Verification (run in demo)

1. Stage 2 ON: take damage from creep → `Damage.GetRecentDamage(self, 1.5) > 0`. Source-attributed → `Damage.GetRecentDamageBySource(self, creep, 1.5) > 0`.
2. Stage 2 OFF: same test → `GetRecentDamage > 0`, source returns 0.
3. Survive 5 seconds without damage → `GetRecentDamage` decays to 0 as ring buffer expires.

---

## Module 3 — `lib/anim.lua`

**Purpose:** animation→ability map dispatcher. Heroes register per-matchup maps; the dispatcher reads `OnUnitAnimation`, looks up the activity in the casting unit's hero map, and fires semantic events.

### Interface

```lua
local Anim = require("lib.anim")

Anim.Init()  -- called once at script load. Subscribes to OnUnitAnimation, OnEntityCreate.

-- Heroes register their matchup maps during their own init.
Anim.RegisterMap("npc_dota_hero_slark", {
  [Enum.GameActivity.ACT_DOTA_ATTACK] = nil,  -- explicitly not interesting
  [SLARK_POUNCE_ACTIVITY] = {
    ability = "slark_pounce",
    role    = "gap_close",     -- one of: gap_close | hard_disable | ult_burst | channel_start | dispel | save
  },
  -- ...
})

-- Hero subscribes to roles it cares about. Multiple subscribers allowed.
Anim.Subscribe("gap_close", function(event)
  -- event = { caster=CNPC, ability_name=string, role=string, raw=anim_callback_data, target_self=boolean }
  -- target_self is computed: true if caster is enemy AND faces local hero AND distance < ability range.
end)

-- Heroes may register particle signatures as a secondary detection path.
Anim.RegisterParticle("particles/units/heroes/hero_bloodseeker/bloodseeker_rupture_start.vpcf", {
  ability = "bloodseeker_rupture",
  role    = "channel_start",
  on_target_field = "entityForModifiers",  -- which OnParticleCreate field identifies the target
})
```

### Implementation requirements

- Internal table: `maps[hero_unit_name][activity_key] = {ability, role}`. `activity_key` may be an integer (`Enum.GameActivity`) or a string (`sequenceName`) — handle both.
- On `OnUnitAnimation(data)`:
  1. `data.unit` → resolve to hero name via `NPC.GetUnitName(unit)`.
  2. If not in any registered map, ignore (optionally log during dev).
  3. Look up `data.activity` or `data.sequenceName` in the hero's map.
  4. If found, build the semantic event. Compute `target_self`:
     - `caster` must be enemy team (`Entity.GetTeamNum(caster) != GetTeamNum(local_hero)`)
     - Caster must face local hero: `NPC.FindRotationAngle(caster, local_hero_pos) <= angle_threshold` (default 30°)
     - Caster within ability range (use a hero-provided range hint or default 1200u)
  5. Fire all subscribers for the matched role with the event.
- Particle path: subscribe to `OnParticleCreate`. Match particle name against registered signatures. Fire equivalent semantic events.
- Stolen abilities (Rubick) and invoked abilities (Invoker) are out of scope for v1 — track in a TODO comment, handle when the first such hero needs it.

### Edge cases

- Multiple heroes share an activity code with different abilities → map is keyed on hero name, so this resolves naturally.
- Sub-units (Lone Druid bear, Visage familiars): register the sub-unit name as a separate map key.
- Activity not in map → no event fires. In dev mode, optionally log "unmapped activity N on hero X" once per (hero, activity) pair so the user can extend the map.
- Local hero animations: don't fire events for self (we know our own state directly).

### Verification (run in demo)

1. Register a minimal map for Slark with the pounce activity → spawn Slark in demo → cast Pounce toward you → `Anim.Subscribe("gap_close", ...)` handler fires with `target_self=true`.
2. Cast Pounce away from you → handler fires with `target_self=false`.
3. Register Bloodseeker Rupture particle signature → cast Rupture on you → handler fires.
4. Cast an ability not in the map → no handler fires; dev log shows the unmapped activity.

---

---

## Module 4 — `lib/target.lua`

**Purpose:** composable predicate helpers used by every hero's Phase 2 rules. **There is no `Target.Pick()` function — that's intentional.** Heroes compose the predicates inline because target-picking logic is per-hero (Tier 3).

### Interface

```lua
local Target = require("lib.target")

-- All return boolean. All accept nil and return false (no nil checks needed at call sites).
Target.IsValid(entity)             -- not nil + IsExist
Target.IsAlive(entity)             -- IsValid + Entity.IsAlive (handles invuln-during-respawn correctly)
Target.IsHero(entity)              -- Entity.IsNPC + NPC.IsHero (uses cached check, not IsConsideredHero)
Target.IsConsideredHero(entity)    -- treats Lone Druid bear, Tempest Double, etc. as heroes
Target.IsEnemyHero(entity, source) -- IsHero + IsTeamSuitable(source, entity, TARGET_TEAM_ENEMY)
Target.IsAllyHero(entity, source)  -- IsHero + IsTeamSuitable(source, entity, TARGET_TEAM_FRIENDLY)
Target.NotIllusion(entity)         -- not NPC.IsIllusion
Target.NotMeepoClone(entity)       -- not NPC.IsMeepoClone (separate API call)
Target.NotClone(entity)            -- NotIllusion + NotMeepoClone + not Tempest Double
Target.NotSummon(entity)           -- not owned-by-hero (filters spirits, brood spiders, etc.)
Target.InRange(target, source, range, [hull])  -- NPC.IsPositionInRange wrapper
Target.IsKillable(entity)          -- NPC.IsKillable (false if Eul/cyclone target)
Target.IsVisible(entity)           -- NPC.IsVisible to local player
Target.HasState(entity, state)     -- NPC.HasState wrapper
Target.HasReadyLinkens(entity)     -- has item_sphere AND Item.HasReady("item_sphere")
Target.HasReadyLotus(entity)       -- has item_lotus_orb AND ready
Target.WillBeInvulnIn(entity, ms)  -- inspects active modifier expirations + known-to-trigger items; returns true if invuln window opens within ms
Target.EffectiveHpVs(target, source, damage_type)
  -- composes: GetHealth + barriers + armor mult (physical) or magic resist (magical) + bonus damage stack (Bloodthorn, etc.)
  -- returns the effective HP a damage_type burst needs to chew through to kill
  -- damage_type is Enum.DamageTypes
```

### Implementation requirements

- Every predicate must accept `nil` input and return `false`. Eliminates nil-checks at call sites.
- `EffectiveHpVs` is the most complex predicate — it must handle:
  - Physical: `Entity.GetHealth + barriers - (damage * NPC.GetArmorDamageMultiplier(target))`
  - Magical: `Entity.GetHealth + magic_barrier - (damage * NPC.GetMagicalArmorDamageMultiplier(target))`
  - Pure: ignores armor and resist
  - Target with `MODIFIER_STATE_MAGIC_IMMUNE` and damage_type=magical → returns Infinity (or very large number)
  - Target with `MODIFIER_STATE_INVULNERABLE` → returns Infinity
- `WillBeInvulnIn(entity, ms)` reads `GetStatesDuration({STATE_INVULNERABLE, STATE_OUT_OF_GAME})` AND checks for known-soon-to-trigger items (Eul on self, Manta dispel-into-invuln window). v1 only checks state durations; v2 (Tier 2 candidate via `lib/timing.lua`) integrates item-cast-window prediction.
- Performance: predicates called every frame on every potential target. No allocations inside predicates. No table creation. Reuse parameter signatures.

### Edge cases

- `EffectiveHpVs` with a target that died this tick → `IsAlive` returns false earlier; predicate shouldn't be called. But add `not Target.IsAlive(target) → return 0` defensive guard.
- `HasReadyLinkens` / `HasReadyLotus` rely on `lib/item.lua`. If `item.lua` isn't loaded, fall back to `NPC.HasItem(name)` (no cooldown check).
- `NotClone` for Arc Warden Tempest Double: Tempest Double has a specific modifier (`modifier_arc_warden_tempest_double`). Check via `NPC.HasModifier`.

### Verification (run in demo)

1. `Target.IsAlive(nil)` → false (no error).
2. `Target.IsEnemyHero(enemy, self)` returns true; `Target.IsEnemyHero(ally, self)` returns false.
3. `Target.EffectiveHpVs(enemy, self, DAMAGE_TYPE_MAGICAL)` against magic-immune enemy → Infinity / very large number.
4. `Target.WillBeInvulnIn(enemy, 500)` against enemy with 0.3s stun remaining and 0.2s eul self-coming → true.
5. `Target.NotMeepoClone(meepo_clone)` → false; `Target.NotMeepoClone(real_meepo)` → true.

---

## Module 5 — `lib/item.lua`

**Purpose:** item state queries that compose `NPC.GetItem` + `Ability.IsReady` + `Ability.GetCooldown` into one-call helpers. Used by every Layer 2 brain and every aggressive combo's pre-condition check.

### Interface

```lua
local Item = require("lib.item")

Item.HasReady(npc, name)              -- → boolean. Has item AND it's off cooldown AND not disabled.
Item.HasAnyReady(npc, names_table)    -- → boolean. names_table is array {"item_force_staff", "item_hurricane_pike"} or hash set {item_force_staff=true, ...}.
Item.GetReady(npc, name)              -- → CItem | nil. The CItem if ready, nil otherwise.
Item.GetFirstReady(npc, names_table)  -- → CItem | nil. First ready item from the list.
Item.CooldownRemaining(npc, name)     -- → number (seconds). 0 if ready, large positive if not ready.
Item.GetCharges(npc, name)            -- → integer | nil. Current charges (wards, bottle, drums, etc.).
Item.HasInSlot(npc, name, slot_range) -- → boolean. slot_range optional, default {1..6} for "real" inventory. Slots 7-8 for backpack, 9 for neutral, 10-15 for stash.
Item.GetActive(npc)                   -- → CItem | nil. Item currently being cast (from Player.GetActiveAbility if it's an item).
```

### Implementation requirements

- `HasReady` composes: `NPC.HasItem(name)` + `NPC.GetItem(name)` + `Ability.IsReady(item)` + check no `MODIFIER_STATE_MUTED` on owner.
- `HasAnyReady` supports both array form (fast iterate) and hash-set form (single-pass; faster when checking against many items).
- Items in stash count as "have" but not "ready" (cannot be cast from stash). Use `Ability.IsReady` (handles this correctly per UCZone docs).
- `GetCharges` returns nil for items that don't have charges (i.e., `Item.IsRequireCharges` returns false). Returns 0 for stack-out items like depleted Bottle.
- Caching: per-frame cache the `NPC.GetItem(npc, name)` lookups indexed by (npc handle, name). Invalidate on `OnUnitInventoryUpdated`. v1 can skip the cache; add later if profile shows hot path.
- Stage 2 doesn't affect this module — no callback gating.

### Edge cases

- NPC silenced/muted: items that require an active state can't be cast — `HasReady` returns false. Items that don't require active state (passives, Bottle if hexed) — case-by-case. Default: treat any owner-active-CC as "not ready" unless the item is known to bypass (BKB-while-silenced edge case).
- Multiple of same item (some items stack, like Wards): `NPC.GetItem(name)` returns the first instance; `HasReady` checks that instance's cooldown. For "do I have a ready ward" the first-instance check is correct.
- Refresher Shard: when refresher is cast, items go from on-cooldown to ready mid-frame. `HasReady` reflects this immediately on next call (no caching of "ready" boolean — recompute).
- Aghs Shard / Aghs Scepter: distinct items vs hero modifiers (`NPC.HasScepter` / `NPC.HasShard` already wraps the modifier check). Don't confuse — for shard/scepter use `NPC.HasScepter`/`NPC.HasShard`; this module is for inventory items only.

### Verification (run in demo)

1. Empty inventory: `Item.HasReady(self, "item_force_staff")` → false.
2. Buy Force Staff: `Item.HasReady(self, "item_force_staff")` → true. Use it: → false until cooldown elapses.
3. `Item.HasAnyReady(self, {"item_force_staff", "item_hurricane_pike"})` returns true if either is ready.
4. `Item.CooldownRemaining(self, "item_force_staff")` returns 0 when ready, ~20 right after use, decreasing.
5. `Item.GetCharges(self, "item_bottle")` returns 0-3 as expected.

---

## Cross-cutting

- Use LuaCATS annotations on the public interface of each module.
- Each module returns its table at the bottom (`return M` pattern).
- Each module's `Init` is idempotent — safe to call multiple times.
- No global side effects beyond the registered callbacks.
- Each module logs to UCZone's `Log.Write` only when an actual error/anomaly happens. No verbose "running" logs in production paths.

When all four Tier 1 modules are written and verified in demo, write a `lib/CHANGELOG.md` entry:

```
## Tier 1 Bootstrap — [date]
- Built lib/order.lua, lib/damage.lua, lib/anim.lua, lib/target.lua
- (lib/item.lua specced but deferred to Tier 2 under augmentation pattern)
- Verified in demo: [list verification cases that passed]
- Known limitations: [anything carried forward as TODO]
```

Then the project is ready for the first hero.

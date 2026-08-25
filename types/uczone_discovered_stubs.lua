---@meta

-- ============================================================================
-- UCZone API v2.0 - Discovered (undocumented) function stubs for VS Code
--
-- These are real APIs used in third-party UCZone scripts (Sniper, KotL, Ogre
-- Magi, Meepo, Tusk, etc.) that aren't in the official UCZone API v2.0
-- documentation tree.
--
-- The signatures below are inferred from call-site usage. Confidence levels
-- are noted per entry. See the UCZone API v2.0 `DISCOVERED_APIs.md` for full
-- context, source citations, and code examples.
--
-- This file complements the stubs bundled with the umbrella-vscode extension
-- and provides VS Code autocomplete for these missing entries.
--
-- To enable: add this `types/` directory to your workspace's
-- `Lua.workspace.library` setting in .vscode/settings.json.
-- ============================================================================

-- ============================================================================
-- Ability namespace
-- ============================================================================

---Returns the special value for a key on the ability without level-aware indexing.
---Returns the level-1 entry or raw value for non-level-keyed KV entries.
---Confidence: HIGH. KotL uses this as a fallback to GetLevelSpecialValueFor.
---@param ability userdata
---@param key string
---@return number
function Ability.GetSpecialValue(ability, key) end

---Returns the level-aware special value for a key on the ability.
---Identical signature to the documented `Ability.GetLevelSpecialValueFor`.
---Both APIs exist; the documented variant is preferred.
---Confidence: HIGH. Used by Meepo for ability + item KV reads.
---@param ability userdata
---@param key string
---@return number
function Ability.GetSpecialValueFor(ability, key) end

-- ============================================================================
-- Entity namespace
-- ============================================================================

---Returns the entity's absolute (world-space) rotation as a quaternion-like
---object that exposes a :GetForward() method returning a Vector.
---The documented `Entity.GetRotation` is similar (may return local rotation).
---Confidence: HIGH. Used by Windranger combo for shackle direction prediction.
---@param entity userdata
---@return userdata  # quaternion-like, has :GetForward() returning Vector
function Entity.GetAbsRotation(entity) end

-- ============================================================================
-- Hero namespace
-- ============================================================================

---Returns the CPlayer that owns/controls this hero. Returns nil for illusions
---or bot units without an associated player slot.
---Alternative to `Players.GetLocal()` when iterating allies (each ally's owner
---is needed individually). Use `Players.GetLocal()` for the local player path.
---Confidence: MEDIUM. Tusk script wraps in pcall; availability may vary.
---@param hero userdata
---@return userdata|nil
function Hero.GetPlayer(hero) end

-- ============================================================================
-- NPC namespace
-- ============================================================================

---Direct shortcut for casting vector-target abilities (Tusk Walrus Kick,
---Magnus Skewer, etc.). Vector abilities take TWO positions: a starting
---reference + an end point that together define cast direction and distance.
---Conventional path: `Player.PrepareUnitOrders` with `DOTA_UNIT_ORDER_VECTOR_TARGET_POSITION`.
---Confidence: MEDIUM. Tusk script wraps in pcall as fallback.
---@param npc userdata
---@param ability userdata
---@param fromPos userdata  # Vector - starting reference (typically target pos)
---@param toPos userdata    # Vector - destination/direction endpoint
function NPC.CastAbilityVector(npc, ability, fromPos, toPos) end

---Returns the unit's physical armor as a raw number (e.g. 8.5).
---Different from `NPC.GetArmorDamageMultiplier` (returns damage multiplier
---like 0.66 for ~34% reduction). Use `GetArmorDamageMultiplier` for damage
---math; `GetArmor` for displaying armor or computing custom adjustments.
---Confidence: MEDIUM. Used by Meepo for armor display.
---@param npc userdata
---@return number
function NPC.GetArmor(npc) end

---Returns the unit's BASE max attack damage (without item or buff bonuses).
---For total damage with bonuses, use `NPC.GetTrueMaximumDamage` (documented).
---Confidence: MEDIUM. Used by Meepo.
---@param npc userdata
---@return number
function NPC.GetDamageMax(npc) end

---Returns the unit's BASE min attack damage (without item or buff bonuses).
---For total damage with bonuses, use `NPC.GetTrueDamage` (documented).
---Confidence: MEDIUM. Used by Meepo.
---@param npc userdata
---@return number
function NPC.GetDamageMin(npc) end

---Returns the unit's facing direction as a Vector. Useful for movement
---prediction (combine with NPC.GetMoveSpeed and NPC.IsMoving / NPC.IsRunning).
---Equivalent: `Entity.GetRotation(npc):GetForward()` (documented path).
---Confidence: HIGH. Used by Sniper auto-grenade for enemy position prediction.
---@param npc userdata
---@return userdata  # Vector
function NPC.GetForwardVector(npc) end

---Returns the unit's magic resist as a fractional value (e.g. 0.25 = 25%).
---Different from `NPC.GetMagicalArmorValue` (raw value) and
---`NPC.GetMagicalArmorDamageMultiplier` (damage multiplier).
---Confidence: MEDIUM. Used by Meepo.
---@param npc userdata
---@return number
function NPC.GetMagicalResist(npc) end

---Returns the CPlayer that owns the unit (works on heroes, summons, wards).
---Returns nil for neutral units, fountain, or bots without a player slot.
---Identical use case to `Hero.GetPlayer` but works on any CNPC.
---Confidence: MEDIUM. Tusk script wraps in pcall.
---@param npc userdata
---@return userdata|nil
function NPC.GetPlayerOwner(npc) end

---Returns the hero's total spell amplification as a fractional value
---(e.g. 0.25 = +25% from int + Octarine + Kaya + talents combined).
---Avoids manual modifier-property summing.
---Confidence: HIGH. Used by KotL for Illuminate damage estimation.
---@param hero userdata
---@return number
function NPC.GetSpellAmplification(hero) end

---Returns true if the unit is a fountain (radiant or dire).
---Filter out from area-of-effect target scans (combat shouldn't target fountains).
---Confidence: HIGH. Used by Meepo with safe_call wrapper.
---@param npc userdata
---@return boolean
function NPC.IsFountain(npc) end

---Returns true if the unit currently has the invulnerable state.
---Equivalent to `NPC.HasState(npc, Enum.ModifierState.MODIFIER_STATE_INVULNERABLE)`.
---Direct predicate is cleaner than HasState lookup.
---Confidence: HIGH. Used by Sniper auto-grenade.
---@param npc userdata
---@return boolean
function NPC.IsInvulnerable(npc) end

---Returns true if the unit is currently moving (velocity is non-zero).
---Distinct from `NPC.IsRunning` which is true while a unit has a move order
---in progress (a unit can be IsRunning=true while velocity ramps, or
---IsMoving=false if blocked).
---Confidence: HIGH. Used by Sniper auto-grenade for prediction gating.
---@param npc userdata
---@return boolean
function NPC.IsMoving(npc) end

---Returns true if the unit currently has the rooted state.
---Equivalent to `NPC.HasState(npc, Enum.ModifierState.MODIFIER_STATE_ROOTED)`.
---Direct predicate is cleaner than HasState lookup.
---Confidence: HIGH. Used by Sniper auto-grenade.
---@param npc userdata
---@return boolean
function NPC.IsRooted(npc) end

---Returns true if the unit is currently visible to the local player's team
---(NOT in fog of war). Snapshot only - for fog-of-war age tracking use
---the documented `Hero.GetLastVisibleTime`.
---NOTE: NOT the same as Vector:IsVisible (which checks screen visibility).
---Confidence: HIGH. Used by Sniper auto-grenade and Meepo.
---@param npc userdata
---@return boolean
function NPC.IsVisible(npc) end

-- ============================================================================
-- "Looks real but doesn't exist" - DO NOT TRY THESE
--
-- These names look plausible but the APIs do not exist in UCZone v2.0.
-- Listed here as warnings so VS Code's autocomplete won't accidentally show
-- them as valid suggestions (commented out - autocomplete will skip).
-- ============================================================================

-- function Entity.GetByIndex(idx) end       -- DOES NOT EXIST. Use Entity.Get(idx).
-- function NPC.GetAttackDamage(npc) end     -- DOES NOT EXIST. Use (NPC.GetTrueDamage + NPC.GetTrueMaximumDamage) / 2
-- function NPC.GetEvasion(npc) end          -- DOES NOT EXIST. Walk items + passive table manually.

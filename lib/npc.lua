---@meta
---lib/npc.lua — generic NPC stat & inventory queries.
---
---Hero-agnostic. Each function takes an npc handle as the first argument.
---Extracted from Sniper.lua v6.15.112 to reduce main-chunk local count
---(Lua 5.4's 200-locals-per-function hard limit was hit twice in
---v6.15.110 and v6.15.111 — see Lesson 7 in Sniper's BRIDGE_FOR_NEXT_CHAT.md).
---
---Two extracted areas:
---  - Aghanim's Shard / Scepter ownership checks
---  - Item lookup + ready checks
---
---NOT in scope (intentional):
---  - Range / cast-range / spell-amp queries are GLOBAL functions in
---    Sniper.lua (no `local` keyword) so they don't consume local slots
---    — extracting them would be aesthetic-only with zero slot benefit.
---    Re-evaluate if a future hero re-uses them and Sniper's globals
---    become awkward.
---  - find_ability / ability_ready stay in Sniper because find_ability has
---    a Sniper-specific multi-slot scan branch for the shard-granted
---    grenade. Generalize when hero #2 has a similar shard-granted ability.

local NPC_lib = {}

---Aghanim's Shard ownership.
---@param npc userdata|nil
---@return boolean
function NPC_lib.has_shard(npc)
    if not npc then return false end
    return (NPC.HasShard and NPC.HasShard(npc)) or false
end

---Aghanim's Scepter ownership.
---@param npc userdata|nil
---@return boolean
function NPC_lib.has_scepter(npc)
    if not npc then return false end
    return (NPC.HasScepter and NPC.HasScepter(npc)) or false
end

---Item lookup by name. Includes backpack/stash by default? NO — third
---arg `true` means INVENTORY ONLY (active slots, not backpack/stash).
---Sniper's pattern. Use `false` to scan inventory + backpack + stash.
---@param npc userdata|nil
---@param name string
---@param inventory_only? boolean (default true)
---@return userdata|nil
function NPC_lib.item(npc, name, inventory_only)
    if not npc or not name then return nil end
    if inventory_only == nil then inventory_only = true end
    return NPC.GetItem(npc, name, inventory_only)
end

---Item is owned AND ready (off cooldown, etc.). Inventory-only by default.
---@param npc userdata|nil
---@param name string
---@param inventory_only? boolean (default true)
---@return boolean
function NPC_lib.item_ready(npc, name, inventory_only)
    local it = NPC_lib.item(npc, name, inventory_only)
    return it ~= nil and Ability.IsReady(it)
end

return NPC_lib

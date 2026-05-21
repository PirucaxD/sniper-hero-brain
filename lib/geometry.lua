---@meta
---lib/geometry.lua — generic 2D position / distance / prediction helpers.
---
---Hero-agnostic. All functions take entity or vector args explicitly
---(no implicit hero-state reads).
---
---Extracted from Sniper.lua v6.15.112 to reduce main-chunk local count.

local Geometry = {}

---2D distance between two entities.
---@param a userdata|nil first entity
---@param b userdata|nil second entity
---@return number distance, math.huge if either entity is nil
function Geometry.dist_between(a, b)
    if not a or not b then return math.huge end
    local pa = Entity.GetAbsOrigin(a)
    local pb = Entity.GetAbsOrigin(b)
    -- Distance2D over (pa - pb):Length2D(): one native call, no temp Vector.
    return pa:Distance2D(pb)
end

---2D distance from one entity to another (alias of dist_between, but
---with an explicit "from → to" mental model for callers used to that).
---@param from userdata|nil
---@param to userdata|nil
---@return number
function Geometry.dist_from_to(from, to)
    return Geometry.dist_between(from, to)
end

---Predicted target position `lead_s` seconds ahead, from the target's
---actual VELOCITY VECTOR.
---
---Returns `nil` when the target is unusable (nil / not an Entity / no
---position). Callers handle this with `... or fallback` (every Sniper
---call site does `Geom.lead_target_pos(...) or c.target_pos`).
---Returns the target's CURRENT position (no lead) when the target is
---valid but not actually moving.
---
---v6.15.125 REWRITE — the old model was mathematically wrong. It used
---`NPC.GetMoveSpeed`, which is a move-speed STAT (≈285-330 for any hero,
---non-zero while standing still), projected along the facing yaw. So a
---STATIONARY target had its zone placed `GetMoveSpeed * lead_s` (~450u
---at lead 1.5s) off-centre in its facing direction, and a moving target
---had the lead pointed along facing rather than travel (wrong whenever
---facing ≠ motion). The `mvspeed < 200` gate never caught stationary
---units because the stat itself is ~300.
---
---The model now reads the engine's true velocity vector via
---`Entity.GetField(target, "m_vecVelocity")`: zero velocity → zero lead
---(a stationary target keeps its centre), real velocity → correct
---travel direction and speed. `future = pos + velocity * lead_s`.
---Pattern proven in the Windranger 2 third-party script (Shackleshot
---leads). `m_vecVelocity` is an undocumented Source 2 field — pcall-
---guarded; the fallback (facing × move-speed, only while a move order
---is live) is the old model but at least gated so it never leads a
---standing unit.
---
---@param target userdata|nil target entity
---@param me userdata|nil caster entity (unused; kept for API stability)
---@param lead_s number lead time in seconds
---@return userdata|nil predicted Vector position, or nil if target invalid
function Geometry.lead_target_pos(target, me, lead_s)
    if not target or not Entity.IsEntity(target) then return nil end
    local tpos = Entity.GetAbsOrigin(target)
    if not tpos then return nil end

    -- Primary: the engine's real velocity vector.
    local vel
    local ok, v = pcall(Entity.GetField, target, "m_vecVelocity")
    if ok and v and v.Length and v:Length() > 5 then
        vel = v
    elseif NPC.IsRunning and NPC.IsRunning(target) then
        -- Fallback (velocity field unavailable): facing × move-speed,
        -- but ONLY while a move order is live so a standing unit gets
        -- no lead.
        local rot = Entity.GetRotation and Entity.GetRotation(target)
        local f   = rot and rot.GetForward and rot:GetForward()
        if f and f.Normalized then
            local n  = f:Normalized()
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(target)) or 0
            vel = Vector((n.x or 0) * ms, (n.y or 0) * ms, 0)
        end
    end
    if not vel then return tpos end

    return Vector(tpos.x + (vel.x or 0) * lead_s,
                  tpos.y + (vel.y or 0) * lead_s,
                  tpos.z)
end

return Geometry

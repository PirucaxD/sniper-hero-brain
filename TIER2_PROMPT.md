# Tier 2 Module Extraction — `lib/{MODULE_NAME}.lua`

API: **UCZone Lua 5.4**
API source documentation: `C:\Users\arcos\uczone-api-v2.0` — canonical reference. Verify every API call signature against this directory before writing the module.
Curated brain-task API reference: `C:\Users\arcos\dota-hero-brains\API_REFERENCE.md` — consult relevant sections (e.g., "Detecting enemy intent" for `threat.lua`, "Damage estimation" for `ability_dmg.lua`, "Dispels and protection" for `linkens.lua`, "Channel mechanics" for combos involving channeled spells).
Project root: `C:\Users\arcos\dota-hero-brains`. Reference: `BRAIN_PROJECT.md` § Shared library plan — three tiers, and the Tier 2 row for this module.

**This is a mechanism-extraction, not a fresh build.** Two heroes have implemented the same logic inline. We're pulling the shared mechanism into `lib/`; the per-hero data stays in each hero file.

Do NOT extract before two heroes have validated the mechanism. The 3-use threshold is real — most "Tier 2 candidates" never reach it, and that's correct. If you're tempted to extract on speculation, stop and inline.

---

## Phase 1 — Confirm the extraction is earned

Before writing code, answer **in this order**:

**0. (Gate) Is this functionality already a base subsystem the framework provides?**
Check `BRAIN_PROJECT.md` § Base subsystems for confirmed bases (ward tracking, smoke detection) and likely bases (Roshan/rune timers, lane state, auto-TP, item-build, hero-grid). Check the framework's loaded-script list. Search the UCZone docs at `C:\Users\arcos\uczone-api-v2.0` for a read-only state API that looks like this module's purpose.
If yes → **abort the extraction.** Document in the requesting heroes' files how to consume the existing subsystem, and update `BRAIN_PROJECT.md` § Base subsystems to add this entry so it's not proposed again.
If no → proceed to step 1.

1. **Which module is being built?** Fill in `{MODULE_NAME}`. Must be one of the Tier 2 catalog entries in `BRAIN_PROJECT.md`. Other names need a `BRAIN_PROJECT.md` update first.

2. **Which two heroes triggered this extraction?** Cite by hero name and the file/section in each hero's `.lua` where the inline implementation lives. Quote the inline code from both — side by side. If the two implementations *don't already look nearly identical*, you're extracting too early. Stop.

3. **What is the mechanism, in one paragraph?** Plain English, no code. The mechanism is what's shared. If you can't describe it without referring to a specific hero, it's not a mechanism — it's hero logic that happened to repeat by coincidence.

4. **What is the per-hero data, in one paragraph?** Plain English. The data is the parameters each hero passes in. If two heroes pass *identical* data, the data is also universal and this is actually a Tier 1 candidate — flag it and stop.

5. **Is there a third hero on the near horizon that would also use this?** If yes, name it and predict its data shape. If no, the 3-use threshold isn't quite met — extract with caution and a clear note that the interface may shift when the third hero arrives.

Stop and report Phase 1 before continuing. Do not write code yet.

---

## Phase 2 — Interface design

Design the public interface for `lib/{MODULE_NAME}.lua`. Constraints:

- The mechanism logic is in `lib/`. The data is supplied per-call by the hero.
- Interface accepts a `spec` table per call, not positional args (we'll add fields without breaking existing callers).
- Heroes that already implemented this inline must be able to refactor to call the new module without losing any current behavior. List those behaviors explicitly and confirm each is supported.
- One public function per use case. If you find yourself designing 8 functions, you're probably building a framework, not a module — stop and re-scope.
- LuaCATS annotations on the public surface.

Report the proposed interface, the behavior list from both triggering heroes, and a mapping from "behavior" → "interface call." Pause for confirmation.

---

## Phase 3 — Implementation

Write `lib/{MODULE_NAME}.lua` to the interface from Phase 2. Implementation requirements:

- Pure Lua. No new global side effects beyond callbacks that the module needs.
- Idempotent `Init()` if the module needs initialization.
- Logs to `Log.Write` only on actual error/anomaly.
- Uses `lib/order.lua`, `lib/damage.lua`, `lib/anim.lua` as appropriate — don't re-invent their responsibilities.
- Respects Stage 2 ON/OFF where relevant (most Tier 2 modules don't need to care; `damage.lua` abstracts this for them).
- No new abstractions inside the module unless used 3+ times within the module.
- Inline comments only for non-obvious WHY.

---

## Phase 4 — Refactor both triggering heroes

Modify the two triggering hero files to call the new module. Show the before/after diffs. Each hero file should shrink — that's the validation that the extraction was real.

If either hero's file *grows* after the refactor, the interface is wrong. Stop and redesign Phase 2.

After the refactor:
- Run the eleven-item quality gate from `BRAIN_PROJECT.md` on both heroes in demo to confirm no regressions.
- Compare combo activation rate, last-hit rate, deaths/min vs the pre-refactor baseline (from each hero's `changelog.md`).

---

## Phase 5 — Document

Update:

- `lib/CHANGELOG.md` — entry for this extraction with: module name, triggering heroes, mechanism description, interface signature.
- Each triggering hero's `changelog.md` — note that the inline X was extracted to `lib/{MODULE_NAME}.lua`, and the diff size.
- `BRAIN_PROJECT.md` Tier 2 row for this module — change "Build when..." to "Built [date]" and link to the changelog entry.

---

## Constraints

- Never extract before two real users exist.
- Never extract if the two implementations aren't *already* nearly identical.
- If extraction makes either hero file longer, the interface is wrong — redesign or abandon.
- No new abstractions beyond the module's purpose.
- LuaCATS annotations on public interface.
- The mechanism goes in `lib/`. The data stays per-hero.

Begin Phase 1.

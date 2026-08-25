# tools/

Standalone developer utilities. None of these run inside the game - they are
either post-match analysis tools that read `C:\Umbrella\debug.log`, or build
tools that regenerate a `lib/` data module from the KV data.

## `gen_item_data.py` (KV-lib generator)

Regenerates `lib/item_data.lua` from the static KV data
(`C:\Umbrella\assets\data\items.json` + `neutral_items.json`).

```bash
python tools/gen_item_data.py
```

Emits a pure-data Lua module (the `ITEMS` / `NEUTRAL_TIERS` tables) plus the
curated `SAVE_GEOMETRY` table and the pure helpers - those last two live as
literals inside the generator, so this script is the single source of truth
for `lib/item_data.lua`. **Do not hand-edit the generated lib** - re-run the
generator after a Dota patch refreshes the KV files. Requires Python 3.

After regenerating: syntax-check (`lua -e "loadfile('lib/item_data.lua')"`)
and `cp` the lib to `C:\Umbrella\scripts\lib\`.

## `gen_ability_data.py` (KV-lib generator)

Regenerates `lib/ability_data.lua` from `C:\Umbrella\assets\data\npc_abilities.json`.

```bash
python tools/gen_ability_data.py
```

Emits a pure-data Lua module - the `ABILITIES` table (all 1949 abilities,
base magnitudes) plus the pure helpers (`Damage` / `Cooldown` / `CastRange`
/ `AtLevel` / `Value` / ...). Talent and facet bonuses are dropped; embedded
`AbilityCooldown` / `AbilityCastRange` / etc. are promoted out of
`AbilityValues`. Same regenerate-don't-hand-edit rule as `gen_item_data.py`.
Requires Python 3.

## `gen_unit_data.py` (KV-lib generator)

Regenerates `lib/unit_data.lua` from `C:\Umbrella\assets\data\npc_units.json`.

```bash
python tools/gen_unit_data.py
```

Emits a pure-data Lua module - the `UNITS` table (all 342 non-hero units:
creeps, summons, wards, buildings, Roshan) plus the pure helpers (`IsSummon`
/ `IsWard` / `IsBuilding` / `AvgAttackDamage` / ...). Same
regenerate-don't-hand-edit rule as the other generators. Requires Python 3.

## `gen_hero_data.py` (KV-lib generator)

Regenerates `lib/hero_data.lua` from `C:\Umbrella\assets\data\npc_heroes.json`.

```bash
python tools/gen_hero_data.py
```

Emits a pure-data Lua module - the `HEROES` table (all 128 heroes: base
stats, abilities, talents, facets, attributes) plus the pure helpers
(`AttributeAt` / `PrimaryAttribute` / `HasAbility` / `Talents` / ...).
Completes the KV-lib set (item / ability / unit / hero). Same
regenerate-don't-hand-edit rule. Requires Python 3.

## `gen_anim_maps.py` (Sniper anim-map generator)

Regenerates the entire `register_anim_maps()` body for the Sniper brain
from `C:\Umbrella\assets\data\npc_heroes.json` + `npc_abilities.json`.

```bash
python tools/gen_anim_maps.py
```

Emits the cast-point threat-detection map for all enemy heroes. Cast-
activity slots (AB1-AB6) are DERIVED, not guessed: walk each hero's
ability list, skip `generic_hidden` / innate / hidden / pure-passive /
talent entries, the `ABILITY_TYPE_ULTIMATE` ability is AB4 and the
first three other castables are AB1/AB2/AB3. Threat roles use a 3-tier
seed - (1) the prior hand-tuned `register_anim_maps` entries
(authoritative), (2) the `threat_data.lua` `ABILITY_TO_THREAT ×
THREATS_ON_SELF` join, (3) a `CHANNELLED`-behaviour draft for the tail.
The generator has a built-in correctness gate (reproduces the
Bane/Lion/Storm known-good maps) and a regression assert (output must
be a strict superset of the prior maps).

Output goes to the scratch file `tools/_anim_maps_generated.lua` for
review; the `register_anim_maps()` body in `Sniper/Sniper.lua` is then
spliced from it (the `Anim.Subscribe` / `Anim.RegisterParticle` tail is
kept). Same regenerate-don't-hand-edit rule as the KV-lib generators.
Requires Python 3. Shipped with Sniper v6.15.206.

## `parse_debuglog.lua` (B2 - replay parser)

Turns the log into a timeline of brain events.

```bash
lua tools/parse_debuglog.lua C:\Umbrella\debug.log
lua tools/parse_debuglog.lua C:\Umbrella\debug.log --hero=Sniper
lua tools/parse_debuglog.lua C:\Umbrella\debug.log --grep=layer1_dispatch
lua tools/parse_debuglog.lua C:\Umbrella\debug.log --summary
lua tools/parse_debuglog.lua C:\Umbrella\debug.log --modseen
lua tools/parse_debuglog.lua C:\Umbrella\debug.log --postmortem
```

Modes:
- *timeline* (default) - one event per line, sorted by source order.
- `--summary` - `event_name → count` table sorted by frequency.
- `--modseen` - unique modifier observations (for closing `(verify)` gaps in `lib/threat_data.lua`).
- `--postmortem` - `death_postmortem` lines + 5-line context before each.

## `run_tests.lua` (B5 - pure-helper test runner)

Pure-Lua unit tests for the `lib/` helpers that don't require game state.

```bash
lua tools/run_tests.lua
```

Stubs `NPC.*` / `Entity.*` / `Ability.*` / `Hero.*` at the top so the libs load
without a running game. Tests cover:
- `lib/threat_data.lua` - `SAVE_KIND` integrity, `ESCAPE_ITEM_NAMES` derivation,
  `SaveCounters`, `SeverityOf`, `ENEMY_BUFF_THREATS` keys, v6.14.1 M3/M4 fixes.
- `lib/target.lua` - `NotClone` nil-safety.
- `lib/timing.lua` - `EscapeReadiness` baseline.

**Requires:** Lua 5.1+ on PATH. If not installed, get it from
<https://www.lua.org/download.html> or `winget install -e --id DEVCOM.Lua`.

## `verify_scenarios.lua` (E3 - demo-scenario verifier)

Defines named scenarios + log-signature assertions. Workflow: human plays
the scenario in a demo, then runs:

```bash
lua tools/verify_scenarios.lua bara_charge_1v1
```

Verifies the demo produced the expected event signatures (e.g.
`armed_threat_fire` count, no Lua errors, etc.).

Scenarios currently covered:
- `bara_charge_1v1` - Spirit Breaker charge save behavior (v6.13 Bug #1 regression check).
- `panic_key_smoke` - panic-save key with empty chain (v6.14.1 C3 fix verification).
- `combo_dispatch_basic` - basic R-combo dispatch (v6.14.1 C1 forward-decl fix).
- `smoke_alert_visibility` - smoke-detection HUD chip (v6.14 C3 / v6.14.1 M10).
- `match_summary_at_end` - v6.15 B1 end-of-match telemetry summary.

Add new scenarios to the `scenarios` table when shipping new behaviors.

## Why not run the demo automatically?

Umbrella doesn't expose a programmable demo runner. The framework is
intentionally read-only to user input. So we settle for: humans play the
scenarios; tools verify the logged signatures.

For continuous regression coverage: keep a "regression suite" markdown
checklist mapping (scenario → expected v6.x behavior). Run it after every
version bump.

# sniper-hero-brain

A decision-making brain for Dota 2's Sniper, written for the UCZone Lua
scripting API. It runs as a companion to the framework's built-in hero
script: the baseline keeps doing the routine work (orbwalk, item usage,
kill-stealing, target selection), and the brain adds the decisions the
baseline cannot make on its own - multi-spell combos, predictive defensive
saves, target valuation for the ultimate, fog pickoffs, teamfight peeling.

This repository is the full source: the brain itself
(`Sniper/Sniper.lua`, around 10,000 lines), the shared Lua libraries it sits
on (`lib/`), the code generators that build the data libraries from Valve's
game files (`tools/`), and the architecture and reference documents written
alongside it over development.

It is also a long case study. The brain went through 222 tracked versions;
the post-mortem section below records the problems, the dead ends, and the
workarounds. If you are reading this to learn how to build something
similar, the failures are the more useful half.

## The augmentation model

The brain does not replace the framework's hero script. It is a sidecar.

UCZone ships a generic per-hero baseline plus framework-wide subsystems
(Hit & Run, Orb Walker, Items Manager, Dodger, Linkbreaker, Target Lock).
Those are competent at the mechanical layer and patch-maintained. The brain
leaves them running and only issues the *additional* orders that require
reasoning the baseline does not do: "is this the right target to ult", "this
enemy is about to gap-close, pre-fire a save", "the combo button is held and
an enemy committed onto me, run the full peel".

This choice is load-bearing, and it is the source of most of the hard
problems in the post-mortem. The brain and the native subsystems both issue
orders to the same unit, and they do not coordinate through any API. Living
with that is a recurring theme.

## Features

What the brain adds on top of the native Sniper script:

**Offense, on the combo key:**

- An adaptive close-gap peel combo - Concussive Grenade (or Hurricane Pike
  when grenade is down) plus Assassinate, Shrapnel and Take Aim - fired when
  an enemy commits onto Sniper.
- An Assassinate finisher on fleeing or out-of-range targets, kill-value
  gated so it is not spent on a full-HP carry.
- Shrapnel and Take Aim chip pressure as the fallback when nothing
  higher-value applies.
- Heavy Starter: a fire-on-command Take Aim and Assassinate on a quick tap.
- A Team Fight mode that adds target focus and Shrapnel spread, and runs the
  same peel combo against a diver.
- Optional speculative fog snipe: auto-Assassinate on a high-value enemy that
  just entered fog while still in cast range.

**Defense, always on, no key:**

- An auto-save layer that fires Hurricane Pike, Concussive Grenade, BKB, Eul,
  Glimmer, Lotus, Force Staff, blinks and similar against incoming lethal
  threats, choosing a save that actually counters the threat in question.
- Channel and teleport punish: auto-Assassinate or grenade an enemy that
  begins a channel or a TP.
- Pre-facing: a brief rotation to beat fast enemy cast points.
- Optional standalone auto-grenade on a rushing enemy, and smoke /
  fog-ambush detection.

**Feedback:**

- A live status panel in the menu: the current decision, candidate scoring,
  the last refused combo and why, and cooldown readiness.
- A structured debug log for post-match review, at four verbosity levels.

## Installing

The brain is two parts that deploy together:

1. Copy `Sniper/Sniper.lua` into the framework's script directory.
2. Copy the `lib/` directory alongside it. The brain `require`s `lib.order`,
   `lib.damage`, `lib.anim` and the rest; without `lib/` it will not load.
3. Reload scripts. On load the brain prints a version banner to the debug
   log.
4. **Hand ability casting to the brain.** Open `Sniper -> Main Settings` and
   turn **off every ability icon** there - both the row under `Hero Settings
   -> Abilities` and the row under `Kill Stealer -> Abilities`. A disabled
   icon shows red. This step is required: any ability left enabled lets the
   native script cast Shrapnel / Take Aim / Assassinate / Grenade on its own,
   racing the brain for the same spell.

Leave the rest of the native Sniper script enabled. Items Settings, Hit &
Run, Orb Walker and Target Selection are the routine work the brain delegates
to and relies on; the brain only needs to be the *sole caster of Sniper's
abilities*. It is a companion to the native script, not a replacement (see
"The augmentation model" above).

## Using the brain

Everything offensive runs off one key. Defense needs no key and no input.

**The combo key** (default Mouse5, rebindable in the menu):

- **Tap** it (release in under 0.18s) for **Heavy Starter**: Take Aim then
  Assassinate, fired on command with no kill check. You tapped, the brain
  commits.
- **Hold** it with **1-2 enemies** near Sniper for the **Starter loop**. Each
  tick the brain re-reads the fight and picks the right response on its own.
- **Hold** it with **3+ enemies** near Sniper for **Team Fight** mode. The
  mode is latched when you start holding, so one unit crossing the count
  boundary cannot flip the brain mid-combo.

Two more keys are unbound by default; set them on the Core page if you want
them:

- **Force-commit key** - hold it while pressing the combo key to make the
  brain commit even when its kill check would otherwise refuse.
- **Panic-save key** - press it to force the defense layer to fire its next
  save immediately.

### What to expect

- With the master toggle on and no input, the brain is **silent**. It acts
  only when you press the combo key or when a real threat appears.
- **Hold the key with an enemy attacking you up close** - the peel combo:
  grenade (or Pike) knocks them back, Assassinate commits the kill, Shrapnel
  drops a slow zone on their return path, Take Aim buffs the follow-up.
- **Hold the key on a fleeing low-HP target** - Assassinate alone, but only
  if the brain's math says R alone is lethal.
- **Hold the key with nothing worth killing** - Shrapnel and Take Aim chip
  damage, no wasted ultimate.
- **An enemy gap-closes, hard-disables or ults you**, at any time and with no
  key held - the defense layer fires the save that counters that specific
  threat.
- **You are about to die and the save layer did not pick what you wanted** -
  tap the panic-save key.

The Diagnostics page carries a live status panel showing what the brain is
deciding, and when it refuses a combo, why.

## Menu settings

The brain's settings are under **Heroes -> Hero List -> Sniper -> Brain**,
split across three pages.

### Core

| Setting | Default | Meaning |
|---|---|---|
| Enable Sniper brain | on | Master toggle. When off the brain issues nothing and the native Sniper runs alone. |
| Combo key | Mouse5 | Hold for the adaptive Starter / Team Fight loop; tap for Heavy Starter. |
| Speculative fog snipe | off | Auto-cast Assassinate at a recently-fogged high-value enemy that is still in cast range. |
| R commit floor | 100 (40-150) | Kill-value gate for Assassinate. 40 fishes for any kill, 100 is strict, 150 is conservative. |
| Starter R finisher min range % | 70 (50-150) | In a 1-2 enemy fight, fire the R finisher only when the target is past this percentage of attack range. Higher values reserve R for escaping targets. |
| Force-commit key | unbound | Hold to force a combo when the kill check would refuse it. |
| Panic-save key | unbound | Press to force the defense layer to fire its next save immediately. |

### Defense

| Setting | Default | Meaning |
|---|---|---|
| Enable auto-defense (Layer 2) | on | The always-on save layer: Pike, grenade, BKB, Eul, Lotus and similar, fired on incoming lethal threats. |
| Auto-punish enemy channels | on | Auto-fire Assassinate or Concussive Grenade when an enemy starts a channel or a teleport. |
| Pre-face imminent threats | on | Briefly rotates Sniper to beat fast enemy cast points. |
| Lotus first vs single-target burst | off | Prefer Lotus Orb as the first save against a single-target burst ultimate. |
| Smoke / fog-ambush detection | off | Warn, and pre-fire BKB below 60% HP, when an ambush looks likely. |
| Ally HP for grenade-save-ally | 30% (10-60) | Ally HP threshold below which Sniper will grenade an ally clear of danger. |
| Auto-grenade on enemy proximity | off | Standalone Concussive Grenade on a rushing enemy, independent of the combo key. |

The **Auto-grenade settings** gear on that last switch adds four tuning
knobs: trigger radius (200-800u, default 500), predicted smart-cast position
(on), skip already-slowed targets (on), and a low-HP extra radius (0-400u,
0 = off).

### Diagnostics

| Setting | Default | Meaning |
|---|---|---|
| Log verbosity | 1 (0-3) | 0 silent, 1 decisions, 2 adds skipped decisions, 3 full trace. Written to the debug log. |
| Show raw-API debug panel | off | Extra read-only labels exposing raw framework reads. A research aid; leave off in normal play. |

The page also carries a live, read-only status panel: current Layer 1 and
Layer 2 actions, candidate counts and scoring, the last refused combo and its
reason, cooldown readiness, and active reservations.

## Repository layout

```
Sniper/
  Sniper.lua            the brain (one file, ~10k lines)
  LIQUIPEDIA_REF.md     Sniper ability reference (cast points, ranges, CDs)
lib/                    shared Lua libraries (see "The library set")
tools/                  KV-data generators + log/test tooling
COMBO_PATTERN.md        the offensive combo/sequence dispatch pattern
DEFENSE_PATTERN.md      the defensive save-layer pattern
DEFENSE_CATEGORIES.md   threat-category -> save-chain mapping
API_GOTCHAS.md          UCZone API quirks found the hard way
API_REFERENCE.md        condensed API reference
```

The brain is deployed by copying `Sniper/Sniper.lua` (and `lib/` when a
library changed) into the framework's script directory. Source and runtime
are kept in sync; the repository is the source.

## Architecture

The full treatment of each layer is in `COMBO_PATTERN.md` and
`DEFENSE_PATTERN.md`. This section is the map.

### The combo key

The brain hangs almost everything offensive off one key, shared with the
baseline combo key. It classifies the press and dispatches one of three
modes:

- **Tap** (press released under 0.18s) -> **Heavy Starter**: E then R,
  fire-on-command, no kill prediction. The player tapped, they meant it.
- **Hold, 1-2 enemies** -> **the Starter loop** (`starter_tick`).
- **Hold, 3+ enemies** -> **Team Fight** (`teamfight_tick`). The mode is
  latched at hold-start so a single enemy crossing the count boundary cannot
  flip the brain mid-combo.

### The Starter loop and its archetypes

`starter_tick` is a per-tick situational appraisal, not a fixed combo
script. Each off-throttle tick it re-reads the engagement and picks one
archetype:

- **`dr`** - the D+R+Q+E close-gap combo. Fires on a *committed attacker*
  (an enemy attacking Sniper, close, not kiting). D (or Hurricane Pike when
  D is on cooldown) peels the attacker, R commits the kill, Q drops a slow
  zone on the return path, E (Take Aim) buffs the follow-up. It is a
  defensive ultimate: a peel that also kills.
- **`r`** - the R finisher: R alone on a fleeing or out-of-range
  R-killable target.
- **`chip`** - the default: Shrapnel plus Take Aim for chip damage and
  pressure when nothing else applies.

Per-tick re-evaluation *is* the state machine. A target that commits
mid-chip escalates to `dr` on the next tick with no explicit phase
variable.

### Team Fight

`teamfight_tick` runs the `tf_r` / `tf_q` / `tf_e` / `tf_focus` archetypes
(R finisher, Shrapnel spread, Take Aim, autoattack focus). As of v6.15.221
it also runs the `dr` peel combo: the most common thing that happens to a
Sniper in a teamfight is the enemy team diving him directly, so a committed
attacker gets the same D+R+Q+E answer there, and it takes priority over the
other teamfight archetypes.

### The defense layer

Always on, independent of the combo key. Two detection routes feed one save
dispatcher:

- **Anim route (primary)** - generated `Anim.Subscribe` handlers detect an
  incoming threat by its cast animation, keyed on the KV-authoritative
  ability name, at cast-point time. This is the fast path: it reacts before
  the threat lands.
- **Modifier-create route (fallback)** - `OnModifierCreate` resolves a
  threat from the modifier the ability puts on Sniper, then dispatches by
  role.

The dispatcher picks a save chain: a hand-tuned per-threat override
(`SNIPER_SAVE_OVERRIDES`) if one exists, else a recommended list, else a
per-category chain (`CATEGORY_CHAINS`). The save items themselves (Pike,
Force, BKB, Glimmer, blinks, cyclones) are scored against the threat so a
displacement save is not picked for a threat displacement does not break.

### Always-on ticks

Beyond the combo and defense layers, a set of ticks runs every frame:
fog-snipe R, armed-threat resolution, a damage-rate panic check, the
Kinetic Field poll, auto-grenade, the live channel detector, the
channel-punish R, persistent-threat re-fire, the R-cast abort monitor, the
deferred-step scheduler, and the Pike prime/re-issue tick (see the
post-mortem).

### One hard constraint: the 200-locals limit

Lua 5.4 allows 200 local variables per function. The brain's main chunk is
near that ceiling. Every module-level function and constant added after the
limit was first hit is stored as a field on one `state` table
(`state.foo = function() ... end`), not as a `local`. A table field does not
consume a local slot. This is why the code is full of `state.X` rather than
plain locals; it is not a style choice, it is the only thing that compiles.

## The library set

The brain sits on a set of hero-agnostic Lua libraries in `lib/`. They split
into tiers.

**Tier 1, event plumbing:** `order` (one validated chokepoint for every
order, with queue dedup), `damage` (recent-damage feed and kill math),
`anim` (enemy animation -> "they cast X" events), `target` (composable unit
predicates).

**Tier 2, reasoning and data:** `threat_data` (the threat / save-kind
catalog), `save_select` (which save actually counters which threat),
`geometry`, `signal`, `npc`, `dedup`, `timing`.

**The KV-data libraries:** `item_data`, `ability_data`, `unit_data`,
`hero_data`. These are pure static reference, *generated* from Valve's KV
files. They are never hand-edited.

### Regenerating the data libraries after a patch

This is the most important maintenance operation, and it is one command per
library. Valve ships the game's authoritative numbers as JSON KV files
(`npc_heroes.json`, `npc_abilities.json`, `npc_units.json`, `items.json`,
`neutral_items.json`). The generators in `tools/` read those and emit the
corresponding lib:

```
gen_item_data.py     -> lib/item_data.lua
gen_ability_data.py  -> lib/ability_data.lua
gen_unit_data.py     -> lib/unit_data.lua
gen_hero_data.py     -> lib/hero_data.lua
gen_anim_maps.py     -> the animation-route maps
```

Each generator is the single source of truth for its output. After a Dota
patch: drop in the new KV files, re-run the generators, and the libs are
current. If a value in a generated lib is wrong, the fix goes in the
generator, never in the lib. This is the difference between a catalog that
rots over patches and one that does not. See "The KV-derivation principle".

## Building, deploying, testing

The loop is: edit the source, syntax-check, bump the version banner, deploy,
play a bot match, read the log.

- **Syntax check:** `luac.exe -p Sniper.lua`. Pure-data libs can also be
  exec-tested out of game with `lua.exe` and a `package.path` pointing at
  the repo.
- **Deploy:** copy `Sniper.lua` (and changed libs) into the framework
  script directory. Source and runtime must stay identical.

### The version banner

The first line of `Sniper.lua` is a `LOG:info(...)` call holding one
enormous double-quoted string: the version number followed by an embedded
changelog. It prints on load. Because the banner embeds the changelog, a
`grep` of the debug log for the version pattern tells you exactly which
build actually ran. That matters: a stale log is worthless as verification
data, and confirming the banner is the first step of every log review.

The banner is one single line, hundreds of kilobytes long. It is edited with
a literal string-replace from a script, not with a text editor, because the
line overflows ordinary editing tools.

### The debug log

The brain emits structured diagnostic events to the framework log. The
discipline that matters most:

- **`cast_verify` is ground truth for whether an ability fired.** It reads
  the ability's cooldown and charges back after the cast point and reports
  `fired=y/n`. If you want to know whether a cast actually happened, this is
  the only event that knows.
- **`cast_outcome`, `layer2_save`, and similar are dispatch records, not
  fire proof.** They say the brain decided to do something. They do not say
  the engine executed it. Conflating the two cost an entire development arc
  once (a reported 50-75% ultimate kill rate while the ultimate was firing
  0% of the time, because a damage-window heuristic was being read as a fire
  confirmation).

`combo_classify`, `starter`, `teamfight`, `threat_modifier_*`, and
`threat_unrecognized` round out the picture: what mode was chosen, what the
gates read, what the defense layer dispatched, and which modifier names the
threat catalog still does not recognize.

## Findings and hard problems

This is the section to read if you are building anything that drives a unit
in this engine. None of it was obvious at the start.

### The native-order flood

The framework's native subsystems (the orbwalker in `!_api_extend.lua`, Hit
& Run in `3_hit_n_run.lua`) issue an order to Sniper roughly every 70
milliseconds, continuously, whenever there is something to do. Around 22
native orders land in a 1.5-second window.

A brain cast that has been issued but has not yet entered its cast point can
be cancelled by the next order that arrives. Sniper's ultimate has a 2-second
cast point; a naive dispatch of it into that order flood is cancelled before
it starts, every time, worst of all against an auto-attacking enemy when the
orbwalker is busiest.

The brain cannot stop the flood. The native subsystems have no
`Disable()`/`Pause()` API. They couple to the native combo key's pressed
state, so they are *most* active exactly when the combo key is held, which
is exactly when the brain is trying to cast. And the brain's
`OnPrepareUnitOrders` veto cannot help: per the API, that callback fires only
for *player* orders, and the native subsystems are scripts, not the player.
This was verified both from the API documentation and empirically (the veto
logged zero hits across a full match with the flood at full volume).

The brain coexists with the flood instead of fighting it, because the flood
is also doing useful work: the brain deliberately delegates Sniper's
autoattack rhythm to native Hit & Run (an earlier attempt at a brain-side
orbwalker was a string of bugs and was removed). The workarounds are in the
next three findings.

### The cast-lock window

The one cooperative behavior the engine offers: once a cast has *entered its
cast point*, it is locked. Subsequent orders, native or otherwise, do not
cancel it. Only the brief gap between issuing the cast order and the cast
point actually starting is vulnerable. The native subsystems, in turn, were
observed to yield (stop issuing orders) while a cast is in progress.

So the entire problem reduces to: get the cast point to *start*. Everything
below is a way of winning that one race.

### The dr-combo regression, and a lesson about trusting your own changelog

The D+R+Q+E combo was designed at v6.15.124 with R deferred 0.2 seconds
behind D: D fires immediately, R is scheduled and dispatched 0.2s later as a
fresh, standalone order. The 0.2s gap clears D's 0.1s cast point so R's order
does not cancel D, and the deferred dispatch path routes R through a helper
that sets `execute_fast` (see the next finding).

Much later, the combo was reported as broken. A regression hunt concluded
that a much older version had "added the defer" and that the defer was the
bug; the defer was removed, R was moved inline, and a per-tick retry was
bolted on.

That diagnosis was wrong, and the way it was wrong is the lesson. The
version it blamed *predated the combo archetype's existence* - it had
touched a different, legacy combo. The deferred R was the original design,
not a regression. Removing it stripped R of `execute_fast` (the inline
dispatch path does not set it) and the per-tick retry then re-issued R with
a queue-clearing flag every frame, which cancelled D, the very step the
combo exists to land.

The fix was to put the original design back: R deferred again, the retry
removed. While reconstructing the history it also surfaced a real latent bug
that had always been there: the combo's Q step was timed to fire *inside*
R's 2-second cast point, so whenever Q actually fired it cancelled R. Q was
moved to fire after R completes.

Two takeaways. First: a project's own changelog is a secondary source. It
records what someone *believed* at the time. Verify a root-cause claim
against the actual version where the code first appeared. Second: a
"consistency rollout" that copies a pattern across combos will copy it onto
combos the pattern does not fit; the misattributed defer was exactly such a
rollout.

### Assassinate and execute_fast

The framework's order API accepts an `execute_fast` flag that bypasses
internal safety delays. Issuing Sniper's ultimate with it set scopes the
order ahead of the native orders queued the same tick, which is often enough
to win the cast-point race. It is scoped narrowly, to the ultimate only, so
ordinary item casts are not accelerated for no reason.

This is why dispatch *path* matters. The deferred dispatch helper sets
`execute_fast`; the inline step dispatcher did not, until that gap was found
and closed for the standalone R finishers as well. Two code paths that look
equivalent were not, and the difference was one flag that one of them
silently dropped.

### The fresh-item engine quirk

The engine silently drops the *first* cast of a freshly-acquired item. The
order is well-formed, it reaches the engine intact, and then nothing
happens: no cooldown, no effect. The second and every later cast of that
same item work normally. One cast "breaks the item in".

This was confirmed by tracing a Hurricane Pike save that failed: the failed
first cast and a later successful cast were byte-identical in the log (same
order type, same ability and target handles, same flags). The brain's side
was provably correct. The engine ate the first one. The likeliest
explanation is that the item's slot or cast state is not fully resolved
until the item is commanded once.

The workaround is two-part. *Prime*: when Sniper owns the item, it is
un-used, and he is safe, the brain fires one throwaway cast to spend the
doomed first attempt while it costs nothing. *Double-issue*: if a real save
needs the item before it was primed, the brain re-issues it one frame later,
so the second (landing) cast covers the save. A freshly-bought save item
cannot be trusted for its first save; plan for that.

### The KV-derivation principle

Valve's KV data is authoritative and it does not rot. Hand-maintained
catalogs do: a hardcoded per-level damage table, a guessed cast range, a
copied cooldown all silently drift the first time a patch changes them.

So anything that *can* be derived from KV is generated or read live, never
hand-maintained. The data libraries are generated. Magnitudes that mirror a
KV field are read from a generated lib, not typed as literals. The few
genuine literals that remain are the ones with no KV source at all (a
projectile speed Valve does not expose, a heuristic damage estimate), and
each is commented as such so it is not "migrated" by mistake.

### Modifier names cannot be derived

The one hard wall. `npc_abilities.json` exposes ability names, behaviors,
damage, cooldowns, cast ranges, and AbilityValues. It does *not* expose the
names of the modifiers an ability applies. A threat catalog keyed on
modifier names therefore cannot be generated; `modifier_<ability>` is a
convention guess.

The brain handles this by logging every unrecognized modifier that lands on
Sniper (`threat_unrecognized`) and correcting the guesses from real matches.
The deeper fix is design, not data: prefer keying logic on the ability name
(which is KV-authoritative) over the modifier name (which is a guess). The
defense layer's primary route does exactly that.

## Conventions

A few rules that are not obvious from the code:

- New module-level functions and constants are `state.X`, never `local X`
  (the 200-locals limit, above).
- Generated files are never hand-edited. Change the generator, re-run it.
- One behavioral change per version, and each version bumps the banner.
- The version banner is one giant single-line string and is edited with a
  literal replace from a script, not a text editor.
- Coordinates are formatted with `%.0f`, not `%d`; they are floats.
- Comments explain *why*, and they are written for the next maintainer.

## Where to read more

- `COMBO_PATTERN.md` - the offensive combo/sequence dispatch pattern,
  reusable for other heroes.
- `DEFENSE_PATTERN.md` and `DEFENSE_CATEGORIES.md` - the defensive save
  layer and the threat-to-save mapping.
- `API_GOTCHAS.md` - every UCZone API quirk found the hard way, with the
  symptom and the fix.
- `API_REFERENCE.md` - the condensed, brain-task-organized API reference.
- `tools/README.md` - the KV generators and the log/test tooling.

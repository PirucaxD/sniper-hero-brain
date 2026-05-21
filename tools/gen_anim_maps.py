#!/usr/bin/env python
# tools/gen_anim_maps.py - generate the register_anim_maps() body from KV data.
#
# Reads C:\Umbrella\assets\data\npc_heroes.json + npc_abilities.json and emits
# tools/_anim_maps_generated.lua - the full body of Sniper.lua's hand-written
# register_anim_maps() for ALL heroes, KV-derived so it is regenerable per
# patch. The main thread reviews the scratch file and integrates it; this
# generator never touches Sniper.lua or any lib/*.lua.
#
# Re-run after a Dota patch refreshes the KV files:
#   python tools/gen_anim_maps.py
#
# Pipeline (the verified "D18" algorithm):
#   1. per-hero ability list      - Ability1..AbilityN, in order
#   2. cast-activity slot         - filter to castables, ULT -> AB4, first
#                                   three non-ult -> AB1/AB2/AB3, 4th+ -> AB5/AB6
#   3. threat classification      - three seed sources, by priority:
#                                   (a) the existing hand-written
#                                       register_anim_maps() in Sniper.lua
#                                       (authoritative, field-tested);
#                                   (b) CURATED_ROLES, seeded from the
#                                       lib/threat_data.lua join;
#                                   (c) a CHANNELLED-only behavior-draft
#                                       fallback. (a) > (b) > (c).
#   4. role -> anim-subscriber    - gap_close / hard_disable / channel_start /
#                                   ult_burst, everything else SKIP
#   5. emit                       - Anim.RegisterMap blocks, alphabetical
#
# CURATED_ROLES below is the single source of truth for threat roles. It was
# seeded by joining lib/threat_data.lua's ABILITY_TO_THREAT (ability -> mod)
# with THREATS_ON_SELF (mod -> role). Entries flagged (seed-unjoined) had no
# THREATS_ON_SELF match; their role is a best-effort read of the modifier.
# Edit roles HERE, not in the generated file.

import json
import os
import re

KV_DIR = r"C:\Umbrella\assets\data"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "_anim_maps_generated.lua")
# The hand-written register_anim_maps() in Sniper.lua is itself a curated,
# field-tested ability->anim-role source. We parse it as the highest-priority
# seed so the generated output is a strict SUPERSET (no regressions).
SNIPER_LUA = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Sniper", "Sniper.lua"))

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


# ---------------------------------------------------------------------------
# CURATED_ROLES - ability name -> threat role. AUTHORITATIVE + patch-stable.
# Seeded from lib/threat_data.lua: ABILITY_TO_THREAT joined with
# THREATS_ON_SELF. (seed-unjoined) = modifier not found in THREATS_ON_SELF,
# role inferred best-effort from the modifier name.
# ---------------------------------------------------------------------------

CURATED_ROLES = {
    "bane_fiends_grip":                    "channel_on_me",
    "bane_nightmare":                      "hard_disable",
    "batrider_flaming_lasso":              "hard_disable",
    "beastmaster_primal_roar":             "hard_disable",
    "bloodseeker_rupture":                 "magic_burst",
    "chaos_knight_chaos_bolt":             "hard_disable",
    "chaos_knight_reality_rift":           "gap_close",
    "dark_willow_bramble_maze":            "delayed_aoe",
    "dark_willow_cursed_crown":            "hard_disable",
    "dark_willow_terrorize":               "delayed_aoe",
    "dawnbreaker_celestial_hammer":        "gap_close",
    "disruptor_kinetic_field":             "trapped",
    "disruptor_static_storm":              "delayed_aoe",
    "drow_ranger_frost_arrows":            "kiting_slow",
    "earth_spirit_rolling_boulder":        "line_projectile",
    "earthshaker_echo_slam":               "delayed_aoe",
    "enigma_malefice":                     "hard_disable",
    "faceless_void_chronosphere":          "delayed_aoe",
    "grimstroke_ink_creature":             "hard_disable",
    "grimstroke_soul_chain":               "channel_on_me",
    "hoodwink_bushwhack":                  "delayed_aoe",
    "huskar_life_break":                   "gap_close",
    "jakiro_ice_path":                     "delayed_aoe",
    "kez_grappling_claw":                  "gap_close",
    "kez_raptor_dance":                    "delayed_aoe",
    "leshrac_split_earth":                 "delayed_aoe",
    "lich_chain_frost":                    "magic_burst",
    "lich_sinister_gaze":                  "channel_on_me",
    "life_stealer_open_wounds":            "physical_burst",
    "lion_voodoo":                         "hard_disable",
    "magnataur_reverse_polarity":          "delayed_aoe",
    "magnataur_skewer":                    "line_projectile",
    "marci_grapple":                       "gap_close",
    "mars_arena_of_blood":                 "delayed_aoe",
    "mars_gods_rebuke":                    "physical_burst",
    "mars_spear":                          "line_projectile",
    "morphling_adaptive_strike_agi":       "hard_disable",
    "muerta_dead_shot":                    "hard_disable",
    "naga_siren_song_of_the_siren":        "delayed_aoe",
    "necrolyte_heartstopper_aura":         "aura_dot",
    "necrolyte_reapers_scythe":            "magic_burst",
    "nyx_assassin_impale":                 "line_projectile",
    "nyx_assassin_vendetta":               "gap_close",
    "obsidian_destroyer_astral_imprisonment": "hard_disable",
    "obsidian_destroyer_sanity_eclipse":   "magic_burst",
    "oracle_fortunes_end":                 "channel_on_me",
    "oracle_purifying_flames":             "dot",
    "pangolier_gyroshell":                 "gap_close",
    "pangolier_swashbuckle":               "gap_close",
    "phantom_assassin_phantom_strike":     "gap_close",
    "phantom_assassin_stifling_dagger":    "light_slow",
    "primal_beast_onslaught":              "gap_close",
    "primal_beast_pulverize":              "channel_on_me",
    "puck_dream_coil":                     "delayed_aoe",
    "puck_waning_rift":                    "hard_disable",
    "pudge_dismember":                     "channel_on_me",
    "pugna_life_drain":                    "drain",
    "rattletrap_hookshot":                 "gap_close",
    "ringmaster_impalement":               "line_projectile",
    "ringmaster_the_box":                  "trapped",
    "ringmaster_wheel":                    "delayed_aoe",
    "sandking_burrowstrike":               "line_projectile",
    "sandking_epicenter":                  "delayed_aoe",
    "shadow_demon_demonic_purge":          "hard_disable",
    "shadow_demon_disruption":             "hard_disable",
    "shadow_shaman_shackles":              "channel_on_me",
    "shadow_shaman_voodoo":                "hard_disable",
    "skeleton_king_reincarnation":         "aura_slow",
    "skywrath_mage_ancient_seal":          "hard_disable",
    "skywrath_mage_mystic_flare":          "delayed_aoe",
    "slark_pounce":                        "gap_close",
    "snapfire_mortimer_kisses":            "delayed_aoe",
    "snapfire_scatterblast":               "magic_burst",
    "spirit_breaker_charge_of_darkness":   "gap_close",
    "spirit_breaker_nether_strike":        "gap_close",
    "sven_storm_bolt":                     "line_projectile",
    "templar_assassin_psionic_trap":       "trapped",
    "tidehunter_ravage":                   "delayed_aoe",
    "tiny_toss":                           "hard_disable",
    "treant_overgrowth":                   "delayed_aoe",
    "tusk_snowball":                       "gap_close",
    "vengefulspirit_nether_swap":          "hard_disable",
    "vengefulspirit_retribution":          "tracker",
    "viper_corrosive_skin":                "attacker_slow",
    "viper_nethertoxin":                   "silence_on_me",
    "viper_poison_attack":                 "kiting_slow",
    "void_spirit_aether_remnant":          "hard_disable",
    "void_spirit_astral_step":             "gap_close",
    "windrunner_shackleshot":              "hard_disable",
    "winter_wyvern_winters_curse":         "hard_disable",
    "zuus_lightning_bolt":                 "magic_burst",
    "zuus_thundergods_wrath":              "magic_burst",
    # --- seed-unjoined: modifier absent from THREATS_ON_SELF, role inferred ---
    "crystal_maiden_freezing_field":       "channel_on_me",       # (seed-unjoined)
    "enigma_black_hole":                   "delayed_aoe",         # (seed-unjoined)
    "lina_laguna_blade":                   "magic_burst",         # (seed-unjoined)
    "lina_light_strike_array":             "delayed_aoe",         # (seed-unjoined)
    "lion_finger_of_death":                "magic_burst",         # (seed-unjoined)
    "lion_mana_drain":                     "drain",               # (seed-unjoined)
    "mirana_arrow":                        "line_projectile",     # (seed-unjoined)
    "naga_siren_ensnare":                  "hard_disable",        # (seed-unjoined)
    "pudge_meat_hook":                     "line_projectile",     # (seed-unjoined)
    "tusk_ice_shards":                     "line_projectile",     # (seed-unjoined)
    "witch_doctor_death_ward":             "channel_on_me",       # (seed-unjoined)
}


# ---------------------------------------------------------------------------
# role -> anim-subscriber-role mapping. Step 4. SKIP (None) = not anim-
# registerable. A trailing _slow and a few literal roles are SKIP.
# ---------------------------------------------------------------------------

ROLE_TO_ANIM = {
    "gap_close":        "gap_close",
    "hard_disable":     "hard_disable",
    "line_projectile":  "hard_disable",
    "delayed_aoe":      "hard_disable",
    "physical_burst":   "hard_disable",
    "drain":            "channel_start",  # drains are channelled (Pugna Life Drain, Lion Mana Drain)
    "lockdown":         "hard_disable",
    "channel_on_me":    "channel_start",
    "magic_burst":      "ult_burst",
}

# Roles that explicitly SKIP (not anim-registerable). Anything ending in
# "_slow" also skips, handled in anim_role().
SKIP_ROLES = {
    "trapped", "taunt", "informational", "dot", "aura_dot", "aura_slow",
    "tracker", "aux", "zone_dot", "silence_on_me", "dispel_on_me",
    "light_slow", "kiting_slow", "attacker_slow",
}


def anim_role(role):
    """Map a threat role to an anim-subscriber role, or None to SKIP."""
    if role in ROLE_TO_ANIM:
        return ROLE_TO_ANIM[role]
    if role in SKIP_ROLES or role.endswith("_slow"):
        return None
    return None


# ---------------------------------------------------------------------------
# Third seed source - the EXISTING hand-written register_anim_maps() body in
# Sniper.lua. These entries are hand-tuned and field-tested, so they have the
# HIGHEST priority. Their `role` is ALREADY an anim-subscriber role
# (gap_close / hard_disable / channel_start / ult_burst) - it must NOT be
# re-mapped through ROLE_TO_ANIM. parse_existing_anim_maps() returns
# {ability_name: anim_role}; these names are tracked in ANIM_MAP_SEEDED so
# classify() emits their role verbatim.
# ---------------------------------------------------------------------------

# matches:  [AB3] = { ability = "bane_nightmare", role = "hard_disable" },
_ANIM_ENTRY = re.compile(
    r'\bability\s*=\s*"([^"]+)"\s*,\s*role\s*=\s*"([^"]+)"')


def parse_existing_anim_maps(path):
    """Extract {ability: anim_role} from Sniper.lua's register_anim_maps()."""
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    start = src.find("local function register_anim_maps()")
    if start < 0:
        raise SystemExit("register_anim_maps() not found in " + path)
    # walk to the matching `end` at column 0 (the function body is not nested
    # deeper than its own scope, so the first line-start "end" closes it).
    m = re.compile(r"^end\b", re.M).search(src, start)
    if not m:
        raise SystemExit("register_anim_maps() end not found in " + path)
    body = src[start:m.end()]
    # only entries inside Anim.RegisterMap blocks count; RegisterParticle
    # entries also use the {ability=,role=} shape, exclude them.
    out = {}
    for em in _ANIM_ENTRY.finditer(body):
        # skip if this match falls inside a RegisterParticle(...) call
        head = body.rfind("Anim.Register", 0, em.start())
        if head >= 0 and body.startswith("Anim.RegisterParticle", head):
            continue
        out[em.group(1)] = em.group(2)
    return out


# ---------------------------------------------------------------------------
# Lua emission helpers (mirrors gen_ability_data.py)
# ---------------------------------------------------------------------------

def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_key(k):
    k = str(k)
    if IDENT.match(k) and k not in LUA_KEYWORDS:
        return k
    return "[" + lua_str(k) + "]"


# ---------------------------------------------------------------------------
# Step 2 - castable filter + cast-activity slot derivation
# ---------------------------------------------------------------------------

def behavior_flags(s):
    """A '|'-joined DOTA_ABILITY_BEHAVIOR_* string -> set of short upper flags."""
    out = set()
    for chunk in str(s).split("|"):
        for f in chunk.split():
            f = f.strip().replace("DOTA_ABILITY_BEHAVIOR_", "")
            if f:
                out.add(f)
    return out


ACTIVE_TARGETING = {"UNIT_TARGET", "POINT", "NO_TARGET", "TOGGLE"}


def is_castable(name, abil):
    """True if `name` is a castable ability per the D18 filter."""
    if name == "generic_hidden":
        return False
    e = abil.get(name)
    if not isinstance(e, dict):
        return False
    if e.get("Innate") == "1":
        return False
    beh = behavior_flags(e.get("AbilityBehavior", ""))
    if "HIDDEN" in beh or "NOT_LEARNABLE" in beh:
        return False
    if "PASSIVE" in beh and not (beh & ACTIVE_TARGETING):
        return False
    atype = e.get("AbilityType") or ""
    if atype.endswith("ABILITY_TYPE_ATTRIBUTES"):
        return False
    return True


def is_ultimate(name, abil):
    e = abil.get(name)
    if not isinstance(e, dict):
        return False
    return (e.get("AbilityType") or "").endswith("ABILITY_TYPE_ULTIMATE")


# AB slot constant names, 1-indexed: SLOT_NAMES[1] = "AB1".
SLOT_NAMES = [None, "AB1", "AB2", "AB3", "AB4", "AB5", "AB6"]


def derive_slots(ability_list, abil):
    """ability name -> AB slot name. Castables only. Step 2."""
    castables = [a for a in ability_list if is_castable(a, abil)]
    slots = {}
    non_ult = []
    for a in castables:
        if is_ultimate(a, abil):
            slots[a] = "AB4"            # all ultimates map to AB4 (facet swap)
        else:
            non_ult.append(a)
    # first three non-ult -> AB1/AB2/AB3, 4th -> AB5, 5th -> AB6
    extra = ["AB1", "AB2", "AB3", "AB5", "AB6"]
    for i, a in enumerate(non_ult):
        if i < len(extra):
            slots[a] = extra[i]
        # 6th+ non-ult castable: no slot (unreachable in practice)
    return slots


# ---------------------------------------------------------------------------
# Step 3/4 - threat classification + anim-role resolution
# ---------------------------------------------------------------------------

# --- merge the existing-anim-map seed (highest priority) ----------------
# ANIM_MAP_ROLES: ability -> anim-subscriber role, parsed from Sniper.lua.
# ANIM_MAP_SEEDED: set of those ability names, so classify() emits the role
# verbatim instead of routing it through ROLE_TO_ANIM.
ANIM_MAP_ROLES = parse_existing_anim_maps(SNIPER_LUA)
ANIM_MAP_SEEDED = set(ANIM_MAP_ROLES)
# existing-anim-map entries are AUTHORITATIVE: they override the
# threat_data-join roles already in CURATED_ROLES.
for _ab, _role in ANIM_MAP_ROLES.items():
    CURATED_ROLES[_ab] = _role


def classify(name, abil):
    """Return (anim_role, seed) for an ability, or (None, _) to SKIP.

    seed is one of: "anim-map", "threat-join", "draft".
    """
    if name in ANIM_MAP_SEEDED:
        # role is already an anim-subscriber role - emit verbatim, no remap.
        return ANIM_MAP_ROLES[name], "anim-map"
    if name in CURATED_ROLES:
        return anim_role(CURATED_ROLES[name]), "threat-join"
    # behavior-draft fallback: only CHANNELLED is unambiguous
    e = abil.get(name)
    if isinstance(e, dict):
        beh = behavior_flags(e.get("AbilityBehavior", ""))
        if "CHANNELLED" in beh:
            return anim_role("channel_on_me"), "draft"
    return None, None


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def hero_short(hero_key):
    """npc_dota_hero_lion -> lion (for sort + comment)."""
    return hero_key.replace("npc_dota_hero_", "")


def build():
    heroes = json.load(open(os.path.join(KV_DIR, "npc_heroes.json")))["DOTAHeroes"]
    abil = json.load(open(os.path.join(KV_DIR, "npc_abilities.json")))["DOTAAbilities"]

    results = []          # list of (hero_key, [(slot, ability, anim_role, draft)])
    unresolved = []       # hero keys with no ability list
    high_slots = []       # (hero, ability, slot) landing on AB5/AB6

    for hero_key in heroes:
        hd = heroes[hero_key]
        if not isinstance(hd, dict) or not hero_key.startswith("npc_dota_hero_"):
            continue
        if hero_key == "npc_dota_hero_base":
            continue
        # Step 1 - ordered ability list
        ability_list = []
        i = 1
        while True:
            k = "Ability%d" % i
            if k not in hd:
                # KV ability slots are not always contiguous; probe a few more
                if i > 30:
                    break
                i += 1
                continue
            v = hd[k]
            if isinstance(v, str) and v:
                ability_list.append(v)
            i += 1
        if not ability_list:
            unresolved.append(hero_key)
            continue

        slots = derive_slots(ability_list, abil)

        # Step 3/4 - classify each castable
        rows = []
        for a, slot in slots.items():
            ar, seed = classify(a, abil)
            if ar is None:
                continue
            rows.append((slot, a, ar, seed))
            if slot in ("AB5", "AB6"):
                high_slots.append((hero_key, a, slot))
        if rows:
            # sort by slot order AB1..AB6
            rows.sort(key=lambda r: SLOT_NAMES.index(r[0]))
            results.append((hero_key, rows))

    results.sort(key=lambda r: hero_short(r[0]))
    return results, unresolved, high_slots


# ---------------------------------------------------------------------------
# correctness gate - Bane / Lion / Storm
# ---------------------------------------------------------------------------

GATE = {
    "npc_dota_hero_bane": [
        ("bane_nightmare", "AB3"), ("bane_fiends_grip", "AB4")],
    "npc_dota_hero_lion": [
        ("lion_impale", "AB1"), ("lion_voodoo", "AB2"),
        ("lion_finger_of_death", "AB4")],
    "npc_dota_hero_storm_spirit": [
        ("storm_spirit_electric_vortex", "AB2"),
        ("storm_spirit_ball_lightning", "AB4")],
}


def run_gate(heroes, abil):
    print("--- correctness gate (Bane / Lion / Storm) ---")
    ok = True
    for hero_key, expected in GATE.items():
        hd = heroes[hero_key]
        ability_list = []
        i = 1
        while i <= 30:
            v = hd.get("Ability%d" % i)
            if isinstance(v, str) and v:
                ability_list.append(v)
            i += 1
        slots = derive_slots(ability_list, abil)
        for ab, want in expected:
            got = slots.get(ab, "<none>")
            mark = "OK" if got == want else "FAIL"
            if got != want:
                ok = False
            print("  [%s] %-32s expected %s  got %s"
                  % (mark, ab, want, got))
    print("--- gate %s ---" % ("PASSED" if ok else "FAILED"))
    return ok


# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

HEADER = """-- _anim_maps_generated.lua - SCRATCH OUTPUT, for review only.
-- Generated by tools/gen_anim_maps.py from npc_heroes.json + npc_abilities.json.
-- This is the full register_anim_maps() body for the modern hero pool.
-- Do NOT require() this file; the main thread reviews it and integrates the
-- blocks into Sniper.lua's register_anim_maps() by hand. Re-run the generator
-- after a patch instead of hand-editing.
"""


def emit(results):
    out = [HEADER, ""]
    for hero_key, rows in results:
        out.append("    -- %s" % hero_short(hero_key))
        out.append('    Anim.RegisterMap("%s", {' % hero_key)
        for slot, ability, ar, seed in rows:
            line = '        [%s] = { ability = "%s", role = "%s" },' % (
                slot, ability, ar)
            if seed == "draft":
                line += "  -- (draft)"
            out.append(line)
        out.append("    })")
    return "\n".join(out) + "\n"


def main():
    heroes = json.load(open(os.path.join(KV_DIR, "npc_heroes.json")))["DOTAHeroes"]
    abil = json.load(open(os.path.join(KV_DIR, "npc_abilities.json")))["DOTAAbilities"]

    # CORRECTNESS GATE - run first, abort on failure.
    if not run_gate(heroes, abil):
        raise SystemExit("correctness gate FAILED - filter is wrong, aborting")

    results, unresolved, high_slots = build()

    text = emit(results)
    with open(os.path.normpath(OUT), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    # counts
    total_heroes = sum(
        1 for k, v in heroes.items()
        if isinstance(v, dict) and k.startswith("npc_dota_hero_")
        and k != "npc_dota_hero_base")
    total_abil = sum(len(rows) for _, rows in results)
    n_animmap = sum(1 for _, rows in results for r in rows
                    if r[3] == "anim-map")
    n_join = sum(1 for _, rows in results for r in rows
                 if r[3] == "threat-join")
    n_draft = sum(1 for _, rows in results for r in rows if r[3] == "draft")

    # regression check: current register_anim_maps() abilities MINUS
    # regenerated output abilities MUST be empty.
    gen_abils = {r[1] for _, rows in results for r in rows}
    regression = sorted(set(ANIM_MAP_ROLES) - gen_abils)
    print()
    print("--- regression check (current anim-map MINUS generated) ---")
    if regression:
        print("  REGRESSIONS: %s" % ", ".join(regression))
    else:
        print("  regression set: empty (OK - generated is a superset)")

    print()
    print("wrote %s (%d bytes)" % (os.path.normpath(OUT), len(text)))
    print("heroes total           : %d" % total_heroes)
    print("heroes with >=1 threat : %d" % len(results))
    print("abilities registered   : %d" % total_abil)
    print("  from existing anim-map : %d" % n_animmap)
    print("  from threat_data-join  : %d" % n_join)
    print("  from behavior-draft    : %d" % n_draft)
    if regression:
        raise SystemExit("REGRESSION - generated output dropped abilities, "
                         "aborting")
    if unresolved:
        print("UNRESOLVED heroes (no ability list): %s"
              % ", ".join(unresolved))
    else:
        print("UNRESOLVED heroes      : none")
    if high_slots:
        print("AB5/AB6 slot landings:")
        for hk, ab, slot in high_slots:
            print("  %s  %s -> %s" % (hero_short(hk), ab, slot))
    else:
        print("AB5/AB6 slot landings  : none")


if __name__ == "__main__":
    main()

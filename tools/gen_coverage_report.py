#!/usr/bin/env python
# tools/gen_coverage_report.py - audit threat-catalog coverage across every
# Dota 2 hero. Reads the KV roster + ability behavior, joins against
# lib/threat_data.lua's 9 catalog tables and Sniper.lua's Anim.RegisterMap
# entries, and emits COVERAGE_REPORT.md + COVERAGE_DATA.csv at project root.
#
# Re-run after each batch of catalog work to verify progress:
#   python tools/gen_coverage_report.py
#
# Outputs:
#   COVERAGE_REPORT.md  - human-readable summary, gap lists, action items
#   COVERAGE_DATA.csv   - machine-readable per-(hero, ability) matrix
#
# Pipeline:
#   1. Load hero roster + per-hero ability slots from npc_heroes.json
#   2. Load per-ability KV behavior from npc_abilities.json
#   3. Parse lib/threat_data.lua catalog tables (balanced-brace walk):
#      THREATS_ON_SELF, DISPLACEMENT_AFFORDANCE, ABILITY_TO_THREAT,
#      THREAT_TIMING, THREAT_CATEGORY, THREAT_SEVERITY,
#      LOTUS_WORTHY_INCOMING, ENEMY_CHANNEL_MODIFIERS, THREAT_TETHER_RANGE
#   4. Parse Sniper.lua Anim.RegisterMap calls (which hero, which ability
#      slots, role, instant_target flag)
#   5. Cross-reference: for each (hero, ability) tuple, mark coverage in
#      each catalog. Use ABILITY_TO_THREAT to bridge ability-name to
#      modifier-name catalogs.
#   6. Emit Markdown summary + CSV matrix.

import csv
import json
import os
import re
import sys
from collections import defaultdict
from datetime import date

KV_DIR = r"C:\Umbrella\assets\data"
ROOT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".."))
THREAT_DATA_LUA = os.path.join(ROOT, "lib", "threat_data.lua")
SNIPER_LUA = os.path.join(ROOT, "Sniper", "Sniper.lua")
REPORT_MD = os.path.join(ROOT, "COVERAGE_REPORT.md")
DATA_CSV = os.path.join(ROOT, "COVERAGE_DATA.csv")

# Catalog tables to parse. (name in ThreatData.X, key kind: "modifier" or "ability")
CATALOG_TABLES = [
    ("THREATS_ON_SELF", "modifier"),
    ("DISPLACEMENT_AFFORDANCE", "modifier"),
    ("ABILITY_TO_THREAT", "ability"),
    ("THREAT_TIMING", "modifier"),
    ("THREAT_CATEGORY", "modifier"),
    ("THREAT_SEVERITY", "modifier"),
    ("LOTUS_WORTHY_INCOMING", "modifier"),
    ("ENEMY_CHANNEL_MODIFIERS", "modifier"),
    ("THREAT_TETHER_RANGE", "modifier"),
]

# Catalog tables that DON'T live under `ThreatData.` -- per-modifier save
# chains live under `SAVE_CHAIN` etc. but in threat_data.lua they're
# anonymous local tables. We harvest them by scanning the whole file
# for `modifier_X = {` definitions that aren't already inside an above
# table. Skip for now -- the named tables are the primary coverage signal.


# ---------------------------------------------------------------------------
# KV loaders
# ---------------------------------------------------------------------------

def load_heroes():
    """Return {hero_key: {short, abilities[1..15], facets}} for all 7.41C
    heroes, excluding _base entries and personas."""
    path = os.path.join(KV_DIR, "npc_heroes.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    out = {}
    for key, val in data.get("DOTAHeroes", {}).items():
        if not isinstance(val, dict):
            continue
        if not key.startswith("npc_dota_hero_"):
            continue
        if key.endswith("_base"):
            continue
        # Personas (e.g. npc_dota_hero_invoker_persona) treated as siblings
        # of their base; skip to avoid double-counting.
        if "_persona" in key:
            continue
        abilities = {}
        for slot in range(1, 18):
            ab = val.get("Ability{}".format(slot))
            if ab and ab not in ("generic_hidden", "attribute_bonus"):
                abilities[slot] = ab
        out[key] = {
            "short": key[len("npc_dota_hero_"):],
            "abilities": abilities,
            "facets": val.get("Facets", {}),
        }
    return out


def load_abilities():
    """Return {ability_name: {behavior, cast_point, ...}} from KV data."""
    path = os.path.join(KV_DIR, "npc_abilities.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    out = {}
    for ab_name, ab in data.get("DOTAAbilities", {}).items():
        if not isinstance(ab, dict):
            continue
        behavior = ab.get("AbilityBehavior", "")
        # Normalize behavior string to a set of tokens
        beh_tokens = set()
        if isinstance(behavior, str):
            for tok in re.split(r"\s*\|\s*", behavior):
                tok = tok.strip()
                if tok:
                    beh_tokens.add(tok)
        out[ab_name] = {
            "behavior": beh_tokens,
            "cast_point": ab.get("AbilityCastPoint", "0"),
            "cast_range": ab.get("AbilityCastRange", "0"),
            "cooldown": ab.get("AbilityCooldown", "0"),
            "damage_type": ab.get("AbilityUnitDamageType", ""),
            "spell_immunity": ab.get("SpellImmunityType", ""),
            "is_granted_by_shard": ab.get("IsGrantedByShard") == "1",
            "is_granted_by_scepter": ab.get("IsGrantedByScepter") == "1",
        }
    return out


# ---------------------------------------------------------------------------
# Lua parsing -- balanced-brace walker for table blocks
# ---------------------------------------------------------------------------

def find_table_block(content, table_name):
    """Find `ThreatData.TABLE_NAME = { ... }` and return the content
    between the braces (exclusive). None if not found."""
    pat = r"ThreatData\." + re.escape(table_name) + r"\s*=\s*\{"
    m = re.search(pat, content)
    if not m:
        return None
    start = m.end()
    depth = 1
    i = start
    in_string = False
    in_line_comment = False
    in_block_comment = False
    while i < len(content) and depth > 0:
        if in_line_comment:
            if content[i] == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if content[i:i+2] == "]]":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if content[i] == '"' and content[i-1] != "\\":
                in_string = False
            i += 1
            continue
        if content[i:i+2] == "--":
            if content[i:i+4] == "--[[":
                in_block_comment = True
                i += 4
                continue
            in_line_comment = True
            i += 2
            continue
        if content[i] == '"':
            in_string = True
            i += 1
            continue
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
            if depth == 0:
                return content[start:i]
        i += 1
    return None


# Match top-level keys at depth 0 inside a table block. Keys are
# `identifier =` (we want the identifier).
_KEY_PATTERN = re.compile(r'(?:^|\n)\s*([A-Za-z_][A-Za-z0-9_]*)\s*=')


def extract_top_level_keys(block):
    """Return list of top-level keys (depth 0) defined as `key = ...`
    inside a Lua table block. Skips keys inside nested tables and
    keys inside comments / strings."""
    if not block:
        return []
    keys = []
    depth = 0
    i = 0
    in_string = False
    in_line_comment = False
    in_block_comment = False
    line_start = True
    pending_indent_end = 0
    while i < len(block):
        c = block[i]
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
                line_start = True
            i += 1
            continue
        if in_block_comment:
            if block[i:i+2] == "]]":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if c == '"' and (i == 0 or block[i-1] != "\\"):
                in_string = False
            i += 1
            continue
        if block[i:i+2] == "--":
            if block[i:i+4] == "--[[":
                in_block_comment = True
                i += 4
                continue
            in_line_comment = True
            i += 2
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == "{":
            depth += 1
            i += 1
            line_start = False
            continue
        if c == "}":
            depth -= 1
            i += 1
            line_start = False
            continue
        if c == "\n":
            line_start = True
            i += 1
            continue
        if depth == 0 and line_start:
            # Try to match an identifier followed by =
            m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", block[i:])
            if m:
                keys.append(m.group(1))
                # Advance past the identifier; the `=` and value are
                # parsed by the main loop (which will descend into the
                # value's braces if any).
                i += m.end() - len(m.group(0))  # back to start of ident
                # advance past identifier + whitespace + '='
                # easier: just skip the matched text
                i += len(m.group(0))
                line_start = False
                continue
        line_start = False
        i += 1
    return keys


# ---------------------------------------------------------------------------
# Sniper.lua anim catalog parser
# ---------------------------------------------------------------------------

_REGMAP_HEADER = re.compile(
    r'Anim\.RegisterMap\("(npc_dota_hero_[A-Za-z0-9_]+)"\s*,\s*\{')
_ANIM_ENTRY = re.compile(
    r'\[AB(\d+)\]\s*=\s*\{\s*'
    r'ability\s*=\s*"([^"]+)"\s*,\s*'
    r'role\s*=\s*"([^"]+)"'
    r'(?:\s*,\s*instant_target\s*=\s*(true|false))?'
)


def parse_anim_registry(content):
    """Return {hero_key: [{slot, ability, role, instant_target}, ...]}"""
    out = {}
    for m in _REGMAP_HEADER.finditer(content):
        hero = m.group(1)
        start = m.end()
        depth = 1
        i = start
        while i < len(content) and depth > 0:
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = content[start:i]
        entries = []
        for em in _ANIM_ENTRY.finditer(block):
            entries.append({
                "slot": int(em.group(1)),
                "ability": em.group(2),
                "role": em.group(3),
                "instant_target": em.group(4) == "true",
            })
        out[hero] = entries
    return out


# ---------------------------------------------------------------------------
# Modifier-name -> hero mapping
# ---------------------------------------------------------------------------

def build_modifier_to_hero(heroes):
    """Build a longest-prefix lookup: given a modifier or ability name,
    return the hero short name (or None)."""
    shorts = sorted({h["short"] for h in heroes.values()}, key=lambda s: -len(s))
    # Also include the ability-name prefixes so e.g. `phantom_assassin_X`
    # resolves even when the modifier doesn't follow the hero-short prefix
    # exactly. Most modifiers do use hero_short though.

    # Special mappings for hero shorts vs ability prefixes that differ
    # (npc_dota_hero_X but abilities are Y_Z). The KV usually keeps the
    # same prefix; document exceptions here.
    aliases = {
        # npc_dota_hero_skeleton_king -> wraith_king prefixes
        "skeleton_king": ["skeleton_king", "wraith_king"],
        # npc_dota_hero_nevermore -> shadow_fiend
        "nevermore": ["nevermore", "shadow_fiend"],
        # npc_dota_hero_furion -> nature's prophet
        "furion": ["furion"],
        # npc_dota_hero_obsidian_destroyer -> outworld_destroyer (modern UI)
        "obsidian_destroyer": ["obsidian_destroyer", "outworld_destroyer"],
        # npc_dota_hero_zuus -> zeus
        "zuus": ["zuus", "zeus"],
        # npc_dota_hero_doom_bringer -> doom
        "doom_bringer": ["doom_bringer", "doom"],
        # npc_dota_hero_magnataur -> magnus
        "magnataur": ["magnataur", "magnus"],
        # npc_dota_hero_necrolyte -> necrophos
        "necrolyte": ["necrolyte", "necrophos"],
        # npc_dota_hero_life_stealer -> lifestealer
        "life_stealer": ["life_stealer", "lifestealer"],
        # npc_dota_hero_drow_ranger
        "drow_ranger": ["drow_ranger", "drow"],
        # npc_dota_hero_centaur -> centaur_warrunner
        "centaur": ["centaur", "centaur_warrunner"],
        # npc_dota_hero_rattletrap -> clockwerk
        "rattletrap": ["rattletrap", "clockwerk"],
        # npc_dota_hero_treant -> treant_protector
        "treant": ["treant", "treant_protector"],
        # npc_dota_hero_wisp -> io
        "wisp": ["wisp", "io"],
        # npc_dota_hero_abyssal_underlord
        "abyssal_underlord": ["abyssal_underlord", "underlord"],
        # npc_dota_hero_shredder -> timbersaw
        "shredder": ["shredder", "timbersaw"],
    }
    prefix_to_hero = {}
    for hero_short in shorts:
        keys = aliases.get(hero_short, [hero_short])
        for k in keys:
            prefix_to_hero[k] = hero_short

    sorted_prefixes = sorted(prefix_to_hero.keys(), key=lambda s: -len(s))

    def lookup(name):
        s = name
        if s.startswith("modifier_"):
            s = s[len("modifier_"):]
        for p in sorted_prefixes:
            if s == p or s.startswith(p + "_"):
                return prefix_to_hero[p]
        return None

    return lookup


# ---------------------------------------------------------------------------
# Main report assembly
# ---------------------------------------------------------------------------

def main():
    heroes = load_heroes()
    abilities = load_abilities()

    with open(THREAT_DATA_LUA, "r", encoding="utf-8") as f:
        td_content = f.read()
    with open(SNIPER_LUA, "r", encoding="utf-8") as f:
        sniper_content = f.read()

    # Parse catalog tables
    catalog = {}  # table_name -> set of keys
    for tbl_name, _kind in CATALOG_TABLES:
        block = find_table_block(td_content, tbl_name)
        keys = extract_top_level_keys(block) if block else []
        catalog[tbl_name] = set(keys)

    # Parse Sniper anim catalog
    anim_catalog = parse_anim_registry(sniper_content)

    # Build modifier-name -> hero lookup
    lookup_hero = build_modifier_to_hero(heroes)

    # Per-hero aggregation
    hero_stats = {}
    for hero_key, hero in heroes.items():
        short = hero["short"]
        anim_entries = anim_catalog.get(hero_key, [])
        # Threat-data coverage by ability for this hero
        per_ability = {}
        for slot, ab in hero["abilities"].items():
            ab_info = abilities.get(ab, {})
            covers = {tbl: False for tbl, _ in CATALOG_TABLES}
            # ABILITY_TO_THREAT: key by ability name
            if ab in catalog["ABILITY_TO_THREAT"]:
                covers["ABILITY_TO_THREAT"] = True
            # All other tables: key by modifier name. We don't have a
            # direct ability->modifier map without parsing the table
            # values, so heuristic: any modifier in each table that
            # belongs to this hero AND starts with the ability name.
            for tbl_name, _kind in CATALOG_TABLES:
                if tbl_name == "ABILITY_TO_THREAT":
                    continue
                for mod in catalog[tbl_name]:
                    # mod is typically "modifier_<ability>_<suffix>" or
                    # "modifier_<ability>"
                    if not mod.startswith("modifier_"):
                        continue
                    rest = mod[len("modifier_"):]
                    if rest == ab or rest.startswith(ab + "_"):
                        covers[tbl_name] = True
                        break
            # Anim entry coverage
            anim_entry = next((e for e in anim_entries if e["ability"] == ab), None)

            per_ability[slot] = {
                "ability": ab,
                "behavior": ab_info.get("behavior", set()),
                "cast_point": ab_info.get("cast_point", ""),
                "damage_type": ab_info.get("damage_type", ""),
                "is_shard": ab_info.get("is_granted_by_shard", False),
                "is_scepter": ab_info.get("is_granted_by_scepter", False),
                "covers": covers,
                "anim": anim_entry,
            }

        # Hero-level summary
        n_active_threats = sum(
            1 for slot, a in per_ability.items()
            if is_active_threat(a["behavior"])
        )
        n_covered = sum(
            1 for slot, a in per_ability.items()
            if any(a["covers"].values()) or a["anim"]
        )
        hero_stats[hero_key] = {
            "short": short,
            "per_ability": per_ability,
            "anim_entries": anim_entries,
            "n_abilities": len(per_ability),
            "n_active_threats": n_active_threats,
            "n_covered": n_covered,
        }

    # Coverage stats
    total_heroes = len(heroes)
    heroes_with_anim = sum(1 for hs in hero_stats.values() if hs["anim_entries"])
    heroes_with_any_coverage = sum(
        1 for hs in hero_stats.values()
        if hs["anim_entries"] or hs["n_covered"] > 0
    )
    heroes_with_zero = total_heroes - heroes_with_any_coverage
    verify_count = td_content.count("(verify)")
    instant_target_count = sum(
        1 for entries in anim_catalog.values()
        for e in entries if e["instant_target"]
    )

    # ---- Emit Markdown ----
    out = []
    out.append("# Sniper brain — threat catalog coverage report\n")
    out.append("_Generated by `tools/gen_coverage_report.py` on {}._\n".format(
        date.today().isoformat()))
    out.append("Re-run after every catalog batch to track progress.\n")

    out.append("\n## Summary\n")
    out.append("| Metric | Count | % |")
    out.append("|---|---|---|")
    out.append("| Heroes in 7.41C (`npc_heroes.json`) | {} | 100% |".format(total_heroes))
    out.append("| Heroes with anim RegisterMap entries | {} | {:.0f}% |".format(
        heroes_with_anim, 100.0 * heroes_with_anim / total_heroes))
    out.append("| Heroes with **any** catalog entry | {} | {:.0f}% |".format(
        heroes_with_any_coverage, 100.0 * heroes_with_any_coverage / total_heroes))
    out.append("| Heroes with **zero** coverage | {} | {:.0f}% |".format(
        heroes_with_zero, 100.0 * heroes_with_zero / total_heroes))
    out.append("| THREATS_ON_SELF entries | {} | — |".format(
        len(catalog["THREATS_ON_SELF"])))
    out.append("| ABILITY_TO_THREAT entries | {} | — |".format(
        len(catalog["ABILITY_TO_THREAT"])))
    out.append("| THREAT_CATEGORY entries | {} | — |".format(
        len(catalog["THREAT_CATEGORY"])))
    out.append("| `(verify)` flags in threat_data.lua | {} | — |".format(verify_count))
    out.append("| `instant_target` flagged anim entries | {} | — |".format(
        instant_target_count))

    # Heroes with zero coverage
    zero_heroes = sorted(
        [hs for hs in hero_stats.values()
         if not hs["anim_entries"] and hs["n_covered"] == 0],
        key=lambda h: h["short"]
    )
    out.append("\n## Heroes with zero catalog coverage ({})\n".format(len(zero_heroes)))
    out.append("Each hero has no entry in either Sniper.lua's anim catalog "
               "or any threat_data.lua table. Listed alphabetically with "
               "their threat-relevant abilities (UNIT_TARGET / POINT_AOE / "
               "skill-shots, excluding passives and self-buffs).\n")
    out.append("| Hero | Active-threat abilities (per KV) |")
    out.append("|---|---|")
    for hs in zero_heroes:
        threats = []
        for slot, a in sorted(hs["per_ability"].items()):
            if is_active_threat(a["behavior"]):
                kind = classify_behavior(a["behavior"])
                threats.append("`{}` ({})".format(a["ability"], kind))
        out.append("| {} | {} |".format(hs["short"], ", ".join(threats) or "—"))

    # Heroes partially covered (have some entries but not all threat-relevant abilities)
    partial_heroes = sorted(
        [hs for hs in hero_stats.values()
         if (hs["anim_entries"] or hs["n_covered"] > 0)
         and hs["n_covered"] < hs["n_active_threats"]],
        key=lambda h: h["n_active_threats"] - h["n_covered"],
        reverse=True
    )
    out.append("\n## Heroes with partial coverage ({})\n".format(len(partial_heroes)))
    out.append("Heroes with at least one entry but where some active-threat "
               "abilities are not catalogued. `gap` = active_threats - covered.\n")
    out.append("| Hero | gap | Active-threat abilities | Covered |")
    out.append("|---|---|---|---|")
    for hs in partial_heroes[:30]:  # top 30
        threats = [a["ability"] for slot, a in sorted(hs["per_ability"].items())
                   if is_active_threat(a["behavior"])]
        covered = [a["ability"] for slot, a in sorted(hs["per_ability"].items())
                   if (any(a["covers"].values()) or a["anim"])
                   and is_active_threat(a["behavior"])]
        out.append("| {} | {} | {} | {} |".format(
            hs["short"], hs["n_active_threats"] - hs["n_covered"],
            ", ".join(threats), ", ".join(covered) or "—"))

    # Anim entries missing instant_target candidates
    out.append("\n## Anim entries missing `instant_target` candidates\n")
    out.append("Entries in Sniper.lua RegisterMap that are UNIT_TARGET "
               "(per KV) and don't have `instant_target = true`. The flag "
               "bypasses lib/anim.lua's facing gate for abilities where the "
               "caster doesn't aim. NOT all of these need it (some abilities "
               "have meaningful cast point + turn-to-face). VERIFY VIA DEMO "
               "LOG before flagging.\n")
    out.append("| Hero | Ability | Cast point | Role | KV note |")
    out.append("|---|---|---|---|---|")
    for hero_key, entries in sorted(anim_catalog.items()):
        for e in entries:
            ab_info = abilities.get(e["ability"], {})
            beh = ab_info.get("behavior", set())
            if "DOTA_ABILITY_BEHAVIOR_UNIT_TARGET" not in beh:
                continue
            if e["instant_target"]:
                continue
            cp = ab_info.get("cast_point", "0")
            note_parts = []
            if "DOTA_ABILITY_BEHAVIOR_IGNORE_BACKSWING" in beh:
                note_parts.append("IGNORE_BACKSWING")
            if "DOTA_ABILITY_BEHAVIOR_CHANNELLED" in beh:
                note_parts.append("CHANNELLED")
            if cp in ("0", "0.0"):
                note_parts.append("instant cast")
            out.append("| {} | `{}` | {} | {} | {} |".format(
                hero_key[len("npc_dota_hero_"):],
                e["ability"], cp, e["role"],
                ", ".join(note_parts) or "—"))

    # (verify) flag list
    out.append("\n## `(verify)` flags in threat_data.lua\n")
    out.append("Lines flagged for empirical confirmation via "
               "`threat_unrecognized` / modseen output in real-match logs.\n")
    out.append("```")
    for m in re.finditer(r"^.*\(verify\).*$", td_content, re.MULTILINE):
        line = m.group(0).strip()
        if len(line) > 140:
            line = line[:137] + "..."
        out.append(line)
    out.append("```")

    # Footer
    out.append("\n## How to use this report\n")
    out.append("- **Zero-coverage heroes**: highest-impact gap to close. "
               "Pick a batch (5-15 heroes per commit), open Liquipedia, "
               "categorize each active-threat ability into the existing "
               "10 categories, add entries to `lib/threat_data.lua` + "
               "`Sniper/Sniper.lua` anim catalog.")
    out.append("- **Partial-coverage heroes**: medium-impact. Often "
               "newer abilities (facets, shard/scepter grants) or "
               "talents missed in earlier passes.")
    out.append("- **`instant_target` candidates**: confirm via demo "
               "before bulk-flagging. The criterion is 'caster doesn't "
               "turn-to-face before cast'; abilities with >=0.3s cast "
               "point and engine turn-to-face usually have working "
               "reactive (OnModifierCreate) detection even if the anim "
               "path is gate-refused.")
    out.append("- **`(verify)` flags**: burndown via `threat_unrecognized` "
               "log lines after each match. Confirmed names lose the flag; "
               "wrong names get corrected.\n")
    out.append("Re-run `python tools/gen_coverage_report.py` after each "
               "batch to track progress against the summary table.\n")

    with open(REPORT_MD, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print("wrote {} ({} bytes)".format(REPORT_MD, os.path.getsize(REPORT_MD)))

    # ---- Emit CSV (machine-readable per-ability matrix) ----
    fieldnames = [
        "hero", "slot", "ability", "behavior",
        "cast_point", "damage_type", "is_shard", "is_scepter",
        "anim_entry", "anim_role", "anim_instant_target",
    ] + [tbl for tbl, _ in CATALOG_TABLES]
    with open(DATA_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for hs in sorted(hero_stats.values(), key=lambda h: h["short"]):
            for slot, a in sorted(hs["per_ability"].items()):
                row = {
                    "hero": hs["short"],
                    "slot": slot,
                    "ability": a["ability"],
                    "behavior": "|".join(sorted(a["behavior"])),
                    "cast_point": a["cast_point"],
                    "damage_type": a["damage_type"],
                    "is_shard": "1" if a["is_shard"] else "",
                    "is_scepter": "1" if a["is_scepter"] else "",
                    "anim_entry": "1" if a["anim"] else "",
                    "anim_role": a["anim"]["role"] if a["anim"] else "",
                    "anim_instant_target": "1" if (a["anim"] and a["anim"]["instant_target"]) else "",
                }
                for tbl, _ in CATALOG_TABLES:
                    row[tbl] = "1" if a["covers"][tbl] else ""
                w.writerow(row)
    print("wrote {} ({} bytes)".format(DATA_CSV, os.path.getsize(DATA_CSV)))


def is_active_threat(behavior):
    """Heuristic: ability is an active threat to Sniper if it's
    UNIT_TARGET on enemies, POINT-AOE, or a CHANNELLED ability.
    Excludes passives, self-buffs, and pure-mobility on caster."""
    if not behavior:
        return False
    if "DOTA_ABILITY_BEHAVIOR_PASSIVE" in behavior:
        return False
    if "DOTA_ABILITY_BEHAVIOR_NO_TARGET" in behavior and \
       "DOTA_ABILITY_BEHAVIOR_AOE" not in behavior and \
       "DOTA_ABILITY_BEHAVIOR_CHANNELLED" not in behavior:
        return False  # self-only NO_TARGET, e.g. mobility self-cast
    if "DOTA_ABILITY_BEHAVIOR_UNIT_TARGET" in behavior:
        return True
    if "DOTA_ABILITY_BEHAVIOR_POINT" in behavior and \
       "DOTA_ABILITY_BEHAVIOR_AOE" in behavior:
        return True
    if "DOTA_ABILITY_BEHAVIOR_CHANNELLED" in behavior:
        return True
    return False


def classify_behavior(behavior):
    """Short label for the ability behavior."""
    if "DOTA_ABILITY_BEHAVIOR_CHANNELLED" in behavior:
        return "channelled"
    if "DOTA_ABILITY_BEHAVIOR_UNIT_TARGET" in behavior:
        if "DOTA_ABILITY_BEHAVIOR_IGNORE_BACKSWING" in behavior:
            return "unit-target instant"
        return "unit-target"
    if "DOTA_ABILITY_BEHAVIOR_POINT" in behavior and \
       "DOTA_ABILITY_BEHAVIOR_AOE" in behavior:
        return "point-aoe"
    if "DOTA_ABILITY_BEHAVIOR_POINT" in behavior:
        return "point"
    return "other"


if __name__ == "__main__":
    sys.exit(main())

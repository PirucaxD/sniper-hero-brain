#!/usr/bin/env python
# tools/sync_threat_data_to_toolkit.py - sync lib/threat_data.lua into the
# uczone-toolkit public repo with style adaptation.
#
# The toolkit is the public MIT mirror of the hand-written lib/ modules.
# Its style differs from the private brain source:
#   - no em-dashes (replaced with -- or ,)
#   - no version tags (v6.15.N stripped from comments)
#   - "Sniper" prose references replaced with "the hero" or "your hero"
#     (but ability / modifier identifiers like `sniper_concussive_grenade`
#     are preserved verbatim)
#   - keeps the toolkit's existing public docstring header
#
# Usage:
#   python tools/sync_threat_data_to_toolkit.py
#
# Writes:
#   C:\Users\arcos\uczone-toolkit\lib\threat_data.lua

import os
import re
import sys

SRC = r"C:\Users\arcos\dota-hero-brains\lib\threat_data.lua"
DST = r"C:\Users\arcos\uczone-toolkit\lib\threat_data.lua"

# Where the source's docstring ends and the data starts. We keep the
# toolkit's existing docstring (the public version) and graft the data on.
SOURCE_DATA_MARKER = "local ThreatData = {}"


def strip_version_tags(line):
    """Remove `v6.15.NNN:` and `v6.15.NNN ` from inline comments.
    Collapses extra `(verify)` punctuation cleanly."""
    # Remove `v6.15.NNN:` (with colon)
    line = re.sub(r"\bv6\.15\.\d+:\s*", "", line)
    # Remove `v6.15.NNN ` (no colon) - keep simple
    line = re.sub(r"\bv6\.15\.\d+\s*", "", line)
    return line


def replace_em_dashes(line):
    """Replace em-dash with hyphens or commas. Heuristic: between two
    spaces => ' -- ', otherwise inline ',' (rare). Toolkit prefers ' -- '."""
    line = line.replace(" - ", " -- ")
    # Stray em-dashes (no surrounding spaces) become hyphens
    line = line.replace("-", "-")
    return line


# Match "Sniper" as a standalone WORD (not part of sniper_xxx identifier or
# Sniper.lua filename). Targets prose comments like "Sniper picks up X" or
# "for Sniper", not modifier_sniper_X or `Sniper.lua` references.
_SNIPER_PROSE = re.compile(r"\bSniper\b(?!\.lua)")


def replace_sniper_prose(line):
    """Replace prose 'Sniper' with 'the hero' in comments. Preserve:
    - sniper_X identifiers (lowercase, not matched by \bSniper\b)
    - Sniper.lua filename references (negative lookahead)"""
    # Only touch comments (lines containing -- or starting with --)
    if "--" not in line and not line.lstrip().startswith("--"):
        return line
    return _SNIPER_PROSE.sub("the hero", line)


def cleanup_collapsed_comments(line):
    """After stripping version tags + em-dashes, some comments end up with
    awkward double-hyphen runs or empty markers. Clean up."""
    # Collapse `-- -- ` (post-strip empty marker)
    line = re.sub(r"--\s+--\s+", "-- ", line)
    # Trim trailing whitespace
    line = line.rstrip() + "\n"
    # Collapse a comment that became `--` (empty) to actually empty
    if line.strip() == "--":
        return ""
    return line


def transform_data_body(text):
    """Apply all style transforms to the data portion of threat_data.lua."""
    out = []
    for line in text.splitlines(keepends=True):
        line = replace_em_dashes(line)
        line = strip_version_tags(line)
        line = replace_sniper_prose(line)
        line = cleanup_collapsed_comments(line)
        if line:  # drop lines that became empty after cleanup
            out.append(line)
    return "".join(out)


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        src = f.read()
    with open(DST, "r", encoding="utf-8") as f:
        dst = f.read()

    # Find the marker in both files
    src_idx = src.find(SOURCE_DATA_MARKER)
    dst_idx = dst.find(SOURCE_DATA_MARKER)
    if src_idx < 0:
        raise SystemExit("marker not found in source: " + SOURCE_DATA_MARKER)
    if dst_idx < 0:
        raise SystemExit("marker not found in dst: " + SOURCE_DATA_MARKER)

    # Toolkit keeps its existing header (up to and including the marker line)
    # plus everything immediately after for the ItemData require + sg() helper.
    # The simplest approach: keep dst header up to ONE FULL block after the
    # marker (the ItemData / sg setup), then take all subsequent ThreatData
    # definitions from source.

    # Strategy: split both files at SOURCE_DATA_MARKER, then for the body
    # take source content but reuse dst's local helper block (ItemData /
    # sg) since the toolkit header references them with the public style.
    # In practice: keep dst up to the first `----------------------------`
    # divider line after the marker (which is the SAVE_KIND section start),
    # then concat the transformed source body from the same divider.

    DIVIDER = "----------------------------------------------------------------------------\n-- SAVE_KIND"

    src_data_idx = src.find(DIVIDER)
    dst_header_idx = dst.find(DIVIDER)
    if src_data_idx < 0:
        raise SystemExit("SAVE_KIND divider not found in source")
    if dst_header_idx < 0:
        raise SystemExit("SAVE_KIND divider not found in dst")

    dst_header = dst[:dst_header_idx]   # toolkit's public header + sg() setup
    src_body = src[src_data_idx:]       # source data tables from SAVE_KIND on

    src_body = transform_data_body(src_body)

    result = dst_header + src_body
    # Normalise line endings to LF
    result = result.replace("\r\n", "\n")

    with open(DST, "w", encoding="utf-8", newline="\n") as f:
        f.write(result)

    print("wrote {} ({} bytes)".format(DST, os.path.getsize(DST)))

    # Quick sanity checks
    with open(DST, "r", encoding="utf-8") as f:
        check = f.read()
    em_dashes = check.count("-")
    version_tags = len(re.findall(r"\bv6\.15\.\d+", check))
    sniper_prose = len(_SNIPER_PROSE.findall(check))
    print("  em-dashes: {} (should be 0)".format(em_dashes))
    print("  v6.15 tags: {} (should be 0)".format(version_tags))
    print("  'Sniper' prose: {} (should be 0 or small)".format(sniper_prose))


if __name__ == "__main__":
    sys.exit(main())

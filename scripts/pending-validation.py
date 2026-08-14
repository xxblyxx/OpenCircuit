#!/usr/bin/env python3
"""Surface validations that are DUE from docs/PENDING_VALIDATION.md.

Run by the `SessionStart` hook in .claude/settings.json (startup + clear), which injects the
output into Claude's context before the first message. Also runnable by hand:

    scripts/pending-validation.py            # what the hook will say (JSON)
    scripts/pending-validation.py --list     # every open item, ripe or not, human-readable

WHY A HOOK AND NOT JUST A DOC. This repo ships changes whose correctness cannot be checked at
merge time — the ring produces the confirming data hours or days later, if at all. A note in
CLAUDE.md is read every session but acted on only when the topic is already in play, which is
exactly when a reminder is least needed. The hook fires regardless of what the session is about.

⚠️ DESIGN RULE: FAIL LOUD, NOT SILENT. An entry with a missing or unparseable `check-after` is
treated as RIPE, not skipped. The whole point is that things do not get quietly forgotten, so a
typo in a date must produce noise rather than an item that never surfaces again.

Stdlib only, no network, reads one file. It must stay fast — it runs before every session.
"""

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path

DOC = Path(__file__).resolve().parent.parent / "docs" / "PENDING_VALIDATION.md"
# Only entries under this heading are live. Anything below `## Settled` is history.
OPEN_HEADING = "## Open"
SETTLED_HEADING = "## Settled"
FIELD = re.compile(r"^-\s+([a-z-]+):\s*(.*)$", re.I)


def parse(text):
    """[{title, fields...}] for entries in the Open section, in document order."""
    # Slice out the Open section so Settled entries can never be re-surfaced.
    start = text.find(OPEN_HEADING)
    if start == -1:
        return []
    end = text.find(SETTLED_HEADING, start)
    body = text[start:end if end != -1 else len(text)]

    items = []
    for block in body.split("\n### ")[1:]:
        lines = block.splitlines()
        item = {"title": lines[0].strip()}
        # Continuation lines matter: these fields are prose and wrap naturally at the margin.
        # Without joining them, `needs:` and `blocked-because:` — the two that explain WHY an
        # item is still open — get truncated mid-sentence in the reminder, which is precisely
        # where a half-sentence is useless.
        last = None
        for line in lines[1:]:
            stripped = line.strip()
            m = FIELD.match(stripped)
            if m:
                last = m.group(1).lower()
                item.setdefault(last, m.group(2).strip())
            elif stripped and last and line.startswith(" "):
                item[last] = f"{item[last]} {stripped}".strip()
            elif not stripped:
                last = None
        items.append(item)
    return items


def ripeness(item, today):
    """(is_ripe, note). Unparseable/missing dates are RIPE on purpose — see the module docstring."""
    raw = item.get("check-after")
    if not raw:
        return True, "no check-after date set"
    try:
        due = date.fromisoformat(raw.split()[0])
    except ValueError:
        return True, f"unparseable check-after {raw!r}"
    if today >= due:
        overdue = (today - due).days
        return True, f"due {raw}" + (f", {overdue}d ago" if overdue else "")
    return False, f"not until {raw}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="print every open item, ripe or not")
    args = ap.parse_args()

    if not DOC.exists():
        return 0
    items = parse(DOC.read_text())
    today = date.today()
    scored = [(item, *ripeness(item, today)) for item in items]
    ripe = [(i, n) for i, r, n in scored if r]

    if args.list:
        if not scored:
            print("No open validations.")
            return 0
        for item, r, note in scored:
            print(f"{'RIPE ' if r else '     '} {item.get('id', '?'):<28} {item['title']}")
            print(f"        {note}; needs: {item.get('needs', '?')}")
        return 0

    if not ripe:
        return 0  # Silence when there is nothing to say — that is what keeps this credible.

    lines = [f"{len(ripe)} pending validation(s) now worth checking "
             f"(from docs/PENDING_VALIDATION.md):"]
    for item, note in ripe:
        lines.append(f"  • [{item.get('id', '?')}] {item['title']}")
        lines.append(f"    shipped: {item.get('shipped', '?')} — {note}")
        lines.append(f"    needs:   {item.get('needs', '?')}")
        lines.append(f"    check:   {item.get('check', '?')}")
    if len(items) > len(ripe):
        lines.append(f"({len(items) - len(ripe)} more not yet ripe.)")
    lines.append("ASK the user whether they want to validate now — do not start pulling data "
                 "unprompted, and do not let this displace what they actually opened the session "
                 "for. If they decline, leave the file alone.")

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "\n".join(lines),
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())

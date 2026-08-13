#!/usr/bin/env bash
#
# sync-refs.sh — clone/refresh the read-only reference codebases into refs/.
#
# These are OTHER PEOPLE'S PROJECTS, kept locally so we can grep them while
# designing and troubleshooting OpenCircuit. See docs/REFERENCES.md for what
# each one is good for.
#
#   refs/ is gitignored. Nothing here is ever committed into OpenCircuit.
#
# ⚖️  LICENSES DIFFER AND SOME ARE COPYLEFT OR NONCOMMERCIAL.
#     Read these for FACTS (byte layouts, opcode semantics, which chart type
#     suits which metric, schema columns). Never copy their code into
#     OpenCircuit. See the top of docs/REFERENCES.md.
#
# Usage:
#   scripts/sync-refs.sh            # clone missing, refresh existing
#   scripts/sync-refs.sh noop       # only the named repo(s)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFS_DIR="$REPO_ROOT/refs"

# name|url|license|why
#
# NOTE ON GADGETBRIDGE: the GitHub repo is an ARCHIVED MIRROR, stale since
# 2024-12-22. Development moved to Codeberg, which is what we track here.
REPOS=(
  "noop|https://github.com/ryanbr/noop.git|PolyForm-Noncommercial-1.0.0|Offline WHOOP companion in Swift + experimental Oura RING driver. Closest sibling: BLE -> local store -> HealthKit -> SwiftUI charts."
  "Gadgetbridge|https://codeberg.org/Freeyourgadget/Gadgetbridge.git|AGPL-3.0|~70 reverse-engineered wearables incl. the Yawell/Colmi RING family. Richest source of BLE protocol prior art."
  "open-wearables|https://github.com/the-momentum/open-wearables.git|MIT|Cross-vendor metric normalization + documented sleep/resilience score algorithms."
  "GarminDB|https://github.com/tcgoetz/GarminDB.git|GPL-2.0|Garmin -> SQLite schemas for sleep/HRV/stress, plus Jupyter plotting decisions."
  "fitbit-grafana|https://github.com/arpanghosh8453/fitbit-grafana.git|BSD-4-Clause|Grafana dashboard JSON = a literal metric -> chart-type map. Most on-point for visualization."
)

mkdir -p "$REFS_DIR"

# want <name> [filter...] — true if no filters were given, or <name> is among them.
# The $# check must come AFTER the shift, or a bare invocation skips everything.
want() {
  local name="$1"; shift
  [ "$#" -eq 0 ] && return 0
  for arg in "$@"; do
    [ "$arg" = "$name" ] && return 0
  done
  return 1
}

for entry in "${REPOS[@]}"; do
  IFS='|' read -r name url license why <<< "$entry"
  want "$name" "$@" || continue

  dest="$REFS_DIR/$name"
  printf '\n=== %s  [%s]\n' "$name" "$license"

  if [ -d "$dest/.git" ]; then
    existing="$(git -C "$dest" remote get-url origin 2>/dev/null || echo '')"
    if [ "$existing" != "$url" ]; then
      echo "  remote changed:"
      echo "    was: ${existing:-<none>}"
      echo "    now: $url"
      echo "  re-cloning (local clone is a disposable read-only copy)"
      rm -rf "$dest"
    else
      echo "  refreshing $dest"
      branch="$(git -C "$dest" rev-parse --abbrev-ref HEAD)"
      git -C "$dest" fetch --depth 1 origin "$branch" --quiet
      git -C "$dest" reset --hard "origin/$branch" --quiet
      git -C "$dest" log -1 --format='  now at %h %ad  %s' --date=short
      continue
    fi
  fi

  echo "  cloning $url"
  git clone --depth 1 --single-branch --quiet "$url" "$dest"
  git -C "$dest" log -1 --format='  now at %h %ad  %s' --date=short
done

printf '\n=== disk usage\n'
du -sh "$REFS_DIR"/*/ 2>/dev/null || true

cat <<'EOF'

Done. Reference material is in refs/ (gitignored).

  Read docs/REFERENCES.md first — it maps each repo to the OpenCircuit
  problem it helps with, and names the specific files worth opening.

  Reminder: read for FACTS, never copy code. Licenses differ.
EOF

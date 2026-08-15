#!/usr/bin/env python3
"""Report Claude plan usage BEFORE work starts, and warn at >=80% on either window.

Run by hooks in .claude/settings.json:
  SessionStart (startup|clear|resume) -> --mode session : always reports both windows
  UserPromptSubmit                    -> --mode prompt  : silent unless >=80%, throttled

Also runnable by hand:

    scripts/usage-guard.py --report        # human-readable, no JSON, no throttle
    scripts/usage-guard.py --mode session  # exactly what the hook injects

WHY A HOOK AND NOT JUST THE SKILL. The global `usage-monitor` skill answers "check usage" when
asked — which is after you have already committed to a piece of work. The failure this guards
against is the opposite order: starting a long task at 78% and running dry halfway through, with
the reasoning in a context that is about to become unusable. So the number has to arrive
unprompted, before the first instruction, and again if we cross the line mid-session.

⚠️ DESIGN RULE: FAIL LOUD, NOT SILENT (same rule as pending-validation.py). If the usage number
cannot be obtained, session mode says so in one line rather than printing nothing. A guard that
silently stops working is worse than no guard, because it still gets trusted.

Stdlib only. One network call at most every REFRESH_MAX_AGE seconds (shared cache), hard
timeouts throughout — it runs before every session and every prompt, so it must never hang.
"""

import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Written by Claude Code's own /usage refresh; we top it up with the same numbers so the two
# stay interchangeable and a manual /usage counts as a refresh for us too.
CACHE = Path.home() / ".claude" / "vscode-claude-status-cache.json"
STATE = Path.home() / ".claude" / "opencircuit-usage-guard.json"  # throttle for --mode prompt

THRESHOLD_PCT = 80.0
REFRESH_MAX_AGE = 15 * 60       # don't hit the API more often than this
STALE_AFTER = 30 * 60           # older than this and we won't report the number as current
REWARN_AFTER = 30 * 60          # --mode prompt: at most one nag per this interval
NET_TIMEOUT = 8
KEYCHAIN_TIMEOUT = 5

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"


def _access_token():
    """OAuth token: plaintext credentials file (Linux) or login keychain (macOS)."""
    creds_path = Path.home() / ".claude" / ".credentials.json"
    if creds_path.exists():
        creds = json.loads(creds_path.read_text())
    elif sys.platform == "darwin":
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=KEYCHAIN_TIMEOUT, check=True,
        ).stdout.strip()
        creds = json.loads(out)
    else:
        raise RuntimeError("no credentials file and not on macOS")
    return creds["claudeAiOauth"]["accessToken"]


def _read_cache():
    """(usageData, age_seconds) or (None, None)."""
    try:
        blob = json.loads(CACHE.read_text())
        updated = datetime.fromisoformat(blob["updatedAt"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - updated).total_seconds()
        return blob["usageData"], age
    except Exception:
        return None, None


def refresh():
    """Top up the cache if stale. Returns (usageData|None, age_seconds|None, error|None).

    Never raises: every failure path falls through to whatever is already cached, because a
    hook that dies on a flaky network is a hook that gets deleted.
    """
    data, age = _read_cache()
    if data is not None and age is not None and age < REFRESH_MAX_AGE:
        return data, age, None

    try:
        req = urllib.request.Request(
            USAGE_URL, headers={"Authorization": f"Bearer {_access_token()}"})
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
            if r.status != 200:
                raise RuntimeError(f"HTTP {r.status}")
            fresh = json.load(r)
    except Exception as e:
        return data, age, f"{type(e).__name__}: {e}"

    def to_unix(iso):
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())

    # The API speaks percent (0-100); the cache stores fractions (0-1). Keep that contract —
    # Claude Code's own /usage reads this same file.
    usage = {
        "utilization5h": fresh["five_hour"]["utilization"] / 100.0,
        "utilization7d": fresh["seven_day"]["utilization"] / 100.0,
        "reset5hAt": to_unix(fresh["five_hour"]["resets_at"]),
        "reset7dAt": to_unix(fresh["seven_day"]["resets_at"]),
        "limitStatus": "allowed",  # not returned by the API; in-app /usage wins if it differs
    }
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(json.dumps({
            "version": 2,
            "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "usageData": usage,
        }, indent=2))
    except Exception:
        pass  # in-memory value is still good for this run
    return usage, 0.0, None


def _local(unix_ts):
    try:
        return datetime.fromtimestamp(int(unix_ts)).strftime("%a %H:%M")
    except Exception:
        return "?"


def _emit(event, context):
    print(json.dumps({
        "hookSpecificOutput": {"hookEventName": event, "additionalContext": context}
    }))


def _should_warn_again(pct):
    """--mode prompt throttle: one nag per REWARN_AFTER, reset when usage drops back under."""
    now = datetime.now(timezone.utc).timestamp()
    try:
        last = json.loads(STATE.read_text()).get("lastWarnAt", 0)
    except Exception:
        last = 0
    if now - last < REWARN_AFTER:
        return False
    try:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps({"lastWarnAt": now, "pct": pct}))
    except Exception:
        pass
    return True


def _warning_block(pct5h, pct7d, usage):
    which = "5h window" if pct5h >= THRESHOLD_PCT else "weekly window"
    reset = _local(usage.get("reset5hAt") if pct5h >= THRESHOLD_PCT else usage.get("reset7dAt"))
    return (
        f"\n⚠️  AT OR OVER {THRESHOLD_PCT:.0f}% on the {which} (resets {reset}).\n"
        "SAY THIS TO THE USER BEFORE STARTING ANY SUBSTANTIAL WORK, and ask which they want:\n"
        "  (a) proceed anyway — fine for a small, self-contained task;\n"
        "  (b) switch to a cheaper model (/model sonnet or haiku) for the rest of the window;\n"
        "  (c) run the `usage-monitor` skill, which writes a resume doc to this project's\n"
        "      memory dir and schedules an auto-resume agent for the reset time.\n"
        "Do not silently start a long task on the assumption the budget will hold."
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["session", "prompt"], default="session")
    ap.add_argument("--report", action="store_true",
                    help="human-readable output, ignore throttle (for running by hand)")
    args = ap.parse_args()

    usage, age, err = refresh()

    if usage is None:
        msg = (f"Claude usage check FAILED ({err or 'no cache'}). Numbers unknown — mention this "
               "once and suggest running /usage in Claude Code, then carry on.")
        if args.report:
            print(msg)
        elif args.mode == "session":
            _emit("SessionStart", msg)   # loud on purpose: see the module docstring
        return 0

    pct5h = usage.get("utilization5h", 0) * 100
    pct7d = usage.get("utilization7d", 0) * 100
    status = usage.get("limitStatus", "?")
    over = pct5h >= THRESHOLD_PCT or pct7d >= THRESHOLD_PCT
    stale = age is None or age > STALE_AFTER

    if args.mode == "prompt" and not args.report:
        # Silent while there is headroom; that silence is what keeps the warning meaningful.
        if not over or not _should_warn_again(max(pct5h, pct7d)):
            return 0
        _emit("UserPromptSubmit", "Claude usage (mid-session check): "
              f"5h {pct5h:.0f}% · weekly {pct7d:.0f}%." + _warning_block(pct5h, pct7d, usage))
        return 0

    lines = [
        "Claude plan usage (Anthropic-side, same numbers as /usage):",
        f"  5h window:  {pct5h:5.1f}%   resets {_local(usage.get('reset5hAt'))}",
        f"  Weekly:     {pct7d:5.1f}%   resets {_local(usage.get('reset7dAt'))}",
    ]
    if status != "allowed":
        lines.append(f"  Status:     {status.upper()}  ← surface this prominently")
    if err:
        lines.append(f"  (refresh failed: {err} — showing cached values)")
    if stale:
        lines.append(f"  (cache is {int((age or 0) / 60)} min old — suggest running /usage)")
    if over:
        lines.append(_warning_block(pct5h, pct7d, usage))
    else:
        lines.append(f"Under the {THRESHOLD_PCT:.0f}% pause point — report these two numbers in "
                     "one line with your first reply, then proceed normally.")

    text = "\n".join(lines)
    if args.report:
        print(text)
    else:
        _emit("SessionStart", text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

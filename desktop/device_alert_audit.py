#!/usr/bin/env python3
"""Audit the health-alert decisions the PHONE actually made, against the phone's own raw data.

*** DEV TOOL. NOTHING HERE SHIPS IN THE APP. ***
Stdlib only, no network. Pulls from a USB-connected iPhone with `xcrun devicectl` and reads the
result on this machine. The app never imports this file.

WHAT THIS IS FOR
----------------
`spo2_alert_autopsy.py` answers "what SHOULD the rule be?" against an export. This answers the
different, later question: **"what did the shipped rule DO last night, and was it right?"**

The gap it closes is that the app is the only witness to its own decisions. `ActivityLogView`
renders `HealthAlertRecord` — the app's own summary of its own verdict — so reading it confirms
nothing that a bug in the evaluator would not also corrupt. This pulls the two independent
sources the app decided FROM and re-derives each verdict from scratch:

  * `Library/Preferences/com.bly.opencircuit.plist` — `obs.healthAlertLog` (the decisions) AND
    `sleep.epochArchive.<ring>` (the raw 23-byte 0x4c records the evidence was read from).
  * `Library/Application Support/default.store` — the SwiftData `ZSTOREDSAMPLE` rows, i.e. the
    SpO2 series the corroboration rule ran over.

A row whose re-derived verdict differs from the logged one is a real finding: either the Swift
evaluator is wrong, or this mirror is. Both are worth knowing before trusting a suppression.

⚠️ THE OUTPUT DIRECTORY DEFAULTS UNDER `captures/` ON PURPOSE. A pulled snapshot contains the
wearer's real health data — the whole SwiftData store. `desktop/captures/` is gitignored (see
CLAUDE.md conventions: commit decoded FINDINGS, never raw captures). Do not move the default.

USAGE
    ./device_alert_audit.py --pull            # phone connected over USB, then audit
    ./device_alert_audit.py                   # re-audit the last snapshot, no phone needed
    ./device_alert_audit.py --dir path/to/snapshot

WHY USB. `devicectl` needs the device `connected`; a phone merely on the same Wi-Fi commonly
shows `unavailable` (no `_remotepairing._tcp` advertisement, `tunnelState: unavailable`) when the
AP isolates clients or the phone is on another VLAN. Plugging in is one step and always works.
"""

import argparse
import json
import plistlib
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# --- Constants MIRRORED from Swift. Each cites the file that owns it; if one of these drifts,
# --- this harness is wrong and will report false mismatches.
SYNC_EPOCH = 1_577_793_600        # Command.syncEpoch (Opcodes.swift)
APPLE_EPOCH = 978_307_200         # Codable/Core Data Date -> unix
RECORD_LEN = 23                   # one 0x4c epoch record (EpochArchive.encode = raw bytes)
MATCH_TOLERANCE = 75              # SpO2EvidenceIndex.matchTolerance
MOTION_STILL_THRESHOLD = 2        # ActivityPeriod.motionStillThreshold (SleepDetection.swift)
INSTANT_LOOKBACK = 12 * 3600      # HealthNotificationCenter.instantLookback
ARCHIVE_RETENTION = 30 * 3600     # EpochArchive.retention

# SpO2AlertPolicy defaults (HealthAlerts.swift)
CORROBORATION_WINDOW = 2700
AGREEMENT_TOLERANCE = 2
MIN_CORROBORATING = 2
MAX_BAD_EPOCH_FRACTION = 0.5
BURST_WINDOW = 60                 # SpO2AlertPolicy.burstWindow
BURST_CONTRADICTION_DELTA = 4     # SpO2AlertPolicy.burstContradictionDelta
DEFAULT_THRESHOLD = 90            # HealthAlertThresholds.lowSpO2Percent

# NOTE what this mirror does NOT cover: D3's first-sighting ledger + `maxNotifiableAge` backstop
# (HealthNotificationCenter's `alerts.lowSpO2.consideredReadings`) are APP-SIDE evaluation-pass
# history, not a function of the reading series alone — re-deriving them here would mean
# replaying every past evaluate() pass, not just the final state. A row this mirror re-derives as
# `fired` that the app actually suppressed as `alreadySeen`/`tooOld` is a MISMATCH this tool
# cannot resolve; that is a known, stated gap, not silent drift — see the `not_before` caveat
# below for the same kind of limitation on the pre-existing freshness bound.

BUNDLE_ID = "com.bly.opencircuit"
DEFAULT_DEVICE = "819D37A3-B45A-56CF-9FEC-40D460EC74F8"   # Jedi Master's iPhone
PULL_FILES = [
    "Library/Preferences/com.bly.opencircuit.plist",
    "Library/Application Support/default.store",
    "Library/Application Support/default.store-shm",
    "Library/Application Support/default.store-wal",
]


def fmt(unix):
    if unix is None:
        return "-"
    return datetime.fromtimestamp(unix, timezone.utc).astimezone().strftime("%b %d %H:%M:%S")


# --------------------------------------------------------------------------- pull

def pull(device, outdir):
    """Copy the app-container files this audit needs off a connected phone."""
    outdir.mkdir(parents=True, exist_ok=True)
    for src in PULL_FILES:
        dest = outdir / Path(src).name
        cmd = ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
               "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
               "--user", "mobile", "--source", src, "--destination", str(dest)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            # -wal/-shm legitimately may not exist if SQLite checkpointed and cleaned up.
            print(f"  ! {src}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'failed'}")
        else:
            print(f"  ✓ {dest.name} ({dest.stat().st_size:,} B)")


# --------------------------------------------------------------------------- 0x4c decode
#
# A faithful mirror of BulkRecord (BulkSleep.swift). Kept deliberately small: only the fields
# SpO2Evidence reads, so there is less to drift.

class Record:
    __slots__ = ("raw", "counter", "layout")

    def __init__(self, raw):
        self.raw = raw
        self.counter = int.from_bytes(raw[0:4], "big")     # BIG-endian [0:4]
        self.layout = self._layout()

    def _layout(self):
        r = self.raw
        if (r[4] == 0x05 and r[5] == 0 and r[6] == 0x0C and r[7] == 0 and r[9] == 0x0A
                and list(r[10:15]) == [1] * 5 and list(r[15:22]) == [0] * 7):
            return "idle"
        if r[8] in (0x12, 0x13, 0x11):
            return "activity"
        return "sleepVitals"

    @property
    def time(self):
        return self.counter + SYNC_EPOCH

    @property
    def spo2(self):
        if self.layout != "sleepVitals":
            return None
        v = self.raw[8]
        return v if 70 <= v <= 100 else None

    @property
    def motion(self):
        return list(self.raw[10:15])

    @property
    def resolves_stillness(self):
        if self.layout == "idle":
            return False
        m = self.motion
        return (max(m) - min(m)) <= MOTION_STILL_THRESHOLD

    @property
    def magnitudes(self):
        """Five 12-bit big-endian nibble-packed magnitudes over [15:23)."""
        def nib(i):
            b = self.raw[15 + i // 2]
            return (b >> 4) if i % 2 == 0 else (b & 0x0F)
        return [(nib(k * 3) << 8) | (nib(k * 3 + 1) << 4) | nib(k * 3 + 2) for k in range(5)]

    @property
    def confidence(self):
        return None if self.layout == "idle" else self.raw[6]

    def evidence(self):
        """SpO2Evidence, or None when this epoch carried no SpO2 (the index-gating rule)."""
        if self.spo2 is None:
            return None
        m = self.motion
        return {
            "unworn": self.layout == "idle",
            "still": self.resolves_stillness,
            "spread": max(m) - min(m),
            "mags_zero": all(v == 0 for v in self.magnitudes),
            "conf": self.confidence,
        }


def evidence_summary(e):
    """Mirrors SpO2Evidence.summary so the string can be compared to the logged one."""
    parts = ["unworn" if e["unworn"] else "worn", "still" if e["still"] else "MOVING",
             f"spread={e['spread']}", "mags=0" if e["mags_zero"] else "mags>0"]
    if e["conf"] is not None:
        parts.append(f"conf={e['conf']}")
    return " ".join(parts)


def is_bad_epoch(e):
    return e["unworn"] or not e["still"]


def load_archives(prefs):
    """{ring namespace: [Record]} from every persisted epoch archive."""
    out = {}
    for key in sorted(k for k in prefs if k.startswith("sleep.epochArchive")):
        data = bytes(prefs[key])
        ns = key[len("sleep.epochArchive"):].lstrip(".") or "(legacy)"
        n, rem = divmod(len(data), RECORD_LEN)
        if rem:
            print(f"!! {ns}: {len(data)} B is not a whole number of {RECORD_LEN}-byte records "
                  f"(remainder {rem}) — decode below is untrustworthy")
        out[ns] = [Record(data[i * RECORD_LEN:(i + 1) * RECORD_LEN]) for i in range(n)]
    return out


def build_index(archives):
    """epoch-second -> evidence, active-ring-first, mirroring spo2EvidenceIndex's union rule."""
    index = {}
    for records in archives.values():
        for r in records:
            e = r.evidence()
            if e is not None and r.time not in index:
                index[r.time] = e
    return index


def lookup(index, t, tolerance=MATCH_TOLERANCE):
    key = int(round(t))
    if key in index:
        return index[key]
    for d in range(1, tolerance + 1):
        if key - d in index:
            return index[key - d]
        if key + d in index:
            return index[key + d]
    return None


# --------------------------------------------------------------------------- rule mirror

def is_contradicted(reading, others):
    """Mirror of SpO2AlertPolicy.isContradicted. SIGNED: only a HIGHER reading seconds away
    contradicts — a nearby lower reading is a deepening desaturation, not an artifact."""
    t, pct = reading
    return any(t2 != t and abs(t2 - t) <= BURST_WINDOW and (p2 - pct) >= BURST_CONTRADICTION_DELTA
               for t2, p2 in others)


def evaluate_one(trigger, readings, threshold, index, contradicted):
    """Mirror of HealthAlertEvaluator.evaluateOne. Returns (outcome, run, resolved, bad)."""
    t_time, t_pct = trigger
    neighbours = [r for r in readings
                  if r[0] != t_time and abs(r[0] - t_time) <= CORROBORATION_WINDOW]
    # A burst artifact cannot corroborate — same reasoning as the trigger exclusion below.
    corroborators = [r for r in neighbours
                     if r[0] not in contradicted
                     and r[1] <= threshold and abs(r[1] - t_pct) <= AGREEMENT_TOLERANCE]
    run = [trigger] + corroborators
    if len(run) < MIN_CORROBORATING:
        # Discriminator reads the ARTIFACT-FILTERED low neighbours — a run whose only low
        # neighbour was itself a rejected burst artifact has nothing LEGITIMATE nearby.
        low = [r for r in neighbours if r[0] not in contradicted and r[1] <= threshold]
        return ("noCorroboration" if not low else "corroborationDisagrees"), len(run), 0, 0
    resolved = [e for e in (lookup(index, r[0]) for r in run) if e is not None]
    if not resolved:
        return "fired", len(run), 0, 0            # fail open — corroboration carries it
    bad = sum(1 for e in resolved if is_bad_epoch(e))
    if bad > len(resolved) * MAX_BAD_EPOCH_FRACTION:
        return "badEpochMajority", len(run), len(resolved), bad
    return "fired", len(run), len(resolved), bad


def low_spo2(readings, threshold, not_before, index):
    """Mirror of HealthAlertEvaluator.lowSpO2 — every candidate, worst first."""
    # Computed once over the full series, same as the Swift `contradicted` pre-pass.
    contradicted = {t for t, p in readings if is_contradicted((t, p), readings)}

    all_candidates = [r for r in readings if 0 < r[1] <= threshold and r[0] > not_before]
    if not all_candidates:
        return ("noCandidate", None, 0, 0, 0)

    candidates = [r for r in all_candidates if r[0] not in contradicted]
    if not candidates:
        worst = sorted(all_candidates, key=lambda r: (r[1], r[0]))[0]
        return ("burstArtifact", worst, 0, 0, 0)

    worst = None
    for trig in sorted(candidates, key=lambda r: (r[1], r[0])):
        outcome, run, resolved, bad = evaluate_one(trig, readings, threshold, index, contradicted)
        if outcome == "fired":
            return (outcome, trig, run, resolved, bad)
        if worst is None:
            worst = (outcome, trig, run, resolved, bad)
    return worst


# --------------------------------------------------------------------------- audit

def spo2_series(store_path):
    con = sqlite3.connect(f"file:{store_path}?mode=ro", uri=True)
    try:
        rows = con.execute(
            "SELECT ZSTART + ?, ZVALUE FROM ZSTOREDSAMPLE WHERE ZKINDRAW='spo2' ORDER BY ZSTART",
            (APPLE_EPOCH,)).fetchall()
    finally:
        con.close()
    # Stored as a 0…1 fraction; the rule works in whole percent (HealthNotificationCenter).
    return [(float(t), int(round(v * 100))) for t, v in rows if v]


def audit(snapshot, threshold, not_before_override=None):
    prefs_path = snapshot / "com.bly.opencircuit.plist"
    store_path = snapshot / "default.store"
    if not prefs_path.exists():
        sys.exit(f"no snapshot at {snapshot} — run with --pull and the phone connected")
    prefs = plistlib.load(prefs_path.open("rb"))

    archives = load_archives(prefs)
    index = build_index(archives)
    all_times = [r.time for records in archives.values() for r in records]
    archive_span = (min(all_times), max(all_times)) if all_times else None

    print("=== epoch archives ===")
    for ns, records in archives.items():
        if not records:
            print(f"{ns}: empty")
            continue
        span = records[-1].time - records[0].time
        with_spo2 = sum(1 for r in records if r.spo2 is not None)
        flag = "" if span <= ARCHIVE_RETENTION + 60 else "  !! EXCEEDS 30 h RETENTION"
        print(f"{ns}: {len(records)} records, {fmt(records[0].time)} -> {fmt(records[-1].time)} "
              f"({span / 3600:.1f} h), {with_spo2} carry SpO2{flag}")
    # The invariant the whole evidence design rests on (SpO2Evidence.swift): retention must
    # strictly cover the alert lookback, or a reading the alert can see has no raw record.
    print(f"retention {ARCHIVE_RETENTION / 3600:.0f} h vs alert lookback "
          f"{INSTANT_LOOKBACK / 3600:.0f} h — {'OK' if ARCHIVE_RETENTION > INSTANT_LOOKBACK else 'BROKEN'}")

    readings = spo2_series(store_path) if store_path.exists() else []
    print(f"\n=== stored SpO2 samples: {len(readings)} ===")
    if readings:
        print(f"span {fmt(readings[0][0])} -> {fmt(readings[-1][0])}")
        # ⚠️ SCOPE THE MISS RATE TO THE ARCHIVE'S OWN SPAN. The store keeps samples far longer
        # than the archive keeps records, so counting the whole series measures RETENTION, not
        # resolvability, and reports an alarming miss rate for a system working exactly as
        # designed. Only samples the alert could actually see (<= 12 h old, comfortably inside
        # the 30 h archive) are in scope; the residual miss is the genuinely unresolvable
        # population — live on-demand readings, which come from the 0x15 frame and have no 0x4c
        # record BY CONSTRUCTION. That residual is what justifies the rule's fail-open policy,
        # so it is the number worth watching drift.
        span = [(t, p) for t, p in readings
                if archive_span and archive_span[0] <= t <= archive_span[1]]
        if span:
            hit = sum(1 for t, _ in span if lookup(index, t) is not None)
            print(f"resolve to a raw record: {hit}/{len(span)} of the samples inside the archive's "
                  f"own span ({100 * (1 - hit / len(span)):.1f}% miss — live on-demand readings)")
        print(f"({len(readings) - len(span)} older samples are outside the 30 h archive and "
              f"cannot resolve; they are also outside the 12 h alert lookback)")

    blob = prefs.get("obs.healthAlertLog")
    if blob is None:
        print("\n!! no obs.healthAlertLog — no decision has ever been recorded")
        return
    rows = json.loads(bytes(blob))

    # ⚠️ THE FRESHNESS BOUND IS PART OF THE RULE AND MUST BE APPLIED, or this harness reports
    # false mismatches. `lowSpO2` only considers candidates with `time > notBefore`, where
    # `notBefore` is the caller's `lastFired[.lowSpO2]` — so a stale low reading that already
    # alerted days ago is not re-tried. Omitting it lets an older reading TIE on percent and win
    # the worst-first tie-break (which is `(percent, time)`), re-deriving a different trigger for
    # the same outcome. Stored as unix seconds by `markFired`, NOT as a Codable Date.
    #
    # LIMITATION, stated rather than hidden: only the CURRENT watermark survives — it is
    # overwritten in place, which is the very gap the decision log was added to close. For a row
    # decided BEFORE the last firing, this bound is too new and the re-derivation may legitimately
    # diverge. That is safe today (a suppression never advances the watermark, so it is exact for
    # every row after the newest FIRED one) but it is why a mismatch is a prompt to look, not a
    # verdict on its own.
    not_before = (prefs.get("alerts.health.lastFired") or {}).get("lowSpO2", 0)
    print(f"\n=== health-alert decisions ({len(rows)}) ===")
    if not_before_override is not None:
        # `--not-before` REPLAYS history against a watermark the device has since advanced past.
        # This exists because the naive check does not discriminate anything: once `lastFired`
        # sits at the newest FIRED row's own timestamp, EVERY historical row re-derives as
        # `noCandidate` (its trigger is older than `notBefore` by construction) regardless of
        # whether a rule change fixed anything — that artifact IS the standing
        # `re-derivation mismatches` count on an unmodified snapshot. Pin `not_before` to a point
        # BEFORE the incident under investigation (e.g. the watermark from before it fired) to get
        # a re-derivation that actually exercises the rule instead of vacuously agreeing.
        not_before = not_before_override
        print(f"lowSpO2 freshness bound: OVERRIDDEN to {fmt(not_before)} (--not-before)")
    else:
        print(f"lowSpO2 freshness bound (last actual firing): {fmt(not_before) if not_before else 'never'}")

    mismatches = 0
    quality_gate_exercised = 0
    for r in rows:
        decided = r["date"] + APPLE_EPOCH
        reading_t = r["readingTime"] + APPLE_EPOCH if r.get("readingTime") is not None else None
        state = "FIRED     " if r.get("fired") else "suppressed"
        print(f"\n[{fmt(decided)}] {r.get('notification')} {state} reason={r.get('reason')} "
              f"value={r.get('value'):g} reading={fmt(reading_t)} run={r.get('runSize')} "
              f"evidence={r.get('badEpochs')}/{r.get('evidenceEpochs')} bad")
        if r.get("evidenceSummary"):
            print(f"    logged evidence: {r['evidenceSummary']}")
        if r.get("evidenceEpochs"):
            quality_gate_exercised += 1

        if r.get("notification") != "lowSpO2" or reading_t is None:
            continue

        # Re-derive: the same 12 h lookback the app evaluated over, ending at the decision.
        window = [x for x in readings if decided - INSTANT_LOOKBACK <= x[0] <= decided]
        outcome, trig, run, resolved, bad = low_spo2(window, threshold, not_before, index)
        ok = outcome == r.get("reason") and (trig is None or abs(trig[0] - reading_t) < 1.5)
        print(f"    re-derived:      {outcome} on {fmt(trig[0] if trig else None)} "
              f"{trig[1] if trig else '-'}% run={run} evidence={bad}/{resolved} bad  "
              f"{'✓ agrees' if ok else '✗ MISMATCH'}")
        if not ok:
            mismatches += 1

        # Show the neighbourhood — this is what makes a suppression judgeable by eye.
        near = [x for x in window if abs(x[0] - reading_t) <= CORROBORATION_WINDOW]
        print("    neighbourhood ±%d min: %s" % (
            CORROBORATION_WINDOW // 60,
            " ".join(f"{'>>' if abs(t - reading_t) < 1.5 else ''}{p}" for t, p in near)))
        ev = lookup(index, reading_t)
        print(f"    archive evidence: {evidence_summary(ev) if ev else 'NONE (no 0x4c record)'}")

        if outcome == "burstArtifact":
            # Name the contradicting neighbour — same reason `neighbourhood` exists: a burst
            # rejection is only judgeable by eye if the reading that refuted it is visible too.
            burst = [x for x in window
                     if x[0] != reading_t and abs(x[0] - reading_t) <= BURST_WINDOW
                     and (x[1] - r.get("value", 0)) >= BURST_CONTRADICTION_DELTA]
            if burst:
                t2, p2 = min(burst, key=lambda x: abs(x[0] - reading_t))
                print(f"    contradicted by: {p2}% at {fmt(t2)} "
                      f"({abs(t2 - reading_t):.0f}s away, in the same on-demand burst)")

    print(f"\n=== summary ===")
    print(f"decisions: {len(rows)}, fired: {sum(1 for r in rows if r.get('fired'))}, "
          f"suppressed: {sum(1 for r in rows if not r.get('fired'))}")
    print(f"re-derivation mismatches: {mismatches}")
    # The open item from the #73 commit: corroboration short-circuits BEFORE the epoch-quality
    # fraction is computed, so a log full of `noCorroboration` rows leaves that half untested.
    print(f"rows that exercised the epoch-quality fraction (evidenceEpochs > 0): "
          f"{quality_gate_exercised}"
          + ("  <- the fraction rule is still UNTESTED on real data" if not quality_gate_exercised else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pull", action="store_true", help="copy fresh files off the connected phone")
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--dir", type=Path,
                    default=Path(__file__).parent / "captures" / "device-snapshot",
                    help="snapshot directory (default under captures/, which is gitignored)")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    ap.add_argument("--not-before", type=str, default=None,
                    help="ISO8601 local time (e.g. 2026-08-13T15:32:25) to REPLAY history "
                         "against instead of the device's current lastFired watermark — needed "
                         "because the current watermark makes every historical row vacuously "
                         "re-derive as noCandidate. See the doc comment in audit().")
    args = ap.parse_args()

    if args.pull:
        print(f"pulling from {args.device} -> {args.dir}")
        pull(args.device, args.dir)
        print()
    not_before_override = (datetime.fromisoformat(args.not_before).timestamp()
                           if args.not_before else None)
    audit(args.dir, args.threshold, not_before_override=not_before_override)


if __name__ == "__main__":
    main()

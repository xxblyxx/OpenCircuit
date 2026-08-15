#!/usr/bin/env python3
"""Read the reference sleep labels (Whoop / Apple Watch intervals) OpenCircuit cached from
HealthKit, and test whether the ring's own signal co-locates with them.

*** DEV TOOL. NOTHING HERE SHIPS IN THE APP. *** Stdlib only, no network.

WHY THIS EXISTS
----------------
`docs/SLEEP_AWAKE_RESOLUTION.md` established that our hypnogram cannot represent a brief mid-night
awakening, and that the ring's `[10:15]` primary motion channel sits at baseline through the whole
core of the night. What it could NOT establish, from two hand-checked events, is whether the
`[15:20]` intensity tail actually encodes arousals -- `PROTOCOL.md` marks the physical meaning of
those magnitudes as UNESTABLISHED, and ~30 % of sleep epochs carry a non-zero tail anyway, so two
hits could easily be chance.

Reference labels turn that into a decidable question. With N labelled awake intervals from an
INDEPENDENT sensor on the same night, we can ask: do the ring's non-zero tail epochs land on
labelled-awake times more often than the base rate predicts? That is a real test with a real null,
and it is the thing worth knowing BEFORE touching a single threshold.

WHAT IT READS
--------------
`sleep.externalSamples` out of the app's own prefs plist -- written by Device Info -> Diagnostics ->
"Import reference sleep labels", and pulled over USB by the same `--pull` mechanism the other
desktop tools use. Format is `ExternalSleepCodec`'s: [[source, startUnix, endUnix, stageCode], ...]
with 0=inBed 1=awake 2=core 3=deep 4=REM.

⚠️ REFERENCE, NOT GROUND TRUTH. These are another consumer wearable's ESTIMATE (see
`ExternalSleepSample`'s header: independent PSG work puts wrist-actigraphy wake sensitivity at
16-30 %). Agreement here is evidence the ring recorded something real at those times; DISagreement
is not proof either side is wrong. Never fit thresholds to reproduce these labels without saying
plainly that is what happened.

USAGE
    ./sleep_reference_labels.py --pull        # pull fresh, then report
    ./sleep_reference_labels.py               # re-read the last snapshot
    ./sleep_reference_labels.py --correlate   # run the tail-vs-awake co-location test
    ./sleep_reference_labels.py --export-groundtruth out.json   # for ringconn_sleep_fit.py
"""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from sleep_awake_trace import (  # noqa: E402
    load_archives, find_qualifying_nights, scope_to_night, fmt, PLIST_NAME,
    BUNDLE_ID, DEFAULT_DEVICE,
)

SAMPLES_KEY = "sleep.externalSamples"
IMPORTED_AT_KEY = "sleep.externalSamplesImportedAt"
WINDOW_KEY = "sleep.externalSamplesWindowDays"

# ExternalSleepCodec's stage codes (pinned by ExternalSleepSampleTests.testStageCodesMatchHypnogramCodec)
STAGE_FOR_CODE = {0: "inBed", 1: "awake", 2: "light", 3: "deep", 4: "rem"}
# The RingConn `sleepPhases` vocabulary ringconn_sleep_fit.py's --groundtruth expects.
SLEEPTYPE_FOR_STAGE = {
    "inBed": "SLEEP_AWAKE_IN_BED", "awake": "SLEEP_AWAKE",
    "light": "SLEEP_LIGHT", "deep": "SLEEP_DEEP", "rem": "SLEEP_REM",
}


def pull(device, outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    src = f"Library/Preferences/{PLIST_NAME}"
    dest = outdir / PLIST_NAME
    cmd = ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
           "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
           "--user", "mobile", "--source", src, "--destination", str(dest)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ! {src}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'failed'}")
    else:
        print(f"  ✓ {dest.name} ({dest.stat().st_size:,} B)")


def load_labels(prefs):
    """[(source, start_unix, end_unix, stage)] from the cached ExternalSleepCodec blob."""
    raw = prefs.get(SAMPLES_KEY)
    if raw is None:
        return None      # never imported -- distinct from "imported, found none"
    try:
        rows = json.loads(bytes(raw).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        print("!! sleep.externalSamples is present but not readable JSON", file=sys.stderr)
        return []
    out = []
    for row in rows:
        if not (isinstance(row, list) and len(row) == 4):
            continue
        source, start, end, code = row
        stage = STAGE_FOR_CODE.get(code)
        if stage is None or not isinstance(start, int) or not isinstance(end, int) or end <= start:
            continue
        out.append((source, start, end, stage))
    return out


def report(labels, prefs, tz):
    imported_at = prefs.get(IMPORTED_AT_KEY)
    window_days = prefs.get(WINDOW_KEY)
    if imported_at:
        print(f"last import: {fmt(imported_at, tz)}"
              + (f"  (lookback {window_days} days)" if window_days else ""))
    if labels is None:
        print("\n!! no reference labels cached yet.\n"
              "   On the phone: Device Info -> Diagnostics -> 'Import reference sleep labels',\n"
              "   then re-run this with --pull.")
        return
    if not labels:
        print("\nreference labels: cached, but EMPTY.\n"
              "   HealthKit does not report read authorization, so this is ambiguous between\n"
              "   'Sleep read access is off for OpenCircuit' and 'no other app writes sleep'.\n"
              "   Check Health -> Sharing -> Apps -> OpenCircuit -> Sleep (allow reading).")
        return

    by_source = Counter(s for s, _, _, _ in labels)
    by_stage = Counter(st for _, _, _, st in labels)
    print(f"\nreference labels: {len(labels)} intervals")
    print(f"  sources: {dict(by_source)}")
    print(f"  stages:  {dict(by_stage)}")
    span_lo = min(s for _, s, _, _ in labels)
    span_hi = max(e for _, _, e, _ in labels)
    print(f"  span:    {fmt(span_lo, tz)} .. {fmt(span_hi, tz)}")


def list_awake(labels, tz, night=None):
    awake = [l for l in labels if l[3] == "awake"]
    if night:
        lo, hi = night
        awake = [l for l in awake if l[1] < hi and l[2] > lo]
    awake.sort(key=lambda l: l[1])
    print(f"\nawake intervals{' in the traced night' if night else ''}: {len(awake)}")
    print(f"{'#':>3}  {'source':<14}{'start':<18}{'end':<18}{'min':>6}")
    print("-" * 62)
    for i, (source, start, end, _) in enumerate(awake, 1):
        print(f"{i:>3}  {source:<14}{fmt(start, tz):<18}{fmt(end, tz):<18}{(end-start)/60:>6.1f}")
    return awake


def correlate(labels, records, night, tz):
    """Do the ring's non-zero [15:20] tail epochs co-locate with labelled-awake times?

    The test: classify every epoch of the traced night by (a) does its intensity tail carry a
    non-zero sum, (b) does a labelled AWAKE interval overlap it. Then compare the hit rate inside
    labelled-awake epochs against the base rate over the rest of the night. A 2x2 table, reported
    with both marginals, so the reader can see the null rather than being handed a verdict.
    """
    lo, hi = night
    epochs = [r for r in records if lo <= r.time <= hi]
    if not epochs:
        print("no epochs inside the traced night -- nothing to correlate")
        return
    awake = [l for l in labels if l[3] == "awake" and l[1] < hi and l[2] > lo]
    if not awake:
        print("\nno labelled AWAKE intervals overlap the traced night -- cannot correlate.\n"
              "  (The labels may cover a different night than the ring archive retained.)")
        return

    EPOCH = 150
    a_nz = a_z = n_nz = n_z = 0
    for r in epochs:
        tail = sum(r.intensity_tail)
        # An epoch counts as labelled-awake if any awake interval overlaps its [t, t+150) span.
        labelled = any(s < r.time + EPOCH and e > r.time for _, s, e, _ in awake)
        if labelled:
            if tail > 0: a_nz += 1
            else: a_z += 1
        else:
            if tail > 0: n_nz += 1
            else: n_z += 1

    a_tot, n_tot = a_nz + a_z, n_nz + n_z
    print(f"\n--- co-location test: non-zero [15:20] tail vs labelled AWAKE ---")
    print(f"night {fmt(lo, tz)} .. {fmt(hi, tz)}  ({len(epochs)} epochs, {len(awake)} awake intervals)\n")
    print(f"{'':<22}{'tail>0':>9}{'tail=0':>9}{'total':>8}{'rate':>9}")
    print("-" * 57)
    print(f"{'labelled AWAKE':<22}{a_nz:>9}{a_z:>9}{a_tot:>8}"
          f"{(100*a_nz/a_tot if a_tot else 0):>8.1f}%")
    print(f"{'not labelled awake':<22}{n_nz:>9}{n_z:>9}{n_tot:>8}"
          f"{(100*n_nz/n_tot if n_tot else 0):>8.1f}%")
    print("-" * 57)
    tot_nz = a_nz + n_nz
    print(f"{'overall':<22}{tot_nz:>9}{a_z+n_z:>9}{len(epochs):>8}"
          f"{100*tot_nz/len(epochs):>8.1f}%")

    if a_tot and n_tot:
        ra, rn = a_nz/a_tot, n_nz/n_tot
        print(f"\nlift: {ra/rn:.2f}x" if rn > 0 else "\nlift: n/a (no non-zero tail outside awake)")
        print("  >1 means the ring's tail signal is enriched inside labelled awake time.")
        print("  This is a DESCRIPTIVE ratio on one night, not a significance test -- with "
              f"{a_tot} awake epochs\n  the sample is small; treat it as a direction to check, "
              "not a result to act on.")


def export_groundtruth(labels, path, source=None):
    """Emit the labels as a RingConn-style `sleepPhases` JSON so ringconn_sleep_fit.py's
    existing --groundtruth loader can consume them unmodified."""
    rows = [l for l in labels if source is None or l[0] == source]
    if not rows:
        print(f"!! no labels{' from ' + source if source else ''} to export", file=sys.stderr)
        return
    phases = [{"start": s, "end": e, "sleepType": SLEEPTYPE_FOR_STAGE[st]}
              for _, s, e, st in sorted(rows, key=lambda l: l[1])]
    Path(path).write_text(json.dumps({"data": {"sleepPhases": phases}}, indent=2))
    srcs = sorted({l[0] for l in rows})
    print(f"wrote {len(phases)} phases from {srcs} -> {path}")
    print(f"  use: python3 ringconn_sleep_fit.py --features <csv> --groundtruth {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pull", action="store_true", help="copy the prefs plist off the phone first")
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--dir", type=Path,
                    default=Path(__file__).parent / "captures" / "device-snapshot")
    ap.add_argument("--list-awake", action="store_true", help="list every awake interval")
    ap.add_argument("--correlate", action="store_true",
                    help="test tail-vs-awake co-location over the traced night")
    ap.add_argument("--export-groundtruth", metavar="PATH",
                    help="write a RingConn-style sleepPhases JSON for ringconn_sleep_fit.py")
    ap.add_argument("--source", help="restrict to one source name (e.g. WHOOP)")
    args = ap.parse_args()

    if args.pull:
        print(f"pulling from {args.device} -> {args.dir}")
        pull(args.device, args.dir)

    plist_path = args.dir / PLIST_NAME
    if not plist_path.exists():
        print(f"!! {plist_path} not found -- run with --pull (phone on USB)", file=sys.stderr)
        raise SystemExit(1)
    with open(plist_path, "rb") as f:
        prefs = plistlib.load(f)

    tz = datetime.now().astimezone().tzinfo
    labels = load_labels(prefs)
    report(labels, prefs, tz)
    if not labels:
        return

    if args.source:
        labels = [l for l in labels if l[0] == args.source]
        print(f"\nfiltered to source {args.source!r}: {len(labels)} intervals")

    # The traced night, for the interval list + correlation.
    archives = load_archives(prefs)
    night = records = None
    if archives:
        recs = sorted(next(iter(archives.values())), key=lambda r: r.counter)
        nights = find_qualifying_nights(recs)
        if nights:
            night = nights[0]
            records = scope_to_night(recs, night)

    if args.list_awake:
        list_awake(labels, tz, night)
    if args.correlate:
        if night is None:
            print("\n!! no qualifying sleep period in the epoch archive -- cannot correlate")
        else:
            correlate(labels, records, night, tz)
    if args.export_groundtruth:
        export_groundtruth(labels, args.export_groundtruth, args.source)


if __name__ == "__main__":
    main()

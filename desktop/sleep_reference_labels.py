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
import sqlite3
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

STORE_NAME = "default.store"
STORE_FILES = [STORE_NAME, f"{STORE_NAME}-shm", f"{STORE_NAME}-wal"]
APPLE_EPOCH = 978_307_200   # Codable/Core Data Date -> unix (matches device_alert_audit.py)

# Mirrors SleepAwakenings.mergeTolerance (ios/OpenCircuitKit/.../Analytics/SleepAwakenings.swift) --
# two interior awake runs touching within this many seconds are ONE awakening. Keep in sync; there
# is no shared source of truth between Swift and this file for this one constant.
MERGE_TOLERANCE_SECONDS = 150

# ExternalSleepCodec's stage codes (pinned by ExternalSleepSampleTests.testStageCodesMatchHypnogramCodec)
STAGE_FOR_CODE = {0: "inBed", 1: "awake", 2: "light", 3: "deep", 4: "rem"}
# The RingConn `sleepPhases` vocabulary ringconn_sleep_fit.py's --groundtruth expects.
SLEEPTYPE_FOR_STAGE = {
    "inBed": "SLEEP_AWAKE_IN_BED", "awake": "SLEEP_AWAKE",
    "light": "SLEEP_LIGHT", "deep": "SLEEP_DEEP", "rem": "SLEEP_REM",
}


def pull(device, outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    # The prefs plist (reference labels) AND the SwiftData store (our own stored hypnograms,
    # ZSTOREDSLEEPSUMMARY.ZHYPNOGRAMDATA) -- --compare-own needs both. -shm/-wal may legitimately
    # be absent if SQLite has checkpointed, same as device_alert_audit.py's PULL_FILES.
    #
    # ⚠️ COPY TO A TEMP PATH, THEN SWAP. `devicectl device copy` can fail PARTWAY (🟢 measured: a
    # "socket was closed unexpectedly" mid-transfer left a 0-byte `default.store` on disk), and
    # writing directly to `dest` means a failed retry silently destroys a previously-good snapshot
    # -- replacing real data with a file `sqlite3.connect` will open (empty file = valid empty DB)
    # but that fails downstream with a confusing "no such table" instead of a clear "pull failed".
    # A successful copy is moved into place; a failed one leaves whatever was already at `dest`
    # untouched, so `--compare-own` on stale-but-real data beats it on none at all.
    for name in [PLIST_NAME] + STORE_FILES:
        src = f"Library/{'Preferences' if name == PLIST_NAME else 'Application Support'}/{name}"
        dest = outdir / name
        tmp = outdir / f"{name}.pulling"
        cmd = ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
               "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
               "--user", "mobile", "--source", src, "--destination", str(tmp)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
            reason = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "failed"
            stale = " (keeping the previous snapshot, if any)" if dest.exists() else ""
            print(f"  ! {src}: {reason}{stale}")
            tmp.unlink(missing_ok=True)
        else:
            tmp.replace(dest)
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


# --------------------------------------------------------------------------- --compare-own
#
# Reproduces docs/SLEEP_AWAKE_RESOLUTION.md §4.1's table automatically instead of by hand: for
# each night we ourselves staged (from the SwiftData store's ZSTOREDSLEEPSUMMARY), compute the
# same interior/edge awake split `SleepAwakenings.from` computes in Swift, and print it beside
# each reference source's awake total for the same in-bed window. See
# docs/SLEEP_AWAKENING_METRICS.md for the metric this ports.

def load_own_nights(store_path):
    """[(inBedStart_unix, inBedEnd_unix, [(start_unix, end_unix, stage), ...]), ...] from our own
    stored hypnograms, oldest first. `stage` uses the same strings as `STAGE_FOR_CODE`."""
    con = sqlite3.connect(f"file:{store_path}?mode=ro", uri=True)
    try:
        rows = con.execute(
            "SELECT ZINBEDSTART, ZINBEDEND, ZHYPNOGRAMDATA FROM ZSTOREDSLEEPSUMMARY "
            "ORDER BY ZNIGHT"
        ).fetchall()
    except sqlite3.OperationalError as e:
        # A previously-failed `--pull` (or a store from before the app ever staged a night) can
        # leave a file sqlite3 opens fine but that lacks the table -- report it plainly rather
        # than a raw traceback (same "never trap, report clearly" stance PENDING_VALIDATION's own
        # tooling takes).
        print(f"!! {store_path} did not open as expected ({e}) -- re-run with --pull", file=sys.stderr)
        return []
    finally:
        con.close()
    out = []
    for in_bed_start, in_bed_end, hyp in rows:
        if in_bed_start is None or in_bed_end is None:
            continue
        segments = []
        if hyp:
            try:
                triples = json.loads(bytes(hyp).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                triples = []
            for t in triples:
                if not (isinstance(t, list) and len(t) == 3):
                    continue
                start, end, code = t
                stage = STAGE_FOR_CODE.get(code)
                if stage is None or end <= start:
                    continue
                segments.append((start, end, stage))
        out.append((in_bed_start + APPLE_EPOCH, in_bed_end + APPLE_EPOCH, segments))
    return out


def compute_awakenings(segments):
    """Port of `SleepAwakenings.from` (SLEEP_AWAKENING_METRICS.md §5.1): given a night's staged
    (start_unix, end_unix, stage) triples INCLUDING inBed, return
    {count, waso, longest, edge_awake} in seconds. Mirrors the Swift algorithm step for step --
    filter inBed, find onset/finalWake from asleep segments, clip awake to that window, merge runs
    touching within `MERGE_TOLERANCE_SECONDS`."""
    staged = [(s, e, st) for s, e, st in segments if st != "inBed"]
    asleep_stages = {"light", "deep", "rem"}
    asleep = [(s, e) for s, e, st in staged if st in asleep_stages]
    if not asleep:
        return {"count": 0, "waso": 0, "longest": 0, "edge_awake": 0}
    onset = min(s for s, e in asleep)
    final_wake = max(e for s, e in asleep)

    awake = [(s, e) for s, e, st in staged if st == "awake"]
    total_awake = sum(e - s for s, e in awake)

    interior = []
    for s, e in awake:
        cs, ce = max(s, onset), min(e, final_wake)
        if ce > cs:
            interior.append((cs, ce))
    interior.sort()

    merged = []
    for s, e in interior:
        if merged and s <= merged[-1][1] + MERGE_TOLERANCE_SECONDS:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))

    waso = sum(e - s for s, e in merged)
    longest = max((e - s for s, e in merged), default=0)
    return {"count": len(merged), "waso": waso, "longest": longest,
            "edge_awake": total_awake - waso}


def compare_own(labels, store_path, tz):
    """Print SLEEP_AWAKE_RESOLUTION §4.1's table: our own interior/edge awake split per night,
    beside each reference source's awake total for the same in-bed window."""
    if not store_path.exists():
        print(f"\n!! {store_path} not found -- pass --pull with the phone connected over USB")
        return
    nights = load_own_nights(store_path)
    if not nights:
        print("\nno stored nights (ZSTOREDSLEEPSUMMARY is empty)")
        return

    sources = sorted({src for src, s, e, st in labels})
    print(f"\n--- our own interior/edge awake split, per stored night (SLEEP_AWAKE_RESOLUTION §4.1) ---")
    header = f"{'night (in-bed window)':<32}{'OC awake':>10}{'OC interior':>13}{'OC edge':>9}"
    for src in sources:
        header += f"{src + ' awake':>16}"
    print(header)
    print("-" * len(header))

    for in_bed_start, in_bed_end, segments in nights:
        result = compute_awakenings(segments)
        oc_total_min = (result["waso"] + result["edge_awake"]) / 60
        oc_interior_min = result["waso"] / 60
        oc_edge_min = result["edge_awake"] / 60
        row = (f"{fmt(in_bed_start, tz) + ' .. ' + fmt(in_bed_end, tz):<32}"
               f"{oc_total_min:>9.1f}m{oc_interior_min:>12.1f}m{oc_edge_min:>8.1f}m")
        for src in sources:
            overlap_min = sum(max(0, min(e, in_bed_end) - max(s, in_bed_start))
                              for s2, s, e, st in labels
                              if s2 == src and st == "awake" and s < in_bed_end and e > in_bed_start) / 60
            row += f"{overlap_min:>15.1f}m"
        print(row)
        if result["count"] == 0 and oc_total_min > 0:
            print(f"    ^ {result['count']} interior awakenings on a "
                  f"{(in_bed_end - in_bed_start) / 3600:.1f}h night -- every awake minute is an edge segment")


# --------------------------------------------------------------------------- --sweep-arousal-cut
#
# Fits `SleepStaging.Tuning.arousalIntensityCut` (docs/SLEEP_INTERIOR_AROUSALS.md §4) WITHOUT
# re-implementing all of `classifyContiguous` in Python: `markInteriorArousals` is purely additive
# and, by construction, never moves onset/finalWake (that's its whole safety argument -- see the
# Swift doc comment). So a candidate cut's effect can be simulated by taking the ALREADY-COMMITTED
# onset/finalWake from the stored hypnogram (which the pass would leave untouched) and scanning
# fresh archive tail sums strictly inside that fixed window -- exactly what the pass itself does.

def load_own_night_bounds(store_path):
    """[(inBedStart, inBedEnd, onset|None, finalWake|None), ...] -- onset/finalWake via the same
    min/max-of-asleep-segment rule `compute_awakenings` uses, so the sweep's fixed window matches
    what `classify()` already committed to."""
    out = []
    for in_bed_start, in_bed_end, segments in load_own_nights(store_path):
        asleep = [(s, e) for s, e, st in segments if st in ("light", "deep", "rem")]
        if not asleep:
            out.append((in_bed_start, in_bed_end, None, None))
            continue
        out.append((in_bed_start, in_bed_end, min(s for s, e in asleep), max(e for s, e in asleep)))
    return out


def sweep_arousal_cut(labels, store_path, archives, tz, cuts):
    bounds = load_own_night_bounds(store_path)
    if not bounds:
        print("\nno stored nights to sweep")
        return
    sources = sorted({src for src, s, e, st in labels})
    all_recs = [r for recs in archives.values() for r in recs]
    print(f"\n--- arousal-cut sweep (docs/SLEEP_INTERIOR_AROUSALS.md §4) ---")
    print("simulates markInteriorArousals: tail sums re-scanned fresh from the pulled archive "
          "inside a FIXED [onset, finalWake] window (the pass never moves that window)")
    for in_bed_start, in_bed_end, our_onset, our_final_wake in bounds:
        print(f"\nnight {fmt(in_bed_start, tz)} .. {fmt(in_bed_end, tz)}")
        if our_onset is None:
            print("  no asleep segments stored -- skipping")
            continue
        # ⚠️ FITTING WINDOW vs SHIPPING WINDOW. Production always uses OUR OWN onset/finalWake --
        # that is what markInteriorArousals actually gets handed and is correct BY CONSTRUCTION
        # (the pass's whole safety argument is that it never moves them). But for CHOOSING the cut,
        # our own onset can itself be wrong (a SEPARATE, pre-existing bug this plan does not touch:
        # 🟢 measured 2026-08-15, our stored onset for 08-14/15 was 74.8 min EARLIER than Whoop's,
        # 22:16 vs 23:31 -- the classifier called "asleep" while the wearer was still visibly moving
        # getting into bed per the tail data). Fitting against that window would count real
        # getting-into-bed motion as "arousals" and inflate every cut's count roughly equally. So:
        # prefer a reference source's OWN asleep-labelled span for THIS night when one exists (a
        # second, independent onset estimate); fall back to our own only when no reference covers
        # the night. This choice affects ONLY which cut number gets picked here, never what ships.
        onset, final_wake, window_source = our_onset, our_final_wake, "our own stored onset/wake"
        for src in sources:
            src_asleep = [(s, e) for s2, s, e, st in labels
                         if s2 == src and st in ("light", "deep", "rem")
                         and s < in_bed_end and e > in_bed_start]
            if src_asleep:
                onset, final_wake = min(s for s, e in src_asleep), max(e for s, e in src_asleep)
                window_source = f"{src}'s own labelled onset/wake"
                break
        if (onset, final_wake) != (our_onset, our_final_wake):
            print(f"  fitting window: {window_source} ({fmt(onset, tz)} .. {fmt(final_wake, tz)}) -- "
                  f"our own stored onset differs by {(our_onset - onset) / 60:+.1f} min")
        else:
            print(f"  fitting window: {window_source} ({fmt(onset, tz)} .. {fmt(final_wake, tz)})")
        interior = sorted((r for r in all_recs if onset < r.time < final_wake), key=lambda r: r.time)
        if not interior:
            print("  no raw epochs in the pulled archive for this night (outside ~30h retention)")
            continue
        for src in sources:
            count = sum(1 for s2, s, e, st in labels
                       if s2 == src and st == "awake" and s < final_wake and e > onset)
            print(f"    {src} reference awake intervals in this window: {count}")
        print(f"    {'cut':>6}{'count':>8}{'waso(min)':>11}")
        for cut in cuts:
            hits = [r.time for r in interior if sum(r.intensity_tail) >= cut]
            merged = []
            for t in hits:
                if merged and t <= merged[-1][1] + MERGE_TOLERANCE_SECONDS:
                    merged[-1] = (merged[-1][0], max(merged[-1][1], t + 150))
                else:
                    merged.append((t, t + 150))
            waso = sum(e - s for s, e in merged) / 60
            print(f"    {cut:>6}{len(merged):>8}{waso:>10.1f}m")


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
    ap.add_argument("--compare-own", action="store_true",
                    help="reproduce SLEEP_AWAKE_RESOLUTION §4.1: our own interior/edge awake "
                         "split per stored night, beside each reference source's awake total "
                         "(needs the SwiftData store -- pulled automatically with --pull)")
    ap.add_argument("--sweep-arousal-cut", nargs="?", const="", metavar="C1,C2,...",
                    help="fit Tuning.arousalIntensityCut (SLEEP_INTERIOR_AROUSALS.md §4): "
                         "simulate markInteriorArousals at each comma-separated cut and print "
                         "the resulting awakening count per stored night. Bare flag (no value) "
                         "uses the default sweep: 345,300,250,200,150,120,100,75,50")
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
    loaded = load_labels(prefs)
    report(loaded, prefs, tz)   # distinguishes None (never imported) from [] (imported, empty)
    labels = loaded or []

    if args.source:
        labels = [l for l in labels if l[0] == args.source]
        print(f"\nfiltered to source {args.source!r}: {len(labels)} intervals")

    if args.compare_own:
        compare_own(labels, args.dir / STORE_NAME, tz)

    if args.sweep_arousal_cut is not None:
        cuts = ([int(c.strip()) for c in args.sweep_arousal_cut.split(",")] if args.sweep_arousal_cut
                else [345, 300, 250, 200, 150, 120, 100, 75, 50])
        sweep_arousal_cut(labels, args.dir / STORE_NAME, load_archives(prefs), tz, cuts)

    if not labels:
        return

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

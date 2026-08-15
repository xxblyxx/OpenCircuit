#!/usr/bin/env python3
"""Per-epoch trace: which of `SleepStaging`'s awake-mask passes killed a specific awakening?

*** DEV TOOL. NOTHING HERE SHIPS IN THE APP. *** Stdlib only, no network.

WHY THIS EXISTS
----------------
The sleep page's hypnogram doesn't show brief (1-4 min) mid-night awakenings that Apple
Health/Whoop do. That's not a graphing bug — the renderer (`SleepStagesSection.swift`) already
gives `.awake` a WIDER minimum bar than every other stage. It's that no mechanism upstream ever
LABELS a brief awakening `.awake` in the first place: the 150 s epoch grid, the +-2-epoch rolling
HR median, and `erodeShortHRWake` (which deletes any HR-only awake run under `minHRWakeRunEpochs`,
default 5 epochs = 12.5 min, unless a motion epoch corroborates it) each independently rule it out.
See `docs/SLEEP_AWAKE_RESOLUTION.md` for the full writeup this tool's output feeds.

This answers, from the wearer's OWN bytes: was a given awakening even recorded as motion, and if
so, which pass in the pipeline erased it?

WHAT IT READS
--------------
The phone's own `sleep.epochArchive.<ring>` (raw 23-byte 0x4c records, 30 h retention) via the
SAME `--pull` mechanism `device_alert_audit.py` uses — no separate BLE capture needed, and no risk
of re-deriving from a stale desktop replay when the app already has last night on-device.

USAGE
    ./sleep_awake_trace.py --pull                              # pull + trace the latest night
    ./sleep_awake_trace.py                                     # re-trace the last pulled snapshot
    ./sleep_awake_trace.py --at 00:19 --at 01:24 --window 20m   # focus on specific clock times
    ./sleep_awake_trace.py --night 2026-08-14                   # a specific calendar night
"""
from __future__ import annotations

import argparse
import math
import plistlib
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from ringconn_sleep_fit import (  # noqa: E402
    Epoch, Tuning, SYNC_EPOCH, MIN_SLEEP_DURATION,
    prepare_night, classify_prepared, _compute_awake_mask, _sleep_span,
    percentile, rolling_median, _motion_timeline, _detect_periods,
)

RECORD_LEN = 23
BUNDLE_ID = "com.bly.opencircuit"
DEFAULT_DEVICE = "819D37A3-B45A-56CF-9FEC-40D460EC74F8"   # Jedi Master's iPhone
PLIST_NAME = "com.bly.opencircuit.plist"
PULL_FILES = [f"Library/Preferences/{PLIST_NAME}"]


def fmt(unix, tz=None):
    return datetime.fromtimestamp(unix, timezone.utc).astimezone(tz).strftime("%m-%d %H:%M:%S")


# --------------------------------------------------------------------------- pull

def pull(device, outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    for src in PULL_FILES:
        dest = outdir / Path(src).name
        cmd = ["xcrun", "devicectl", "device", "copy", "from", "--device", device,
               "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
               "--user", "mobile", "--source", src, "--destination", str(dest)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  ! {src}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'failed'}")
        else:
            print(f"  ✓ {dest.name} ({dest.stat().st_size:,} B)")


# --------------------------------------------------------------------------- 0x4c decode
#
# A faithful mirror of BulkRecord (BulkSleep.swift) -- richer than device_alert_audit.py's Record
# (which only carries the SpO2-evidence fields): this one decodes HR/HRV/RR too, since the staging
# trace needs them. Kept as its own small mirror rather than importing device_alert_audit's, same
# as extract_last_night.py's independent mirror -- "less to drift" per that file's own note.

VALID_BPM = range(30, 221)          # LiveHR.validBPM (30...220), BulkSleep.swift:126


class Record:
    __slots__ = ("raw", "counter", "layout")

    def __init__(self, raw):
        self.raw = raw
        self.counter = int.from_bytes(raw[0:4], "big")
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
    def heart_rate(self):
        if self.layout == "idle":
            return None
        hr = self.raw[4]
        return hr if hr in VALID_BPM else None

    @property
    def hrv_rmssd(self):
        if self.layout != "sleepVitals" or self.raw[5] <= 0:
            return None
        return self.raw[5]

    @property
    def respiratory_rate(self):
        if self.layout != "sleepVitals" or self.raw[7] <= 0:
            return None
        return self.raw[7] / 8.0

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
    def motion_is_placeholder(self):
        m = self.motion
        return len(set(m)) == 1

    @property
    def intensity_tail(self):
        # `motionIntensityTail` (BulkSleep.swift): raw[15..<20], 5 bytes -- NOT the 8-byte
        # [15:23) nibble-packed `magnitudes` property some other mirrors decode. This is the
        # channel `motionIntensityFallbackMagnitudes` actually sums.
        return list(self.raw[15:20])

    @property
    def intensity_tail_is_zero(self):
        return all(v == 0 for v in self.intensity_tail)

    @property
    def resolves_stillness(self):
        if self.layout == "idle":
            return False
        m = self.motion
        return (max(m) - min(m)) <= 2   # ActivityPeriod.motionStillThreshold


def load_archives(prefs):
    out = {}
    for key in sorted(k for k in prefs if k.startswith("sleep.epochArchive")):
        data = bytes(prefs[key])
        ns = key[len("sleep.epochArchive"):].lstrip(".") or "(legacy)"
        n, rem = divmod(len(data), RECORD_LEN)
        if rem:
            print(f"!! {ns}: {len(data)} B is not a whole number of {RECORD_LEN}-byte records "
                  f"(remainder {rem})")
        out[ns] = [Record(data[i * RECORD_LEN:(i + 1) * RECORD_LEN]) for i in range(n)]
    return out


# --------------------------------------------------------------------------- motion-source verdict
#
# Port of BulkSleep.motionSource / primaryMotionIsDegenerate (BulkSleep.swift:449-540): is the
# primary [10:15] motion channel usable, or does staging fall back to the [15:20] intensity tail
# (or, worse, see nothing but a flat placeholder)? This is the single most important line of the
# trace's output -- a brief awakening is undetectable by motion at all if this comes back anything
# but "primary".
DEGENERATE_MIN_QUIET_EPOCHS = 24
DEGENERATE_MAX_QUIET_STILL_FRACTION = 0.50
DEGENERATE_MIN_SLOT_ORDER_FRACTION = 0.75


def _slot_order_consistency(recs):
    if not recs:
        return 0.0
    best = 0
    for j in range(4):
        for k in range(j + 1, 5):
            less = greater = 0
            for r in recs:
                a, b = r.raw[10 + j], r.raw[10 + k]
                if a < b:
                    less += 1
                elif b < a:
                    greater += 1
            best = max(best, less, greater)
    return best / len(recs)


def _primary_motion_is_degenerate(worn):
    quiet = [r for r in worn if r.intensity_tail_is_zero]
    if len(quiet) < DEGENERATE_MIN_QUIET_EPOCHS:
        return False
    still_count = sum(1 for r in quiet if r.resolves_stillness)
    if still_count >= len(quiet) * DEGENERATE_MAX_QUIET_STILL_FRACTION:
        return False
    return _slot_order_consistency(quiet) >= DEGENERATE_MIN_SLOT_ORDER_FRACTION


def motion_source_verdict(records):
    """('primary' | 'constant-filler' | 'intensity-tail-fallback(degenerate)', detail str)."""
    worn = [r for r in records if r.layout != "idle"]
    if len(worn) < 4:
        return "primary", "fewer than 4 worn epochs -- defaulting to primary"
    constant_filler = not any(not r.motion_is_placeholder for r in worn)
    degenerate = False if constant_filler else _primary_motion_is_degenerate(worn)
    if not (constant_filler or degenerate):
        return "primary", f"{len(worn)} worn epochs, motion channel expresses real variation"
    tail_nonzero = sum(1 for r in worn if any(v > 0 for v in r.intensity_tail))
    if tail_nonzero < 2:
        return "primary", ("constant-filler/degenerate but the [15:20] fallback has < 2 nonzero "
                           "epochs too -- staging stays on the (useless) primary channel")
    kind = "constant-filler" if constant_filler else "degenerate"
    return f"intensity-tail-fallback({kind})", (
        f"{sum(1 for r in worn if r.motion_is_placeholder)}/{len(worn)} worn epochs are a flat "
        f"placeholder" if constant_filler else
        "primary channel varies but never resolves stillness where the ring's own [15:20] tail "
        "says nothing moved -- a fixed instrumentation template, not real motion")


# --------------------------------------------------------------------------- intensity-tail fallback
#
# Port of BulkSleep.otsuIntensityCut / motionIntensityFallbackMagnitudes (BulkSleep.swift:701-767):
# when the primary [10:15] channel is unusable, staging reads motion off the [15:20] intensity tail
# instead. This is the piece the earlier version of this tool was missing entirely -- it always fed
# the (possibly dead) primary channel into staging regardless of what `motion_source_verdict` said.

MOTION_INTENSITY_ACTIVE_CUT = 345   # BulkSleep.motionIntensityActiveCut


def _otsu_intensity_cut(positive):
    """Port of BulkSleep.otsuIntensityCut: the two-class (still/active) split of `positive` that
    maximizes between-class variance. `positive` must already be sorted ascending."""
    n = len(positive)
    if n == 0:
        return 0
    if n < 2:
        return positive[-1]
    total = sum(positive)
    low_sum = 0
    best = positive[-1]
    best_variance = -1.0
    for i in range(1, n):
        low_sum += positive[i - 1]
        if positive[i] == positive[i - 1]:
            continue   # never split a tie
        w0, w1 = i / n, 1 - i / n
        m0 = low_sum / i
        m1 = (total - low_sum) / (n - i)
        v = w0 * w1 * (m0 - m1) * (m0 - m1)
        if v > best_variance:
            best_variance = v
            best = positive[i]
    return best


def motion_intensity_fallback_magnitudes(records, degenerate, absolute_active_cut=MOTION_INTENSITY_ACTIVE_CUT):
    """Port of BulkSleep.motionIntensityFallbackMagnitudes: per-record motion magnitude (0/1/16)
    read off the [15:20] intensity tail instead of the (unusable) primary [10:15] channel."""
    sums = [sum(r.intensity_tail) for r in records]
    positive = sorted(s for s in sums if s > 0)
    if not positive:
        return [0] * len(records)
    if absolute_active_cut > 0:
        active_cut = absolute_active_cut
    else:
        # Swift's `.rounded()` is round-half-away-from-zero; Python's builtin `round()` is
        # round-half-to-even and would disagree on an exact .5 tie -- floor(x+0.5) matches Swift
        # for the non-negative index this always is.
        idx = math.floor((len(positive) - 1) * 0.80 + 0.5)
        active_cut = _otsu_intensity_cut(positive) if degenerate else positive[idx]
    return [0 if s == 0 else (16 if s >= active_cut else 1) for s in sums]


# --------------------------------------------------------------------------- trace

def find_qualifying_nights(records):
    """All motion-detected `.sleep` periods > 1 h in the WHOLE archive, latest-ending first.

    `prepare_night`/`_main_sleep` (ringconn_sleep_fit.py) only ever returns the FIRST such period
    per contiguous run -- correct for its own CSV workflow, where `extract_last_night.py` has
    already scoped the input to one night, but wrong for a raw 30 h phone-archive pull: fed the
    whole archive, it can anchor on an early, unrelated block (a residual nap, a dozing-off) and
    never reach the real night. This is the (deliberately simplified) counterpart of
    `BulkSleep.latestNightRecords` -- it does not replicate that function's overnight-window
    filter, anchor-eviction, or truncated-night clustering, so treat its pick as a first guess to
    sanity-check against the printed span, not as authoritative as the shipped classifier's.
    """
    epochs = [to_epoch(r) for r in records]
    times, deltas = _motion_timeline(epochs)
    periods = _detect_periods(times, deltas)
    nights = [(st, en) for (act, st, en) in periods if act == "sleep" and (en - st) > MIN_SLEEP_DURATION]
    return sorted(nights, key=lambda p: p[1], reverse=True)


def scope_to_night(records, night, pad_hours=2):
    """Records within `night` (start, end) unix-seconds, padded so staging's own onset/offset
    trim still has edge context to work with."""
    lo = night[0] - pad_hours * 3600
    hi = night[1] + pad_hours * 3600
    return [r for r in records if lo <= r.time <= hi]


def to_epoch(r, motion_override=None):
    # `motion_override`, when given, is a single fallback magnitude (0/1/16, from
    # `motion_intensity_fallback_magnitudes`) rather than the 5 real [10:15] bytes. It's packed as
    # [magnitude, 1, 1, 1, 1] so `prepare_night`'s `sum(0 if c == 1 else c for c in e.motion)`
    # reduces to exactly `magnitude` (the trailing 1's each contribute 0, matching how it already
    # treats the primary channel's own baseline byte) -- the printed "motion Σ" column then reads
    # the true 0/1/16 magnitude rather than an artifact of repeating it across 5 slots.
    motion = [motion_override, 1, 1, 1, 1] if motion_override is not None else r.motion
    return Epoch(counter=r.counter, time=r.time, layout=r.layout,
                 hr=(float(r.heart_rate) if r.heart_rate is not None else None),
                 hrv=(float(r.hrv_rmssd) if r.hrv_rmssd is not None else None),
                 spo2=(float(r.spo2) if r.spo2 is not None else None),
                 rr=r.respiratory_rate, motion=motion)


def run_trace(records, at_times=None, window_minutes=20, tz=None, night=None):
    # Score the verdict on the STRICT sleep window when one is known, not the padded set
    # `scope_to_night` returns for staging's edge context -- the pad exists specifically to
    # include real pre-sleep/post-wake motion, which would dilute a constant-filler primary
    # channel into a false "primary" verdict (measured: this is not a hypothetical, see
    # docs/SLEEP_AWAKE_RESOLUTION.md's ring-motion-dead-during-sleep finding).
    verdict_records = [r for r in records if night[0] <= r.time <= night[1]] if night else records
    kind, detail = motion_source_verdict(verdict_records)
    print(f"motion source: {kind}")
    print(f"  {detail}")
    fallback_by_counter = {}
    if kind != "primary":
        degenerate = "degenerate" in kind
        magnitudes = motion_intensity_fallback_magnitudes(records, degenerate)
        fallback_by_counter = {r.counter: m for r, m in zip(records, magnitudes)}
        nonzero = sum(1 for m in magnitudes if m > 0)
        active = sum(1 for m in magnitudes if m >= 16)
        print(f"  primary channel dead -- staging reads the [15:20] intensity-tail fallback "
              f"instead (BulkSleep.motionSource): {nonzero}/{len(magnitudes)} epochs nonzero, "
              f"{active} at the active magnitude (16)")
    print()

    epochs = [to_epoch(r, fallback_by_counter.get(r.counter)) for r in records]
    prepared = prepare_night(epochs)
    if not prepared:
        print("no detectable sleep block in this archive (< 1 h still) -- nothing to trace")
        return
    t = Tuning()

    for frag_i, pf in enumerate(prepared):
        if len(prepared) > 1:
            print(f"--- fragment {frag_i + 1}/{len(prepared)} ---")
        n = len(pf.hr)
        sleep_floor = percentile(sorted(pf.hr), t.sleepFloorPercentile)
        wake_threshold = sleep_floor + t.wakeHRMarginBPM
        sm_hr = rolling_median(pf.hr, t.hrWakeHalfWindow)
        motion_awake_raw = [pf.motion_sum[i] > t.awakeMotion for i in range(n)]
        raw_awake = [sm_hr[i] >= wake_threshold or motion_awake_raw[i] for i in range(n)]
        final_awake, final_sm_hr, final_floor, not_before = _compute_awake_mask(pf, t)
        span = _sleep_span(final_awake, t.onsetSustainEpochs)
        labels = classify_prepared(pf, t)

        print(f"sleep floor (p{t.sleepFloorPercentile:.0%}): {sleep_floor:.1f} bpm   "
              f"wake threshold (+{t.wakeHRMarginBPM:.0f}): {wake_threshold:.1f} bpm   "
              f"rescue ceiling (+{t.hrWakeRescueCeilingBPM:.0f}): "
              f"{sleep_floor + t.hrWakeRescueCeilingBPM:.1f} bpm")
        if span:
            lo, hi = span
            print(f"kept sleep window: rows {lo}..{hi} "
                  f"({fmt(int(pf.counters[lo]) + SYNC_EPOCH, tz)} .. "
                  f"{fmt(int(pf.counters[hi]) + SYNC_EPOCH, tz)})")
        print(f"raw-awake epochs (before erode/rescue/onset passes): {sum(raw_awake)}")
        print(f"final-awake epochs: {sum(final_awake)}")
        print()

        # Which rows to print: everything if no --at given, else a window around each --at time.
        show = set(range(n))
        if at_times:
            show = set()
            for at in at_times:
                target = at.timestamp()
                for i, ctr in enumerate(pf.counters):
                    if abs((ctr + SYNC_EPOCH) - target) <= window_minutes * 60:
                        show.add(i)
        rows = sorted(show)
        if not rows:
            continue

        header = (f"{'time':<18}{'motion Σ':>9}{'hr':>5}{'smHR':>7}{'thr':>7}  "
                  f"{'m-awk':>5} {'raw':>4} {'final':>7}  class")
        print(header)
        print("-" * len(header))
        prev_i = None
        for i in rows:
            if prev_i is not None and i != prev_i + 1:
                print("  ...")
            ctr = pf.counters[i]
            t_unix = int(ctr) + SYNC_EPOCH
            cls = labels.get(ctr, "?")
            marker = "  <-- AWAKE" if final_awake[i] else ""
            print(f"{fmt(t_unix, tz):<18}{pf.motion_sum[i]:>9}{pf.hr[i]:>5.0f}{sm_hr[i]:>7.1f}"
                  f"{wake_threshold:>7.1f}  {'M' if motion_awake_raw[i] else '.':>5} "
                  f"{'A' if raw_awake[i] else '.':>4} {'A' if final_awake[i] else '.':>7}  "
                  f"{cls}{marker}")
            prev_i = i
        print()

    # Per-pass kill count, aggregated across fragments.
    print("--- per-pass summary (epochs the RAW gate called awake that survived to be RESCUED "
          "back to asleep, i.e. never reach the hypnogram) ---")
    total_raw = total_final = total_rescued_away = 0
    for pf in prepared:
        n = len(pf.hr)
        sleep_floor = percentile(sorted(pf.hr), t.sleepFloorPercentile)
        wake_threshold = sleep_floor + t.wakeHRMarginBPM
        sm_hr = rolling_median(pf.hr, t.hrWakeHalfWindow)
        motion_awake_raw = [pf.motion_sum[i] > t.awakeMotion for i in range(n)]
        raw_awake = [sm_hr[i] >= wake_threshold or motion_awake_raw[i] for i in range(n)]
        final_awake, *_ = _compute_awake_mask(pf, t)
        total_raw += sum(raw_awake)
        total_final += sum(final_awake)
        total_rescued_away += sum(1 for i in range(n) if raw_awake[i] and not final_awake[i])
    print(f"  raw-awake total: {total_raw} epochs ({total_raw * 150 / 60:.0f} min)")
    print(f"  final-awake total: {total_final} epochs ({total_final * 150 / 60:.0f} min)")
    print(f"  erased by erode/rescue (not by the onset/offset edge passes): "
          f"{total_rescued_away} epochs ({total_rescued_away * 150 / 60:.0f} min)")


def _parse_at(s):
    for fmt_ in ("%H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(s, fmt_)
        except ValueError:
            continue
    raise argparse.ArgumentTypeError(f"bad time {s!r}; use HH:MM or YYYY-MM-DDTHH:MM")


def _parse_window(s):
    s = s.strip().lower()
    if s.endswith("m"):
        return int(s[:-1])
    if s.endswith("h"):
        return int(s[:-1]) * 60
    return int(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pull", action="store_true", help="copy the epoch archive off the phone first")
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    ap.add_argument("--dir", type=Path,
                    default=Path(__file__).parent / "captures" / "device-snapshot",
                    help="snapshot directory (default under captures/, which is gitignored)")
    ap.add_argument("--at", action="append", type=_parse_at, default=None,
                    help="a clock time (HH:MM, or full ISO) to zoom the table on; repeatable")
    ap.add_argument("--window", type=_parse_window, default="20m",
                    help="minutes on either side of each --at time (default 20m)")
    ap.add_argument("--night", help="YYYY-MM-DD -- filter to epochs whose local date matches "
                                    "(default: no filter, whole archive)")
    args = ap.parse_args()

    if args.pull:
        print(f"pulling from {args.device} -> {args.dir}")
        pull(args.device, args.dir)
        print()

    plist_path = args.dir / PLIST_NAME
    if not plist_path.exists():
        print(f"!! {plist_path} not found -- pass --pull with the phone connected over USB, or "
              f"--dir pointing at an existing device_alert_audit.py snapshot", file=sys.stderr)
        raise SystemExit(1)
    with open(plist_path, "rb") as f:
        prefs = plistlib.load(f)
    archives = load_archives(prefs)
    if not archives:
        print("!! no sleep.epochArchive.* keys in the pulled plist", file=sys.stderr)
        raise SystemExit(1)

    tz = datetime.now().astimezone().tzinfo
    for ns, records in archives.items():
        print(f"=== ring '{ns}': {len(records)} records "
              f"({fmt(records[0].time, tz)} .. {fmt(records[-1].time, tz)}) ===\n")
        recs = sorted(records, key=lambda r: r.counter)

        chosen_night = None
        if args.night:
            target = args.night
            recs = [r for r in recs
                    if datetime.fromtimestamp(r.time, tz).strftime("%Y-%m-%d") == target]
            if not recs:
                print(f"  no records on {target} for this ring\n")
                continue
        else:
            # Scope to the LATEST-ending qualifying sleep period, not the archive's whole 30 h --
            # otherwise `prepare_night`'s single-first-block logic can anchor on an unrelated
            # early block. See `find_qualifying_nights`'s docstring for what this simplifies away.
            nights = find_qualifying_nights(recs)
            if not nights:
                print("  no motion-detected sleep period > 1 h anywhere in this archive\n")
                continue
            chosen_night = nights[0]
            print(f"  scoped to latest-ending qualifying period: "
                  f"{fmt(chosen_night[0], tz)} .. {fmt(chosen_night[1], tz)}")
            if len(nights) > 1:
                others = ", ".join(f"{fmt(s, tz)}..{fmt(e, tz)}" for s, e in nights[1:])
                print(f"  (other qualifying periods in this archive, NOT traced: {others})")
            recs = scope_to_night(recs, chosen_night)

        at_times = None
        if args.at:
            at_times = []
            lo = recs[0].time - 2 * 3600 if recs else float("-inf")
            hi = recs[-1].time + 2 * 3600 if recs else float("inf")
            candidate_dates = ({datetime.fromtimestamp(recs[0].time, tz).date(),
                               datetime.fromtimestamp(recs[-1].time, tz).date()}
                               if recs else set())
            for a in args.at:
                if a.year != 1900:   # a full date was given explicitly -- nothing to anchor
                    at_times.append(a.replace(tzinfo=tz) if a.tzinfo is None else a)
                    continue
                # HH:MM-only: anchor against the SCOPED window's own span, not blindly to the
                # archive's first record -- an archive starting the prior morning would otherwise
                # misdate an early-AM time (e.g. 00:19) onto the wrong calendar day. Try each
                # calendar date the window straddles and keep whichever lands inside it.
                anchored = next((a.replace(year=d.year, month=d.month, day=d.day, tzinfo=tz)
                                 for d in candidate_dates
                                 if lo <= a.replace(year=d.year, month=d.month, day=d.day,
                                                    tzinfo=tz).timestamp() <= hi), None)
                if anchored is None:
                    d = max(candidate_dates) if candidate_dates else datetime.now(tz).date()
                    anchored = a.replace(year=d.year, month=d.month, day=d.day, tzinfo=tz)
                at_times.append(anchored)
        run_trace(recs, at_times=at_times, window_minutes=args.window, tz=tz, night=chosen_night)
        print()


if __name__ == "__main__":
    main()

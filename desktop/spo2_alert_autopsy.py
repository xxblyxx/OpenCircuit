#!/usr/bin/env python3
"""Autopsy a low-SpO2 alert against the raw 0x4c epoch that produced it.

*** DEV TOOL. NOTHING HERE SHIPS IN THE APP. ***
Stdlib only, no network. Reads a JSON export the wearer chose to produce, on this machine.
The app never imports this file and never computes any number defined here.

WHAT THIS ANSWERS
-----------------
The app notified "Low blood oxygen (80%)" while the wearer was washing dishes. The shipped
rule is a SINGLE-SAMPLE instantaneous crossing (`HealthAlertEvaluator.lowSpO2`) with no motion,
signal-quality, wear or corroboration check. This harness answers the four questions that must
be answered with DATA before a suppression rule is written, because each one freezes a constant:

  A  --incident   What did that epoch actually look like? Was its motion channel anomalous
                  versus its own neighbours, and what were the nearest SpO2 readings?
  B  (default)    How far apart are consecutive SpO2 readings, REALLY, on this ring?
                  -> freezes `corroborationWindow`.
  C  (default)    Does any per-epoch quality signal separate low readings from normal ones?
                  -> decides whether `confidence` earns a gate or ships log-only.
  D  --sweep      Over a (window x tolerance x badFraction) grid: what fires, what is
                  suppressed and WHY — plus every reading today's rule fires on that the new
                  rule would NOT. That last list is the "did we silence a real desaturation?"
                  artefact and every entry must be individually defensible.
  E  --miss-report How many stored SpO2 samples have no raw record at all? Live on-demand
                  readings (`RingSession.stopLiveMonitoring`) come from the 0x15 frame and have
                  no 0x4c record BY CONSTRUCTION, so they can never resolve. That rate is what
                  justifies the rule's fail-open-with-corroboration miss policy in writing.

WHY THE WINDOW IS THE WHOLE BALLGAME
------------------------------------
There are TWO SpO2 cadences and they differ by an order of magnitude:

  * channel 0x00 (sleep program) — PROTOCOL.md 5.3, the 300 s duty cycle. Confirmed over
    5650 records / 4 rings.
  * channel 0x03 (all-day)       — PROTOCOL.md 5.6.1, "a periodic (~10 min) daytime SpO2
    reading". The one real capture printed there steps
        09:52 -> 98%, 10:12 -> 97%, 10:42 -> 92%, 11:02 -> 89%, 11:22 -> 90%
    i.e. gaps of 20, 30, 20, 20 MINUTES.

The dishes reading is daytime, so it is on the second one. A corroboration window sized to the
300 s sleep cadence would make every daytime reading structurally uncorroborated and — under a
fail-closed miss policy — silently reduce the low-SpO2 alert to overnight-only. That would look
like a working fix while deleting the entire daytime channel. Section B measures the real
cadence on THIS ring so the constant rests on this wearer's data, not on one capture in a doc.

HONESTY RULES BAKED INTO THE OUTPUT
-----------------------------------
1. Every distribution prints its n. An AUC without a sample count is a decoration.
2. An AUC over fewer than --min-low low readings is REFUSED, not printed.
3. A missing input is ABSENT with a reason, never substituted with 0. Here 0 is a real byte
   value ("still", or "no measurement"), so imputing it would fabricate evidence.
4. Section D prints the SUPPRESSED-that-today-fires list in full and never truncates it. A rule
   that silently caps its own regression list is not evidence.
5. Nothing here is a diagnosis. SpO2 from this ring is an ESTIMATE (docs/HEALTHKIT_MAPPING.md).

INPUTS
------
  --export export.json   The app's JSON export: Settings > Data export > Export health data,
                         Format JSON, mode "Date range". Release-reachable, not DEBUG-gated.
                         Sections consumed (ios/OpenCircuitKit/.../ExportEngine.swift):
                           epochArchive[].recordsBase64        concatenated 23-byte records,
                                                               deduped by counter, ascending
                           historySyncEvidence[].rawRecordBlobBase64   per-drain slice (union'd
                                                               in as a secondary source)
                           samples[]  kind/start/end/value     value is a 0..1 FRACTION
                         !! Sync the ring BEFORE exporting. `epochArchive` is emitted only when
                         a `historySyncEvidence` row falls inside the export window, and that
                         buffer is 24 entries / 3 days (ObservabilityStore).

  --synthetic            Fabricate an export in a temp dir and self-test the analysis: a genuine
                         overnight desaturation at the 300 s cadence with quiet motion, plus an
                         isolated daytime 80% with 97%/96% neighbours 20-30 min away. Asserts
                         the first fires and the second is suppressed. Proves the harness before
                         real data touches it.

USAGE
-----
  python3 spo2_alert_autopsy.py --synthetic
  python3 spo2_alert_autopsy.py --export captures/export.json
  python3 spo2_alert_autopsy.py --export captures/export.json --incident "2026-08-12 19:34"
  python3 spo2_alert_autopsy.py --export captures/export.json --sweep --miss-report
  python3 spo2_alert_autopsy.py --export captures/export.json --csv /tmp/spo2.csv
"""
from __future__ import annotations

import argparse
import base64
import csv
import datetime as dt
import json
import os
import statistics
import sys
import tempfile

# ---------------------------------------------------------------------------
# CONSTANTS MIRRORED FROM SWIFT
# Any change here must be mirrored there and vice versa. Source of truth in parens.
# ---------------------------------------------------------------------------
EPOCH = 1_577_793_600          # Command.syncEpoch (Opcodes.swift:107) = 2019-12-31 12:00 UTC
RECLEN = 23                    # BulkRecord.length
STEP = 150                     # one epoch, seconds

SPO2_VALID = range(70, 101)    # BulkRecord.spo2Percent guard (BulkSleep.swift:148-152)
ACTIVITY_TAGS = {0x12, 0x13, 0x11}   # "no SpO2 here" sentinels (BulkSleep.swift:108)
MOTION_STILL_THRESHOLD = 2     # ActivityPeriod.motionStillThreshold (SleepDetection.swift:87)

# Shipped alert config (HealthAlertDefaults / HealthAlertThresholds)
DEFAULT_THRESHOLD = 90         # alerts.lowSpO2.percent

# PROPOSED rule constants — these are what this harness exists to freeze.
PROPOSED_WINDOW = 2700         # corroborationWindow, seconds — MEASURED 2026-08-13 against a
                                # real 30h export from this wearer's ring: all-day cadence p99
                                # 2325s, max 2550s (n=31 gaps). Mirrors HealthAlerts.swift.
PROPOSED_TOLERANCE = 2         # agreementTolerance, percentage points (NOOP MetricArbitration)
PROPOSED_MIN_RUN = 2           # minCorroboratingReadings (NOOP minCorroboratingSignals = 2)
PROPOSED_BAD_FRACTION = 0.5    # maxBadEpochFraction, applied with STRICT >

SWEEP_WINDOWS = [300, 600, 900, 1800, 2700]
SWEEP_TOLERANCES = [1, 2, 3, 4]
SWEEP_BAD_FRACTIONS = [0.34, 0.5, 0.67]


# ---------------------------------------------------------------------------
# Record decode — mirrors BulkRecord (BulkSleep.swift) and desktop/decode_bulk.py
# ---------------------------------------------------------------------------
class Record:
    """One 23-byte 0x4c epoch record."""

    __slots__ = ("raw", "counter")

    def __init__(self, raw: bytes):
        self.raw = raw
        self.counter = int.from_bytes(raw[0:4], "big")

    # -- time ---------------------------------------------------------------
    @property
    def epoch_seconds(self) -> int:
        return self.counter + EPOCH

    @property
    def utc(self) -> dt.datetime:
        return dt.datetime.fromtimestamp(self.epoch_seconds, dt.timezone.utc)

    @property
    def local(self) -> dt.datetime:
        return dt.datetime.fromtimestamp(self.epoch_seconds)

    # -- layout (BulkSleep.swift:71-110) ------------------------------------
    @property
    def layout(self) -> str:
        r = self.raw
        if (r[4] == 0x05 and r[5] == 0x00 and r[6] == 0x0C and r[7] == 0x00
                and r[9] == 0x0A
                and r[10:15] == bytes([1, 1, 1, 1, 1])
                and r[15:22] == bytes(7)):
            return "idle"
        if r[8] in ACTIVITY_TAGS:
            return "activity"
        return "sleepVitals"

    # -- vitals -------------------------------------------------------------
    @property
    def spo2(self):
        """BulkRecord.spo2Percent — sleep-vitals only, band-guarded 70...100."""
        if self.layout != "sleepVitals":
            return None
        v = self.raw[8]
        return v if v in SPO2_VALID else None

    @property
    def heart_rate(self):
        if self.layout == "idle":
            return None
        hr = self.raw[4]
        return hr if 30 <= hr <= 220 else None

    @property
    def hrv(self):
        if self.layout != "sleepVitals" or self.raw[5] == 0:
            return None
        return self.raw[5]

    @property
    def respiratory_rate(self):
        if self.layout != "sleepVitals" or self.raw[7] == 0:
            return None
        return self.raw[7] / 8.0

    @property
    def confidence(self):
        """BulkRecord.confidence — byte[6]. Decoded, NOT consumed by any shipped analytic."""
        if self.layout == "idle":
            return None
        return self.raw[6]

    # -- motion -------------------------------------------------------------
    @property
    def motion(self) -> list:
        """[10:15] — five per-30 s counts. Baseline 01 = still."""
        return list(self.raw[10:15])

    @property
    def motion_spread(self) -> int:
        m = self.motion
        return max(m) - min(m)

    @property
    def motion_is_placeholder(self) -> bool:
        """All five equal — a constant field is a FILLER, not a measurement."""
        if self.layout == "idle":
            return False
        m = self.motion
        return all(x == m[0] for x in m)

    @property
    def resolves_stillness(self) -> bool:
        """motionResolvesStillness — the epoch on its OWN cannot express movement.

        A step INSIDE one epoch is precisely the component `motionAboveLocalFloor` cannot
        remove: the rolling floor subtracts a per-window LEVEL, so a flat plateau at any level
        cancels (Gen-2 01, Gen-3 0f, drifting 16->24->39 alike), but an intra-epoch step
        survives de-flooring intact. Keys on STRUCTURE, never a device-dependent level.
        """
        if self.layout == "idle":
            return False
        return self.motion_spread <= MOTION_STILL_THRESHOLD

    @property
    def magnitudes(self) -> list:
        """[15:23) — five 12-bit big-endian magnitudes, nibble-packed (#195)."""
        def nib(i: int) -> int:
            b = self.raw[15 + i // 2]
            return (b >> 4) if i % 2 == 0 else (b & 0x0F)
        return [(nib(k * 3) << 8) | (nib(k * 3 + 1) << 4) | nib(k * 3 + 2) for k in range(5)]

    @property
    def magnitudes_all_zero(self) -> bool:
        return all(m == 0 for m in self.magnitudes)

    @property
    def info_nibble(self) -> int:
        return self.raw[22] & 0x0F

    # -- the evidence the rule would see ------------------------------------
    def evidence(self) -> dict:
        """Mirrors SpO2Evidence. Only meaningful for an epoch that carries an SpO2 value."""
        return {
            "unworn": self.layout == "idle",
            "resolvesStillness": self.resolves_stillness,
            "motionSpread": self.motion_spread,
            "magnitudesAllZero": self.magnitudes_all_zero,
            "confidence": self.confidence,
        }


def is_bad_epoch(ev: dict) -> bool:
    """Mirrors SpO2AlertPolicy.isBadEpoch.

    v1 gates on WEAR and INTRA-EPOCH MOTION only. `confidence` and `magnitudesAllZero` are
    carried for section C to screen and are deliberately NOT gated on — see the module
    docstring and the plan's "deliberately log-only in v1".
    """
    return bool(ev["unworn"]) or not bool(ev["resolvesStillness"])


def split_records(blob: bytes) -> list:
    """Split a flat concatenation of 23-byte records. A trailing partial chunk is dropped."""
    return [Record(blob[i:i + RECLEN])
            for i in range(0, len(blob) - RECLEN + 1, RECLEN)]


# ---------------------------------------------------------------------------
# Export loading
# ---------------------------------------------------------------------------
def parse_iso(s: str):
    """Tolerant ISO-8601 parse. v2/v3 export sections are UTC with a trailing Z."""
    if not s:
        return None
    t = s.strip().replace("Z", "+00:00")
    try:
        d = dt.datetime.fromisoformat(t)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


class Export:
    """The subset of the app's JSON export this harness reads."""

    def __init__(self, doc: dict, path: str):
        self.path = path
        self.doc = doc
        self.records = {}        # epoch_seconds -> Record   (deduped by counter)
        self.record_source = {}  # epoch_seconds -> "archive" | "evidence"
        self.samples = []        # [(epoch_seconds, percent)] for kind == spo2
        self.ring_ids = []
        self.notes = []
        self._load()

    def _load(self):
        archives = self.doc.get("epochArchive") or []
        if not archives:
            self.notes.append(
                "ABSENT: `epochArchive` — the export carries no raw records. It is emitted only "
                "when a historySyncEvidence row falls inside the export window (24 entries / 3 "
                "days). Sync the ring, then export again.")
        for a in archives:
            self.ring_ids.append(a.get("ringID", "?"))
            for rec in split_records(base64.b64decode(a.get("recordsBase64") or "")):
                self.records[rec.epoch_seconds] = rec
                self.record_source[rec.epoch_seconds] = "archive"
            cov = a.get("evidenceBlobCoverage") or {}
            if cov and not cov.get("isComplete", True):
                self.notes.append(
                    "NOTE: evidence blobs are an incomplete view of ring %s's archive "
                    "(%s records missing, longest run %ss). The archive itself is the source "
                    "used below." % (a.get("ringID", "?"),
                                     cov.get("missingFromEvidenceCount", "?"),
                                     cov.get("longestMissingRunSeconds", "?")))

        # Secondary source: per-drain slices. Union'd in only for counters the archive lacks,
        # so the archive (deduped, pruned, authoritative) always wins on a collision.
        added = 0
        for e in self.doc.get("historySyncEvidence") or []:
            for rec in split_records(base64.b64decode(e.get("rawRecordBlobBase64") or "")):
                if rec.epoch_seconds not in self.records:
                    self.records[rec.epoch_seconds] = rec
                    self.record_source[rec.epoch_seconds] = "evidence"
                    added += 1
        if added:
            self.notes.append("NOTE: %d record(s) recovered from per-drain evidence blobs that "
                              "the archive had already pruned." % added)

        for s in self.doc.get("samples") or []:
            if s.get("kind") != "spo2":
                continue
            start = parse_iso(s.get("start"))
            if start is None:
                continue
            # Stored as a 0..1 FRACTION (MetricKind.spo2 unit, BulkSleep.swift:1109).
            self.samples.append((int(start.timestamp()), int(round(float(s["value"]) * 100))))
        self.samples.sort()

    # -- derived views ------------------------------------------------------
    def spo2_readings(self) -> list:
        """[(epoch_seconds, percent, evidence|None)] from the RAW RECORDS, time-ordered.

        Records are the ground truth for this analysis because they alone carry the quality
        bytes. `samples[]` is used separately by --miss-report to measure what the alert engine
        actually sees, which is a strictly larger set (it includes live on-demand readings).
        """
        out = []
        for t in sorted(self.records):
            rec = self.records[t]
            v = rec.spo2
            if v is not None:
                out.append((t, v, rec.evidence()))
        return out


def load_export(path: str) -> Export:
    with open(path, "r", encoding="utf-8") as fh:
        return Export(json.load(fh), path)


# ---------------------------------------------------------------------------
# The proposed rule — mirrors HealthAlertEvaluator.lowSpO2 exactly
# ---------------------------------------------------------------------------
def verdict_for(trigger, readings, threshold, window, tolerance,
                min_run=PROPOSED_MIN_RUN, bad_fraction=PROPOSED_BAD_FRACTION) -> dict:
    """Evaluate ONE candidate reading. `trigger` is (t, percent, evidence|None).

    Mirrors the Swift algorithm step for step:
      2. neighbours are searched over the FULL series, never a freshness-filtered one
      4. the bad-epoch denominator is `resolved`, NOT the whole run
    """
    t0, p0, _ = trigger
    if not (p0 > 0 and p0 <= threshold):
        return {"outcome": "noCandidate", "runSize": 0, "nearestDelta": None,
                "evidenceEpochs": 0, "badEpochs": 0}

    neighbours = [r for r in readings if r[0] != t0 and abs(r[0] - t0) <= window]
    corroborators = [r for r in neighbours
                     if r[1] <= threshold and abs(r[1] - p0) <= tolerance]
    run = [trigger] + corroborators

    nearest = None
    if neighbours:
        closest = min(neighbours, key=lambda r: abs(r[0] - t0))
        nearest = abs(closest[1] - p0)

    if len(run) < min_run:
        outcome = "noCorroboration" if not neighbours else "corroborationDisagrees"
        return {"outcome": outcome, "runSize": len(run), "nearestDelta": nearest,
                "evidenceEpochs": 0, "badEpochs": 0}

    resolved = [r[2] for r in run if r[2] is not None]
    if not resolved:
        # MISS: corroboration carries it. Never more permissive than today's rule, which
        # fires on ONE reading with no evidence at all.
        return {"outcome": "fired", "runSize": len(run), "nearestDelta": nearest,
                "evidenceEpochs": 0, "badEpochs": 0}

    bad = sum(1 for ev in resolved if is_bad_epoch(ev))
    if bad > len(resolved) * bad_fraction:
        return {"outcome": "badEpochMajority", "runSize": len(run), "nearestDelta": nearest,
                "evidenceEpochs": len(resolved), "badEpochs": bad}
    return {"outcome": "fired", "runSize": len(run), "nearestDelta": nearest,
            "evidenceEpochs": len(resolved), "badEpochs": bad}


# ---------------------------------------------------------------------------
# Small stats helpers
# ---------------------------------------------------------------------------
def percentile(values: list, q: float):
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    pos = q * (len(s) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def mann_whitney_auc(a: list, b: list):
    """P(random a > random b), ties counted as half. Same statistic PROTOCOL.md 5.3 uses.

    Returns None when either group is empty — an AUC over an empty arm is not a number.
    """
    if not a or not b:
        return None
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = [0.0] * len(combined)
    i = 0
    while i < len(combined):
        j = i
        while j + 1 < len(combined) and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[k] = avg
        i = j + 1
    ra = sum(r for r, (_, g) in zip(ranks, combined) if g == 0)
    return (ra - len(a) * (len(a) + 1) / 2.0) / (len(a) * len(b))


def fmt(v, nd=1):
    if v is None:
        return "  -"
    return ("%%.%df" % nd) % v


# ---------------------------------------------------------------------------
# A. Incident autopsy
# ---------------------------------------------------------------------------
def report_incident(exp: Export, when: dt.datetime, window_min: int):
    centre = int(when.timestamp())
    half = window_min * 60
    keys = [t for t in sorted(exp.records) if abs(t - centre) <= half]

    print("=" * 100)
    print("A. INCIDENT AUTOPSY  %s  (+/- %d min, local time)"
          % (when.strftime("%Y-%m-%d %H:%M"), window_min))
    print("=" * 100)
    if not keys:
        print("NO RECORDS in this window. Either the archive has been pruned past it "
              "(retention is 30 h) or the export predates the incident.")
        # Fall back to stored samples so the window is not a dead end.
        near = [(t, p) for t, p in exp.samples if abs(t - centre) <= half]
        if near:
            print("\nStored SpO2 samples in the same window (no raw record, so no evidence):")
            for t, p in near:
                print("  %s  %3d%%" % (dt.datetime.fromtimestamp(t).strftime("%H:%M:%S"), p))
        return

    print("Every RECORD in the window, not just the SpO2 ones — the sleep-vitals/activity")
    print("alternation is itself a signal (PROTOCOL.md 5.3), and it is invisible if the")
    print("activity epochs are filtered out.\n")
    hdr = ("%-9s %-10s %5s %5s %-17s %6s %-24s %5s %4s %4s %5s %6s"
           % ("time", "layout", "spo2", "conf", "motion[10:15]", "spread",
              "magnitudes", "mZero", "hr", "hrv", "rr", "dt"))
    print(hdr)
    print("-" * len(hdr))
    prev = None
    for t in keys:
        r = exp.records[t]
        sp = r.spo2
        mark = " <<<" if sp is not None and sp <= DEFAULT_THRESHOLD else ""
        print("%-9s %-10s %5s %5s %-17s %6d %-24s %5s %4s %4s %5s %6s%s"
              % (r.local.strftime("%H:%M:%S"),
                 r.layout,
                 sp if sp is not None else "-",
                 r.confidence if r.confidence is not None else "-",
                 " ".join("%2d" % m for m in r.motion),
                 r.motion_spread,
                 " ".join("%4d" % m for m in r.magnitudes),
                 "yes" if r.magnitudes_all_zero else "no",
                 r.heart_rate if r.heart_rate is not None else "-",
                 r.hrv if r.hrv is not None else "-",
                 fmt(r.respiratory_rate),
                 (t - prev) if prev is not None else "-",
                 mark))
        prev = t

    lows = [(t, exp.records[t]) for t in keys
            if exp.records[t].spo2 is not None and exp.records[t].spo2 <= DEFAULT_THRESHOLD]
    if not lows:
        print("\nNo reading at or below the %d%% threshold in this window." % DEFAULT_THRESHOLD)
        return

    all_readings = exp.spo2_readings()
    print("\n--- The two questions this exists to answer -------------------------------------")
    for t, r in lows:
        ev = r.evidence()
        spreads = [exp.records[k].motion_spread for k in keys
                   if k != t and exp.records[k].layout != "idle"]
        med = statistics.median(spreads) if spreads else None
        print("\n  %s  SpO2 %d%%" % (r.local.strftime("%H:%M:%S"), r.spo2))
        print("    motion spread %d vs neighbour median %s  -> %s"
              % (r.motion_spread, fmt(med),
                 "ANOMALOUS" if med is not None and r.motion_spread > 2 * max(med, 1)
                 else "in family with its neighbours"))
        print("    resolvesStillness=%s  unworn=%s  magsZero=%s  conf=%s  -> epoch is %s"
              % (ev["resolvesStillness"], ev["unworn"], ev["magnitudesAllZero"],
                 ev["confidence"], "BAD" if is_bad_epoch(ev) else "clean"))
        before = [x for x in all_readings if x[0] < t]
        after = [x for x in all_readings if x[0] > t]
        if before:
            b = before[-1]
            print("    nearest SpO2 BEFORE: %d%% at -%s" % (b[1], mmss(t - b[0])))
        else:
            print("    nearest SpO2 BEFORE: none in the archive")
        if after:
            a = after[0]
            print("    nearest SpO2 AFTER : %d%% at +%s" % (a[1], mmss(a[0] - t)))
        else:
            print("    nearest SpO2 AFTER : none in the archive")
        v = verdict_for((t, r.spo2, ev), all_readings, DEFAULT_THRESHOLD,
                        PROPOSED_WINDOW, PROPOSED_TOLERANCE)
        print("    PROPOSED RULE (window=%ds tol=%d): %s  [run=%d resolved=%d bad=%d]"
              % (PROPOSED_WINDOW, PROPOSED_TOLERANCE, v["outcome"].upper(),
                 v["runSize"], v["evidenceEpochs"], v["badEpochs"]))
        print("    TODAY'S RULE: FIRES (any single reading <= %d)" % DEFAULT_THRESHOLD)


def mmss(seconds: int) -> str:
    return "%d:%02d" % (seconds // 60, seconds % 60)


# ---------------------------------------------------------------------------
# B. Cadence
# ---------------------------------------------------------------------------
def spo2_gaps(exp: "Export"):
    """Consecutive SpO2 reading gaps, SPLIT into cadence gaps and data gaps.

    A gap only measures CADENCE if the epoch record stream is continuous across it. The ring
    emits a 0x4c record every 150 s whenever it is worn and logging, so if the records between
    two SpO2 readings are present, the ring was awake and simply did not take a reading — that
    is duty cycle. If the records are MISSING, the ring was off-finger, charging, or the drain
    has a hole, and the interval says nothing about how often SpO2 is measured.

    Pooling the two is the mistake that would size `corroborationWindow` off an overnight
    off-finger stretch or a night->day boundary and silently make the window meaningless.
    Returns (cadence_gaps, data_gaps).
    """
    readings = exp.spo2_readings()
    cadence, data = [], []
    keys = set(exp.records)
    for i in range(len(readings) - 1):
        t0, t1 = readings[i][0], readings[i + 1][0]
        span = t1 - t0
        expected = max(1, span // STEP)
        present = sum(1 for k in range(t0 + STEP, t1, STEP) if k in keys)
        # >=90% of the intervening epochs present => the stream is continuous across the gap.
        (cadence if present >= 0.9 * (expected - 1) else data).append(span)
    return cadence, data


def report_cadence(exp: "Export"):
    print("\n" + "=" * 100)
    print("B. SpO2 CADENCE — this is what freezes `corroborationWindow`")
    print("=" * 100)
    readings = exp.spo2_readings()
    if len(readings) < 2:
        print("ABSENT: fewer than 2 SpO2-carrying records (%d). No cadence can be measured."
              % len(readings))
        return None

    cadence, data = spo2_gaps(exp)
    print("A gap measures CADENCE only when the 150 s epoch stream is continuous across it.")
    print("Gaps spanning missing records are OFF-FINGER / charging / drain holes and are")
    print("reported separately — pooling them would size the window off a night->day boundary.\n")
    print("n readings = %d   cadence gaps = %d   data gaps = %d"
          % (len(readings), len(cadence), len(data)))

    if not cadence:
        print("\nABSENT: no gap in this export has a continuous record stream across it, so the")
        print("cadence is UNMEASURED here. The %ds constant then rests on PROTOCOL.md 5.6.1's"
              % PROPOSED_WINDOW)
        print("single capture (20-30 min), not on this ring. Re-run with a fuller archive.")
        return None

    # Split the cadence gaps by regime. The sleep program alternates sleepVitals/activity 1:1
    # at 150 s epochs, so its SpO2 readings land ~300 s apart (PROTOCOL.md 5.3); the all-day
    # channel 0x03 is an order of magnitude sparser (5.6.1: "~10 min", capture shows 20-30).
    sleepish = [g for g in cadence if g <= 450]
    daytimeish = [g for g in cadence if g > 450]
    for name, arr in ((" <=450s  sleep-program cadence (ch 0x00)", sleepish),
                      ("  >450s  all-day cadence      (ch 0x03)", daytimeish)):
        if not arr:
            print("  %-40s ABSENT (0 gaps)" % name)
            continue
        print("  %-40s n=%-5d p50=%-7s p90=%-7s p99=%-7s max=%s"
              % (name, len(arr), fmt(percentile(arr, .50), 0), fmt(percentile(arr, .90), 0),
                 fmt(percentile(arr, .99), 0), fmt(max(arr), 0)))
    if data:
        print("  %-40s n=%-5d p50=%-7s max=%s   (EXCLUDED from the window)"
              % ("         data gaps (records missing)", len(data),
                 fmt(percentile(data, .50), 0), fmt(max(data), 0)))

    print("\n  histogram of CADENCE gaps (seconds):")
    buckets = [(0, 300), (300, 450), (450, 900), (900, 1800), (1800, 2700), (2700, 10 ** 9)]
    for lo, hi in buckets:
        n = sum(1 for g in cadence if lo <= g < hi)
        label = "%5d-%-6s" % (lo, ("inf" if hi > 10 ** 8 else str(hi)))
        print("    %s %-5d %s" % (label, n, "#" * min(n, 60)))

    print("\n  VERDICT: the window must cover the p99 of the WIDER cadence regime.")
    if daytimeish:
        p99 = percentile(daytimeish, .99)
        print("           all-day cadence p99 = %ss, max = %ss" % (fmt(p99, 0), fmt(max(daytimeish), 0)))
        print("           %ds covers p99: %s" % (PROPOSED_WINDOW,
              "YES" if PROPOSED_WINDOW >= p99 else "NO — RAISE THE CONSTANT to >= %d" % int(p99 + 0.5)))
        return p99
    print("           NO all-day cadence gaps observed (n=0). This export has no waking day")
    print("           with a continuous record stream, so the daytime cadence is UNMEASURED")
    print("           here and %ds still rests on 5.6.1's single capture. Re-run after a full"
          % PROPOSED_WINDOW)
    print("           waking day is in the archive — this is the constant that matters most.")
    return percentile(sleepish, .99) if sleepish else None


# ---------------------------------------------------------------------------
# C. Discriminator screen
# ---------------------------------------------------------------------------
def report_discriminators(exp: Export, threshold: int, min_low: int):
    readings = exp.spo2_readings()
    lows = [r for r in readings if r[1] <= threshold]
    normals = [r for r in readings if r[1] > threshold]

    print("\n" + "=" * 100)
    print("C. DISCRIMINATOR SCREEN — does any quality signal separate LOW from NORMAL?")
    print("=" * 100)
    print("AUC is P(low > normal) with ties at half — the same statistic PROTOCOL.md 5.3 used")
    print("to rank cues (the duty cycle scored 0.819-1.000; `confidence` scored 0.42/0.27, the")
    print("WORST of everything tested). 0.5 is chance. A signal near 0.5 has earned nothing.\n")
    print("n low (<=%d%%) = %d      n normal = %d" % (threshold, len(lows), len(normals)))

    if len(lows) < min_low:
        print("\nREFUSED: fewer than --min-low (%d) low readings. An AUC computed from %d "
              "positives is noise wearing a decimal point. Wear the ring longer, or lower "
              "--threshold to enlarge the low arm." % (min_low, len(lows)))
        return

    signals = [
        ("confidence byte [6]", lambda ev: ev["confidence"]),
        ("motion spread", lambda ev: ev["motionSpread"]),
        ("magnitudesAllZero", lambda ev: 1 if ev["magnitudesAllZero"] else 0),
        ("resolvesStillness", lambda ev: 1 if ev["resolvesStillness"] else 0),
    ]
    hdr = "%-22s %-28s %-28s %7s" % ("signal", "LOW  p50 / p90 (n)", "NORMAL  p50 / p90 (n)", "AUC")
    print("\n" + hdr)
    print("-" * len(hdr))
    for name, get in signals:
        a = [get(r[2]) for r in lows if r[2] is not None and get(r[2]) is not None]
        b = [get(r[2]) for r in normals if r[2] is not None and get(r[2]) is not None]
        auc = mann_whitney_auc(a, b)
        print("%-22s %-28s %-28s %7s"
              % (name,
                 "%s / %s (%d)" % (fmt(percentile(a, .5)), fmt(percentile(a, .9)), len(a)),
                 "%s / %s (%d)" % (fmt(percentile(b, .5)), fmt(percentile(b, .9)), len(b)),
                 fmt(auc, 3)))

    print("\n  READ IT THIS WAY: a signal only earns a GATE if its AUC is far from 0.5 AND the")
    print("  direction makes physical sense. `confidence` ships LOG-ONLY unless it clears that")
    print("  bar here — BulkSleep.swift:330-335 explicitly forbids baking in an untested")
    print("  weighting, and 5.3 already measured it as the weakest cue available.")


# ---------------------------------------------------------------------------
# D. Rule sweep
# ---------------------------------------------------------------------------
def report_sweep(exp: Export, threshold: int):
    readings = exp.spo2_readings()
    lows = [r for r in readings if r[1] > 0 and r[1] <= threshold]

    print("\n" + "=" * 100)
    print("D. RULE SWEEP — window x tolerance x badFraction")
    print("=" * 100)
    print("TODAY'S RULE fires on every one of these %d reading(s) at or below %d%%."
          % (len(lows), threshold))
    if not lows:
        print("Nothing to sweep: no reading crosses the threshold in this export.")
        return

    hdr = ("%7s %5s %6s | %6s %14s %12s %12s"
           % ("window", "tol", "badFr", "fired", "noCorrob", "disagree", "badMajority"))
    print("\n" + hdr)
    print("-" * len(hdr))
    for w in SWEEP_WINDOWS:
        for tol in SWEEP_TOLERANCES:
            for bf in SWEEP_BAD_FRACTIONS:
                counts = {"fired": 0, "noCorroboration": 0,
                          "corroborationDisagrees": 0, "badEpochMajority": 0}
                for r in lows:
                    v = verdict_for(r, readings, threshold, w, tol, bad_fraction=bf)
                    counts[v["outcome"]] = counts.get(v["outcome"], 0) + 1
                print("%7d %5d %6.2f | %6d %14d %12d %12d"
                      % (w, tol, bf, counts["fired"], counts["noCorroboration"],
                         counts["corroborationDisagrees"], counts["badEpochMajority"]))

    print("\n" + "-" * 100)
    print("THE REGRESSION LIST — every reading today's rule fires on that the PROPOSED")
    print("constants (window=%ds tol=%d minRun=%d badFr=%.2f) would SUPPRESS."
          % (PROPOSED_WINDOW, PROPOSED_TOLERANCE, PROPOSED_MIN_RUN, PROPOSED_BAD_FRACTION))
    print("Never truncated. EVERY entry must be individually defensible or a constant is wrong.")
    print("-" * 100)
    suppressed = []
    for r in lows:
        v = verdict_for(r, readings, threshold, PROPOSED_WINDOW, PROPOSED_TOLERANCE)
        if v["outcome"] != "fired":
            suppressed.append((r, v))
    if not suppressed:
        print("  (none — the proposed rule fires on everything today's rule fires on)")
    for (t, p, ev), v in suppressed:
        print("  %s  %3d%%  %-22s run=%d nearestDelta=%s resolved=%d bad=%d  "
              "[spread=%s stillness=%s conf=%s]"
              % (dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S"), p,
                 v["outcome"], v["runSize"],
                 v["nearestDelta"] if v["nearestDelta"] is not None else "-",
                 v["evidenceEpochs"], v["badEpochs"],
                 ev["motionSpread"] if ev else "-",
                 ev["resolvesStillness"] if ev else "-",
                 ev["confidence"] if ev else "-"))
    print("\n  %d of %d low reading(s) suppressed." % (len(suppressed), len(lows)))


# ---------------------------------------------------------------------------
# E. Miss report
# ---------------------------------------------------------------------------
def report_misses(exp: Export):
    print("\n" + "=" * 100)
    print("E. EVIDENCE LOOKUP MISS RATE")
    print("=" * 100)
    print("The alert engine reads `samples[]`, not records. A sample with no record resolves to")
    print("NO evidence. Live on-demand readings (RingSession.stopLiveMonitoring, from the 0x15")
    print("frame) have no 0x4c record BY CONSTRUCTION and can never resolve — which is exactly")
    print("why the rule fails OPEN when corroboration is present.\n")
    if not exp.samples:
        print("ABSENT: no SpO2 samples in this export.")
        return
    tol = STEP // 2
    hits, misses = [], []
    keys = sorted(exp.records)
    keyset = set(keys)
    for t, p in exp.samples:
        if t in keyset:
            hits.append((t, p))
            continue
        near = [k for k in keys if abs(k - t) <= tol]
        (hits if near else misses).append((t, p))
    n = len(exp.samples)
    print("samples=%d   resolved=%d (%.1f%%)   MISSED=%d (%.1f%%)   [tolerance +/-%ds]"
          % (n, len(hits), 100.0 * len(hits) / n, len(misses),
             100.0 * len(misses) / n, tol))
    if misses:
        print("\n  missed samples (first 40):")
        for t, p in misses[:40]:
            print("    %s  %3d%%" % (dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S"), p))
        if len(misses) > 40:
            print("    ... %d more" % (len(misses) - 40))


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------
def write_csv(exp: Export, path: str, threshold: int):
    readings = exp.spo2_readings()
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["local_time", "epoch_seconds", "spo2", "confidence", "motion_spread",
                    "resolves_stillness", "magnitudes_all_zero", "unworn", "bad_epoch",
                    "layout", "hr", "hrv", "proposed_outcome", "run_size", "nearest_delta"])
        for t, p, ev in readings:
            rec = exp.records[t]
            v = verdict_for((t, p, ev), readings, threshold,
                            PROPOSED_WINDOW, PROPOSED_TOLERANCE)
            w.writerow([dt.datetime.fromtimestamp(t).isoformat(), t, p,
                        ev["confidence"], ev["motionSpread"], ev["resolvesStillness"],
                        ev["magnitudesAllZero"], ev["unworn"], is_bad_epoch(ev),
                        rec.layout, rec.heart_rate, rec.hrv,
                        v["outcome"], v["runSize"], v["nearestDelta"]])
    print("\nwrote %s (%d rows)" % (path, len(readings)))


# ---------------------------------------------------------------------------
# --synthetic
# ---------------------------------------------------------------------------
def make_record(counter, hr=70, hrv=45, conf=6, rr8=120, spo2=97,
                motion=(1, 1, 1, 1, 1), mags=(0, 0, 0, 0, 0), info=0, idle=False):
    """Fabricate one 23-byte record. Mirrors the layouts in BulkSleep.swift:71-110."""
    raw = bytearray(RECLEN)
    raw[0:4] = int(counter).to_bytes(4, "big")
    if idle:
        raw[4], raw[5], raw[6], raw[7] = 0x05, 0x00, 0x0C, 0x00
        raw[8], raw[9] = 0x00, 0x0A
        raw[10:15] = bytes([1, 1, 1, 1, 1])
        return bytes(raw)
    raw[4], raw[5], raw[6], raw[7] = hr, hrv, conf, rr8
    raw[8] = spo2
    raw[9] = 0x0A
    raw[10:15] = bytes(motion)
    nibbles = []
    for m in mags:
        nibbles += [(m >> 8) & 0xF, (m >> 4) & 0xF, m & 0xF]
    nibbles.append(info & 0xF)
    for j in range(8):
        raw[15 + j] = (nibbles[2 * j] << 4) | nibbles[2 * j + 1]
    return bytes(raw)


def build_synthetic_export() -> dict:
    """Two known shapes, one of each verdict.

    NIGHT — a genuine 4-reading desaturation on the 300 s sleep cadence, quiet motion.
            Must FIRE: corroborated, agreeing inside tolerance, epochs clean.
    DAY   — an isolated 80% with 97%/96% neighbours 20 and 30 min away, moving epoch.
            Must be SUPPRESSED: the neighbours disagree by 16-17 points, far beyond tolerance.
    """
    base = 1_760_000_000 - EPOCH          # arbitrary fixed counter, no wall-clock dependency
    recs = []

    # --- night: alternate sleepVitals/activity every 150 s, SpO2 every 300 s ---
    night = base
    desat = [88, 87, 86, 88]
    for i in range(24):
        c = night + i * STEP
        if i % 2 == 0:
            k = i // 2
            v = desat[k - 4] if 4 <= k < 8 else 96
            recs.append(make_record(c, hr=58, hrv=52, conf=7, spo2=v, motion=(1, 1, 1, 1, 1)))
        else:
            recs.append(make_record(c, hr=59, hrv=51, conf=6, spo2=0x12, motion=(1, 1, 2, 1, 1)))

    # --- day: the all-day channel 0x03. PROTOCOL.md 5.6.1 — activity-HR epochs at the normal
    # 150 s cadence, with a periodic daytime SpO2 reading interspersed. The record stream is
    # CONTINUOUS; only the SpO2 readings are sparse. That distinction is the whole point of
    # `spo2_gaps`, so the fixture has to reproduce it or the cadence path is never exercised.
    # SpO2 at +0 (97%), +1200 s (80%, hand moving), +3000 s (96%) — 20 and 30 min apart,
    # matching the real capture 5.6.1 prints (09:52/10:12/10:42/11:02/11:22).
    day = base + 40_000
    day_spo2 = {0: (97, (3, 5, 4, 6, 3)),
                1200: (80, (14, 40, 11, 33, 8)),
                3000: (96, (4, 5, 4, 5, 4))}
    for i in range(25):
        off = i * STEP
        if off in day_spo2:
            v, mot = day_spo2[off]
            recs.append(make_record(day + off, hr=95 if v == 80 else 83, hrv=42,
                                    conf=3 if v == 80 else 6, spo2=v, motion=mot,
                                    mags=(2100, 0, 97, 1302, 0) if v == 80 else (97, 0, 194, 0, 0)))
        else:
            recs.append(make_record(day + off, hr=84, hrv=40, conf=5, spo2=0x12,
                                    motion=(4, 7, 5, 9, 4), mags=(194, 97, 0, 1302, 0)))

    blob = base64.b64encode(b"".join(recs)).decode()
    iso = lambda t: dt.datetime.fromtimestamp(t + EPOCH, dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    samples = []
    for r in split_records(b"".join(recs)):
        if r.spo2 is not None:
            samples.append({"kind": "spo2", "start": iso(r.counter), "end": iso(r.counter),
                            "value": r.spo2 / 100.0})
    # One live on-demand reading with NO record — the miss population.
    samples.append({"kind": "spo2", "start": iso(day + 5000), "end": iso(day + 5000),
                    "value": 0.95})

    return {
        "schemaVersion": 3,
        "exportedAt": iso(day + 6000),
        "samples": samples,
        "epochArchive": [{
            "ringID": "SYNTHETIC-RING",
            "recordCount": len(recs),
            "firstEpoch": iso(recs[0][0:4] and int.from_bytes(recs[0][0:4], "big")),
            "lastEpoch": iso(int.from_bytes(recs[-1][0:4], "big")),
            "recordsBase64": blob,
            "evidenceBlobCoverage": {"archiveRecordCount": len(recs), "evidenceRecordCount": 0,
                                     "missingFromEvidenceCount": len(recs),
                                     "longestMissingRunSeconds": 0, "isComplete": False},
        }],
        "historySyncEvidence": [],
    }


def run_synthetic() -> int:
    doc = build_synthetic_export()
    tmp = os.path.join(tempfile.mkdtemp(prefix="spo2_autopsy_"), "export.json")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    print("synthetic export written to %s\n" % tmp)

    exp = load_export(tmp)
    readings = exp.spo2_readings()
    lows = [r for r in readings if r[1] <= DEFAULT_THRESHOLD]

    failures = []

    night_lows = [r for r in lows if r[1] in (86, 87, 88)]
    if not night_lows:
        failures.append("no synthetic overnight desaturation was decoded")
    for r in night_lows:
        v = verdict_for(r, readings, DEFAULT_THRESHOLD, PROPOSED_WINDOW, PROPOSED_TOLERANCE)
        if v["outcome"] != "fired":
            failures.append("overnight desat %d%% should FIRE, got %s" % (r[1], v["outcome"]))

    day_low = [r for r in lows if r[1] == 80]
    if not day_low:
        failures.append("the synthetic isolated daytime 80% was not decoded")
    for r in day_low:
        v = verdict_for(r, readings, DEFAULT_THRESHOLD, PROPOSED_WINDOW, PROPOSED_TOLERANCE)
        if v["outcome"] == "fired":
            failures.append("isolated daytime 80% should be SUPPRESSED, got fired")
        else:
            print("  daytime 80%% -> %s (run=%d, nearestDelta=%s)  OK"
                  % (v["outcome"], v["runSize"], v["nearestDelta"]))

    # The record-level predicates must agree with the bytes we fabricated.
    for t, p, ev in day_low:
        if ev["resolvesStillness"]:
            failures.append("the moving daytime epoch should NOT resolve stillness "
                            "(spread=%d)" % ev["motionSpread"])
        if not is_bad_epoch(ev):
            failures.append("the moving daytime epoch should be a BAD epoch")
    for t, p, ev in night_lows:
        if not ev["resolvesStillness"]:
            failures.append("a quiet overnight epoch should resolve stillness")
        if is_bad_epoch(ev):
            failures.append("a quiet overnight epoch should NOT be a bad epoch")

    # Nibble packing round-trip.
    probe = Record(make_record(0, mags=(4095, 0, 2100, 1, 194), info=4))
    if probe.magnitudes != [4095, 0, 2100, 1, 194]:
        failures.append("12-bit magnitude packing round-trip failed: %s" % probe.magnitudes)
    if probe.info_nibble != 4:
        failures.append("info nibble round-trip failed: %s" % probe.info_nibble)
    if not Record(make_record(0, idle=True)).layout == "idle":
        failures.append("the idle template did not classify as idle")

    print()
    report_cadence(exp)
    report_sweep(exp, DEFAULT_THRESHOLD)
    report_misses(exp)

    print("\n" + "=" * 100)
    if failures:
        print("SELF-TEST FAILED (%d):" % len(failures))
        for f in failures:
            print("  - %s" % f)
        return 1
    print("SELF-TEST PASSED — the harness reproduces both known shapes.")
    print("=" * 100)
    return 0


# ---------------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Autopsy a low-SpO2 alert against the raw 0x4c epoch behind it.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--export", help="the app's JSON export")
    ap.add_argument("--incident", help='local time of the alert, "YYYY-MM-DD HH:MM"')
    ap.add_argument("--window-min", type=int, default=90,
                    help="half-width of the incident window, minutes (default 90)")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help="low-SpO2 threshold %% (default %d, the shipped value)" % DEFAULT_THRESHOLD)
    ap.add_argument("--min-low", type=int, default=5,
                    help="refuse an AUC computed from fewer low readings than this (default 5)")
    ap.add_argument("--sweep", action="store_true", help="run the rule grid + regression list")
    ap.add_argument("--miss-report", action="store_true", help="evidence lookup miss rate")
    ap.add_argument("--csv", help="write the per-reading table to this path")
    ap.add_argument("--synthetic", action="store_true", help="self-test on a fabricated export")
    args = ap.parse_args(argv)

    if args.synthetic:
        return run_synthetic()
    if not args.export:
        ap.error("one of --export or --synthetic is required")
    if not os.path.exists(args.export):
        print("no such file: %s" % args.export, file=sys.stderr)
        return 2

    exp = load_export(args.export)
    print("export: %s" % exp.path)
    print("rings : %s" % (", ".join(exp.ring_ids) or "(none)"))
    print("raw records: %d      SpO2-carrying: %d      stored SpO2 samples: %d"
          % (len(exp.records), len(exp.spo2_readings()), len(exp.samples)))
    if exp.records:
        ks = sorted(exp.records)
        print("archive span: %s .. %s"
              % (dt.datetime.fromtimestamp(ks[0]).strftime("%Y-%m-%d %H:%M"),
                 dt.datetime.fromtimestamp(ks[-1]).strftime("%Y-%m-%d %H:%M")))
    for n in exp.notes:
        print("  " + n)
    print()

    if args.incident:
        try:
            when = dt.datetime.strptime(args.incident, "%Y-%m-%d %H:%M")
        except ValueError:
            print('--incident must look like "2026-08-12 19:34"', file=sys.stderr)
            return 2
        report_incident(exp, when, args.window_min)

    report_cadence(exp)
    report_discriminators(exp, args.threshold, args.min_low)
    if args.sweep:
        report_sweep(exp, args.threshold)
    if args.miss_report:
        report_misses(exp)
    if args.csv:
        write_csv(exp, args.csv, args.threshold)
    return 0


if __name__ == "__main__":
    sys.exit(main())

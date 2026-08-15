#!/usr/bin/env python3
"""Cross-language parity check: `ringconn_sleep_fit.py` (the Python PORT of `SleepStaging.swift`,
used to fit `SleepStaging.Tuning` against captured RingConn ground truth) against the actual Swift
classifier, on one shared synthetic night.

The counterpart lives in
`ios/OpenCircuitKit/Tests/OpenCircuitKitTests/SleepStagingSwiftPythonParityTests.swift` — same 191-
epoch byte sequence, same expected awake-epoch set. The set below was established by RUNNING BOTH
sides (this script, and `swift test --filter SleepStagingSwiftPythonParityTests`) and recording
where they agreed, not derived by hand. It exercises `markLeadInWakeOnset`, `rescueSecondBoutHRWake`
and `protectsLeadingHRWake` — the three passes newly ported alongside this file — because together
they cover every AWAKE-mask pass the port previously lacked.

If a future change to either side's staging moves this fixture's output, update BOTH files together
and re-run both checks — a silent divergence here means every `ringconn_sleep_fit.py` fit is
approximate without anyone noticing (which is exactly what the pre-existing `onsetSettleFraction`
drift, corrected alongside this file, was).

Usage: python3 test_sleep_fit_swift_parity.py
"""
from __future__ import annotations

from ringconn_sleep_fit import Epoch, Tuning, SYNC_EPOCH, prepare_night, classify_prepared

STEP = 150
BASE_COUNTER = 0x0c220000   # matches SleepStagingSwiftPythonParityTests.swift's `base`


def build_fixture():
    """Byte-equivalent (via decoded fields, not raw bytes) to the Swift fixture's `fixture()`:
      [0..14)    quietA      -- floor HR (50), asleep on its own
      [14..28)   leadin      -- elevated HR (95), no real evening->floor descent
      [28..108)  sleep1      -- 80 real asleep epochs (floor HR)
      [108..111) getup       -- real motion, genuinely awake
      [111..131) secondbout  -- motion-free, HR 72 (floor+22, inside the rescue band)
      [131..191) sleep2      -- 60 real asleep epochs closing the night
    """
    epochs = []
    c = BASE_COUNTER

    def add(n, hr, motion=(1, 1, 1, 1, 1), layout="sleepVitals"):
        nonlocal c
        for _ in range(n):
            epochs.append(Epoch(counter=c, time=c + SYNC_EPOCH, layout=layout,
                                 hr=hr, hrv=(60.0 if layout == "sleepVitals" else None),
                                 spo2=None, rr=None, motion=list(motion)))
            c += STEP

    add(14, 50.0)                                                    # quietA
    add(14, 95.0)                                                    # leadin
    add(80, 50.0)                                                    # sleep1
    add(3, None, motion=(60, 60, 60, 60, 60), layout="activity")     # getup
    add(20, 72.0)                                                    # secondbout
    add(60, 50.0)                                                    # sleep2
    return epochs


EXPECTED_AWAKE_INDICES = set(range(0, 28)) | set(range(108, 111))


def main():
    epochs = build_fixture()
    prepared = prepare_night(epochs)
    assert len(prepared) == 1, f"expected one fragment (no motion-detected split), got {len(prepared)}"
    pf = prepared[0]
    assert len(pf.counters) == 191, f"expected 191 in-block rows, got {len(pf.counters)}"

    labels = classify_prepared(pf, Tuning())
    got_awake = {(counter - BASE_COUNTER) // STEP for counter, cls in labels.items() if cls == "awake"}

    missing = sorted(EXPECTED_AWAKE_INDICES - got_awake)
    extra = sorted(got_awake - EXPECTED_AWAKE_INDICES)
    if missing or extra:
        print("PARITY MISMATCH")
        if missing:
            print(f"  expected awake but got asleep: {missing}")
        if extra:
            print(f"  expected asleep but got awake: {extra}")
        raise SystemExit(1)
    print(f"PARITY OK — {len(got_awake)} awake epochs match "
          "SleepStagingSwiftPythonParityTests.swift exactly")


if __name__ == "__main__":
    main()

# Low-SpO2 health alert — plan of record

There was no dedicated doc for this feature before this one — the de-facto plan of record was the
`4d0b884` commit message plus the doc comments on `SpO2AlertPolicy` in
`ios/OpenCircuitKit/Sources/OpenCircuitKit/HealthAlerts.swift`. This file is the missing piece:
what the rule does, why, and what's still unconfirmed. Read `docs/PENDING_VALIDATION.md` for the
open/settled claims — this doc is the reasoning behind them, not a duplicate of them.

## 1. The 2026-08-17 incident

A "Low blood oxygen (90%)" notification arrived at **20:42** about a reading taken at **08:45** —
almost 12 hours late. Pulled and confirmed from the device
(`desktop/device_alert_audit.py --pull`):

```
[Aug 17 20:42:12] lowSpO2 FIRED  reason=fired  value=90
                  reading=Aug 17 08:45:51  run=2  evidence=0/0 bad
```

Investigation found **three independent defects**, not one. Fixing only one would have left
either a live false alarm or a live lateness bug in place.

## 2. D1 — the corroboration gate was blind to healthy neighbours (the false positive)

The run that "corroborated" this alert:

```
08:45:51  90%   <- trigger
08:46:08  98%      17 seconds later
08:54:35  98%
08:54:52  90%   <- "corroborator"
```

Both 90% readings sit **17 seconds** from a 98% reading in the same on-demand measurement burst.
`HealthAlertEvaluator.evaluateOne` filtered `neighbours` to `percent <= thresholdPercent` *before*
the agreement test, so a healthy reading seconds away was invisible to it. It paired one 90 from
burst A with one from burst B, found Δ = 0, and fired — while 5 of the 7 readings in the
corroboration window were 94–98%.

This is the same shape as the wet-hands 88% that motivated the original corroboration rule
(`4d0b884`). The stricter gate did not hold, because it was never looking at the readings that
contradict a candidate.

**Fix**: `SpO2AlertPolicy.isContradicted(_:by:)` — a candidate is rejected as a burst artifact if
a HIGHER reading sits within `burstWindow` (60s) and exceeds it by `burstContradictionDelta` (4
points). SIGNED on purpose: a nearby *lower* reading is a deepening desaturation, not evidence
against the candidate. Applied to both trigger candidacy and the corroborator pool — an artifact
cannot corroborate another candidate either, or the defect reopens one level up.

### Why this can't touch overnight desaturation detection (#91)

🟢 MEASURED (2026-08-18, this wearer's own 6-day export, 1091 SpO2 samples):

| Fact | Value |
|---|---|
| Inter-sample gaps ≤ 60s ("bursts") | 100 of 1090 |
| Longest tight gap in the whole corpus | 56.6s |
| Sleep-program cadence (channel `0x00`) | ~300s |
| All-day cadence (channel `0x03`) | > 310s |
| Tight pairs with \|Δ\| ≥ 4 points | 22 |
| **Tight pairs between 23:00 and 07:00** | **0** |

Bursts are exclusively a daytime on-demand phenomenon across the whole corpus, and a 60s window
sits ~5× below the tightest legitimate cadence (300s). This is provable by construction, not by
hope — the same trap `corroborationWindow`'s own doc comment warns about ("a fix that suppresses
the false alarm by deleting the channel it came from").

### Constant confidence

- `burstWindow = 60` — 🟢 MEASURED, margin above the corpus max (56.6s), well below the sleep
  cadence.
- `burstContradictionDelta = 4` — 🟡 REASONED, not sourced. Set one point above
  `agreementTolerance = 2`. ⚠️ **Deviates from the NOOP/Strand citation already used for
  `agreementTolerance`** — that source puts conflict at ≥ 5, not ≥ 4. 4 was chosen as the smallest
  value strictly above this codebase's own agreement bound, not because NOOP supports it
  specifically. The corpus does not sharply determine this: 4 and 5 produce *identical* outcomes
  on every logged decision to date. Fitted on one wearer.

## 3. D2 — on-demand readings can never be quality-gated (the fail-open path)

`evidence=0/0` on the incident row is not a lookup miss. On-demand measurements have **no `0x4c`
epoch record by construction**, so they always take the documented fail-open path in
`evaluateOne`. The entire epoch-quality half of `4d0b884` is structurally inapplicable to exactly
the population that produced this false positive.

🟡 **Measured twice now, both well above the original estimate**: the evidence-lookup miss rate
was 25.8% (2026-08-14, possibly inflated by that day's manual testing) and **30.7%** (2026-08-18,
ordinary wear) against an original citation of 5.3%. See `docs/PENDING_VALIDATION.md` →
`spo2-evidence-miss-rate` — fail-open is load-bearing for roughly a third of SpO2 samples, not a
rare diagnostic corner, and the original 5.3% figure needs re-deriving from source.

**Not fixed by making a miss fatal.** The doc comment on `evaluateOne`'s fail-open branch explains
why: it would permanently un-alert every live on-demand measurement, any differently-namespaced
ring, and anything after a UserDefaults reset — a silent, unbounded false negative created by a
diagnostic detail. D1's burst-artifact rejection supplies the discriminator this population was
missing instead: an on-demand reading can still be rejected as an artifact even with no epoch
evidence at all, because burst rejection reads only the reading series, not the archive.

## 4. D3 — a reading stayed alertable for up to 12 hours (the lateness)

`HealthNotificationCenter.instantLookback = 12 * 3600` with **no device-timestamp freshness
gate**, and `lastFired` only advances for alerts that actually fire. A minute-by-minute simulation
over the real Aug 17 series showed `08:45:51` only became the surviving worst-first candidate at
**20:19**, when the earlier `08:18:11` candidate aged out of the 12h window — the next background
pass (20:42:11) fired it. The trigger silently *rotates* as older candidates expire; nothing marks
a suppressed reading as "already looked at."

**Why not a simple max-age cap.** The measured overnight arrival latency on this device runs up to
**6h19m** (2026-08-15: reading 02:03:56, first evaluation 08:22:50 — the ring buffers overnight,
the phone only evaluates after the morning sync). A cap tight enough to stop a 12h-late banner
would silence genuine overnight desaturations that legitimately take hours to reach the phone.

**Fix — first-sighting, not age.** `HealthNotificationStore`'s considered-SpO2 ledger
(`alerts.lowSpO2.consideredReadings`, app target) records every reading time some earlier
`evaluate()` pass has looked at, independent of what that pass decided. A fired verdict may post
only if its trigger has never been seen before. The KIT half of this (`alreadyConsidered: Set<Date>`
on `HealthAlertEvaluator.lowSpO2`) excludes already-seen readings from candidacy as a **trigger**
only — they remain fully eligible as **corroborators**, so a genuine event where the corroborator
arrives on a later pass still fires (the corroborator, not the stale reading, becomes the trigger).

A hard backstop, `SpO2AlertPolicy.maxNotifiableAge` (8h, 🟡 one device — ~27% headroom above the
measured 6h19m worst case), still catches the pathological case: the phone was off long enough
that even a first sighting is very stale.

**The insertion rule is not unconditional.** A verdict that fires but is held by the shared
quiet-hours/backoff gate — or whose notification authorization is denied — must NOT have its
trigger inserted into the considered ledger, or the self-healing retry every other suppression
reason already gets from `lastFired`/`notBefore` would be silently lost for this one path.
`HealthNotificationCenter.evaluate` defers that insertion until delivery is actually confirmed
(after `ensureAuthorized()` succeeds and the notification is in `fire`); everything else in the
evaluation window is marked considered unconditionally, whether or not it played any part in the
pass's verdict.

**Cold start.** The ledger key absent from UserDefaults means "never written" — the app seeds it
with every reading currently in view and posts nothing that pass, so an app upgrade can never
surface a stale banner for a reading that predates the fix.

## 5. Verification

`desktop/device_alert_audit.py` mirrors D1 (burst-artifact rejection) in Python so a re-derivation
against a real device snapshot can be checked without a full app rebuild. It does **not** mirror
D3 (first-sighting) — that is app-side evaluation-pass history, not a function of the reading
series alone, and re-deriving it would mean replaying every past `evaluate()` pass. A row this
tool re-derives as `fired` that the app actually suppressed as `alreadySeen`/`tooOld` is a known,
stated gap (see the tool's own header comment), not silent drift.

The `--not-before <ISO8601>` flag (added alongside this fix) replays history against a watermark
from *before* an incident, because the device's live `lastFired` watermark makes every historical
row vacuously re-derive as `noCandidate` once it has advanced past them — that artifact is the
standing `re-derivation mismatches` count on an unmodified pull, and it discriminates nothing on
its own.

A/B against the real 2026-08-17 snapshot, both rules evaluated at the same pre-incident
`notBefore` (2026-08-13 15:32:25): **exactly one row changes fired-status** —
`[Aug 17 20:42] fired → noCorroboration`. Every other change across the 12 logged decisions is a
reason-string or reported-trigger detail on an already-suppressed row (worst-first re-selecting a
different non-artifact candidate), not a new suppression or a lost alert.

See `docs/PENDING_VALIDATION.md` → `spo2-burst-fix-real-world` for what real-world confirmation is
still outstanding: a genuine overnight desaturation firing under the fixed rule, a first-sighting
notification actually posting, and a quiet week with no new daytime false positive.

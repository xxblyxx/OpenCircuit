# CLAUDE.md — OpenCircuit

> ## 🚫 NO UPSTREAM CONTRIBUTIONS — this fork does not talk back
>
> This is a **personal learning fork** (`xxblyxx/OpenCircuit`) of
> `perezjuanj/OpenCircuit`. The owner is experimenting on his own ring and does not
> want to add noise to the maintainer's process.
>
> **Never** open a pull request against upstream, push to an upstream branch, or
> file/comment on an upstream issue. Do not run `gh pr create` or any equivalent
> targeting `perezjuanj/OpenCircuit`, and **do not suggest it** — not even for a fix
> that would obviously benefit upstream. If something here would help them, say so
> in a doc and leave it at that.
>
> The `upstream` remote is **read-only**: `git fetch upstream` and merging to stay
> current is expected and encouraged. Nothing flows the other way.
>
> **This is not about secrecy.** This fork is public and that is fine — pushing to
> `origin` (`xxblyxx/OpenCircuit`) is normal and expected. The rule is about not
> creating work for the upstream maintainer, nothing more.
>
> Where a doc recommends contributing something back, that recommendation is
> **void** — this rule wins.

Project context for Claude Code. Read this and `docs/ROADMAP.md` first.

## Goal
Replicate [openwhoop](https://github.com/bWanShiTong/openwhoop)'s local-first health
extraction for the **RingConn Gen 2** smart ring and write all metrics to **Apple
Health** — no cloud, no subscription.

## Where we are
- **Phase 1 (protocol RE) is the gating work.** The RingConn Gen 2 BLE protocol is
  almost entirely undocumented and reportedly not fully GATT-compatible.
- `desktop/` holds a working Python + `bleak` workbench to decode it. The living
  spec it feeds is `docs/PROTOCOL.md`.
- The **make-or-break unknown**: is the BLE link encrypted with a cloud-issued key?
  If so, offline decoding stalls. Answer this before deep work.

## Hard constraints (don't relitigate)
- HealthKit is **iOS-only**; iOS BLE must use **CoreBluetooth** → the data-writing
  app must be **native Swift**. openwhoop's Rust/btleplug stack cannot be reused on
  iOS. The desktop workbench is throwaway tooling for decoding only.
- Only openwhoop's **analytics** (sleep/HRV/strain) port across devices; its
  transport + parser are Whoop-specific and rewritten here.

## Decisions already made
- Desktop RE client first (Python + bleak), iOS app after the protocol is proven.
- Analytics ported **natively to Swift** (no Rust/UniFFI).
- User has the ring and can capture Android HCI snoop logs.

## Map
| Path | What |
|---|---|
| `desktop/opencircuit/` | RE workbench: scan/enumerate/listen/replay/decode-log/guess-checksum |
| `docs/PROTOCOL.md` | Living protocol spec (the Phase 1 deliverable) |
| `docs/REVERSE_ENGINEERING.md` | Capture + decode workflow |
| `docs/RUNBOOK_OVERNIGHT_TEMP.md` | **Overnight capture for skin temp / sleep stages / HRV (#7,#9,#12)** |
| `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` | **Capture RingConn's computed hypnogram (`sleepPhases`) via mitmproxy → fit our staging to it** |
| `docs/RUNBOOK_OSA_APNEA.md` | **OSA sleep-apnea (#91) — capture cracked (start `05 22 01`, dense PPG `0x48`), decode→AHI parked; forward plan** |
| `desktop/ringconn_sleep_fit.py` | Supervised-fit harness: align our epochs to RingConn `sleepPhases`, fit `SleepStaging.Tuning` (`--synthetic` to demo) |
| `docs/HEADACHE_SIGNALS.md` | **Headache signals (#183) — plan of record. Read §1 first: the honest accuracy arithmetic is why the alert must EARN its way on per-user** |
| `docs/RUNBOOK_HEADACHE_VALIDATION.md` | **On-device validation for #183 (freeze / migration / HealthKit) + the tester-facing "What to Test"** |
| `docs/WIDGETS_HOME_SCREEN.md` | **Home Screen widgets — plan of record (PROPOSED, not built). Read §1: the App-Group/SwiftData hazard and why a read-only snapshot sidesteps it** |
| `docs/HEALTHKIT_MAPPING.md` | Each metric → HealthKit type |
| `docs/BACKGROUND_SYNC.md` | **How the official RingConn app syncs to Apple Health without being opened (RE'd blueprint) → mapped to our BGTask + CoreBluetooth-restoration implementation (#119); deliberate divergences + validation runbook** |
| `docs/HANDOFF_MACOS_IOS.md` | **Pickup instructions for the iOS work on macOS** |
| `docs/ROADMAP.md` | Phases + risks |
| `ios/` | Swift app (Phase 3+, not yet created) |

## Build & deploy to the iPhone
**Not using TestFlight right now.** Build locally and install straight to the paired
phone over the wire — no App Store Connect key, no interactive Xcode sign-in needed.

> ⚠️ Always regenerate with **`--spec project.local.yml`**. A bare `xcodegen generate`
> rewrites the project with upstream's paid team (`765RD9BJ8C`), which this Mac has no
> account for → signing dies with *"No Account for Team"*. `project.local.yml`
> (gitignored) includes `project.yml` and overrides only signing: personal team
> `KNK78KA6NE`, bundle id `com.bly.opencircuit`.

```bash
cd ios
DEV=819D37A3-B45A-56CF-9FEC-40D460EC74F8   # Jedi Master's iPhone — `xcrun devicectl list devices`
xcodegen generate --spec project.local.yml
xcodebuild -project OpenCircuit.xcodeproj -scheme OpenCircuit -configuration Debug \
  -destination "id=$DEV" -allowProvisioningUpdates build
APP="$(xcodebuild -project OpenCircuit.xcodeproj -scheme OpenCircuit -configuration Debug \
  -destination "id=$DEV" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/OpenCircuit.app"
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" com.bly.opencircuit
```

- Simulator instead: `-destination 'platform=iOS Simulator,name=iPhone 17'` (no "iPhone 16"
  simulator exists on this Mac).

## Conventions
- Captures in `desktop/captures/` are gitignored — they hold real health data. Commit
  decoded *findings* only, never raw captures.
- Tag every protocol claim 🟢 confirmed / 🟡 probable / 🔴 guess, with its source.

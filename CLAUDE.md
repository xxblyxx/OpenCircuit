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

## Validating what we ship (`docs/PENDING_VALIDATION.md`)
Some fixes here **cannot be checked when they land** — the ring produces the confirming data
hours or days later, and some only when the wearer's body does the thing the code watches for.
That gap is how a fix quietly becomes folklore: carefully reasoned, tests green, never once
observed working.

- **Shipping something whose correctness rests on data that doesn't exist yet? Add an entry
  before calling the work done.** The file's table lists the required fields; the load-bearing
  ones are `needs` (the data event that must occur), `check` (the exact command), `passes-if`
  (decided *now*, not after seeing the result), and `check-after` (earliest useful date).
- A `SessionStart` hook (`.claude/settings.json` → `scripts/pending-validation.py`) surfaces
  ripe entries at the start of every session. When it does: **ask whether to validate now.**
  Don't start pulling data unprompted, and don't let it displace what the session is for.
- Validated → move the entry to `## Settled` with what was actually observed. Data still absent
  → bump `check-after`. Never delete an entry that was never checked.
- Keep it to **claims awaiting evidence**. It is not a TODO list; general follow-ups go in
  issues. Once it fills with wishlist items the session-start reminder becomes wallpaper.

## Usage guard — know the budget *before* starting (`scripts/usage-guard.py`)
Running out of plan usage halfway through a task is expensive in a specific way: the reasoning
lives in a context that is about to become unusable, and the work has to be re-derived after the
reset. The global `usage-monitor` skill answers "check usage" — but only when asked, which is
*after* committing to the work. So the number arrives unprompted instead:

- **`SessionStart`** (`--mode session`) reports both windows every session. **Include the two
  numbers in your first reply**, in one line, then get on with what the session is for.
- **`UserPromptSubmit`** (`--mode prompt`) is silent until either window hits **80%**, then warns
  at most once per 30 min. That silence is what keeps the warning worth reading.
- At ≥80%: **tell the user before starting substantial work** and offer (a) proceed, (b) cheaper
  model, (c) the `usage-monitor` skill — which writes a resume doc and schedules an auto-resume
  agent for the reset time.
- Numbers come from Anthropic's `/api/oauth/usage` (same source as `/usage`), cached in
  `~/.claude/vscode-claude-status-cache.json` and refreshed at most every 15 min. Never use
  `ccusage` — it estimates against a guessed limit and won't match `/usage`.
- Failures are reported, not swallowed (same rule as `pending-validation.py`): a guard that goes
  quiet still gets trusted. Run `scripts/usage-guard.py --report` to check it by hand.

## git branching
Maintain the integrity of `master` — always create a branch to work from. Before
implementing any code change, if you are on `master`, ask the user whether to create
a branch and recommend a branch name. Do not start editing until that's settled.

- This applies to code changes, not to docs-only tweaks the user asked for directly.
- Branch names follow the existing convention: `feat/…`, `fix/…`, `docs/…`.
- Merging back to `master` is the user's call — don't merge without being asked.
- (Reminder: `origin` is `xxblyxx/OpenCircuit`. Branches never go to `upstream` —
  see the no-upstream-contributions rule at the top.)

## Model tiering
Opus (main thread) decides; delegated subagents in `.claude/agents/` do the work; the
Opus advisor is Sonnet's escalation path back to Opus without leaving execution mode.

- **Opus (main thread)** — read the problem, design, write plans, review diffs, and make
  the calls that need taste: protocol confidence tags, sleep-staging tuning, whether a
  `PENDING_VALIDATION` entry actually passed.
- **Delegate by default, don't ask first** — repo search (`Explore`/`locate`), builds and
  tests and capture/audit script runs (`implementer`/`chore-runner`), and all reading
  under `refs/` (`refs-reader`).
- **Never on Opus** — bulk grep, `xcodebuild`, `pytest`, `--pull` runs, AGPL/PolyForm
  source reading. These belong on the agents above, not the main thread.
- **`locate` vs `Explore`**: `locate` only when the complete answer is a file list
  producible by glob/grep alone. The moment answering needs reading a file to understand
  what the code *does*, it's `Explore`. When in doubt, `Explore`.
- **Accuracy rule** — a delegated result is evidence, not truth. Cross-check a surprising
  `Explore` or `refs-reader` finding against the file before it becomes a 🟢 protocol
  claim or a plan premise.
- **Belt-and-braces** — pass `model` explicitly on Agent invocations too, in case an
  agent-name override (e.g. `Explore` shadowing the built-in) is ever rejected.

## Map
| Path | What |
|---|---|
| `.claude/agents/` | **Model-tiered subagents** — `Explore`/`locate` (search), `implementer` (write code), `refs-reader` (mine `refs/`), `chore-runner` (run+report). See "Model tiering" above |
| `desktop/opencircuit/` | RE workbench: scan/enumerate/listen/replay/decode-log/guess-checksum |
| `docs/PROTOCOL.md` | Living protocol spec (the Phase 1 deliverable) |
| `docs/REVERSE_ENGINEERING.md` | Capture + decode workflow |
| `docs/RUNBOOK_OVERNIGHT_TEMP.md` | **Overnight capture for skin temp / sleep stages / HRV (#7,#9,#12)** |
| `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` | **Capture RingConn's computed hypnogram (`sleepPhases`) via mitmproxy → fit our staging to it** |
| `docs/RUNBOOK_OSA_APNEA.md` | **OSA sleep-apnea (#91) — capture cracked (start `05 22 01`, dense PPG `0x48`), decode→AHI parked; forward plan** |
| `desktop/ringconn_sleep_fit.py` | Supervised-fit harness: align our epochs to RingConn `sleepPhases`, fit `SleepStaging.Tuning` (`--synthetic` to demo) |
| `desktop/device_alert_audit.py` | **Did the shipped alert rule decide correctly?** `--pull` over USB, then re-derives every logged health-alert decision from the phone's own SwiftData samples + raw epoch archive |
| `docs/SLEEP_AWAKE_RESOLUTION.md` | **Why brief mid-night awakenings don't show on the hypnogram. 🟢 MEASURED: we emit ZERO interior awake segments; Whoop 16.7/night, RingConn's own app 5.8/night on this same ring. Read §4 (the three-way comparison), §7 (two corrections), §10 (options, recommended order C→B→A)** |
| `desktop/sleep_awake_trace.py` | **Per-epoch trace: which awake-mask pass killed a specific awakening?** `--pull` over USB, `--at HH:MM --window 20m` to zoom on a known wake time |
| `desktop/sleep_reference_labels.py` | **Reference sleep labels (Whoop / official RingConn app) read from HealthKit.** `--list-awake`, `--correlate` (tail-vs-awake 2×2), `--export-groundtruth` → feeds `ringconn_sleep_fit.py --groundtruth` unmodified. Import them on the phone first: Device Info → Diagnostics → *Import reference sleep labels* |
| `docs/SLEEP_INTERIOR_AROUSALS.md` | **THE FIX for brief awakenings — BUILT 2026-08-15, `arousalIntensityCut = 200`.** Second, lower tail-sum cut for interior-only arousals (existing 345 cut fires ONLY at night edges). On-device confirmation against a real re-staged night still pending — see `docs/PENDING_VALIDATION.md` → `sleep-arousal-cut-single-night-fit`** |
| `docs/SLEEP_AWAKENING_METRICS.md` | **WASO + awakening-count metrics — plan of record (PROPOSED, not built).** Option C of SLEEP_AWAKE_RESOLUTION §10, and the measuring instrument options A/B need. Read §2 first: derive from the stored hypnogram, NO SwiftData columns (the V4→V5 migration wiped raw history) |
| `docs/HEADACHE_SIGNALS.md` | **Headache signals (#183) — plan of record. Read §1 first: the honest accuracy arithmetic is why the alert must EARN its way on per-user** |
| `docs/RUNBOOK_HEADACHE_VALIDATION.md` | **On-device validation for #183 (freeze / migration / HealthKit) + the tester-facing "What to Test"** |
| `docs/WIDGETS_HOME_SCREEN.md` | **Home Screen widgets — plan of record (PROPOSED, not built). Read §1: the App-Group/SwiftData hazard and why a read-only snapshot sidesteps it** |
| `docs/HEALTHKIT_MAPPING.md` | Each metric → HealthKit type |
| `docs/BACKGROUND_SYNC.md` | **How the official RingConn app syncs to Apple Health without being opened (RE'd blueprint) → mapped to our BGTask + CoreBluetooth-restoration implementation (#119); deliberate divergences + validation runbook** |
| `docs/HANDOFF_MACOS_IOS.md` | **Pickup instructions for the iOS work on macOS** |
| `docs/PENDING_VALIDATION.md` | **Shipped but unconfirmed claims + their check commands. Surfaced at session start by `scripts/pending-validation.py`** |
| `scripts/usage-guard.py` | **Plan-usage guard — reports 5h/weekly at session start, warns at ≥80% before work begins** |
| `docs/REFERENCES.md` | **Five related projects cloned to `refs/` for design + troubleshooting (charts, BLE RE, schemas). Read the ⚖️ license rule first, then "if you're working on X, read Y"** |
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

## Reference codebases (`refs/`) — read for FACTS, never copy CODE
`refs/` holds read-only clones of five other projects we mine for design ideas
(`scripts/sync-refs.sh` to create/refresh; gitignored). **`docs/REFERENCES.md` maps
each one to the problem it helps with and names the specific files worth opening** —
read the index before grepping 200 MB of someone else's source.

- **Two are copyleft (Gadgetbridge AGPL-3.0, GarminDB GPL-2.0) and one is
  noncommercial (NOOP PolyForm-1.0.0). OpenCircuit is public.** Never copy their code
  into `ios/` or `desktop/`, and never paraphrase a file closely enough to be a
  translation. Read it, understand the approach, close it, write ours.
- **Facts are free** — byte layouts, opcode numbers, checksums, units, schema columns,
  which chart type suits which metric. Take those, and cite the source.
- Prefer having a **subagent** read AGPL/PolyForm source and report back in prose: it
  keeps the implementation out of the main context, where it could otherwise bleed
  into Swift written later.
- Facts about *other* devices (e.g. the Colmi R0x rings) are a sanity check only —
  never promote them into `docs/PROTOCOL.md` as RingConn claims.

# Sorted

## To do

- Write and train our own model for reminder sorting, and deploy that.
- Allow user input for training in the app.

A native app (macOS and iOS) that reads your Apple Reminders and ranks them by
importance using Apple's on-device Foundation Models framework (Apple
Intelligence), with a deterministic fallback when that's unavailable.

## Project layout

```
Shared/  Platform-agnostic code (Models, Services, ViewModels, shared Views)
         — one copy on disk, compiled into both apps
macOS/   SwiftUI app for macOS (open macOS/Sorted.xcodeproj) + unit tests
iOS/     SwiftUI app for iOS (open iOS/Sorted.xcodeproj)
```

The two are independent Xcode projects (generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from each folder's
`project.yml`), and both reference `Shared/` directly — there is exactly one
copy of the platform-agnostic source, so the platforms can't silently
diverge. Only the app entry point, `ContentView`, `HomeView`, and
`SettingsView` are per-platform.

To regenerate either project after editing its `project.yml`:

```
cd macOS && xcodegen generate   # or: cd iOS && xcodegen generate
```

Unit tests for the deterministic scoring formula live in `macOS/Tests`
(standalone bundle — running them never launches the app or triggers its
permission prompt):

```
cd macOS && xcodebuild test -scheme SortedTests -destination 'platform=macOS'
```

## Features

### Tabs

- **Home** — shows a single card for the most important reminder overall,
  determined by AI ranking (see below). A refresh button sits in the top-right
  toolbar, same placement as the other three tabs.
  - **Snooze** opens a picker (spinning wheel on iOS; stepper + segmented
    control on macOS, since SwiftUI's wheel picker style is iOS-only) to pick
    an amount and a unit (Day/Week/Month), then pushes the reminder's due
    date to *now + that amount* in Reminders. Updates instantly in the UI
    without a full re-rank; the next real refresh re-ranks normally, and
    since due dates aren't part of what the AI judges (see below), snoozing
    costs zero model calls — only the deterministic time component of the
    score changes.
  - **Complete** marks it done in Reminders and advances to the next one.
  - **Skip** cycles to the next-most-important reminder without changing
    anything in Reminders (wraps back to the top after the last one).
  - **Delete** removes the reminder from Reminders entirely (after a
    confirmation prompt), and advances to the next one. Deleted reminders
    land in Reminders.app's own "Recently Deleted" list, same as deleting
    them there directly.
- **Today** — the top *N* most important reminders overall, in ranked
  order, regardless of when they're due — a "what should I do next"
  shortlist (*N* is 5 by default, configurable in Settings).
- **Upcoming** — all reminders with a future due date, in ranked order.
- **Someday** — all reminders with no due date at all, in ranked order.

- **Face Off** — an optional fifth tab (off by default; enable it under
  Settings) that shows two reminders and asks which is more important. Each
  pick is logged as explicit pairwise training data (see below).
  - Runs as a **single-elimination bracket** over a sampled pool of 16
    reminders: round one is random, but winners advance to face other
    winners, so successive comparisons are between increasingly important
    reminders — the highest-signal labels, near the top of the importance
    scale where ranking accuracy matters most. Odd reminders advance by
    bye; a resolved bracket reseeds with a fresh sample.
  - A pair is **never asked twice**: everything already compared — in the
    on-device log (imported history included) or skipped this session — is
    excluded from pairing. Left/right stays randomized so position isn't a
    tell. Skip records nothing and advances neither reminder.
  - Recent picks also feed straight back into ranking as prompt
    calibration (see "Few-shot calibration" below) — Face Off improves the
    ranking *today*, not just after a future training run.

Upcoming and Someday have a **search field** (filtering by title, notes, and
list name) since those lists grow long; Today is already a short curated
slice.

### Live updates

The app observes EventKit's change notification (`EKEventStoreChanged`), so
reminders added, edited, or completed elsewhere — in Reminders.app, via
Siri, or synced in from iCloud — flow in automatically: a debounced (1.5s)
**quiet refresh** re-fetches and re-ranks *without* flashing the loading
screen or resetting session state (Today's swiped-away skips are kept; the
reminder showing on Home keeps its spot if it still exists). New reminders
get classified and slotted into ranked order as part of the same pass;
everything already cached stays instant. EventKit also fires this
notification for the app's own writes (complete/snooze/delete), which is
harmless — the quiet refresh just converges on the same state the UI
already shows.

### Settings

A gear icon in Home's toolbar opens Settings (`AppSettings.swift`, persisted
via `UserDefaults`):

- **Reminders shown in Today** — a stepper, 1-20, controlling the cap
  described above.
- **Show urgency score** — a toggle that displays each reminder's 0-100
  urgency score as a colored badge (red 67+, orange 34-66, blue below) next
  to its priority badge, on Home and in the list tabs.
- **Consider due dates in ranking** — on by default. When off, the time
  axis is dropped from scoring entirely (due dates, overdue status, and the
  undated-item neglect bonus) and reminders are ranked purely by the AI's
  importance judgment of what each task is. Toggling it re-ranks
  immediately — importance stays cached, so no model calls are involved,
  only the deterministic score composition changes. Same-importance items
  still order by earlier due date as a tie-break.
- **Log ranking feedback** — on by default; toggles the preference log
  described below. **Export Log…** next to it saves the accumulated log
  (including any rotated history, in chronological order) via the standard
  save panel (macOS) / Files sheet (iOS) as a `.jsonl` file. The button is
  disabled until at least one event has been logged.
- **Show Face Off tab** — off by default; adds the Face Off tab described
  above. **Export Face-Off Log…** next to it exports the pairwise-judgment
  log the same way, as a separate `.jsonl` file. **Import Face-Off Log…**
  merges a log exported from another device into this device's log — e.g.
  pull the iPhone's face-offs into the Mac — so prompt calibration, pair
  dedupe, and future training all see the combined history.
- **Lists** — one toggle per Reminders list (fetched live from EventKit,
  including empty lists). Turning a list off adds it to an ignored set;
  reminders in ignored lists are filtered out *before* ranking, so they
  appear nowhere in the app (not Home, Today, Upcoming, Someday, or Face
  Off). Toggling re-runs the ranking pass immediately. Stored by list title
  in `AppSettings.ignoredLists`.

The list tabs draw from one shared ranking pass, so Home and the buckets
always agree on relative importance.

### AI-based priority ranking

Ranking is done by Apple's **Foundation Models** framework
(`SystemLanguageModel` / `LanguageModelSession`), the on-device LLM behind
Apple Intelligence — no network calls, nothing leaves the device.

**Importance and time urgency, judged separately.** Earlier versions asked
the model for a single combined urgency judgment — first as a raw 0-100
score (scores clustered near the top and over-weighted incidental signals),
then as a coarse urgency tier (better, but the tier rubric still asked the
model to fold due-date proximity into its judgment — exactly the kind of
date reasoning a small on-device model, ~3B parameters, is worst at, and it
produced misfires like a same-day reminder landing in a lower tier than a
next-day one). Combined judgments also had to be cached whole, so a score
assigned when a reminder was due in three weeks stayed frozen as the due
date arrived. The current design splits ranking into two independent axes,
each handled by the part of the system that's actually good at it:

- **Importance** — real-world stakes: how much it matters that the task
  ever gets done. Judged by the model from the title, notes, and list
  *only* — no dates in the prompt at all — into one of four tiers:
  critical, high, normal, low (`ImportanceTier` in
  `Models/ImportanceTiers.swift`). Because the judgment is date-blind by
  construction, it stays valid until the reminder's content changes, no
  matter how much time passes or how often it's rescheduled.
- **Time urgency** — computed deterministically in code (`UrgencyScorer`)
  from precise calendar-day math, fresh on every rank: overdue maps to
  0.75-1.0 (being overdue at all is the strong signal; extra days add a
  little more, capped at two weeks so long-abandoned items can't drown out
  everything else), due today is 0.70 (always above any future date), future
  due dates fade linearly to zero a month out, and undated reminders get a
  small neglect bonus growing with age since creation so long-forgotten
  items drift up rather than sitting at the bottom forever.

The final 0-100 score combines them: `55% × time urgency + 45% × importance`
(with tier weights critical 1.0, high 0.7, normal 0.4, low 0.15). Ties break
by earlier due date, then stable fetch order. The weighting means an overdue
trivial errand surfaces, but a genuinely important task due this week still
outranks it — and because the time component is recomputed on every rank, a
reminder drifting toward its due date climbs the ranking day by day with no
model call and no cache invalidation. (A Settings toggle, "Consider due
dates in ranking," drops the time axis entirely for stakes-only ranking —
see Settings above.)

This structurally removes the failure modes documented against the previous
design: a same-day reminder can never rank below a next-day one of equal
importance (dates never pass through the model), long-overdue low-stakes
items can't outrank recently-overdue important ones (the overdue bonus is
capped and importance is weighted in), and scores can't go stale (time is
recomputed each rank).

**A listwise re-rank of the top of the list.** Per-item classification into
coarse tiers is reliable but throws away *comparative* judgment — and the
best-feeling ranking this app ever had (the old 40-per-batch era) got its
quality precisely from the model seeing many reminders side by side. So
after deterministic scoring picks *which* ~15 reminders matter most, one
extra model call orders that group as a whole, weighing stakes and timing
together (this pass, unlike importance classification, does see due/creation
dates — as app-computed relative offsets). The group's existing scores are
reassigned in the new order so displayed scores stay monotonic. The result
is cached per candidate set per calendar day (`TopOrderCache`) — same-day
relaunches with unchanged data cost no model call, but the ordering
naturally refreshes at midnight since relative urgency shifts as time
passes. If the call fails or Apple Intelligence is unavailable, the
deterministic order simply stands. (When "Consider due dates in ranking" is
off, the pass still runs but judges content only, cached separately.)

The reminder's explicit priority field (`EKReminder.priority` — the
none/low/medium/high flag you can set in Reminders.app, read directly via
EventKit's public API, no scripting involved) is deliberately **not** sent
to the model — an earlier test showed it being weighted too heavily,
scoring reminders close to 100 just for being marked high-priority even
when due weeks or months out. Priority is still shown in the UI
(`PriorityBadge`) and still seeds the fallback importance (below); it's only
excluded from what the AI classification call sees.

The model's context window can't hold an unlimited number of reminders in one
call, so classification is split into chunks of at most 15 (kept
deliberately small so each reminder gets more individual attention).

**Few-shot calibration in the classification prompt**
(`ClassificationExamples.swift`, shared verbatim by the Apple and MLX arms so
their rubrics can't drift):

- **Tier anchors** — four canonical examples, one per tier ("schedule
  follow-up for abnormal blood test" = critical … "someday: try that ramen
  place" = low), pinning the rubric's scale. Judged in the abstract, small
  models drift toward calling everything "high"; anchors give the scale a
  fixed reference.
- **The user's own judgments** — the five most recent Face Off picks are
  included as relative examples ("X matters more than Y"), personalizing the
  importance judgment immediately, before the trained custom model exists.
  The importance cache key carries a prompt version (bumped when the rubric
  changes, so everything re-judges once under a new prompt), but the ongoing
  drift of these calibration examples is deliberately *not* versioned —
  versioning it would evict the whole cache on every Face Off pick.

**A single up-front pass.** Classification happens synchronously, before the
tabs appear — there's no background refinement step. An earlier version
split this into a batched pass followed by a slower background per-item pass
(to counter batching's tendency to compress scores together); that's gone
now in favor of one straightforward pass, with a loading screen covering it.

If Apple Intelligence isn't available (unsupported hardware, not enabled in
System Settings, or the on-device model is still downloading), a model call
fails, or the model omits a reminder from its response, the affected
reminders get a fallback importance derived from the explicit priority flag
(high → high, medium/none → normal, low → low) and flow through the same
scoring formula — so even the fallback ranking respects due dates properly.
Fallback importances are computed fresh each rank and never cached, so they
self-correct the moment the model can actually judge the item. A small note
explains why on the Home screen when AI is unavailable entirely.

### Importance cache

Running the on-device model takes several seconds, so each reminder's AI
importance tier is cached **individually**, keyed by a content hash of
exactly what the model judges (`ImportanceCache.swift`, persisted via
`UserDefaults`) — title, notes, and list. Due date, priority, and creation
date are deliberately excluded from the hash: importance is date-blind, so
snoozing or rescheduling never forces a re-classification. On the next
launch or manual refresh:

- Reminders whose hash matches a cached entry reuse that importance
  instantly — no model call. The score itself is *always* recomputed from
  current dates, cached importance or not.
- Only reminders that are new or have a changed hash (edited
  title/notes/list) get sent to the model. If none did, refresh is
  effectively instant with zero model calls — except the first refresh of
  each calendar day, which redoes the one listwise re-rank call (see
  above).
- The cache is rewritten from scratch each save, scoped to exactly the
  current reminder set, so entries for completed/deleted/edited-away
  reminders never pile up.

This is deliberately simpler than reconstructing or merging a previous
ordering: there's no ordering to reconstruct at all, just a hash lookup per
reminder, a recomputed time component, and a plain sort by score at the end.
(The predecessor score cache, which worked the same way structurally, was
verified on-device across repeated launches with unchanged data: zero
model-generation activity in the logs after the first full pass.)

### Training data (two logs)

Groundwork for the custom-model to-do above. Both logs are JSON Lines (one
event per line) in `Application Support/Sorted/`, rotated once at 10 MB,
written best-effort off the main actor, and never leave the device unless
exported. They share their file machinery and per-reminder feature schema
(`TrainingLog.swift`); each is exportable as a `.jsonl` file from Settings.

- **Implicit feedback** (`PreferenceLog.swift`, `preferences.jsonl`) — every
  **Complete**, **Skip** (Home), swipe-skip (Today), **Snooze**, and
  **Delete**, together with the ranked context the user was looking at (top
  10: position, title, truncated notes, list, due/created day offsets,
  priority flag, score). Each action is an *implicit* preference judgment —
  completing the top item endorses the ranking, skipping it says something
  below deserved the spot. Can be turned off in Settings ("Log ranking
  feedback", enforced at a single gate in the view model).

- **Explicit face-offs** (`FaceOffLog.swift`, `faceoffs.jsonl`) — one
  `{winner, loser}` record per pick in the Face Off tab. This is the
  cleanest signal of the two: a direct pairwise label with no ranked-order
  noise to untangle. Written only while the Face Off tab is enabled.

**Merging data across devices.** Each device's local log is its canonical
store; exports are *cumulative* (the whole history every time), so
successive exports of the same device overlap heavily. "Import Face-Off
Log…" is therefore an **idempotent merge**: events are identified by
timestamp + pair, anything already present is skipped, and the pass also
compacts the local log (healing duplicates from earlier naive imports).
Importing the same export twice — or an older export after a newer one —
adds nothing. Workflow: export from the iPhone whenever, import on the Mac
in any order, and the Mac's log (which `train.py` reads directly, and which
prompt calibration and Face Off pair-dedupe consult) is always the combined,
duplicate-free history.

### Loading screen

Because classification is a single synchronous pass, `refresh()` always
shows a full-screen spinner ("Reminders are being processed and sorted…")
while it runs. If everything's already cached, `rank(_:)` returns
essentially instantly and the screen just flashes through. The same view
covers the brief initial permission-check phase too, so there's never a
blank window between launch and content. On iOS, the window before *that* —
process cold start, which can run several seconds on a device — is covered
by a static launch screen (`UILaunchScreen` in `iOS/project.yml`) showing a
centered star (`Assets.xcassets/LaunchIcon.imageset`); an empty launch
screen renders solid systemBackground, which in dark mode is
indistinguishable from a hung black screen.

Note: the launch screen only masks the cold start, it doesn't shorten it.
Most of that 5-10s on a physical iPhone is debug-build loading plus
on-device signature verification from free Apple ID signing — a Release
build and/or a paid Developer Program signing profile would cut it
substantially. (An earlier version showed a
per-batch progress bar instead, and checked Foundation Models availability
synchronously on the main actor at startup — that check can take a
noticeable moment on first access, which blocked the first frame and left
the window blank. The check now runs off the main actor.)

### Swipe-to-skip (Today tab)

Swiping a row left in Today (same direction as Mail/Reminders' own swipe
actions — full swipe or tap the revealed button) skips it for the current
session only — it isn't marked complete or deleted, it just drops out of
Today's top-5 so the next-ranked reminder takes its place. Skipped state
resets on refresh/app relaunch.

### Completing and deleting

Both actions write directly to the same EventKit store that backs
Reminders.app, so they're real changes that sync via iCloud like anything
done in Reminders.app itself — not local-only UI state.

## Permissions

The app only requests **Reminders access** (`NSRemindersFullAccessUsageDescription`
in Info.plist). An earlier version also read the Reminders "flagged" status
via an AppleScript workaround (since EventKit's public API doesn't expose it)
which required a second Automation permission — that path has been removed,
so flagged status isn't used and there's only the one permission prompt.

## Requirements

- macOS 26+ / iOS 26+
- Xcode 26+
- For AI-based ranking: a Mac or iPhone that supports Apple Intelligence,
  with it enabled in System Settings. Older/unsupported hardware still runs
  the app fine via the deterministic fallback.

## Running it

**macOS**: open `macOS/Sorted.xcodeproj` in Xcode, select a signing team
under Signing & Capabilities, and run (⌘R). No App Sandbox entitlements are
needed since it isn't distributed through the App Store.

**iOS**: open `iOS/Sorted.xcodeproj` in Xcode. For the simulator, just
run. For a physical device: connect via USB, enable Developer Mode on the
phone (Settings → Privacy & Security → Developer Mode — this option only
appears after Xcode's first install attempt), set a signing team, select the
device as the run destination, and run. Free Apple ID signing re-signs every
7 days; a paid Apple Developer Program membership extends that to a year.

## MLX ranker (experimental A/B arm)

Selecting **"MLX big-batch"** in Settings routes ranking through `MLXRanker`
(`Shared/Services/MLXRanker.swift`): an on-device open LLM run via
[MLX Swift](https://github.com/ml-explore/mlx-swift-examples), used with
**exactly the Apple arm's two-axis architecture** — per-item importance
classification (date-blind, chunked prompts parsed defensively from free
text, cached per reminder *per model* so one model's judgments are never
served as another's) + deterministic `UrgencyScorer` time urgency + one
listwise re-rank of the top 15.

This arm originally ranked with a single large comparative pass (~40
reminders judged together in one prompt). **A/B testing showed Apple's
per-item structure beating pure listwise on every MLX model tried**, so the
arm now varies only the *model*, not the design — the open question it
answers is whether a bigger open model classifies importance better than
Apple's ~3B on-device model.

- **Model**: chosen in Settings ("MLX model"): Qwen 2.5 1.5B (balanced,
  default), Llama 3.2 1B (fastest; gets smaller 20-item chunks — it degrades
  holding larger comparisons), or Qwen 2.5 3B (best, ~2GB). Downloaded from
  the Hugging Face hub **in the background on first rank** (ranking falls
  back to the deterministic order until it's ready — a rank never blocks on
  the download), then cached and reused across ranks (`ModelStore`). No
  weights are bundled at build time.
- **Requires Apple Silicon.** MLX's Metal kernels have no x86_64 support, so the
  project excludes that arch on the simulator
  (`EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`). Run the MLX arm on an
  **Apple-Silicon simulator (arm64)** or a **real device**. On any slice where
  MLX can't link (or on non-Apple-Silicon hardware), `MLXRanker` compiles the
  MLX paths out (`#if canImport(MLXLLM) && arch(arm64)`) and degrades to the
  deterministic ordering, and `availability` reports why — so the baseline app
  keeps building and running everywhere.
- **Packages** (see each `project.yml`): `mlx-swift-examples` from `2.29.1`
  (products `MLXLLM`, `MLXLMCommon`; pulls in `mlx-swift` and
  `swift-transformers` transitively). `swift-transformers` and `swift-jinja` are
  pinned by revision to the exact commits `mlx-swift-examples` 2.29.1 tested
  against (transformers 1.0.0, jinja 2.1.0); without those pins SwiftPM floats
  jinja to a version whose API breaks transformers 1.0.0's build. Remove the
  pins once a tagged `mlx-swift-examples` release ships a fixed dependency
  range. Building the Metal kernels needs Xcode's Metal Toolchain component
  (`xcodebuild -downloadComponent MetalToolchain` if missing).

# RemindSort

A native app (macOS and iOS) that reads your Apple Reminders and ranks them by
importance using Apple's on-device Foundation Models framework (Apple
Intelligence), with a deterministic fallback when that's unavailable.

## Project layout

```
macOS/   SwiftUI app for macOS (open macOS/RemindSort.xcodeproj)
iOS/     SwiftUI app for iOS (open iOS/RemindSort.xcodeproj)
```

The two are independent Xcode projects (generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from each folder's
`project.yml`), but share the same architecture and, for the
platform-agnostic files (Models, Services, ViewModel, and most Views), the
same source. Only the app entry point and Home screen's button layout differ
between platforms.

To regenerate either project after editing its `project.yml`:

```
cd macOS && xcodegen generate   # or: cd iOS && xcodegen generate
```

## Features

### Four tabs

- **Home** — shows a single card for the most important reminder overall,
  determined by AI ranking (see below). A refresh button sits in the top-right
  toolbar, same placement as the other three tabs.
  - **Snooze** opens a picker (spinning wheel on iOS; stepper + segmented
    control on macOS, since SwiftUI's wheel picker style is iOS-only) to pick
    an amount and a unit (Day/Week/Month), then pushes the reminder's due
    date to *now + that amount* in Reminders. Updates instantly in the UI
    without a full re-rank; the next real refresh re-ranks normally since the
    due date change invalidates the ranking cache.
  - **Complete** marks it done in Reminders and advances to the next one.
  - **Skip** cycles to the next-most-important reminder without changing
    anything in Reminders (wraps back to the top after the last one).
  - **Delete** removes the reminder from Reminders entirely (after a
    confirmation prompt), and advances to the next one. Deleted reminders
    land in Reminders.app's own "Recently Deleted" list, same as deleting
    them there directly.
- **Today** — the top *N* most important reminders that are due today or
  overdue, in ranked order (*N* is 5 by default, configurable in Settings).
- **Upcoming** — all reminders with a future due date, in ranked order.
- **Someday** — all reminders with no due date at all, in ranked order.

### Settings

A gear icon in Home's toolbar opens Settings (`AppSettings.swift`, persisted
via `UserDefaults`):

- **Reminders shown in Today** — a stepper, 1-20, controlling the cap
  described above.
- **Show urgency score** — a toggle that displays each reminder's 0-100
  urgency score as a colored badge (red 67+, orange 34-66, blue below) next
  to its priority badge, on Home and in the list tabs.

All four tabs draw from one shared ranking pass, so Home and the tab buckets
always agree on relative importance.

### AI-based priority ranking

Ranking is done by Apple's **Foundation Models** framework
(`SystemLanguageModel` / `LanguageModelSession`), the on-device LLM behind
Apple Intelligence — no network calls, nothing leaves the device. Each
reminder gets an **independent urgency score from 0-100** (`AIPrioritizer.swift`,
`Models/UrgencyScores.swift`), not a relative rank within a batch. For each
reminder, the model is given:

- Title and notes
- Due date and creation date, as **relative offsets from today** ("due in 3
  days", "overdue by 12 days", "created 45 days ago") computed by the app,
  not raw calendar dates — on-device models are unreliable at date
  arithmetic, so this removes that failure mode entirely. Creation date lets
  long-neglected reminders (especially ones with no due date) get weighed
  instead of sitting forgotten forever.
- Which Reminders list it belongs to

The reminder's explicit priority field (`EKReminder.priority` — the
none/low/medium/high flag you can set in Reminders.app, read directly via
EventKit's public API, no scripting involved) is deliberately **not** sent
to the model. Early testing showed the model weighted it too heavily,
scoring reminders close to 100 just for being marked high-priority even
when due weeks or months out. Priority is still shown in the UI
(`PriorityBadge`) and still used by the heuristic fallback (see below); it's
only excluded from what the AI scoring call sees.

The instructions also include a rough scoring rubric (e.g. "overdue by
several days → 80-100", "no due date, recently created → 10-30") and
explicitly ask the model to use the full 0-100 range rather than clustering
scores near the same value, which it otherwise tends to do.

The model's context window can't hold an unlimited number of reminders in one
call, so scoring is split into chunks of at most 15 (kept deliberately small
so each reminder gets more individual attention). Because scores are
absolute rather than relative to a batch, combining chunks afterward is just
a plain sort by score — no merging separately-ranked batches together, which
was both slower and a source of bugs in an earlier ordinal-ranking design.

**Two background scoring passes.** After the instant heuristic placeholder,
new/changed reminders go through two passes, both non-blocking:

1. A **batched** pass (chunks of 15) gives everyone a real AI score
   reasonably quickly.
2. An **individual** pass re-scores each reminder completely alone (one per
   model call) — batching reminders together implicitly invites the model to
   compare them, which compresses scores toward a narrow band; scoring in
   isolation avoids that. This is meaningfully slower (one call per
   reminder) but runs entirely in the background and every result is
   cached, so it's a one-time cost per reminder.

Verified concretely with a deliberately varied test set (overdue+high-
priority, due-tomorrow+no-priority, no-due-date+old, etc.): the individual
pass measurably corrected under-scoring from the batch pass in at least one
case (a reminder due tomorrow with no explicit priority scored 0 in the
batch pass, 40 individually) and produced a real spread across the range
rather than clustering near 100. That same test also surfaced the
priority-flag over-weighting described above, which led to dropping
priority from the model's input entirely.

If Apple Intelligence isn't available (unsupported hardware, not enabled in
System Settings, or the on-device model is still downloading), or a given
model call fails, ranking falls back to a deterministic heuristic score
(priority level + overdue/due-soon proximity) for the affected reminders —
the app still works, it just won't be AI-scored, and a small note explains
why on the Home screen when AI is unavailable entirely.

**Placeholder-then-refine scoring.** New or changed reminders (including on
the very first pass ever, with an empty cache) get an instant heuristic
placeholder score so nothing ever blocks the UI. The real `UrgencyScores`
call — the model echoing back each reminder's token alongside its score, so
mapping the response back to items is unambiguous — then runs as a
background task and silently updates the UI (via an `onImproved` callback)
once it finishes.

An earlier version tried a cheaper `QuickScores` pass first (plain integers,
no per-item token, matched back to items purely by position) to get an
AI-scored placeholder faster than the full pass. In practice the model
doesn't reliably return the right *count* of scores without a token
anchoring each value to a specific reminder — one test batch of 40 items
came back with 50 scores, all identical. That silently fell back to the
heuristic anyway (the safety net worked), but paid for a wasted model call
to get there. `QuickScores` was removed; the heuristic placeholder is used
directly instead, which is both faster and more honest about what's
actually happening. Heuristic-derived scores are clamped to the same 0-100
range as AI scores so a placeholder can never outrank a legitimately-scored
item by virtue of being unbounded.

### Ranking cache

Running the on-device model takes several seconds, so each reminder's score
is cached **individually**, keyed by a content hash of that reminder alone
(`ScoreCache.swift`, persisted via `UserDefaults`) — title, notes, due date,
priority, and list. On the next launch or manual refresh:

- Reminders whose hash matches a cached entry reuse that score instantly —
  no model call.
- Only reminders that are new or have a changed hash (edited title/notes/due
  date/priority/list) get sent to the model. If none did, refresh is
  effectively instant with zero model calls.
- The cache is rewritten from scratch each save, scoped to exactly the
  current reminder set, so entries for completed/deleted/edited-away
  reminders never pile up.

This is deliberately simpler than reconstructing or merging a previous
ordering: there's no ordering to reconstruct at all, just a hash lookup per
reminder and a plain sort by score at the end — verified on-device (iOS
Simulator) across repeated launches with unchanged data: zero model-generation
activity in the logs on the second and third launch after the first full
scoring pass.

### Loading screen

Since scoring now always returns an instant placeholder (heuristic-derived,
or cached) rather than blocking on the model, the app never actually needs
the full-screen progress bar ("Reminders are being processed and sorted…")
in normal operation — every launch or refresh goes straight to the tabs, and
real AI scores for new/changed reminders arrive quietly in the background.
The progress-bar loading state (`LoadState.loading`, gated by
`AIPrioritizer.isFirstPass()`) is kept as a defensive fallback for any future
case that does need to block synchronously, but you shouldn't expect to see
it under normal use.

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
  the app fine via the heuristic fallback.

## Running it

**macOS**: open `macOS/RemindSort.xcodeproj` in Xcode, select a signing team
under Signing & Capabilities, and run (⌘R). No App Sandbox entitlements are
needed since it isn't distributed through the App Store.

**iOS**: open `iOS/RemindSort.xcodeproj` in Xcode. For the simulator, just
run. For a physical device: connect via USB, enable Developer Mode on the
phone (Settings → Privacy & Security → Developer Mode — this option only
appears after Xcode's first install attempt), set a signing team, select the
device as the run destination, and run. Free Apple ID signing re-signs every
7 days; a paid Apple Developer Program membership extends that to a year.

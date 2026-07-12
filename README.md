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
- **Today** — the top 5 most important reminders that are due today or
  overdue, in ranked order.
- **Upcoming** — all reminders with a future due date, in ranked order.
- **Someday** — all reminders with no due date at all, in ranked order.

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
- Due date (and whether it's overdue)
- The reminder's explicit priority field (High / Medium / Low / None)
- Which Reminders list it belongs to

The model's context window can't hold an unlimited number of reminders in one
call, so scoring is split into chunks of at most 40. Because scores are
absolute rather than relative to a batch, combining chunks afterward is just
a plain sort by score — no merging separately-ranked batches together, which
was both slower and a source of bugs in an earlier ordinal-ranking design.

If Apple Intelligence isn't available (unsupported hardware, not enabled in
System Settings, or the on-device model is still downloading), or a given
model call fails, ranking falls back to a deterministic heuristic score
(priority level + overdue/due-soon proximity) for the affected reminders —
the app still works, it just won't be AI-scored, and a small note explains
why on the Home screen when AI is unavailable entirely.

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

While a refresh needs the model, the app shows a progress bar and "Reminders
are being processed and sorted…" rather than a bare spinner. Progress is a
real (if approximate) estimate of completed vs. expected model calls for that
refresh — since most refreshes only need to rank a handful of new/changed
reminders thanks to the cache above, this is usually brief.

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

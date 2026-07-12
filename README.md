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
Apple Intelligence — no network calls, nothing leaves the device.

**Tiered classification, not raw scoring.** Earlier versions asked the model
directly for a 0-100 urgency number. In practice this didn't hold up: scores
clustered near the top of the range, and the model over-weighted incidental
signals like the explicit priority flag (see below). A raw, well-calibrated
magnitude estimate turns out to be a harder, less reliable task for a small
on-device model (~3B parameters) than a coarse categorical judgment. So the
model's job now is narrower: classify each reminder into one of five urgency
**tiers** — critical, high, medium, low, minimal (`UrgencyTier` in
`Models/UrgencyTiers.swift`) — each mapped to a fixed score band (critical =
90-100, high = 70-89, medium = 45-69, low = 20-44, minimal = 0-19). The final
0-100 score is then computed in code: reminders sharing a tier are spread
across that tier's band by the deterministic due-date heuristic, most urgent
first. The model decides *how urgent, roughly*; code decides *exactly where
in that ballpark*, using precise date math the model can't reliably do.

For each reminder, the model is given:

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
to the model — an earlier test showed it being weighted too heavily,
scoring reminders close to 100 just for being marked high-priority even
when due weeks or months out. Priority is still shown in the UI
(`PriorityBadge`) and still used by the heuristic (both as the classification
fallback and for within-tier ordering, see below); it's only excluded from
what the AI classification call sees.

The model's context window can't hold an unlimited number of reminders in one
call, so classification is split into chunks of at most 15 (kept
deliberately small so each reminder gets more individual attention).

**A single up-front pass.** Classification happens synchronously, before the
tabs appear — there's no background refinement step. An earlier version
split this into a batched pass followed by a slower background per-item pass
(to counter batching's tendency to compress scores together); that's gone
now in favor of one straightforward pass, with a loading screen covering it.

If Apple Intelligence isn't available (unsupported hardware, not enabled in
System Settings, or the on-device model is still downloading), or a given
model call fails, ranking falls back to a deterministic heuristic score
(priority level + overdue/due-soon proximity) for the affected reminders —
the app still works, it just won't be AI-classified, and a small note
explains why on the Home screen when AI is unavailable entirely. The same
heuristic also supplies a coarse fallback tier for any reminder the model's
response happens to omit.

**Known remaining imperfections**, found via a deliberately varied 8-reminder
test set rather than assumed: a same-day reminder was classified into the
"low" tier, ranking below a next-day one in "medium" — a plausible tier
mis-classification, not a placement bug. Separately, the within-tier
heuristic ordering favors raw overdue duration without an upper bound, which
let a low-priority reminder overdue by a month outrank a high-priority one
overdue by less time, even though the tiers themselves were reasonable.
Worth revisiting either the tier rubric or capping the heuristic's overdue
bonus if this is still noticeably off in practice.

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

Because classification is a single synchronous pass now, `refresh()` always
shows the full-screen progress bar ("Reminders are being processed and
sorted…") while it runs. If everything's already cached, `rank(_:)` returns
essentially instantly and the screen just flashes through; if there's real
classification work to do, the progress bar tracks actual batch completion
so it's not just a spinner.

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

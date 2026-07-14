# Gathering training & evaluation data for the ranker experiment

A step-by-step guide for collecting the data that trains and evaluates the
custom rankers (Core ML LTR = Option 1, MLX big-batch = Option 2) and compares
them against the Apple baseline.

Everything here is **on-device and private** — the logs never leave the Mac/phone
unless you export them.

---

## TL;DR — the loop

1. Settings → turn on **Show Face Off tab** and **Log ranking feedback**.
2. Do a **Face Off session** (10–15 min), judging on *importance, not urgency*,
   across different lists and priorities.
3. Use the app normally for a few days (implicit data accrues on its own).
4. Retrain the Core ML model from the logs (`Tooling/CoreMLLTR/train.py`).
5. Compare in **Ranker Lab** and/or the offline eval CLI.
6. Repeat. Keep a slice of data back so you can measure generalization.

---

## The one rule that determines data quality: importance, not urgency

The learned model scores **importance only** — how much it matters that a task
*ever* gets done — judged from content alone. It is deliberately **date-blind**:
timing (due dates, overdue, age) is handled separately and deterministically by
`UrgencyScorer` and combined in later.

So when you make a Face Off pick, choose the one with higher real-world stakes,
**not** the one due sooner. Use this scale as your mental model (it mirrors the
app's `ImportanceTier`):

- **critical** — serious consequences if it never happened: health, safety,
  legal or financial obligations, hard commitments to other people.
- **high** — clearly matters: work deliverables, family needs, appointments,
  things someone is counting on.
- **normal** — ordinary tasks, errands, chores worth doing.
- **low** — optional/trivial/someday, no real consequence if skipped.

> ⚠️ If you let "it's due tomorrow" drive a Face Off pick, you're teaching the
> importance model a signal it structurally can't represent — that poisons the
> data. Be consistent about this across a whole session.

---

## Step 1 — Turn on the logs

In **Settings**:

- **Show Face Off tab** → adds the tab where you pick the more important of two
  reminders. Writes explicit pairwise labels to `faceoffs.jsonl`. *This is the
  cleanest, most valuable signal.*
- **Log ranking feedback** → records every skip / complete / snooze / delete
  (with the ranking you saw) to `preferences.jsonl`. Implicit, higher-volume,
  noisier.

Both are off/optional by default and store data only on this device.

---

## Step 2 — Run good Face Off sessions

The Face Off tab shows two reminders; tap the more important one. It already:

- biases toward reminders **near each other in the current ranking** (the
  comparisons the ranker is least sure about — the most informative labels), and
- randomizes left/right, so screen position isn't a tell.

Your job is to maximise **signal quality and coverage**:

- **Judge on importance** (see the rule above). Same criterion every time.
- **Cover variety.** The model can only *see* these features: priority, which
  list, whether there are notes, and title/notes *length*. So spread your picks
  across **different lists and priorities**. Comparisons *across* categories
  (a work deliverable vs. a trivial errand vs. a family obligation) carry far
  more signal than many comparisons within one list at one priority.
- **Volume:** it's a small (16-feature) linear model, so it stabilises quickly.
  A focused 10–15 min session (~100+ pairs) starts moving the weights; a few
  hundred well-spread pairs is a solid base.
- If two reminders are genuinely a toss-up, use **Skip** rather than forcing a
  coin-flip label.

---

## Step 3 — Let implicit data accrue

With **Log ranking feedback** on, just use the app normally. Completing the top
item says the ranking was right; skipping/snoozing it says something below
deserved the spot. Pairs are reconstructed from this later. It's secondary to
Face Off data (noisier, and conditioned on whichever ranker was active), but
it's free.

---

## Step 4 — Keep a held-out set (evaluation discipline)

Do **not** train on 100% of your data, or the only number you can get is
*training accuracy*, which always looks good and tells you nothing about
generalisation. Two easy ways:

- **Time split (simplest):** every log line has a `ts`. Train on older data,
  evaluate on the most recent ~20%.
- **Random 80/20 split** once you have enough pairs.

Gather a bit more than you think you need so a held-out slice is affordable.

---

## Step 5 — Export the data

The logs live in the app's Application Support directory:

```
~/Library/Application Support/Sorted/faceoffs.jsonl
~/Library/Application Support/Sorted/preferences.jsonl
```

- **macOS (easiest):** you don't need to export at all — `train.py` reads those
  paths directly by default.
- **iOS / to move data around:** Settings → **Export Log…** and **Export
  Face-Off Log…** (save `Sorted-preferences.jsonl` / `Sorted-faceoffs.jsonl`),
  then point `train.py` at the files.

---

## Step 6 — Train the Core ML model

Run in the integration worktree so you can compare right after:

```bash
cd Tooling/CoreMLLTR
python3.13 -m venv .venv && source .venv/bin/activate   # coremltools needs Python <= 3.13
pip install -r requirements.txt

# macOS, auto-reading the live logs:
python train.py

# or with explicit exports:
python train.py --faceoffs ~/Downloads/Sorted-faceoffs.jsonl \
                --preferences ~/Downloads/Sorted-preferences.jsonl
```

`--weak-count` (default 4000) mixes in synthetic weak-label pairs as a prior.
Early on, keep them so a handful of real pairs don't dominate; as your real data
grows into the hundreds, lower it (`--weak-count 500`, then `0`) so *your*
preferences win. Sanity-check the printed **Learned weights** (e.g.
`priority_high` positive).

Bundle the retrained model and rebuild:

```bash
cp -R ImportanceRanker.mlpackage ../../Shared/Resources/
(cd ../../iOS && xcodegen generate); (cd ../../macOS && xcodegen generate)
```

See `Tooling/CoreMLLTR/README.md` for the full feature schema and model details.

---

## Step 7 — Compare / evaluate

**In-app, side by side — Ranker Lab.** Settings → **Show Ranker Lab tab**, open
it, set picker **A** and **B** to the two strategies (e.g. Apple baseline vs
Core ML LTR). It re-ranks your live reminders through both and shows them side by
side with per-item rank deltas, **Kendall τ** (rank agreement), and **% moved**.
Read-only. This shows *how different* two rankings are and *where* they diverge —
inspect whether A or B's top items match your gut.

**Live daily-driver.** Settings → **Ranking model** sets the active ranker for
the whole app. Run one for a while, switch, judge by feel. This is the ultimate
acceptance test — perceived quality on your real list.

**Objective number — offline CLI.** `Tooling/RankerEval` (`swift run
RankerEval`) scores pairwise agreement against your Face Off labels.

---

## Known gaps (so you interpret results honestly)

- **Core ML model quality is capped by the data.** Until you gather real
  face-offs, it ships trained on *synthetic weak labels* — a priority+list
  heuristic prior, not your preferences.
- **Coarse features.** The model sees no title *semantics* yet (only length), so
  many within-list/same-priority comparisons hit diminishing returns for the
  current model — prioritise *variety* over sheer *quantity*. A title-embedding
  feature is the higher-leverage follow-up.
- **Held-out eval of the trained model isn't wired end-to-end yet.** `train.py`
  reports *training* accuracy (optimistic), and the offline CLI currently scores
  proxy strategies, not the actual `.mlpackage` / MLX models. A held-out
  evaluation that runs the trained model on unseen face-offs is the missing
  piece for a real quality number.
- **MLX first run.** The MLX ranker downloads its model on first use (needs
  network + Apple Silicon + memory) and falls back to a deterministic order
  until ready — give its first rank a moment or it'll look identical to baseline.
```

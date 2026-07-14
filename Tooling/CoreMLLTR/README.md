# Core ML LTR training pipeline

Trains a small **pairwise learning-to-rank** model that scores a reminder's
real-world **importance**, and exports it as a Core ML `.mlpackage` for the
Sorted app to bundle and run on device (`Shared/Services/CoreMLRanker.swift`).

This is Option 1 of the ranker A/B experiment: replace the on-device LLM's
per-item importance judgment with a model trained on Matt's own feedback
(`faceoffs.jsonl` explicit pairs + `preferences.jsonl` implicit actions), while
keeping the deterministic time-urgency axis (`UrgencyScorer`) exactly as-is.

## What it models (and what it does not)

The model scores the **importance axis only** — how much a task matters, judged
from content alone. It is deliberately **date-blind**, mirroring the app's
`ImportanceTier`/`AIPrioritizer` design: due dates and creation age are handled
separately and deterministically by `UrgencyScorer` at rank time, then combined
with the learned importance using the app's existing 0.55 (time) / 0.45
(importance) split. Feeding dates into the model would double-count against that
time term, so `dueInDays`/`createdDaysAgo` are present in the logs but are **not**
model inputs.

## Feature schema (canonical: `features.py`)

Each reminder becomes a `FEATURE_COUNT`-length float vector. `features.py` is the
single source of truth; `CoreMLRanker.features(for:)` in Swift reimplements it
byte-for-byte and **must stay in lockstep** — any change here means changing the
Swift side and retraining/rebundling.

| idx   | name               | meaning                                             |
|-------|--------------------|-----------------------------------------------------|
| 0     | `priority_high`    | 1 if RFC-5545 priority 1..4                          |
| 1     | `priority_medium`  | 1 if priority == 5                                   |
| 2     | `priority_low`     | 1 if priority 6..9                                   |
| 3     | `priority_none`    | 1 if priority 0 / unset                              |
| 4     | `has_notes`        | 1 if notes non-empty (after trimming)               |
| 5     | `title_len_norm`   | `min(len(title), 100) / 100`                        |
| 6     | `title_words_norm` | `min(word_count(title), 20) / 20`                   |
| 7     | `notes_len_norm`   | `min(len(notes), 140) / 140`                        |
| 8..15 | `list_bucket_i`    | one-hot of the list name hashed into 8 md5 buckets  |
| 16..47| `title_emb_i`      | 32-dim semantic title embedding (see below)          |

**Title embedding (idx 16..47).** Apple's on-device sentence embedding
(`NLEmbedding`) projected to 32 dims and L2-normalized — the signal that
distinguishes "pay the mortgage" from "buy sponges" when list and priority
tie (measured: ~half of real face-off pairs). Parity between training and
inference is **by construction**: `embeddings.py` never computes a vector —
it shells out to `Tooling/EmbedTool`, a CLI compiled from the very
`Shared/Services/TitleEmbedding.swift` the app runs. Training therefore
needs the Swift toolchain on this Mac (the first run builds the tool).
Zeros when embedding assets are unavailable, matching the app's fallback.

List identity uses the **hashing trick**: the list name is md5-hashed (first 4
bytes, big-endian, mod 8) into a fixed bucket, so the app needs no fixed list
vocabulary. Empty list name maps to bucket 0.

## Model

RankNet-style logistic regression on feature **differences**. For a pair
(winner `w`, loser `l`): `P(w > l) = sigmoid(W · (f(w) − f(l)))`. The bias
cancels in the difference, so the learned per-item scorer is just `W · f(item)`.
The exported Core ML model is a single linear layer: input `features`
(MLMultiArray, length `FEATURE_COUNT`) → output `score` (scalar; higher = more
important). Swift squashes `score` through a sigmoid into the [0,1] importance
weight before combining with the time axis.

## Training data

Two on-device JSON Lines logs (schema in `Shared/Services/TrainingLog.swift`):

- **`faceoffs.jsonl`** — `{ts, winner, loser}`, explicit pairwise labels. The
  cleanest signal; used directly.
- **`preferences.jsonl`** — `{ts, action, item, context}`, implicit feedback.
  Pairs are reconstructed against the ranked `context` the user saw:
  - `complete`/`open` → the acted item should rank above every context item
    strictly below it.
  - `skip`/`snooze` → every context item strictly below it should rank above it.
  - `delete` → no importance signal, skipped.

Export both logs from the app (Settings → export), or point `train.py` at them
directly. By default `train.py` reads them from the app's Application Support
dir (`~/Library/Application Support/Sorted/`) if present.

### Weak-label bootstrap

With little or no real data, `train.py` still produces a usable model by
generating synthetic reminders labeled by a heuristic "teacher" (a Python port
of the priority/importance intuition). Control with `--weak-count` (default
4000; set `0` to train on real data only). As real logs grow, real pairs are
mixed in and dominate.

## Running

```bash
cd Tooling/CoreMLLTR
python3.13 -m venv .venv           # coremltools supports Python <= 3.13
source .venv/bin/activate
pip install -r requirements.txt

# Bootstrap only (no real data needed):
python train.py

# With exported logs:
python train.py --faceoffs /path/to/faceoffs.jsonl \
                --preferences /path/to/preferences.jsonl

# Real data only, no synthetic:
python train.py --weak-count 0

# train.py holds out the newest 20% of real pairs and prints held-out
# accuracy (the number that matters) before the final full-data training;
# --holdout 0 disables.
```

This writes `ImportanceRanker.mlpackage` into this directory. To ship it, copy
it into the app resources and rebuild:

```bash
cp -R ImportanceRanker.mlpackage ../../Shared/Resources/
cd ../../iOS   && xcodegen generate
cd ../macOS    && xcodegen generate
```

Both `project.yml`s reference `Shared/Resources/ImportanceRanker.mlpackage` as a
resource; Xcode compiles it to `.mlmodelc` at build and `CoreMLRanker` loads the
compiled form from the bundle.

## Notes / limitations

- coremltools needs macOS and a supported Python (3.13 works here; 3.14 does not
  yet load coremltools' native libs). No network access is required to train.
- The weak-teacher labels encode a rough prior, not ground truth; the model is
  only as good as the (currently synthetic) data. Real face-off/preference data
  is what makes it actually reflect Matt's preferences.
- Title/notes are only used as coarse length/word-count signals today. A real
  title-semantics feature (e.g. `NLEmbedding` in Swift with a matching Python
  representation) is a documented future step — omitted now to guarantee the two
  sides compute identical features.

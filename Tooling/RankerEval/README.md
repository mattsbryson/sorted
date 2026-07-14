# RankerEval — offline ranking evaluation harness

A self-contained Swift command-line tool that scores Sorted's ranking
strategies against the feedback the app collects, so competing strategies can be
compared on the *same* real data rather than by feel.

It answers one question per strategy: **of the comparisons the user actually
made, what fraction does this strategy order correctly?** — for both the
explicit Face Off judgments and the implicit judgments reconstructed from
everyday actions.

## Running

From this directory:

```sh
swift run RankerEval                              # evaluate the bundled sample data
swift run RankerEval faceoffs.jsonl               # your exported Face Off log
swift run RankerEval faceoffs.jsonl preferences.jsonl   # both logs
```

With no arguments it evaluates the synthetic logs in `SampleData/`, so a fresh
`swift run` prints meaningful output immediately. To evaluate your own data,
export the logs from the app (Settings ▸ **Export Log…** for `preferences.jsonl`
and **Export Face-Off Log…** for `faceoffs.jsonl`) and pass their paths. Either
argument may be omitted; the harness reports on whatever it's given.

Run the tests with `swift test`.

## What it measures

### Pairwise agreement accuracy (the headline metric)

Every judgment reduces to a labeled pair — *winner should rank above loser*. For
each pair the harness asks the strategy to score both items and checks whether it
ranks the winner strictly higher:

```
accuracy = correct / (correct + wrong)
```

Ties and pairs with a missing item are reported separately as `undet.`
(undetermined) and excluded from the denominator, so accuracy is never inflated
or deflated by pairs the strategy couldn't decide. A strategy that agreed with
every decidable judgment scores 100%; random ordering trends toward 50%.

This is identical whether the pairs came from Face Off or from reconstructed
actions, so the two sources are directly comparable.

### Two sources of pairs

- **Explicit — Face Off.** Each `faceoffs.jsonl` line is already a clean
  `winner`/`loser` pair: the user was shown two reminders and picked one. This is
  the cleanest label, with no ordering noise to untangle.

- **Implicit — reconstructed from actions.** Each `preferences.jsonl` line is an
  action (`complete`, `skip_home`, `skip_today`, `snooze`, `delete`) plus the
  ranked list the user saw. The reconstruction rule turns each into pairs (see
  `PreferenceReconstruction` in `Shared/`):
  - **complete** → the completed item beats everything it was ranked *above* (the
    user engaged with it and left those below alone).
  - **skip / snooze** → everything ranked *below* the skipped item beats it (the
    user moved past it to consider them).
  - **delete** → the deleted item loses to *every* other item still on the list.

  These are noisier labels than Face Off (a skip can mean "not now" rather than
  "less important"), but they're abundant and come from real usage.

## Strategies under test

Defined in `Sources/RankEvalCore/Strategies.swift`. On this branch, only what can
be reproduced from logged features is evaluable:

- **heuristic-baseline** — the app's deterministic `UrgencyScorer`
  (`0.55·time-urgency + 0.45·priority-importance`), the shipping composite when
  Apple Intelligence is off. This is the one strategy we can reproduce faithfully
  offline.
- **logged-app-score** — ranks by the 0–100 score the app *actually displayed*
  when each action was logged, which includes whatever live AI judgment was
  active then. The most faithful "what the app really did" baseline, with a
  heuristic fallback for items that carry no score.
- **time-only** — deadline pressure alone, ignoring importance. An ablation floor:
  how much do due dates alone explain the user's choices?

## What's evaluable now vs. after the ranker branches merge

The **AI importance tier is not written to the logs** (only the final composite
`score` is), so the Apple prioritizer's *content* judgment can't be replayed
offline here — `heuristic-baseline` and `logged-app-score` are the closest
proxies this branch can offer.

The Core ML LTR and MLX big-batch rankers live on sibling branches. When they
merge, adding each as a strategy is a **one-line append** to `Strategies.all`:
give it a `Strategy { name, detail, score }` closure that runs its model over the
same `LoggedReminder` features. Every table then scores all strategies on the
same pairs with no other change — the metric code and pair reconstruction are
ranker-agnostic by design.

## Layout

- `Sources/RankEvalCore/RankingMetrics.swift`, `PreferenceReconstruction.swift` —
  symlinks to the shared, unit-tested implementations in `../../Shared/Services/`,
  so the CLI and the in-app Ranker Lab use *one* copy of the math, not a fork.
- `Sources/RankEvalCore/LoggedData.swift` — JSON Lines decoders matching the
  app's export schema.
- `Sources/RankEvalCore/Strategies.swift` — the strategies to score (append here).
- `Sources/RankEvalCore/Evaluator.swift` — builds pairs from logs and scores them.
- `Sources/RankerEval/main.swift` — the CLI: parse args, print the report.
- `SampleData/` — synthetic `faceoffs.jsonl` / `preferences.jsonl` so `swift run`
  demonstrates output with no setup.

## Limitations

- Accuracy is only as meaningful as the labels. Implicit pairs are heuristic and
  noisy; treat the Face Off numbers as the stronger signal.
- The sample data is synthetic and small — it demonstrates the tool and its
  output format, not any real conclusion about which strategy is better.
- Only strategies reproducible from logged features are scored offline (see
  above); the on-device AI content judgment isn't replayable from the current log
  schema.

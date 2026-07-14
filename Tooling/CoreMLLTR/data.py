"""Load the on-device JSON Lines logs and build pairwise training examples.

A pairwise example is (winner_reminder, loser_reminder): the winner should score
higher. We train a RankNet-style model on the *difference* of their feature
vectors, so the learned scorer is a plain per-item function.

Sources, in order of signal quality:
  1. faceoffs.jsonl  — explicit {winner, loser} pairs. Cleanest.
  2. preferences.jsonl — implicit actions with the ranked `context` the user
     saw. We reconstruct pairs from the action:
       - complete/open: the acted item deserved its slot -> it should rank
         above every context item strictly below it.
       - skip/snooze:   the user pushed it down -> every context item strictly
         below it should rank above it.
       - delete: no ranking signal about the acted item's importance relative
         to others (user removed it), so we skip it.
  3. weak labels — synthetic pairs derived from the UrgencyScorer heuristic (a
     Python port of the importance fallback + tier weights) over synthetic
     reminders, so `train.py` always yields a model even with zero real data.
"""

from __future__ import annotations

import json
import os
import random
from typing import Iterable, Optional

from features import Reminder, extract


# --- reading logs ---------------------------------------------------------

def _read_jsonl(path: str) -> Iterable[dict]:
    if not path or not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def faceoff_pairs(path: str) -> list[tuple[Reminder, Reminder]]:
    pairs: list[tuple[Reminder, Reminder]] = []
    for ev in _read_jsonl(path):
        w, l = ev.get("winner"), ev.get("loser")
        if isinstance(w, dict) and isinstance(l, dict):
            pairs.append((Reminder.from_log(w), Reminder.from_log(l)))
    return pairs


_DOWN_ACTIONS = {"skip", "snooze"}
_UP_ACTIONS = {"complete", "open", "done"}


def preference_pairs(path: str) -> list[tuple[Reminder, Reminder]]:
    """Reconstruct pairwise (winner, loser) from implicit feedback.

    Only relative-to-context comparisons are emitted, and only against items
    strictly below the acted item in the list the user actually saw.
    """
    pairs: list[tuple[Reminder, Reminder]] = []
    for ev in _read_jsonl(path):
        action = (ev.get("action") or "").lower()
        item = ev.get("item")
        context = ev.get("context") or []
        if not isinstance(item, dict):
            continue
        pos = item.get("position")
        if pos is None:
            continue
        below = [c for c in context if isinstance(c, dict) and (c.get("position") or 0) > pos]
        acted = Reminder.from_log(item)
        if action in _UP_ACTIONS:
            for c in below:
                pairs.append((acted, Reminder.from_log(c)))
        elif action in _DOWN_ACTIONS:
            for c in below:
                pairs.append((Reminder.from_log(c), acted))
        # delete / unknown: no importance signal.
    return pairs


# --- weak-label bootstrap -------------------------------------------------

_LISTS = ["Work", "Personal", "Health", "Groceries", "Someday", "Finance", "Family"]

# Templates paired with a rough "true importance" 0..1 used only to generate
# consistent synthetic labels. This is a heuristic teacher, not ground truth.
_TEMPLATES = [
    ("Pay {} tax bill", 0.95, "Finance", 1),
    ("Call doctor about results", 0.95, "Health", 1),
    ("Renew passport", 0.85, "Personal", 5),
    ("Submit project report", 0.85, "Work", 1),
    ("Pick up prescription", 0.8, "Health", 5),
    ("Sign school forms for {}", 0.75, "Family", 5),
    ("Send invoice to client", 0.75, "Work", 5),
    ("Book dentist appointment", 0.6, "Health", 0),
    ("Reply to landlord email", 0.55, "Personal", 0),
    ("Buy milk and {}", 0.35, "Groceries", 0),
    ("Water the plants", 0.3, "Personal", 0),
    ("Take out recycling", 0.3, "Personal", 0),
    ("Organize photo library", 0.15, "Someday", 6),
    ("Watch that {} documentary", 0.1, "Someday", 6),
    ("Try new coffee place", 0.1, "Someday", 6),
]

_FILLERS = ["quarterly", "the kids", "climate", "eggs", "space", "annual", "history"]


def _synthetic_reminder(rng: random.Random) -> tuple[Reminder, float]:
    title_tpl, imp, list_name, priority = rng.choice(_TEMPLATES)
    title = title_tpl.format(rng.choice(_FILLERS)) if "{}" in title_tpl else title_tpl
    notes = rng.choice([None, None, "follow up", "see attached", "don't forget"])
    # Small jitter so identical templates aren't perfectly separable.
    imp = max(0.0, min(1.0, imp + rng.uniform(-0.05, 0.05)))
    return Reminder(title=title, notes=notes, list_name=list_name, priority=priority), imp


def weak_pairs(count: int, seed: int = 0) -> list[tuple[Reminder, Reminder]]:
    """Generate `count` weak pairwise labels from the heuristic teacher."""
    rng = random.Random(seed)
    pairs: list[tuple[Reminder, Reminder]] = []
    while len(pairs) < count:
        (a, ia), (b, ib) = _synthetic_reminder(rng), _synthetic_reminder(rng)
        if abs(ia - ib) < 0.08:
            continue  # too close to call — skip, keeps labels clean
        if ia > ib:
            pairs.append((a, b))
        else:
            pairs.append((b, a))
    return pairs


# --- assembling the training matrix --------------------------------------

def load_pairs(
    faceoffs: Optional[str],
    preferences: Optional[str],
    weak_count: int,
) -> tuple[list[tuple[Reminder, Reminder]], list[tuple[Reminder, Reminder]], dict]:
    """Return (real_pairs, weak_pairs, counts).

    Real pairs preserve log order (chronological), which is what makes a
    time-based holdout split meaningful in train.py.
    """
    real: list[tuple[Reminder, Reminder]] = []
    n_faceoff = 0
    n_pref = 0
    if faceoffs:
        fo = faceoff_pairs(faceoffs)
        n_faceoff = len(fo)
        real.extend(fo)
    if preferences:
        pr = preference_pairs(preferences)
        n_pref = len(pr)
        real.extend(pr)

    weak = weak_pairs(weak_count) if weak_count > 0 else []
    counts = {"faceoff_pairs": n_faceoff, "preference_pairs": n_pref, "weak_pairs": len(weak)}
    return real, weak, counts


def pair_titles(pairs: list[tuple[Reminder, Reminder]]) -> list[str]:
    return [r.title for pair in pairs for r in pair]


def pair_matrix(
    pairs: list[tuple[Reminder, Reminder]],
    embeddings: dict[str, list[float]],
) -> tuple[list[list[float]], list[int]]:
    """Rows of (winner_features - loser_features) labeled 1, each with its
    negated label-0 twin, so the logistic model learns an antisymmetric
    scorer. `embeddings` maps title -> TitleEmbedding vector (embeddings.py).
    """
    X: list[list[float]] = []
    y: list[int] = []
    for winner, loser in pairs:
        fw = extract(winner, embeddings.get(winner.title))
        fl = extract(loser, embeddings.get(loser.title))
        diff = [a - b for a, b in zip(fw, fl)]
        X.append(diff)
        y.append(1)
        # Symmetric negative example.
        X.append([-d for d in diff])
        y.append(0)
    return X, y

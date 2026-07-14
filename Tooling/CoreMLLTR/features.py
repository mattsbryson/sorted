"""Feature extraction for the Core ML learning-to-rank importance model.

THIS FILE IS THE CANONICAL FEATURE SCHEMA. The Swift side
(`Shared/Services/CoreMLRanker.swift`, function `features(for:)`) reimplements
exactly the same computation and MUST be kept in lockstep with it. If you change
anything here — order, count, normalization, hashing — change the Swift side too
and retrain/rebundle the model.

Design notes
------------
The model scores the *importance* axis only (real-world stakes), mirroring how
`AIPrioritizer`/`ImportanceTier` are date-blind: the time axis is computed
deterministically by `UrgencyScorer` at rank time and combined afterwards. So we
deliberately do NOT feed due dates / creation age into the model — those are not
"importance", they are timing, and folding them in would double-count against the
UrgencyScorer time term. (`dueInDays`/`createdDaysAgo` are still present in the
logs; they're just not model inputs here.)

All features are plain floats so they can be produced identically in Swift with
no locale/tokenizer dependencies.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Optional

# Number of hashed buckets for the reminder's list name. The "hashing trick":
# instead of a fixed one-hot vocabulary of list names (which the app can't know
# ahead of time), we hash the list name into a small fixed number of buckets.
# Keep this identical in Swift.
LIST_HASH_BUCKETS = 8

# Feature vector layout (index -> meaning). Kept as an explicit list so the
# README, the Core ML input description, and the Swift side all agree.
# Dimensionality of the semantic title embedding appended to the vector.
# Computed by TitleEmbedding.swift (via Tooling/EmbedTool at training time);
# must match TitleEmbedding.dimension.
EMBED_DIM = 32

FEATURE_NAMES = [
    "priority_high",       # 1 if RFC-5545 priority 1..4
    "priority_medium",     # 1 if priority == 5
    "priority_low",        # 1 if priority 6..9
    "priority_none",       # 1 if priority 0 / unset
    "has_notes",           # 1 if non-empty notes
    "title_len_norm",      # min(len(title), 100) / 100
    "title_words_norm",    # min(word_count(title), 20) / 20
    "notes_len_norm",      # min(len(notes), 140) / 140
] + [f"list_bucket_{i}" for i in range(LIST_HASH_BUCKETS)] \
  + [f"title_emb_{i}" for i in range(EMBED_DIM)]

FEATURE_COUNT = len(FEATURE_NAMES)


@dataclass
class Reminder:
    """The fields a logged reminder exposes that we turn into features.

    Matches `TrainingLog.LoggedReminder` / `PreferenceLog.LoggedItem`.
    """

    title: str = ""
    notes: Optional[str] = None
    list_name: str = ""
    priority: int = 0

    @classmethod
    def from_log(cls, d: dict) -> "Reminder":
        return cls(
            title=d.get("title") or "",
            notes=d.get("notes"),
            list_name=d.get("list") or "",
            priority=int(d.get("priority") or 0),
        )


def _priority_onehot(priority: int) -> list[float]:
    # Mirrors ReminderPriorityLevel(rawPriority:) in ReminderItem.swift.
    high = 1.0 if 1 <= priority <= 4 else 0.0
    medium = 1.0 if priority == 5 else 0.0
    low = 1.0 if 6 <= priority <= 9 else 0.0
    none = 1.0 if not (high or medium or low) else 0.0
    return [high, medium, low, none]


def _list_bucket(list_name: str) -> int:
    """Stable hash of the list name into [0, LIST_HASH_BUCKETS).

    Uses md5 (available identically everywhere) rather than Python's salted
    hash(); the Swift side reimplements this exact md5-based bucketing so the
    two agree bit for bit.
    """
    if not list_name:
        return 0
    digest = hashlib.md5(list_name.encode("utf-8")).digest()
    # First 4 bytes big-endian, matching the Swift implementation.
    value = int.from_bytes(digest[:4], byteorder="big")
    return value % LIST_HASH_BUCKETS


def _word_count(text: str) -> int:
    return len([w for w in text.split() if w])


def extract(reminder: Reminder, title_embedding: Optional[list[float]] = None) -> list[float]:
    """Turn one reminder into its float feature vector (length FEATURE_COUNT).

    `title_embedding` is the TitleEmbedding vector for `reminder.title`
    (see embeddings.py); None falls back to zeros, matching the Swift side's
    behavior when NLEmbedding is unavailable.
    """
    notes = reminder.notes or ""
    title = reminder.title or ""

    feats: list[float] = []
    feats.extend(_priority_onehot(reminder.priority))
    feats.append(1.0 if notes.strip() else 0.0)
    feats.append(min(len(title), 100) / 100.0)
    feats.append(min(_word_count(title), 20) / 20.0)
    feats.append(min(len(notes), 140) / 140.0)

    buckets = [0.0] * LIST_HASH_BUCKETS
    buckets[_list_bucket(reminder.list_name)] = 1.0
    feats.extend(buckets)

    embedding = title_embedding if title_embedding is not None else [0.0] * EMBED_DIM
    assert len(embedding) == EMBED_DIM, len(embedding)
    feats.extend(embedding)

    assert len(feats) == FEATURE_COUNT, (len(feats), FEATURE_COUNT)
    return feats

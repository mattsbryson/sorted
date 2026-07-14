"""Train the pairwise LTR importance model and export a Core ML .mlpackage.

Model
-----
RankNet-style logistic regression on feature *differences*. For a pair
(winner w, loser l) we model P(w > l) = sigmoid(W . (f(w) - f(l))). The bias
cancels in the difference, so the learned per-item score is simply

    score(item) = W . f(item)

which is exactly what the exported Core ML model computes: a single linear layer
mapping the FEATURE_COUNT-length feature vector to one scalar importance score.
The Swift side then squashes that scalar into the [0,1] importance weight and
combines it with UrgencyScorer's time axis.

Run:
    python train.py                 # weak-label bootstrap only
    python train.py --faceoffs /path/faceoffs.jsonl \
                    --preferences /path/preferences.jsonl
The default log paths point at the app's on-device directory if present.

No network access is required. Deps: numpy, coremltools (see requirements.txt).
"""

from __future__ import annotations

import argparse
import os

import numpy as np

from data import load_pairs, pair_matrix, pair_titles
from embeddings import embed_titles
from features import FEATURE_COUNT, FEATURE_NAMES

# The app's on-device Application Support directory (macOS). Used as the default
# log location so `python train.py` picks up exported/real logs automatically.
_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/Sorted")
DEFAULT_FACEOFFS = os.path.join(_APP_SUPPORT, "faceoffs.jsonl")
DEFAULT_PREFERENCES = os.path.join(_APP_SUPPORT, "preferences.jsonl")

MODEL_NAME = "ImportanceRanker"


def train_logistic(X: np.ndarray, y: np.ndarray, l2: float = 1e-2,
                   lr: float = 0.5, epochs: int = 2000) -> np.ndarray:
    """Plain full-batch gradient descent logistic regression, no bias.

    Returns the weight vector (length FEATURE_COUNT). Kept dependency-free
    (numpy only) and deterministic so training is reproducible.
    """
    n, d = X.shape
    w = np.zeros(d, dtype=np.float64)
    for _ in range(epochs):
        z = X @ w
        p = 1.0 / (1.0 + np.exp(-z))
        grad = X.T @ (p - y) / n + l2 * w
        w -= lr * grad
    return w


def evaluate(X: np.ndarray, y: np.ndarray, w: np.ndarray) -> float:
    """Pairwise accuracy: fraction of examples the scorer orders correctly."""
    if len(X) == 0:
        return float("nan")
    pred = (X @ w) > 0
    return float(np.mean(pred == (y > 0.5)))


def export_coreml(w: np.ndarray, out_dir: str) -> str:
    """Export a single-input, single-output linear Core ML model.

    Input:  "features" — MLMultiArray of shape (FEATURE_COUNT,)
    Output: "score"    — scalar importance (raw linear score)
    """
    import coremltools as ct
    from coremltools.models import datatypes
    from coremltools.models.neural_network import NeuralNetworkBuilder

    input_features = [("features", datatypes.Array(FEATURE_COUNT))]
    output_features = [("score", datatypes.Array(1))]
    builder = NeuralNetworkBuilder(input_features, output_features)
    builder.add_inner_product(
        name="linear",
        W=w.astype(np.float32).reshape(1, FEATURE_COUNT),
        b=np.zeros(1, dtype=np.float32),
        input_channels=FEATURE_COUNT,
        output_channels=1,
        has_bias=True,
        input_name="features",
        output_name="score",
    )

    mlmodel = ct.models.MLModel(builder.spec)
    mlmodel.author = "Sorted Core ML LTR pipeline"
    mlmodel.short_description = (
        "Pairwise learning-to-rank importance scorer. Input 'features' is the "
        f"{FEATURE_COUNT}-dim vector from Tooling/CoreMLLTR/features.py; output "
        "'score' is a raw linear importance score (higher = more important)."
    )
    mlmodel.input_description["features"] = (
        "Reminder feature vector: " + ", ".join(FEATURE_NAMES)
    )
    mlmodel.output_description["score"] = "Raw importance score (higher = more important)."

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{MODEL_NAME}.mlpackage")
    mlmodel.save(path)
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--faceoffs", default=DEFAULT_FACEOFFS,
                    help="Path to faceoffs.jsonl (explicit pairwise labels).")
    ap.add_argument("--preferences", default=DEFAULT_PREFERENCES,
                    help="Path to preferences.jsonl (implicit feedback).")
    ap.add_argument("--weak-count", type=int, default=4000,
                    help="Number of weak/synthetic pairs to bootstrap with. "
                         "Set 0 to train only on real data.")
    ap.add_argument("--holdout", type=float, default=0.2,
                    help="Fraction of real pairs (newest, by log order) held "
                         "out to report generalization before the final "
                         "full-data training. 0 disables.")
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)),
                    help="Output directory for the .mlpackage.")
    args = ap.parse_args()

    faceoffs = args.faceoffs if os.path.exists(args.faceoffs) else None
    preferences = args.preferences if os.path.exists(args.preferences) else None

    real, weak, counts = load_pairs(faceoffs, preferences, args.weak_count)
    if not real and not weak:
        print("No training data at all (no real logs and weak_count=0). "
              "Nothing to train. Re-run with --weak-count > 0.")
        raise SystemExit(1)

    print("Data sources:")
    print(f"  explicit face-off pairs : {counts['faceoff_pairs']}")
    print(f"  implicit preference pairs: {counts['preference_pairs']}")
    print(f"  weak/synthetic pairs     : {counts['weak_pairs']}")

    print("Embedding titles via Tooling/EmbedTool (the app's own Swift code)…")
    embeddings = embed_titles(pair_titles(real + weak))

    def matrices(pairs):
        X, y = pair_matrix(pairs, embeddings)
        return np.asarray(X, dtype=np.float64), np.asarray(y, dtype=np.float64)

    # Honest generalization check: train on the older real pairs + weak
    # prior, test on the newest slice the model never saw. Training accuracy
    # alone flatters memorization.
    n_test = int(len(real) * args.holdout)
    if n_test >= 5:
        Xh, yh = matrices(real[:-n_test] + weak)
        Xt, yt = matrices(real[-n_test:])
        held = evaluate(Xt, yt, train_logistic(Xh, yh))
        print(f"Held-out accuracy ({n_test} newest real pairs): {held:.3f}")
    elif args.holdout > 0:
        print("Held-out check skipped: too few real pairs to split.")

    X, y = matrices(real + weak)
    print(f"  total training rows      : {len(X)} "
          "(each pair contributes a +/- symmetric row)")

    w = train_logistic(X, y)
    acc = evaluate(X, y, w)
    print(f"Pairwise training accuracy : {acc:.3f} (on the training set — "
          "see held-out above for generalization)")
    print("Learned weights (top 16 by magnitude):")
    ranked = sorted(zip(FEATURE_NAMES, w), key=lambda t: -abs(t[1]))
    for name, weight in ranked[:16]:
        print(f"  {name:>16}: {weight:+.3f}")

    path = export_coreml(w, args.out)
    print(f"\nExported Core ML model -> {path}")


if __name__ == "__main__":
    main()

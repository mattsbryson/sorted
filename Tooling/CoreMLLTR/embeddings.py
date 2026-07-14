"""Title embeddings for training, computed by the app's own Swift code.

Parity with the app is by construction, not by porting: this module never
computes an embedding itself — it shells out to `Tooling/EmbedTool`, a tiny
CLI compiled from the very `Shared/Services/TitleEmbedding.swift` the app
runs (NLEmbedding sentence vector -> seeded 32-dim projection -> L2 norm).
Requires a Mac with the Swift toolchain (the same machine you train on).
"""

from __future__ import annotations

import json
import os
import subprocess

EMBED_DIM = 32  # Must match TitleEmbedding.dimension.

_TOOL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "EmbedTool")


def embed_titles(titles: list[str]) -> dict[str, list[float]]:
    """Embed all unique titles in one tool invocation: title -> vector."""
    unique = sorted(set(titles))
    if not unique:
        return {}
    proc = subprocess.run(
        ["swift", "run", "-c", "release", "--package-path", _TOOL_DIR, "embedtool"],
        input=json.dumps(unique).encode("utf-8"),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "embedtool failed (is the Swift toolchain installed?):\n"
            + proc.stderr.decode("utf-8", "replace")
        )
    vectors = json.loads(proc.stdout)
    assert all(len(v) == EMBED_DIM for v in vectors), "EMBED_DIM mismatch with TitleEmbedding.dimension"
    return dict(zip(unique, vectors))

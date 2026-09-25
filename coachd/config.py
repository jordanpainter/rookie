#!/usr/bin/env python3
"""Settings that belong to the person using this, not to the code.

The chess.com username was a default in an argument parser, which is fine for
one person and wrong for everyone else. Anything that is about *whose* chess
this is goes here, so packaging is a matter of filling this in rather than
grepping for a name.
"""
import json
import os
import paths

WORKSPACE = paths.HOME
PATH = os.path.join(WORKSPACE, "config.json")


def load():
    try:
        with open(PATH) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def get(key, default=None):
    value = load().get(key)
    return default if value in (None, "") else value


def set_value(key, value):
    data = load()
    data[key] = value
    tmp = PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(data, handle, indent=2)
    os.replace(tmp, PATH)
    return data


# ------------------------------------------------------- derived from ratings

# What Lichess's opening explorer will bucket by. Fixed by them, not by us.
EXPLORER_BUCKETS = (0, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500)


def explorer_bands(rating):
    """The three buckets worth seeing: yours, the one below, the one above.

    Masters play a different game. The useful question is what happens at the
    level you actually meet, and one bucket up is where you are heading. With
    no rating at all this returns the bottom three, which is where a new
    account starts anyway.
    """
    if not rating:
        return "0,1000,1200"
    mine = max(b for b in EXPLORER_BUCKETS if b <= rating)
    index = EXPLORER_BUCKETS.index(mine)
    # Three buckets, always. Sliding rather than clipping at the ends, so the
    # bottom of the range gets the two above it instead of a shorter window.
    start = min(max(0, index - 1), len(EXPLORER_BUCKETS) - 3)
    return ",".join(str(b) for b in EXPLORER_BUCKETS[start:start + 3])


def puzzle_band(rating):
    """Puzzle ratings to import: a little below what you can already do, and
    reaching well above it, because puzzles you cannot yet solve are where the
    improvement is. Lichess puzzle ratings run higher than chess.com's tactics
    score, which is why the window is wide and lopsided upward.
    """
    if not rating:
        return 400, 1300
    return max(400, rating - 300), rating + 600


def ratings():
    """The stored chess.com ratings, or an empty dict before an account is linked."""
    return load().get("ratings") or {}


def tactics_rating():
    return ratings().get("tactics")


def play_rating():
    """Rapid if it exists, else blitz, else bullet. Rapid is the one most
    people's rating actually reflects."""
    stored = ratings()
    for key in ("rapid", "blitz", "bullet"):
        if stored.get(key):
            return stored[key]
    return None

"""Where Rookie keeps its data, and where it finds Stockfish.

The data lives in one folder, chosen in this order:

1. `ROOKIE_HOME`, if set. How a clean install is tested without touching a real
   one.
2. `data_dir` in `~/Library/Application Support/Rookie/config.json`, if that
   file says so, which is how an install keeps its data somewhere else without
   moving the app. The pointer has to live at the default location: the folder
   cannot be named from a file inside the folder it names.
3. `~/Library/Application Support/Rookie`, which is what everyone else gets.

The Swift side resolves the same way (`Paths` in `CoachClient.swift`). Change
one, change both.
"""
import json
import os
import shutil

DEFAULT_HOME = os.path.expanduser("~/Library/Application Support/Rookie")


def _home():
    if os.environ.get("ROOKIE_HOME"):
        return os.path.expanduser(os.environ["ROOKIE_HOME"])
    try:
        with open(os.path.join(DEFAULT_HOME, "config.json")) as handle:
            pointed = json.load(handle).get("data_dir")
    except (OSError, ValueError, AttributeError):
        pointed = None
    return os.path.expanduser(pointed) if pointed else DEFAULT_HOME


HOME = _home()
os.makedirs(HOME, exist_ok=True)


def data(*parts):
    return os.path.join(HOME, *parts)


def stockfish():
    """The Stockfish bundled in Rookie.app, or Homebrew's, wherever this Mac keeps it.

    An app launched from the Dock does not get a shell's PATH, so `which` alone
    misses `/opt/homebrew/bin`; the two Homebrew prefixes are checked by hand.
    If none exists the first is returned anyway, so the failure happens when the
    engine starts, where the app already says to install Stockfish.
    """
    # Inside Rookie.app the engine sits next to this folder, in Resources.
    bundled = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stockfish")
    if os.access(bundled, os.X_OK):
        return os.path.abspath(bundled)
    found = shutil.which("stockfish")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"):
        if os.path.exists(candidate):
            return candidate
    return "/opt/homebrew/bin/stockfish"

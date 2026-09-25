#!/bin/sh
# Everything Rookie needs besides itself. Safe to run again: each step checks
# before it does anything.
#
#   ./setup.sh
#
# Data goes to ~/Library/Application Support/Rookie, or to ROOKIE_HOME if set.
# ROOKIE_MODEL picks a different Ollama model (default gemma4:12b, which is the
# one Chichi's voice was tuned against).
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
DATA="${ROOKIE_HOME:-$HOME/Library/Application Support/Rookie}"
MODEL="${ROOKIE_MODEL:-gemma4:12b}"
PYV="python@3.14"   # puzzles.py reads the Lichess dump with 3.14's built-in zstd

say() { printf '\n==> %s\n' "$1"; }

if ! command -v brew >/dev/null 2>&1; then
    echo "Rookie installs its engine and Python through Homebrew, which isn't here."
    echo "Install it from https://brew.sh, then run this again."
    exit 1
fi

say "Stockfish, the chess engine"
command -v stockfish >/dev/null 2>&1 || brew install stockfish

say "Python 3.14"
brew list "$PYV" >/dev/null 2>&1 || brew install "$PYV"
PY="$(brew --prefix "$PYV")/bin/python3.14"

say "Python environment in $DATA"
mkdir -p "$DATA"
[ -x "$DATA/venv/bin/python3" ] || "$PY" -m venv "$DATA/venv"
"$DATA/venv/bin/python3" -m pip install --quiet --upgrade pip chess
VPY="$DATA/venv/bin/python3"

say "Ollama and the model ($MODEL)"
command -v ollama >/dev/null 2>&1 || brew install ollama
if ! ollama list >/dev/null 2>&1; then
    echo "Ollama is installed but not running. Open the Ollama app"
    echo "(or run: brew services start ollama), then run this again."
    exit 1
fi
ollama list | awk 'NR > 1 {print $1}' | grep -qx "$MODEL" || ollama pull "$MODEL"

# Only when it differs from the app's own default, so a plain install writes no
# config at all and the default stays the one place the model is named.
# Values go in as arguments, never pasted into the Python: the puzzle query has
# quotes of its own.
if [ "$MODEL" != "gemma4:12b" ]; then
    ROOKIE_HOME="$DATA" "$VPY" - "$REPO/coachd" "$MODEL" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import config
config.set_value("model", sys.argv[2])
PYEOF
fi

count() {
    ROOKIE_HOME="$DATA" "$VPY" - "$REPO/coachd" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import db
print(db.connect().execute(sys.argv[2]).fetchone()[0])
PYEOF
}

say "The named opening list"
if [ "$(count 'SELECT COUNT(*) FROM openings')" -gt 0 ]; then
    echo "Already there."
else
    ROOKIE_HOME="$DATA" "$VPY" "$REPO/coachd/openings.py" import
fi

say "Puzzles"
if [ "$(count "SELECT COUNT(*) FROM puzzles WHERE source = 'lichess'")" -gt 0 ]; then
    echo "Already there. Settings can re-import them for your rating."
else
    echo "Streaming the Lichess puzzle set. This takes a few minutes."
    ROOKIE_HOME="$DATA" "$VPY" "$REPO/coachd/puzzles.py" import
fi

say "Done"
echo "Build and run from $REPO:"
echo "  swift build && .build/debug/ChessCoach"
echo "Then link your chess.com account from the gear in the top right."

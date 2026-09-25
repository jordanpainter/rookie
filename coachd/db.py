"""
SQLite storage for the coach. Until now the app had no memory of Jordan at
all: state lived in a JSON file that was overwritten every move. Everything
from game review onward needs a record that persists.

The database is the truth. `game-state.json` is still written on every move,
but only as a published view for Chichi to read.
"""
import os
import paths
import sqlite3

DEFAULT_PATH = paths.data("coach.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS games (
    id          INTEGER PRIMARY KEY,
    source      TEXT NOT NULL,               -- 'app' or 'chesscom'
    external_id TEXT UNIQUE,                 -- chess.com game url; NULL for app games
    played_at   TEXT,
    white       TEXT,
    black       TEXT,
    my_colour   TEXT,                        -- 'white' or 'black'
    result      TEXT,
    level       INTEGER,                     -- app games only
    status      TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS moves (
    game_id    INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    ply        INTEGER NOT NULL,             -- 0-based half-move
    uci        TEXT NOT NULL,
    san        TEXT NOT NULL,
    fen_before TEXT NOT NULL,                -- position the move was played FROM
    by_me      INTEGER NOT NULL,
    eval_cp    INTEGER,                      -- filled in by analysis, from the mover's side
    best_uci   TEXT,
    best_san   TEXT,
    loss_cp    INTEGER,
    severity   TEXT,                         -- inaccuracy / mistake / blunder
    PRIMARY KEY (game_id, ply)
);

-- Stockfish disagrees with itself run to run, because its hash table carries
-- between searches. Caching the first answer makes the coach reproducible:
-- the same position gets the same verdict every time it is ever asked about.
CREATE TABLE IF NOT EXISTS analysis_cache (
    fen       TEXT NOT NULL,
    limit_key TEXT NOT NULL,                 -- e.g. 't0.3' or 'd12'
    score_cp  INTEGER NOT NULL,              -- from the side-to-move's perspective
    best_uci  TEXT,
    depth     INTEGER,
    PRIMARY KEY (fen, limit_key)
);

-- Drills. Puzzles come from two places: the Lichess public set, and Jordan's
-- own blunders, which are the ones that actually cost him games.
CREATE TABLE IF NOT EXISTS puzzles (
    id         TEXT PRIMARY KEY,
    source     TEXT NOT NULL,               -- 'lichess' or 'own'
    fen        TEXT NOT NULL,               -- position BEFORE the opponent's move
    moves      TEXT NOT NULL,               -- space-separated UCI; moves[0] is theirs
    rating     INTEGER,
    themes     TEXT,
    popularity INTEGER,
    game_id    INTEGER REFERENCES games(id) ON DELETE SET NULL,
    played_san TEXT,                        -- what he actually played, for 'own'
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Endgame drills had no record at all, so they could not be counted. Puzzles
-- are counted from `puzzle_attempts` joined to the puzzle's own source, which
-- is where that fact already lives; this is only for the drills that have no
-- puzzle row to join to.
CREATE TABLE IF NOT EXISTS endgame_attempts (
    id           INTEGER PRIMARY KEY,
    drill        TEXT NOT NULL,          -- queen / rook / twoR / pawn
    attempted_at TEXT NOT NULL DEFAULT (datetime('now')),
    solved       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS puzzle_attempts (
    id           INTEGER PRIMARY KEY,
    puzzle_id    TEXT NOT NULL REFERENCES puzzles(id) ON DELETE CASCADE,
    attempted_at TEXT NOT NULL DEFAULT (datetime('now')),
    solved       INTEGER NOT NULL,
    seconds      REAL
);

-- SM-2 style spacing. A puzzle you got right recedes; one you failed comes back.
CREATE TABLE IF NOT EXISTS puzzle_schedule (
    puzzle_id     TEXT PRIMARY KEY REFERENCES puzzles(id) ON DELETE CASCADE,
    due_at        TEXT NOT NULL,
    interval_days REAL NOT NULL DEFAULT 0,
    ease          REAL NOT NULL DEFAULT 2.5,
    reps          INTEGER NOT NULL DEFAULT 0,
    lapses        INTEGER NOT NULL DEFAULT 0
);

-- The real ECO list, ~3,500 named lines, straight from lichess-org/chess-openings.
-- Replaces a hand-typed dictionary of 31 openings that could never keep up.
CREATE TABLE IF NOT EXISTS openings (
    eco   TEXT NOT NULL,
    name  TEXT NOT NULL,
    pgn   TEXT NOT NULL,               -- "1. e4 e5 2. Nf3"
    uci   TEXT NOT NULL,               -- space-separated, for replaying
    epd   TEXT NOT NULL,               -- position reached, for explorer lookups
    PRIMARY KEY (eco, name)
);

CREATE INDEX IF NOT EXISTS openings_epd  ON openings(epd);
CREATE INDEX IF NOT EXISTS openings_name ON openings(name);
CREATE INDEX IF NOT EXISTS puzzles_rating ON puzzles(rating);
CREATE INDEX IF NOT EXISTS puzzles_source ON puzzles(source);
CREATE INDEX IF NOT EXISTS schedule_due   ON puzzle_schedule(due_at);
CREATE INDEX IF NOT EXISTS moves_severity ON moves(severity) WHERE severity IS NOT NULL;
CREATE INDEX IF NOT EXISTS games_source   ON games(source);
CREATE INDEX IF NOT EXISTS moves_game     ON moves(game_id);
"""

# Columns added after the first databases already existed. CREATE TABLE IF NOT
# EXISTS will not add them, so they go on by hand.
MIGRATIONS = [
    ("games", "eco", "TEXT"),
    ("games", "opening", "TEXT"),
    ("games", "time_class", "TEXT"),
    ("games", "time_control", "TEXT"),
    ("moves", "clock_s", "REAL"),      # seconds left on the mover's clock after the move
]


def migrate(conn):
    for table, column, kind in MIGRATIONS:
        existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
    conn.commit()


def flatten(text):
    """A name reduced to plain lowercase words, so "King's Indian" and
    "kings indian" compare equal. Registered with SQLite below so the query
    and the stored names are normalised by exactly the same code."""
    if text is None:
        return ""
    out = []
    for ch in text.lower():
        if ch.isalnum():
            out.append(ch)
        elif ch in "'\u2019":
            pass          # King's -> kings, not "king s"
        else:
            out.append(" ")
    return " ".join("".join(out).split())


def record_endgame(conn, drill, solved):
    conn.execute("INSERT INTO endgame_attempts (drill, solved) VALUES (?, ?)",
                 (drill, int(solved)))
    conn.commit()


def connect(path=DEFAULT_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.create_function("flat", 1, flatten, deterministic=True)
    conn.executescript(SCHEMA)
    migrate(conn)
    return conn


def get_setting(conn, key, default=None):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(conn, key, value):
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, str(value)),
    )
    conn.commit()


def cached_analysis(conn, fen, limit_key):
    return conn.execute(
        "SELECT score_cp, best_uci, depth FROM analysis_cache WHERE fen = ? AND limit_key = ?",
        (fen, limit_key),
    ).fetchone()


def store_analysis(conn, fen, limit_key, score_cp, best_uci, depth):
    conn.execute(
        "INSERT OR IGNORE INTO analysis_cache (fen, limit_key, score_cp, best_uci, depth) "
        "VALUES (?, ?, ?, ?, ?)",
        (fen, limit_key, score_cp, best_uci, depth),
    )
    conn.commit()


def new_game(conn, source, level=None, white=None, black=None, my_colour=None,
             external_id=None, played_at=None, result=None, eco=None, opening=None,
             time_class=None, time_control=None, status="ongoing"):
    cur = conn.execute(
        "INSERT INTO games (source, external_id, played_at, white, black, my_colour, "
        "result, level, status, eco, opening, time_class, time_control) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (source, external_id, played_at, white, black, my_colour, result, level,
         status, eco, opening, time_class, time_control),
    )
    conn.commit()
    return cur.lastrowid


def record_moves(conn, rows):
    """Bulk insert. `rows` are (game_id, ply, uci, san, fen_before, by_me, clock_s)."""
    conn.executemany(
        "INSERT OR REPLACE INTO moves (game_id, ply, uci, san, fen_before, by_me, clock_s) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
    conn.commit()


def store_analyses(conn, rows):
    """Bulk cache write. `rows` are (fen, limit_key, score_cp, best_uci, depth)."""
    conn.executemany(
        "INSERT OR IGNORE INTO analysis_cache (fen, limit_key, score_cp, best_uci, depth) "
        "VALUES (?, ?, ?, ?, ?)", rows)
    conn.commit()


def record_move(conn, game_id, ply, uci, san, fen_before, by_me):
    conn.execute(
        "INSERT OR REPLACE INTO moves (game_id, ply, uci, san, fen_before, by_me) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (game_id, ply, uci, san, fen_before, int(by_me)),
    )
    conn.commit()


def set_game_status(conn, game_id, status):
    conn.execute("UPDATE games SET status = ? WHERE id = ?", (status, game_id))
    conn.commit()


def delete_moves_from(conn, game_id, ply):
    """Drop this move and everything after it. Used by takeback."""
    conn.execute("DELETE FROM moves WHERE game_id = ? AND ply >= ?", (game_id, ply))
    conn.commit()


def game_moves(conn, game_id):
    return conn.execute(
        "SELECT uci FROM moves WHERE game_id = ? ORDER BY ply", (game_id,)
    ).fetchall()


def game_colour(conn, game_id):
    """Which side the player had. Returns None for a game that predates the
    column being filled in, whose caller should assume white."""
    row = conn.execute("SELECT my_colour FROM games WHERE id = ?", (game_id,)).fetchone()
    return row["my_colour"] if row else None

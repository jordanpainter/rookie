#!/usr/bin/env python3
"""
Drills. Two sources, and the second one matters more.

The Lichess set is six million public-domain puzzles, filtered here to the band
Jordan can actually solve. His own blunders are the other source: every position
where he threw something away is a puzzle he has already failed once, in a real
game, which is a far stickier thing to be shown again.

Scheduling is SM-2: get one right and it recedes, get it wrong and it comes back
tomorrow.

Usage:
  puzzles.sh import [--min 400] [--max 1200]   fetch and filter the Lichess set
  puzzles.sh from-blunders [--limit N]         build puzzles from real games
  puzzles.sh next                              the next puzzle due
  puzzles.sh grade <id> <solved 0|1>           record an attempt and reschedule
  puzzles.sh stats
"""
import argparse
import csv
import datetime
import io
import json
import os
import sys
import urllib.request
from compression import zstd

import chess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config
import db as database

PUZZLE_URL = "https://database.lichess.org/lichess_db_puzzle.csv.zst"

# The band to import, derived from the linked account's tactics rating. See
# config.puzzle_band for the rule. Falls back to 400-1300 with no account
# linked, which is where a beginner would want it anyway.


# ---------------------------------------------------------------- import

def import_lichess(conn, low, high, cap=None):
    """Stream the dump, keep only what is in band, never land it on disk."""
    print(f"streaming {PUZZLE_URL}", flush=True)
    print(f"keeping puzzles rated {low}-{high}", flush=True)

    request = urllib.request.Request(PUZZLE_URL, headers={"User-Agent": "chess-coach/1.0"})
    kept = seen = 0
    batch = []

    with urllib.request.urlopen(request, timeout=120) as response:
        with zstd.ZstdFile(response) as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8")
            for row in csv.DictReader(text):
                seen += 1
                try:
                    rating = int(row["Rating"])
                    popularity = int(row["Popularity"])
                except (ValueError, KeyError):
                    continue
                # Popularity below zero means solvers disliked it, usually
                # because the "solution" is ambiguous.
                if not (low <= rating <= high) or popularity < 50:
                    continue

                batch.append((row["PuzzleId"], "lichess", row["FEN"], row["Moves"],
                              rating, row["Themes"], popularity, None, None))
                kept += 1
                if len(batch) >= 5000:
                    _store(conn, batch); batch.clear()
                    print(f"  kept {kept} of {seen} scanned", flush=True)
                if cap and kept >= cap:
                    break
    if batch:
        _store(conn, batch)
    print(f"imported {kept} puzzles (scanned {seen})")
    return kept


def trim(conn, per_bucket=3000):
    """Keep only the most-played puzzles in each 100-point rating band.

    The full in-band set is 2.5 million puzzles, which is over three centuries
    of daily practice and half a gigabyte of database. Popularity is the right
    thing to keep by: the most-played puzzles are the ones whose solution is
    least ambiguous.
    """
    before = conn.execute("SELECT COUNT(*) FROM puzzles WHERE source='lichess'").fetchone()[0]
    conn.execute("""
        DELETE FROM puzzles WHERE source = 'lichess' AND id NOT IN (
            SELECT id FROM (
                SELECT id, ROW_NUMBER() OVER (
                    PARTITION BY rating / 100 ORDER BY popularity DESC, nb_key
                ) AS rn
                FROM (SELECT id, rating, popularity, id AS nb_key FROM puzzles
                      WHERE source = 'lichess')
            ) WHERE rn <= ?
        )""", (per_bucket,))
    conn.commit()
    after = conn.execute("SELECT COUNT(*) FROM puzzles WHERE source='lichess'").fetchone()[0]
    print(f"trimmed {before} -> {after} puzzles (top {per_bucket} per 100-point band)")
    conn.execute("VACUUM")
    # The in-band set passes through the write-ahead log on its way to being
    # trimmed, and the log keeps the high-water mark: a 7 MB database was
    # sitting next to a 351 MB .db-wal after a first import. Nothing reads it
    # again, so fold it back in.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return after


def _store(conn, rows):
    conn.executemany(
        "INSERT OR IGNORE INTO puzzles (id, source, fen, moves, rating, themes, "
        "popularity, game_id, played_san) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    conn.commit()


def import_own_blunders(conn, limit=None):
    """Every blunder the player made while the game was still level, turned
    back into a puzzle.

    The stored `fen_before` is the position they faced. The solution is what the
    engine wanted; `played_san` is what they actually did, so the drill can say
    they have seen this before and what they chose last time.

    Only blunders from positions within `history.COMPETITIVE` of level, the same
    rule as the Review tab's "while the game was still level" figure. A blunder
    in a game already lost changes nothing, and taking every one turned 282
    games into 1,520 puzzles, most of them about games that were over.
    """
    from history import COMPETITIVE
    rows = conn.execute("""
        SELECT m.game_id, m.ply, m.fen_before, m.best_uci, m.san, m.loss_cp, g.played_at
        FROM moves m JOIN games g ON g.id = m.game_id
        WHERE g.source = 'chesscom' AND m.by_me = 1 AND m.severity = 'blunder'
          AND m.best_uci IS NOT NULL
          AND m.eval_cp IS NOT NULL AND ABS(m.eval_cp) <= ?
        ORDER BY m.loss_cp DESC
    """, (COMPETITIVE,)).fetchall()

    kept, batch = 0, []
    for row in rows:
        if limit and kept >= limit:
            break
        board = chess.Board(row["fen_before"])
        try:
            best = chess.Move.from_uci(row["best_uci"])
        except ValueError:
            continue
        if best not in board.legal_moves:
            continue

        # Lichess puzzles start one move early, with the opponent's move first.
        # These start at Jordan's turn, so there is no opponent move to prepend
        # and `moves` is just the answer.
        batch.append((f"own-{row['game_id']}-{row['ply']}", "own", row["fen_before"],
                      best.uci(), None, "own-blunder", None, row["game_id"], row["san"]))
        kept += 1

    if batch:
        _store(conn, batch)
    print(f"built {kept} puzzles from your own blunders")
    return kept


# ---------------------------------------------------------------- scheduling

def sm2(ease, interval, reps, solved):
    """Classic SM-2, simplified to pass/fail.

    A failure resets the interval and nudges the ease down, so a puzzle you keep
    missing keeps coming back rather than drifting away.
    """
    if not solved:
        return max(1.3, ease - 0.2), 0.0, 0, True
    reps += 1
    if reps == 1:
        interval = 1.0
    elif reps == 2:
        interval = 3.0
    else:
        interval = round(interval * ease, 1)
    return min(2.8, ease + 0.05), interval, reps, False


def grade(conn, puzzle_id, solved, seconds=None):
    conn.execute("INSERT INTO puzzle_attempts (puzzle_id, solved, seconds) VALUES (?, ?, ?)",
                 (puzzle_id, int(bool(solved)), seconds))
    row = conn.execute("SELECT ease, interval_days, reps, lapses FROM puzzle_schedule "
                       "WHERE puzzle_id = ?", (puzzle_id,)).fetchone()
    ease, interval, reps, lapses = (row["ease"], row["interval_days"], row["reps"],
                                    row["lapses"]) if row else (2.5, 0.0, 0, 0)

    ease, interval, reps, lapsed = sm2(ease, interval, reps, solved)
    due = datetime.datetime.now() + datetime.timedelta(days=interval if interval else 0)
    conn.execute(
        "INSERT INTO puzzle_schedule (puzzle_id, due_at, interval_days, ease, reps, lapses) "
        "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(puzzle_id) DO UPDATE SET "
        "due_at=excluded.due_at, interval_days=excluded.interval_days, ease=excluded.ease, "
        "reps=excluded.reps, lapses=excluded.lapses",
        (puzzle_id, due.isoformat(), interval, ease, reps, lapses + int(lapsed)))
    conn.commit()
    return {"puzzle_id": puzzle_id, "solved": bool(solved), "next_due": due.isoformat(),
            "interval_days": interval, "ease": round(ease, 2), "reps": reps}


def next_puzzle(conn, source=None):
    """Anything overdue first, oldest due first; then anything never seen.

    Your own blunders are served before strangers' puzzles, because they are
    positions you have already lost material in. Within them the order is by
    rowid, which is the order they were built in: worst blunder first. Ordering
    by rating was wrong, since own-puzzles have none and NULL sorts arbitrarily.
    """
    where = "AND p.source = ?" if source else ""
    args = (source,) if source else ()
    row = conn.execute(f"""
        SELECT p.*, s.due_at FROM puzzles p
        JOIN puzzle_schedule s ON s.puzzle_id = p.id
        WHERE s.due_at <= datetime('now') {where}
        ORDER BY s.due_at LIMIT 1""", args).fetchone()
    if row is None:
        row = conn.execute(f"""
            SELECT p.*, NULL AS due_at FROM puzzles p
            LEFT JOIN puzzle_schedule s ON s.puzzle_id = p.id
            WHERE s.puzzle_id IS NULL {where}
            ORDER BY CASE p.source WHEN 'own' THEN 0 ELSE 1 END,
                     COALESCE(p.rating, 0), p.rowid LIMIT 1""", args)
        row = row.fetchone()
    if row is None:
        return None

    puzzle = dict(row)
    board = chess.Board(puzzle["fen"])
    moves = puzzle["moves"].split()
    # Lichess puzzles open with the opponent's move; play it so the position
    # handed to the solver is the one they actually have to solve.
    if puzzle["source"] == "lichess" and moves:
        opening = chess.Move.from_uci(moves[0])
        puzzle["opponent_move"] = board.san(opening)
        board.push(opening)
        moves = moves[1:]
    puzzle["position_fen"] = board.fen()
    puzzle["solution"] = moves
    puzzle["solution_san"] = board.san(chess.Move.from_uci(moves[0])) if moves else None
    puzzle["turn"] = "white" if board.turn == chess.WHITE else "black"
    return puzzle


def today(conn):
    """What was attempted today, per drill source.

    The Drill tab used to show one lifetime tally across every source, so a
    puzzle failed on Tuesday was still being reported on Friday and there was no
    way to tell a bad day at endgames from a bad day at your own blunders. Local
    time, not UTC: "today" should end when the day does, not at one in the
    morning.
    """
    out = {}
    for row in conn.execute(
            "SELECT p.source AS source, COUNT(*) AS n, "
            "       COALESCE(SUM(a.solved), 0) AS s "
            "FROM puzzle_attempts a JOIN puzzles p ON p.id = a.puzzle_id "
            "WHERE date(a.attempted_at, 'localtime') = date('now', 'localtime') "
            "GROUP BY p.source"):
        out[row["source"]] = {"solved": row["s"], "attempted": row["n"]}
    row = conn.execute(
        "SELECT COUNT(*) AS n, COALESCE(SUM(solved), 0) AS s FROM endgame_attempts "
        "WHERE date(attempted_at, 'localtime') = date('now', 'localtime')").fetchone()
    out["endgame"] = {"solved": row["s"], "attempted": row["n"]}
    for source in ("own", "lichess", "endgame"):
        out.setdefault(source, {"solved": 0, "attempted": 0})
    return out


def stats(conn):
    out = {"total": conn.execute("SELECT COUNT(*) FROM puzzles").fetchone()[0]}
    for row in conn.execute("SELECT source, COUNT(*) c, MIN(rating), MAX(rating) "
                            "FROM puzzles GROUP BY source"):
        out[row["source"]] = {"count": row["c"], "min_rating": row[2], "max_rating": row[3]}
    out["attempted"] = conn.execute("SELECT COUNT(DISTINCT puzzle_id) FROM puzzle_attempts").fetchone()[0]
    out["solved"] = conn.execute("SELECT COUNT(*) FROM puzzle_attempts WHERE solved = 1").fetchone()[0]
    out["failed"] = conn.execute("SELECT COUNT(*) FROM puzzle_attempts WHERE solved = 0").fetchone()[0]
    out["today"] = today(conn)
    out["due_now"] = conn.execute(
        "SELECT COUNT(*) FROM puzzle_schedule WHERE due_at <= datetime('now')").fetchone()[0]
    return out


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("import")
    low, high = config.puzzle_band(config.tactics_rating())
    p.add_argument("--min", type=int, default=low)
    p.add_argument("--max", type=int, default=high)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--per-bucket", type=int, default=3000,
                   help="keep this many of the most-played puzzles per 100 rating points")

    b = sub.add_parser("from-blunders")
    b.add_argument("--limit", type=int, default=None)

    n = sub.add_parser("next")
    n.add_argument("--source", choices=["lichess", "own"], default=None)

    g = sub.add_parser("grade")
    g.add_argument("puzzle_id")
    g.add_argument("solved", type=int, choices=[0, 1])
    g.add_argument("--seconds", type=float, default=None)

    t = sub.add_parser("trim")
    t.add_argument("--per-bucket", type=int, default=3000)
    sub.add_parser("stats")
    args = parser.parse_args()

    conn = database.connect()
    if args.command == "import":
        import_lichess(conn, args.min, args.max, args.limit)
        trim(conn, args.per_bucket)
    elif args.command == "trim":
        trim(conn, args.per_bucket)
    elif args.command == "from-blunders":
        import_own_blunders(conn, args.limit)
    elif args.command == "next":
        print(json.dumps(next_puzzle(conn, args.source), indent=2))
    elif args.command == "grade":
        print(json.dumps(grade(conn, args.puzzle_id, args.solved, args.seconds), indent=2))
    else:
        print(json.dumps(stats(conn), indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
The whole history, not just the last game.

Chess.com holds every game Jordan has played; the coach was only ever looking
at one of them at a time. This imports the lot, evaluates every position once,
and reports where the rating is actually going.

Positions are cached in `analysis_cache`, shared with coachd, and openings
repeat heavily across games, so the expensive part runs once and shrinks every
time it is asked again.

Usage:
  history.sh import                 fetch and store every game
  history.sh analyse [--workers N]  evaluate every position not yet evaluated
  history.sh report                 where the rating goes
  history.sh link --username <name> link an account, derive the bands from it
  history.sh account                what is linked, and what was derived
"""
import argparse
import contextlib
import datetime
import io
import json
import multiprocessing as mp
import os
import sys
import time

import chess
import chess.engine
import chess.pgn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import analyze
import config
import db as database

STOCKFISH_PATH = paths.stockfish()
TIME_PER_MOVE = 0.3
LIMIT_KEY = f"t{TIME_PER_MOVE:g}"

INACCURACY, MISTAKE, BLUNDER = 50, 100, 200

PIECE_NAMES = {
    chess.PAWN: "pawn", chess.KNIGHT: "knight", chess.BISHOP: "bishop",
    chess.ROOK: "rook", chess.QUEEN: "queen", chess.KING: "king",
}


# ---------------------------------------------------------------- linking

def forget_account(conn):
    """Drop everything that belongs to whoever was linked before.

    Moves cascade from games; own-blunder puzzles do not, because a puzzle's
    game_id is ON DELETE SET NULL, so they are deleted explicitly or they
    survive as orphans and quietly keep drilling the last person's mistakes.
    Lichess puzzles are nobody's in particular and stay.
    """
    puzzles = conn.execute("DELETE FROM puzzles WHERE source = 'own'").rowcount
    games = conn.execute("DELETE FROM games WHERE source = 'chesscom'").rowcount
    conn.commit()
    return games, puzzles


def account(conn):
    """What is currently linked and what has been derived from it, for the
    settings panel. Costs a config read and two counts, so it can be called
    every time the panel opens."""
    username = config.get("chesscom_username")
    ratings = config.ratings()
    low, high = config.puzzle_band(ratings.get("tactics"))
    count = lambda sql, args=(): conn.execute(sql, args).fetchone()[0]
    return {
        "username": username,
        "ratings": ratings,
        "explorer_bands": config.explorer_bands(config.play_rating()),
        "puzzle_band": [low, high],
        "games": count("SELECT COUNT(*) FROM games WHERE source = 'chesscom'"),
        "own_puzzles": count("SELECT COUNT(*) FROM puzzles WHERE source = 'own'"),
        "lichess_puzzles": count("SELECT COUNT(*) FROM puzzles WHERE source = 'lichess'"),
        "lichess_out_of_band": count(
            "SELECT COUNT(*) FROM puzzles WHERE source = 'lichess' "
            "AND (rating < ? OR rating > ?)", (low, high)),
    }


def link(conn, username):
    """Point the coach at a chess.com account and personalise what it derives.

    The rating is what makes the rest fit: the opening explorer reports the
    buckets around it, and the puzzle import aims a little below and well
    above the tactics score. Linking someone new wipes the old account's games
    and blunder puzzles, because a review built from two players is a report
    about neither.
    """
    ratings = analyze.fetch_stats(username)          # raises if there is no such account
    previous = config.get("chesscom_username")
    removed_games = removed_puzzles = 0
    if previous and previous.lower() != username.lower():
        removed_games, removed_puzzles = forget_account(conn)

    config.set_value("chesscom_username", username)
    config.set_value("ratings", ratings)

    low, high = config.puzzle_band(ratings.get("tactics"))
    stale = conn.execute(
        "SELECT COUNT(*) FROM puzzles WHERE source = 'lichess' "
        "AND (rating < ? OR rating > ?)", (low, high)).fetchone()[0]
    return {
        "username": username,
        "ratings": ratings,
        "explorer_bands": config.explorer_bands(config.play_rating()),
        "puzzle_band": [low, high],
        "replaced": previous if previous and previous.lower() != username.lower() else None,
        "removed_games": removed_games,
        "removed_puzzles": removed_puzzles,
        "lichess_out_of_band": stale,
    }


# ---------------------------------------------------------------- import

def import_games(conn, username):
    games = analyze.load_games(username)
    known = {row["external_id"] for row in
             conn.execute("SELECT external_id FROM games WHERE external_id IS NOT NULL")}

    added = 0
    for raw in games:
        external_id = analyze.game_id(raw)
        if external_id in known:
            continue

        white, black = raw["white"]["username"], raw["black"]["username"]
        i_am_white = white.lower() == username.lower()
        mine = raw["white"] if i_am_white else raw["black"]

        pgn = chess.pgn.read_game(io.StringIO(raw["pgn"]))
        if pgn is None:
            continue
        eco_url = pgn.headers.get("ECOUrl", "")
        opening = eco_url.rsplit("/", 1)[-1].replace("-", " ") if eco_url else None

        game_pk = database.new_game(
            conn, "chesscom",
            external_id=external_id,
            played_at=(datetime.datetime.fromtimestamp(raw["end_time"]).isoformat()
                       if raw.get("end_time") else None),
            white=white, black=black,
            my_colour="white" if i_am_white else "black",
            result=mine["result"],
            eco=pgn.headers.get("ECO"),
            opening=opening,
            time_class=raw.get("time_class"),
            time_control=raw.get("time_control"),
            status="finished",
        )

        board = pgn.board()
        my_colour = chess.WHITE if i_am_white else chess.BLACK
        rows = []
        node = pgn
        ply = 0
        while node.variations:
            node = node.variation(0)
            rows.append((game_pk, ply, node.move.uci(), board.san(node.move),
                         board.fen(), int(board.turn == my_colour), node.clock()))
            board.push(node.move)
            ply += 1
        database.record_moves(conn, rows)
        added += 1

    return added, len(games)


# ---------------------------------------------------------------- analysis

_engine = None


def _worker_init():
    global _engine
    _engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH_PATH)
    _engine.configure({"Skill Level": 20})


def _worker_analyse(fen):
    board = chess.Board(fen)
    info = _engine.analyse(board, chess.engine.Limit(time=TIME_PER_MOVE))
    pov = info["score"].pov(board.turn)
    if pov.is_mate():
        mate = pov.mate()
        score = 10000 - abs(mate) * 10 if mate > 0 else -10000 + abs(mate) * 10
    else:
        score = pov.score()
    best = info["pv"][0].uci() if info.get("pv") else None
    return fen, score, best, info.get("depth")


def positions_needing_analysis(conn):
    """Every position we hold that has never been evaluated, deduplicated.

    Includes the position each game ended in: evaluating a move needs the
    position after it as well as before it.
    """
    wanted = set()
    for row in conn.execute(
            "SELECT fen_before FROM moves WHERE game_id IN "
            "(SELECT id FROM games WHERE source = 'chesscom')"):
        wanted.add(row["fen_before"])

    for row in conn.execute(
            "SELECT g.id FROM games g WHERE g.source = 'chesscom'"):
        moves = conn.execute(
            "SELECT uci FROM moves WHERE game_id = ? ORDER BY ply", (row["id"],)).fetchall()
        board = chess.Board()
        try:
            for m in moves:
                board.push(chess.Move.from_uci(m["uci"]))
        except ValueError:
            continue
        wanted.add(board.fen())

    cached = {r["fen"] for r in conn.execute(
        "SELECT fen FROM analysis_cache WHERE limit_key = ?", (LIMIT_KEY,))}
    return sorted(wanted - cached)


def analyse_all(conn, workers):
    todo = positions_needing_analysis(conn)
    if not todo:
        print("Every position is already evaluated.")
    else:
        print(f"{len(todo)} positions to evaluate on {workers} workers "
              f"(~{len(todo) * TIME_PER_MOVE / workers / 60:.0f} min)", flush=True)
        started = time.time()
        done, batch = 0, []
        with mp.Pool(workers, initializer=_worker_init) as pool:
            for fen, score, best, depth in pool.imap_unordered(_worker_analyse, todo, chunksize=16):
                batch.append((fen, LIMIT_KEY, score, best, depth))
                done += 1
                if len(batch) >= 500:
                    database.store_analyses(conn, batch)
                    batch.clear()
                # Every 100, not every 500: the Review tab turns this line into
                # a progress bar, and a first link runs for minutes.
                if done % 100 == 0:
                    rate = done / (time.time() - started)
                    print(f"  {done}/{len(todo)}  {rate:.0f}/s  "
                          f"eta {(len(todo) - done) / rate / 60:.0f} min", flush=True)
        if batch:
            database.store_analyses(conn, batch)
        print(f"evaluated {done} positions in {(time.time() - started) / 60:.1f} min")

    score_moves(conn)


def score_moves(conn):
    """Turn cached evaluations into per-move verdicts.

    The position after move n is the position before move n+1, so one lookup
    per position covers both sides of every move.
    """
    cache = {r["fen"]: (r["score_cp"], r["best_uci"]) for r in conn.execute(
        "SELECT fen, score_cp, best_uci FROM analysis_cache WHERE limit_key = ?", (LIMIT_KEY,))}

    updates = []
    for game in conn.execute("SELECT id FROM games WHERE source = 'chesscom'"):
        moves = conn.execute(
            "SELECT ply, uci, fen_before FROM moves WHERE game_id = ? ORDER BY ply",
            (game["id"],)).fetchall()
        if not moves:
            continue
        board = chess.Board()
        fens = [m["fen_before"] for m in moves]
        for m in moves:
            board.push(chess.Move.from_uci(m["uci"]))
        fens.append(board.fen())

        replay = chess.Board()
        for index, move in enumerate(moves):
            before = cache.get(fens[index])
            after = cache.get(fens[index + 1])
            uci = move["uci"]
            if before is None or after is None:
                replay.push(chess.Move.from_uci(uci))
                continue

            best_eval, best_uci = before
            played_eval = -after[0]
            loss = max(0, best_eval - played_eval)
            severity = ("blunder" if loss >= BLUNDER else
                        "mistake" if loss >= MISTAKE else
                        "inaccuracy" if loss >= INACCURACY else None)
            best_san = None
            if best_uci:
                try:
                    best_san = replay.san(chess.Move.from_uci(best_uci))
                except (ValueError, AssertionError):
                    best_san = None
            replay.push(chess.Move.from_uci(uci))
            updates.append((best_eval, best_uci, best_san, loss, severity,
                            game["id"], move["ply"]))

    conn.executemany(
        "UPDATE moves SET eval_cp = ?, best_uci = ?, best_san = ?, loss_cp = ?, severity = ? "
        "WHERE game_id = ? AND ply = ?", updates)
    conn.commit()
    print(f"scored {len(updates)} moves")


# ---------------------------------------------------------------- report

DRAWS = {"stalemate", "insufficient", "agreed", "repetition", "50move", "timevsinsufficient"}
CLOCK_BUCKETS = [("under 10s", 0, 10), ("10 to 30s", 10, 30),
                 ("30 to 60s", 30, 60), ("over 60s", 60, 10 ** 9)]

# A blunder in a position that was already lost teaches much less than one that
# threw away a level game. COMPETITIVE is the window where the game was still
# genuinely in the balance.
COMPETITIVE = 200
NON_PAWN = {chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9}


def phase_of(board, ply):
    if ply < 24:
        return "opening"
    material = sum(NON_PAWN.get(p.piece_type, 0) for p in board.piece_map().values())
    return "endgame" if material <= 13 else "middlegame"


def pct(part, whole):
    return f"{100 * part / whole:.0f}%" if whole else "  -"


def bar(fraction, width=18):
    return "#" * round(fraction * width)


def compute_stats(conn):
    """Everything the report shows, as plain data. The terminal view and the
    app's Review tab both render this, so they can never disagree."""
    games = conn.execute(
        "SELECT id, my_colour, result, opening, time_class FROM games "
        "WHERE source = 'chesscom'").fetchall()
    if not games:
        return None

    wins = sum(1 for g in games if g["result"] == "win")
    draws = sum(1 for g in games if g["result"] in DRAWS)
    outcomes = {}
    for g in games:
        outcomes[g["result"]] = outcomes.get(g["result"], 0) + 1

    rows = conn.execute(
        "SELECT m.ply, m.uci, m.fen_before, m.severity, m.loss_cp, m.eval_cp, m.clock_s, g.my_colour "
        "FROM moves m JOIN games g ON g.id = m.game_id "
        "WHERE g.source = 'chesscom' AND m.by_me = 1 AND m.loss_cp IS NOT NULL").fetchall()

    phase, piece, colour = {}, {}, {}
    for r in rows:
        board = chess.Board(r["fen_before"])
        is_blunder = r["severity"] == "blunder"

        key = phase_of(board, r["ply"])
        seen = phase.setdefault(key, [0, 0]); seen[0] += 1; seen[1] += is_blunder

        moved = board.piece_at(chess.Move.from_uci(r["uci"]).from_square)
        key = PIECE_NAMES.get(moved.piece_type, "?") if moved else "?"
        seen = piece.setdefault(key, [0, 0]); seen[0] += 1; seen[1] += is_blunder

        seen = colour.setdefault(r["my_colour"], [0, 0]); seen[0] += 1; seen[1] += is_blunder

    clock = {}
    for label, low, high in CLOCK_BUCKETS:
        subset = [r for r in rows if r["clock_s"] is not None and low <= r["clock_s"] < high]
        clock[label] = [len(subset), sum(1 for r in subset if r["severity"] == "blunder")]

    timed = [r["clock_s"] for r in rows if r["clock_s"] is not None]
    clock_summary = {
        "lowest_s": min(timed) if timed else None,
        "average_s": sum(timed) / len(timed) if timed else None,
        "moves_under_60s": sum(1 for t in timed if t < 60),
    }

    live = [r for r in rows if r["eval_cp"] is not None and abs(r["eval_cp"]) <= COMPETITIVE]

    openings = {}
    for side in ("white", "black"):
        tally = {}
        for g in games:
            if g["my_colour"] != side or not g["opening"]:
                continue
            short = " ".join(g["opening"].split()[:4])
            played, won = tally.get(short, (0, 0))
            tally[short] = (played + 1, won + (g["result"] == "win"))
        openings[side] = sorted(
            ({"name": name, "played": played, "won": won}
             for name, (played, won) in tally.items() if played >= 5),
            key=lambda row: -row["played"])

    return {
        "games": len(games),
        "wins": wins, "draws": draws, "losses": len(games) - wins - draws,
        "outcomes": dict(sorted(outcomes.items(), key=lambda x: -x[1])),
        "moves_scored": len(rows),
        "blunders": sum(1 for r in rows if r["severity"] == "blunder"),
        "competitive_moves": len(live),
        "competitive_blunders": sum(1 for r in live if r["severity"] == "blunder"),
        "clock_summary": clock_summary,
        "mistakes": sum(1 for r in rows if r["severity"] == "mistake"),
        "inaccuracies": sum(1 for r in rows if r["severity"] == "inaccuracy"),
        "by_phase": phase, "by_piece": piece, "by_colour": colour,
        "by_clock": clock, "openings": openings,
    }


def print_report(stats):
    if stats is None:
        print("No games imported yet. Run `history.sh import` first.")
        return
    if not stats["moves_scored"]:
        print("No moves evaluated yet. Run `history.sh analyse`.")
        return

    total = stats["games"]
    print(f"{total} games:  {stats['wins']} won  {stats['draws']} drawn  "
          f"{stats['losses']} lost   ({pct(stats['wins'], total)} win rate)\n")

    print("HOW GAMES END")
    for result, count in stats["outcomes"].items():
        print(f"  {result:<22} {count:>4}  {pct(count, total):>4}  {bar(count / total)}")
    abandoned = stats["outcomes"].get("abandoned", 0)
    if abandoned:
        print(f"\n  {abandoned} abandoned, {pct(abandoned, total)} of everything played.")

    scored, blunders = stats["moves_scored"], stats["blunders"]
    live, live_bad = stats["competitive_moves"], stats["competitive_blunders"]
    print(f"\n\nYOUR MOVES  ({scored} evaluated: {blunders} blunders, "
          f"{stats['mistakes']} mistakes, {stats['inaccuracies']} inaccuracies)")
    print(f"  a blunder every {scored / max(1, blunders):.0f} moves overall")
    print(f"  in positions still within {COMPETITIVE}cp, where the game was genuinely live:")
    print(f"    {live_bad} blunders in {live} moves ({pct(live_bad, live)}), "
          f"one every {live / max(1, live_bad):.0f} moves")

    def block(title, table, minimum=0, order=None):
        keys = order or sorted(table, key=lambda k: -(table[k][1] / max(1, table[k][0])))
        print(f"\n  {title}")
        for key in keys:
            if key not in table:
                continue
            seen, bad = table[key]
            if seen >= minimum:
                print(f"    {key:<12} {bad:>4} blunders in {seen:>5} moves   "
                      f"{pct(bad, seen):>4}  {bar(bad / seen, 30)}")

    block("by phase", stats["by_phase"], order=["opening", "middlegame", "endgame"])
    block("by piece moved", stats["by_piece"], minimum=20)
    block("by colour", stats["by_colour"], order=["white", "black"])

    summary = stats["clock_summary"]
    print("\n\nTHE CLOCK")
    if summary["lowest_s"] is not None:
        print(f"  lowest your clock has ever been: {summary['lowest_s']:.0f}s")
        print(f"  average left after your moves:   {summary['average_s']:.0f}s")
        print(f"  moves made with under a minute:  {summary['moves_under_60s']}")
        if summary["moves_under_60s"] >= 0.01 * max(1, stats["moves_scored"]):
            for label, _, _ in CLOCK_BUCKETS:
                seen, bad = stats["by_clock"].get(label, [0, 0])
                if seen:
                    print(f"  {label:<12} {bad:>4} blunders in {seen:>5} moves   "
                          f"{pct(bad, seen):>4}  {bar(bad / seen, 30)}")

    print("\n\nOPENINGS  (5+ games)")
    for side in ("white", "black"):
        if not stats["openings"][side]:
            continue
        print(f"\n  as {side}")
        for row in stats["openings"][side]:
            print(f"    {row['played']:>3}g  {pct(row['won'], row['played']):>4} won   {row['name']}")


# ---------------------------------------------------------------- cli

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command",
                        choices=["import", "analyse", "report", "update",
                                 "link", "account", "set-username"])
    # No default: whose games these are is a setting, not a constant. Set it
    # once with `history.sh set-username <name>` or from the Review tab.
    parser.add_argument("--username", default=None)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    args = parser.parse_args()

    conn = database.connect()
    username = args.username or config.get("chesscom_username")

    if args.command == "account":
        print(json.dumps(account(conn)))
        return

    if args.command == "link":
        if not args.username:
            print(json.dumps({"error": "no_username"}))
            return
        try:
            print(json.dumps(link(conn, args.username)))
        except Exception as exc:
            # The likely cause by far is a username that does not exist, and
            # the app has to be able to say so rather than showing a traceback.
            print(json.dumps({"error": "link_failed", "detail": str(exc)}))
        return

    if args.command == "set-username":
        name = args.username or (args.rest[0] if getattr(args, "rest", None) else None)
        if not name:
            print("Usage: history.sh set-username --username <name>")
            return
        config.set_value("chesscom_username", name)
        print(f"chess.com username set to {name}")
        return

    if args.command in ("import", "update") and not username:
        if args.command == "update":
            # Machine-readable, so the Review tab can offer a field to fill in
            # rather than showing a parse failure.
            print(json.dumps({"error": "no_username"}))
        else:
            print("No chess.com username set. Run: history.sh set-username --username <name>")
        return

    if args.command == "import":
        added, total = import_games(conn, username)
        print(f"imported {added} new game(s); {total} on chess.com")
    elif args.command == "analyse":
        analyse_all(conn, args.workers)
    elif args.command == "update":
        # Fetch, evaluate, report: what the Review tab needs in one call, so it
        # cannot show a report built from games it never imported.
        #
        # Progress goes to stderr. Both steps print as they work and the app
        # decodes stdout as JSON, so a chatty import would look like a parse
        # failure rather than a working update.
        with contextlib.redirect_stdout(sys.stderr):
            added, total = import_games(conn, username)
            if added:
                analyse_all(conn, args.workers)
                # The blunder drill is built from these games, and nothing else
                # ever built it: it only existed because the author once ran
                # `puzzles.py from-blunders` by hand. A new account got an empty
                # drill forever, and so did an old one after switching accounts.
                import puzzles
                puzzles.import_own_blunders(conn)
        stats = compute_stats(conn)
        stats["imported"] = added
        stats["total_on_chesscom"] = total
        print(json.dumps(stats))
    else:
        stats = compute_stats(conn)
        if args.json:
            print(json.dumps(stats))
        else:
            print_report(stats)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
What to actually play, worked out from Jordan's own results.

Chess.com labels a game by whatever opening it drifted into, which at this
level is often nonsense: dozens of games filed under "King's Pawn Opening,
1...e5" that are really different things. This instead replays each game
against the real ECO list and takes the deepest named position it reached,
which is the opening he actually played.

Then it says which lines earn their keep and which are leaking rating. The
recommendation is arithmetic, not opinion.
"""
import os
import sys

import chess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db as database
import openings as opening_book

MIN_GAMES = 5          # below this a win rate is noise
DRAWS = {"stalemate", "insufficient", "agreed", "repetition", "50move", "timevsinsufficient"}


def eco_index(conn):
    """Every named position, keyed by EPD, so a game can be walked forward."""
    return {row["epd"]: (row["eco"], row["name"])
            for row in conn.execute("SELECT eco, name, epd FROM openings")}


def family(name):
    """"Sicilian Defense: Najdorf Variation" -> "Sicilian Defense"."""
    return name.split(":")[0].strip()


def classify_games(conn):
    """Each game tagged with the deepest real opening it reached."""
    index = eco_index(conn)
    out = []
    for game in conn.execute(
            "SELECT id, my_colour, result FROM games WHERE source = 'chesscom'"):
        moves = conn.execute("SELECT uci FROM moves WHERE game_id = ? ORDER BY ply LIMIT 24",
                             (game["id"],)).fetchall()
        board = chess.Board()
        deepest = None
        for row in moves:
            try:
                board.push(chess.Move.from_uci(row["uci"]))
            except ValueError:
                break
            hit = index.get(board.epd())
            if hit:
                deepest = hit
        if deepest:
            out.append({"colour": game["my_colour"], "result": game["result"],
                        "eco": deepest[0], "name": deepest[1], "family": family(deepest[1])})
    return out


def tally(games, colour, key):
    counts = {}
    for g in games:
        if g["colour"] != colour:
            continue
        played, won, drawn = counts.get(g[key], (0, 0, 0))
        counts[g[key]] = (played + 1,
                          won + (g["result"] == "win"),
                          drawn + (g["result"] in DRAWS))
    return counts


def score(stats):
    played, won, drawn = stats
    return (won + 0.5 * drawn) / played


def book_line(conn, family_name, for_colour):
    """A real, named line inside that family, short enough to remember.

    Read out of the opening list rather than written from memory, which is the
    standing rule: asked for a Reti once from memory the answer contained
    "Bg1", which is not a move. Shallow entries first, and plain names before
    heavily subtitled ones, because the point is something learnable rather
    than something impressive.
    """
    length = "(LENGTH(uci) - LENGTH(REPLACE(uci, ' ', ''))) + 1"
    base = conn.execute(
        f"SELECT eco, name, pgn, uci, epd FROM openings WHERE name = ? "
        f"ORDER BY {length} DESC LIMIT 1", (family_name,)).fetchone()
    if base is None:
        base = conn.execute(
            f"SELECT eco, name, pgn, uci, epd FROM openings WHERE name LIKE ? "
            f"ORDER BY {length} LIMIT 1", (family_name + "%",)).fetchone()
    if base is None:
        return None

    # Which continuation to learn is a popularity question, and the opening list
    # cannot answer it: sorted by anything local it offered the "Alapin Gambit"
    # against the French, which nobody plays. The explorer knows what players at
    # his own rating actually do from this position, so ask it.
    board = chess.Board(base["epd"] + " 0 1")
    played = base["uci"].split()
    want = chess.WHITE if for_colour == "white" else chess.BLACK
    top = None

    # Walk forward until the move being recommended is one he actually gets to
    # play. Taking the most popular move from the family's own position gave
    # him White's move in a line he plays as Black, which is a fact about his
    # opponent, not advice.
    for _ in range(2):
        data = opening_book.explorer(board.epd())
        if not isinstance(data, dict) or not data.get("moves"):
            top = None
            break
        total = sum(m["white"] + m["draws"] + m["black"] for m in data["moves"]) or 1
        candidate = data["moves"][0]
        seen = candidate["white"] + candidate["draws"] + candidate["black"]
        try:
            move = board.parse_san(candidate["san"])
        except ValueError:
            top = None
            break
        mover = board.turn
        board.push(move)
        played.append(move.uci())
        top = {"share": round(100 * seen / total),
               "scores": round(100 * candidate["white"] / seen) if seen else None,
               "by": mover}
        if mover == want:
            break

    if top is not None and top["by"] == want:
        if True:
            # The ECO list names the position at the *end* of each line, so the
            # position one move on is usually nameless: after 1.e4 e6 2.d4 d5
            # 3.e5 there is no entry, because "Advance Variation" is stored four
            # plies later. Match the shallowest line that continues this way
            # instead of the exact position.
            named = conn.execute(
                "SELECT eco, name FROM openings WHERE uci LIKE ? "
                "ORDER BY LENGTH(uci) LIMIT 1", (" ".join(played) + "%",)).fetchone()
            # "French Defense: Advance Variation, Extended Bishop Swap" is the
            # deepest thing that happens to match; he wants the variation, not
            # somebody's name for a sideline four moves later.
            label = (named or base)["name"].split(",")[0].strip()
            replay = chess.Board()
            return {"eco": (named or base)["eco"], "name": label,
                    "moves": replay.variation_san(
                        [chess.Move.from_uci(u) for u in played]),
                    "you_play": for_colour,
                    "played_by_pct": top["share"],
                    "white_scores_pct": top["scores"]}

    # No token, or no network. Say the family's own line rather than nothing.
    return {"eco": base["eco"], "name": base["name"], "moves": base["pgn"],
            "played_by_pct": None, "white_scores_pct": None}


def advice(conn):
    """What to work on, from his own results rather than from a random draw.

    Asked for "an opening", the honest answer is not one of 3,329 lines picked
    uniformly: 96% of those are sub-variations nobody at this level will ever
    reach, and the draw returned things like "Queen's Gambit Declined: Baltic
    Defense, Argentinian Gambit". His own games already say which openings he
    keeps meeting and which of them are costing him, so that is the answer.
    """
    games = classify_games(conn)
    out = {"games_classified": len(games), "as_white": None, "as_black": None}
    if not games:
        return out

    for colour in ("white", "black"):
        counts = tally(games, colour, "family")
        ranked = [(name, stats) for name, stats in counts.items()
                  if stats[0] >= MIN_GAMES]
        if not ranked:
            continue
        ranked.sort(key=lambda pair: score(pair[1]))
        worst_name, worst_stats = ranked[0]
        best_name, best_stats = ranked[-1]
        line = book_line(conn, worst_name, colour)
        out[f"as_{colour}"] = {
            "weakest": {"family": worst_name, "games": worst_stats[0],
                        "won": worst_stats[1],
                        "score_pct": round(100 * score(worst_stats))},
            "strongest": {"family": best_name, "games": best_stats[0],
                          "won": best_stats[1],
                          "score_pct": round(100 * score(best_stats))},
            "a_line_in_the_weak_one": line,
        }
    return out


def report(conn):
    games = classify_games(conn)
    if not games:
        print("No classified games. Run history.sh import first.")
        return

    print(f"{len(games)} games matched against the real opening list\n")

    for colour in ("white", "black"):
        counts = tally(games, colour, "family")
        big = {k: v for k, v in counts.items() if v[0] >= MIN_GAMES}
        if not big:
            continue
        print(f"AS {colour.upper()}")
        print(f"  {'games':>5} {'score':>6}  line")
        for name, stats in sorted(big.items(), key=lambda x: -score(x[1])):
            print(f"  {stats[0]:>5} {100*score(stats):>5.0f}%  {name}")

        best = max(big.items(), key=lambda x: score(x[1]))
        worst = min(big.items(), key=lambda x: score(x[1]))
        print(f"\n  Keep:  {best[0]} — {best[1][0]} games at {100*score(best[1]):.0f}%")
        if worst[0] != best[0]:
            print(f"  Drop:  {worst[0]} — {worst[1][0]} games at {100*score(worst[1]):.0f}%")
        print()

    # Where the choice is actually his: what he opens with, and what he meets 1.e4 with.
    print("WHAT YOU ACTUALLY OPEN WITH")
    firsts = {}
    for game in conn.execute(
            "SELECT g.id, g.my_colour, g.result FROM games g WHERE g.source='chesscom'"):
        first = conn.execute("SELECT uci FROM moves WHERE game_id=? AND ply=0", (game["id"],)).fetchone()
        if not first:
            continue
        board = chess.Board()
        san = board.san(chess.Move.from_uci(first["uci"]))
        if game["my_colour"] == "white":
            played, won, drawn = firsts.get(san, (0, 0, 0))
            firsts[san] = (played + 1, won + (game["result"] == "win"),
                           drawn + (game["result"] in DRAWS))
    for san, stats in sorted(firsts.items(), key=lambda x: -x[1][0]):
        if stats[0] >= 3:
            print(f"  1.{san:<5} {stats[0]:>4} games  {100*score(stats):>5.0f}%")


if __name__ == "__main__":
    report(database.connect())

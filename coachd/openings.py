#!/usr/bin/env python3
"""
Openings, from the real list rather than a hand-typed one.

The previous version held 31 openings typed out by hand. This uses the full
lichess-org/chess-openings set, 3,810 named lines, each already validated
upstream. Nothing here is recalled from memory: a name maps to a stored move
sequence or it does not resolve at all.

The explorer answers a different question: not "what is this line called" but
"what do players at my level actually play here", which is the one that matters
when choosing what to learn.

Usage:
  openings.sh import                     (re)load the ECO list
  openings.sh show "<name>"              look one up and put it on the board
  openings.sh explorer "<name>"          what people actually play from there
  openings.sh repertoire                 what to play, from your own results
"""
import argparse
import csv
import difflib
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import chess
import chess.pgn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import config
import db as database

WORKSPACE = paths.HOME
STATE_PATH = os.path.join(WORKSPACE, "board-state.json")
TOKEN_PATH = os.path.join(WORKSPACE, "lichess-token")
ECO_BASE = "https://raw.githubusercontent.com/lichess-org/chess-openings/master/{}.tsv"
EXPLORER = "https://explorer.lichess.org/lichess"

# Which rating buckets the explorer reports. Derived from the linked account's
# own rating rather than hardcoded to one person's, and computed per call so
# that re-linking an account takes effect without a restart.
SPEEDS = "blitz,rapid,classical"


# ---------------------------------------------------------------- the list

def import_eco(conn):
    rows = []
    for letter in "abcde":
        with urllib.request.urlopen(ECO_BASE.format(letter), timeout=60) as response:
            for rec in csv.DictReader(io.TextIOWrapper(response, encoding="utf-8"),
                                      delimiter="\t"):
                game = chess.pgn.read_game(io.StringIO(rec["pgn"]))
                if game is None:
                    continue
                board = game.board()
                ucis = []
                for node in game.mainline():
                    ucis.append(node.move.uci())
                    board.push(node.move)
                rows.append((rec["eco"], rec["name"], rec["pgn"], " ".join(ucis), board.epd()))
    conn.executemany("INSERT OR REPLACE INTO openings (eco, name, pgn, uci, epd) "
                     "VALUES (?,?,?,?,?)", rows)
    conn.commit()
    return len(rows)


def find(conn, query):
    """Resolve a name the way a person would say it.

    Exact, then prefix, then substring, then every word present, then fuzzy.
    All comparisons go through `flat()`, so "kings indian" finds "King's Indian
    Defense". Shortest match wins among equals, so "Italian Game" beats
    "Italian Game: Anti-Fried Liver Defense".

    The fuzzy step is deliberately strict. At a loose cutoff "banana opening"
    resolved to the Canard Opening, and a confidently wrong opening is worse
    than admitting the name was not recognised.
    """
    flat = database.flatten(query)
    if not flat:
        return None

    exact = conn.execute("SELECT * FROM openings WHERE flat(name) = ?", (flat,)).fetchone()
    if exact:
        return exact

    for pattern in (f"{flat}%", f"%{flat}%"):
        row = conn.execute(
            "SELECT * FROM openings WHERE flat(name) LIKE ? "
            "ORDER BY length(name) LIMIT 1", (pattern,)).fetchone()
        if row:
            return row

    # "sicilian najdorf" should find "Sicilian Defense: Najdorf Variation":
    # every word is there, just not adjacent.
    words = [w for w in flat.split() if len(w) > 2]
    if words:
        clauses = " AND ".join(["flat(name) LIKE ?"] * len(words))
        row = conn.execute(
            f"SELECT * FROM openings WHERE {clauses} ORDER BY length(name) LIMIT 1",
            [f"%{w}%" for w in words]).fetchone()
        if row:
            return row

    names = [r["name"] for r in conn.execute("SELECT name FROM openings")]
    close = difflib.get_close_matches(query, names, n=1, cutoff=0.8)
    if close:
        return conn.execute("SELECT * FROM openings WHERE name = ?", (close[0],)).fetchone()
    return None


def suggestions(conn, query, limit=5):
    names = [r["name"] for r in conn.execute("SELECT name FROM openings")]
    return difflib.get_close_matches(query, names, n=limit, cutoff=0.3)


def show(conn, query):
    row = find(conn, query)
    if row is None:
        near = suggestions(conn, query)
        print(f"No opening called {query!r}.")
        if near:
            print("Closest names:")
            for n in near:
                print(f"  {n}")
        return None

    board = chess.Board()
    sans = []
    for uci in row["uci"].split():
        move = chess.Move.from_uci(uci)
        sans.append(board.san(move))
        board.push(move)

    state = {"name": row["name"], "eco": row["eco"],
             "moves": sans, "fen": board.fen(), "epd": row["epd"],
             "steps": steps(row["uci"])}
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_PATH)

    print(f"Set board to: {row['name']} ({row['eco']})")
    print(f"Moves: {' '.join(sans)}")
    print(f"FEN: {board.fen()}")
    return state


def pick_random(conn, plies=(4, 12)):
    """One named opening, at random, deep enough to be worth learning.

    The two-ply stubs ("King's Pawn Game") name a position rather than teach a
    plan, and the twenty-ply theory dumps are not where a 200 starts. Between
    those is a line you can actually hold in your head.
    """
    row = conn.execute(
        "SELECT eco, name, uci, epd FROM openings "
        "WHERE (LENGTH(uci) - LENGTH(REPLACE(uci, ' ', ''))) + 1 BETWEEN ? AND ? "
        "ORDER BY RANDOM() LIMIT 1", plies).fetchone()
    return row


def numbered(sans):
    """SAN list as "1. e4 c5 2. Nf3 d6", so whose move is whose is unmissable."""
    out = []
    for i in range(0, len(sans), 2):
        pair = " ".join(sans[i:i + 2])
        out.append(f"{i // 2 + 1}. {pair}")
    return " ".join(out)


def line_from(uci_text):
    """A space-separated UCI line as SAN, with the position it reaches."""
    board = chess.Board()
    sans = []
    for uci in uci_text.split():
        move = chess.Move.from_uci(uci)
        sans.append(board.san(move))
        board.push(move)
    return sans, board


def steps(uci_text):
    """Every position the line passes through, so it can be watched rather than
    jumped to. An opening is a move order, and a board showing only where it
    ends up has thrown away the part that matters.
    """
    board = chess.Board()
    out = [{"fen": board.fen(), "san": None, "from": None, "to": None}]
    for uci in uci_text.split():
        move = chess.Move.from_uci(uci)
        san = board.san(move)
        board.push(move)
        out.append({"fen": board.fen(), "san": san,
                    "from": chess.square_name(move.from_square),
                    "to": chess.square_name(move.to_square)})
    return out


def write_state(row, sans, board):
    """Publish for the Explore tab, the same shape `show` writes."""
    state = {"name": row["name"], "eco": row["eco"],
             "moves": sans, "fen": board.fen(), "epd": row["epd"],
             "steps": steps(row["uci"])}
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_PATH)
    return state


def print_random(conn):
    row = pick_random(conn)
    if row is None:
        print("No openings imported yet. Run: openings.sh import")
        return None
    sans, board = line_from(row["uci"])
    write_state(row, sans, board)
    print(f"Set board to: {row['name']} ({row['eco']})")
    print(f"Line: {numbered(sans)}")
    # Split by side explicitly. "It is White to move after this" was read as
    # "this is an opening for White", and a Sicilian was duly described as
    # White's. Whose moves are whose is a fact; do not make it inferable.
    print(f"White plays: {', '.join(sans[0::2])}")
    print(f"Black plays: {', '.join(sans[1::2]) or '(nothing yet)'}")
    print(f"The line ends on {'Black' if len(sans) % 2 == 0 else 'White'}'s move, "
          f"and {'White' if board.turn else 'Black'} moves next.")
    return row


def game_moves():
    """The live game's moves, from the published state the app writes."""
    path = os.path.join(WORKSPACE, "game-state.json")
    try:
        with open(path) as f:
            return json.load(f).get("moves", [])
    except (OSError, ValueError):
        return []


def identify(conn, moves):
    """The deepest named opening this move list actually reached.

    Walks the line and keeps the last position that has a name, which is the
    same test `repertoire.py` uses to tag a finished game. Names come from the
    position reached, never from a guess about what the moves looked like.
    """
    index = {row["epd"]: (row["eco"], row["name"])
             for row in conn.execute("SELECT eco, name, epd FROM openings")}
    board = chess.Board()
    deepest, at_ply = None, 0
    for i, uci in enumerate(moves):
        try:
            board.push(chess.Move.from_uci(uci))
        except ValueError:
            break
        hit = index.get(board.epd())
        if hit:
            deepest, at_ply = hit, i + 1
    return deepest, at_ply


def continuations(conn, moves, limit=6):
    """Named lines that carry on from exactly where this game stands."""
    if not moves:
        return []
    prefix = " ".join(moves) + " "
    return conn.execute(
        "SELECT eco, name, uci, epd FROM openings WHERE uci LIKE ? "
        "ORDER BY LENGTH(uci) LIMIT ?", (prefix + "%", limit)).fetchall()


def print_here(conn):
    moves = game_moves()
    if not moves:
        print("No game in progress, so there is no line to name.")
        return None
    sans, _ = line_from(" ".join(moves))
    deepest, at_ply = identify(conn, moves)
    if deepest:
        print(f"You are in: {deepest[1]} ({deepest[0]}), named after "
              f"{numbered(sans[:at_ply])}")
    else:
        print("This line does not match any named opening.")

    if at_ply < len(moves):
        print(f"You have since left the book: {' '.join(sans[at_ply:])}")

    rows = continuations(conn, moves)
    if not rows:
        print("Nothing named continues from this exact position.")
        return deepest
    print("Named lines that continue from here:")
    for row in rows:
        full, _ = line_from(row["uci"])
        print(f"  {row['name']} ({row['eco']}) — plays on with "
              f"{' '.join(full[len(moves):])}")
    return deepest


# ---------------------------------------------------------------- explorer

def token():
    if os.environ.get("LICHESS_TOKEN"):
        return os.environ["LICHESS_TOKEN"].strip()
    if os.path.exists(TOKEN_PATH):
        return open(TOKEN_PATH).read().strip()
    return None


def explorer(epd, plies=None):
    """What players around Jordan's level actually play from this position.

    Lichess made the explorer login-only in March 2026, so this needs a token.
    Without one it says so plainly rather than returning something invented.
    """
    auth = token()
    if not auth:
        return {"error": "No Lichess token. Create one at "
                         "https://lichess.org/account/oauth/token (no scopes needed) "
                         f"and save it to {TOKEN_PATH}"}
    params = {"variant": "standard", "fen": epd, "speeds": SPEEDS,
              "ratings": config.explorer_bands(config.play_rating()),
              "moves": 8, "topGames": 0, "recentGames": 0}
    url = f"{EXPLORER}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {auth}", "User-Agent": "chess-coach/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        return {"error": f"Explorer returned {exc.code}. "
                         f"{'The token may be wrong or revoked.' if exc.code == 401 else ''}"}
    except OSError as exc:
        return {"error": f"Could not reach the explorer: {exc}"}


def print_explorer(conn, query):
    row = find(conn, query)
    if row is None:
        print(f"No opening called {query!r}."); return
    data = explorer(row["epd"])
    if "error" in data:
        print(data["error"]); return

    total = data["white"] + data["draws"] + data["black"]
    print(f"{row['name']} ({row['eco']})")
    print(f"{total} games at your level\n")
    print(f"{'move':<8} {'games':>8} {'share':>6}   {'white':>5} {'draw':>5} {'black':>5}")
    for move in data.get("moves", []):
        played = move["white"] + move["draws"] + move["black"]
        print(f"{move['san']:<8} {played:>8} {100*played/max(1,total):>5.0f}%   "
              f"{100*move['white']/max(1,played):>4.0f}% {100*move['draws']/max(1,played):>4.0f}% "
              f"{100*move['black']/max(1,played):>4.0f}%")


COMMANDS = ("import", "show", "explorer", "repertoire", "random", "here")


def main():
    # `openings.sh "Italian Game"` is the form AGENTS.md has always documented,
    # and argparse rejected it as an invalid choice of command, so a bare name
    # never worked. Treat a first word that is not a command as what it plainly
    # is: the name being asked about.
    argv = sys.argv[1:]
    if argv and argv[0] not in COMMANDS:
        argv = ["show"] + argv

    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?", default="show",
                        choices=["import", "show", "explorer", "repertoire",
                                 "random", "here"])
    parser.add_argument("query", nargs="*")
    args = parser.parse_args(argv)
    conn = database.connect()
    query = " ".join(args.query)

    if args.command == "import":
        print(f"imported {import_eco(conn)} named openings")
    elif args.command == "explorer":
        print_explorer(conn, query or "Italian Game")
    elif args.command == "random":
        print_random(conn)
    elif args.command == "here":
        print_here(conn)
    elif args.command == "repertoire":
        import repertoire
        repertoire.report(conn)
    else:
        show(conn, query or "Italian Game")


if __name__ == "__main__":
    main()

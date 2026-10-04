#!/usr/bin/env python3
"""
Deterministic chess game analysis. Fetches a real game from chess.com, runs
it through Stockfish move-by-move, and flags the moves where Jordan's actual
move lost significant value versus the engine's best. No LLM involved in any
of this — every number here is real Stockfish output. Chichi's job is
explaining what this script found, never re-evaluating the position himself.

Reads every monthly archive, not just the newest one, so the whole history is
reachable. Older months are cached on disk since they can never change.

Evaluation goes through coachd rather than starting its own Stockfish, which
keeps the engine warm across a whole game and, more importantly, makes the
verdict reproducible: coachd caches every position it has ever evaluated, so
re-analysing a game gives the same answer instead of a different one.

Usage:
  analyze.py --list [N]        list recent games with their id
  analyze.py --game <id>       analyse that game (stable)
  analyze.py [--index N]       analyse by position (-1 = most recent)

The account is whichever one is linked; --username overrides it.

Prefer --game. Indexes count backwards from the newest game, so they shift the
moment another game is played: "game -171" means something different tomorrow.
The id comes from the chess.com game URL and never moves.
"""
import argparse
import datetime
import io
import json
import os
import sys
import urllib.request

import chess
import chess.pgn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import client
import config

# Code lives in the repo; data lives in the agent workspace. Deriving this from
# __file__ used to work when the scripts sat inside the workspace, and silently
# wrote to the repo once they moved.
WORKSPACE = paths.HOME
CACHE_DIR = os.path.join(WORKSPACE, "cache", "archives")
UA = {"User-Agent": "chichi-chess-coach/1.0"}
TIME_PER_MOVE = 0.3  # seconds — enough for club-level accuracy without being slow

# centipawn-loss thresholds, from the mover's own perspective
INACCURACY = 50
MISTAKE = 100
BLUNDER = 200


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=25) as resp:
        return json.load(resp)


def fetch_stats(username):
    """The public rating card: rapid, blitz, bullet and the tactics score.

    Everything here is on the same public endpoint the games come from, so
    linking an account needs no login and no key. A player with no rating in a
    format simply has no entry.
    """
    raw = get_json(f"https://api.chess.com/pub/player/{username}/stats")
    out = {}
    for key, field in (("chess_rapid", "rapid"), ("chess_blitz", "blitz"),
                       ("chess_bullet", "bullet")):
        rating = (raw.get(key) or {}).get("last", {}).get("rating")
        if rating:
            out[field] = rating
    tactics = (raw.get("tactics") or {}).get("highest", {}).get("rating")
    if tactics:
        out["tactics"] = tactics
    return out


def load_games(username):
    """Every game across every monthly archive, oldest first.

    Past months are frozen once they're over, so they're cached. The current
    month never is.
    """
    archives = get_json(f"https://api.chess.com/pub/player/{username}/games/archives")["archives"]
    current = datetime.date.today().strftime("%Y/%m")
    os.makedirs(CACHE_DIR, exist_ok=True)

    games = []
    for number, url in enumerate(archives, 1):
        # Read by the app's Review tab to show how far the fetch has got. A
        # first link downloads every month there has ever been, and said
        # nothing while it did.
        print(f"  fetched {number}/{len(archives)} months", file=sys.stderr, flush=True)
        month = "/".join(url.rsplit("/", 2)[-2:])
        cache_path = os.path.join(CACHE_DIR, f"{month.replace('/', '-')}.json")
        if month != current and os.path.exists(cache_path):
            with open(cache_path) as f:
                batch = json.load(f)
        else:
            batch = get_json(url)["games"]
            if month != current:
                with open(cache_path, "w") as f:
                    json.dump(batch, f)
        games.extend(batch)
    return games


def game_id(game):
    """Stable id straight from the chess.com game URL."""
    return (game.get("url") or "").rsplit("/", 1)[-1] or "?"


def describe(game, username):
    white = game["white"]["username"]
    mine = game["white"] if white.lower() == username.lower() else game["black"]
    theirs = game["black"] if mine is game["white"] else game["white"]
    date = datetime.date.fromtimestamp(game["end_time"]).isoformat() if game.get("end_time") else "?"
    colour = "white" if mine is game["white"] else "black"
    return (f"{game_id(game):>14}  {date}  {game.get('time_class','?'):<6} "
            f"as {colour:<5} vs {theirs['username'][:20]:<20} {mine['result']}")


def cmd_list(games, username, count):
    print(f"{len(games)} games total. Most recent {min(count, len(games))}:\n")
    print(f"{'id':>14}  {'date':<10}  {'class':<6} {'colour':<8} {'opponent':<23} result")
    for offset in range(1, min(count, len(games)) + 1):
        print(describe(games[-offset], username))
    print("\nAnalyse one with --game <id>.")


def classify(loss):
    if loss >= BLUNDER:
        return "blunder"
    if loss >= MISTAKE:
        return "mistake"
    if loss >= INACCURACY:
        return "inaccuracy"
    return None


def analyse_game(game_data, username):
    white = game_data["white"]["username"]
    black = game_data["black"]["username"]
    your_colour = chess.WHITE if white.lower() == username.lower() else chess.BLACK
    side = game_data["white"] if your_colour == chess.WHITE else game_data["black"]

    print(f"Game: {white} (white) vs {black} (black) — {game_data.get('time_class', '?')}")
    if game_data.get("end_time"):
        print(f"Played: {datetime.date.fromtimestamp(game_data['end_time']).isoformat()}")
    print(f"You played {'white' if your_colour == chess.WHITE else 'black'}, "
          f"result: {side['result']}")
    print(f"URL: {game_data.get('url', '(no url)')}")
    print()

    game = chess.pgn.read_game(io.StringIO(game_data["pgn"]))
    board = game.board()
    moves = list(game.mainline())

    flagged = []
    # One analysis per position, not two per move: the position after move n is
    # the position before move n+1, so the evaluation carries forward.
    info = client.request({"op": "analyse", "fen": board.fen(), "time": TIME_PER_MOVE})

    for ply, node in enumerate(moves):
        move = node.move
        mover = board.turn
        best_eval = info["score_cp"]          # already from the mover's side
        best_uci = info.get("best_uci")

        san = board.san(move)
        best_san = board.san(chess.Move.from_uci(best_uci)) if best_uci else None
        fen_before = board.fen()
        board.push(move)

        info = client.request({"op": "analyse", "fen": board.fen(), "time": TIME_PER_MOVE})
        played_eval = -info["score_cp"]       # flip: it is the opponent's turn now

        loss = max(0, best_eval - played_eval)
        severity = classify(loss)

        if severity and mover == your_colour:
            flagged.append({
                "move_num": ply // 2 + 1,
                "played": san,
                "best": best_san,
                "loss_cp": loss,
                "severity": severity,
                "fen_before": fen_before,
            })

        if ply % 10 == 0:
            print(f"  ...analysing, move {ply // 2 + 1} of {len(moves) // 2}",
                  file=sys.stderr, flush=True)

    return flagged, len(moves)


def main():
    parser = argparse.ArgumentParser()
    # Defaults to the linked account, so neither Chichi nor anyone at a shell
    # has to know whose games these are.
    parser.add_argument("--username", default=None)
    parser.add_argument("--game", metavar="ID",
                        help="chess.com game id, from --list. Stable; prefer this.")
    parser.add_argument("--index", type=int, default=-1,
                        help="position from the end (-1 = newest). Shifts as new games are played.")
    parser.add_argument("--list", nargs="?", type=int, const=15, default=None,
                        metavar="N", help="list the N most recent games instead of analysing")
    args = parser.parse_args()

    username = args.username or config.get("chesscom_username")
    if not username:
        print("No chess.com account linked. Link one in Settings, or pass --username.")
        return

    games = load_games(username)
    if not games:
        print(f"No games found for {username}.")
        return

    if args.list is not None:
        cmd_list(games, username, args.list)
        return

    if args.game:
        matches = [g for g in games if game_id(g) == args.game]
        if not matches:
            print(f"No game with id {args.game}. Use --list to see recent ids.")
            return
        game_data = matches[0]
    else:
        try:
            game_data = games[args.index]
        except IndexError:
            print(f"No game at index {args.index}. There are {len(games)}; "
                  f"valid indexes run -1 to -{len(games)}.")
            return

    flagged, plies = analyse_game(game_data, username)

    if not flagged:
        print("No significant mistakes flagged — clean game by the numbers.")
        return

    print(f"{len(flagged)} flagged moment(s) across {plies // 2} moves:")
    for f in flagged:
        print(f"- Move {f['move_num']}: played {f['played']}"
              + (f", engine wanted {f['best']}" if f["best"] else "")
              + f" ({f['severity']}, -{f['loss_cp']}cp)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Endgame drills against perfect defence.

No engine involved. Lichess hosts the 7-piece Syzygy tablebases, which are not
"strong" but *solved*: for these positions there is a known best move and a known
number of moves to mate. That is exactly what a drill wants, and it is free.

Jordan has four stalemates in 217 games, which at this level almost always means
a won position thrown away. Converting a won endgame is a skill with a small,
finite syllabus, and this is the syllabus.

Usage:
  endgames.sh new <drill>        start one (see --list)
  endgames.sh move --uci e2e4    your move, then perfect defence replies
  endgames.sh state
  endgames.sh --list
"""
import argparse
import json
import os
import random
import sys
import paths
import urllib.parse
import urllib.request

import chess

WORKSPACE = paths.HOME
STATE_PATH = os.path.join(WORKSPACE, "endgame-state.json")
TABLEBASE = "https://tablebase.lichess.ovh/standard"

# The syllabus. Each is a mate every player needs and most beginners cannot do.
DRILLS = {
    "queen":  {"name": "King and queen vs king", "white": [chess.QUEEN]},
    "rook":   {"name": "King and rook vs king",  "white": [chess.ROOK]},
    "twoR":   {"name": "King and two rooks vs king", "white": [chess.ROOK, chess.ROOK]},
    "pawn":   {"name": "King and pawn vs king",  "white": [chess.PAWN]},
}


def lookup(board):
    """Ask the tablebase. Its `moves` come back best-first for the side to move."""
    url = f"{TABLEBASE}?{urllib.parse.urlencode({'fen': board.fen()})}"
    request = urllib.request.Request(url, headers={"User-Agent": "chess-coach/1.0"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def random_position(drill):
    """A legal, winning starting position for this drill."""
    spec = DRILLS[drill]
    while True:
        board = chess.Board(None)
        squares = random.sample(range(64), 2 + len(spec["white"]))
        board.set_piece_at(squares[0], chess.Piece(chess.KING, chess.WHITE))
        board.set_piece_at(squares[1], chess.Piece(chess.KING, chess.BLACK))
        for piece_type, square in zip(spec["white"], squares[2:]):
            if piece_type == chess.PAWN and chess.square_rank(square) in (0, 7):
                break
            board.set_piece_at(square, chess.Piece(piece_type, chess.WHITE))
        else:
            board.turn = chess.WHITE
            if board.is_valid() and not board.is_game_over():
                return board


def save(board, drill, best_dtm=None):
    state = {
        "drill": drill,
        "name": DRILLS[drill]["name"],
        "fen": board.fen(),
        "moves": [m.uci() for m in board.move_stack],
        "status": status_of(board),
        "your_moves": (len(board.move_stack) + 1) // 2,
        "mate_in_at_best": best_dtm,
    }
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)
    return state


def status_of(board):
    if board.is_checkmate():
        return "checkmate" if board.turn == chess.BLACK else "you_got_mated"
    if board.is_stalemate():
        return "stalemate"
    if board.is_insufficient_material():
        return "drawn_no_material"
    return "ongoing"


def cmd_new(args):
    board = random_position(args.drill)
    info = lookup(board)
    state = save(board, args.drill, info.get("dtm"))
    state["tablebase"] = info.get("category")
    print(json.dumps(state, indent=2))


def cmd_move(args):
    if not os.path.exists(STATE_PATH):
        print(json.dumps({"error": "No drill in progress. Start one first."})); sys.exit(1)
    saved = json.load(open(STATE_PATH))
    board = chess.Board()
    board.clear()
    board.set_fen(saved["fen"])

    try:
        move = chess.Move.from_uci(args.uci)
    except ValueError:
        print(json.dumps({"error": f"'{args.uci}' is not a validly formatted move."})); sys.exit(1)
    if move not in board.legal_moves:
        print(json.dumps({"error": f"'{args.uci}' is not legal here."})); sys.exit(1)

    before = lookup(board)
    best = before["moves"][0]["uci"] if before.get("moves") else None
    played_san = board.san(move)
    board.push(move)

    result = {"you_played": played_san, "best_was": best, "optimal": move.uci() == best}

    if status_of(board) == "ongoing":
        after = lookup(board)
        if after.get("moves"):
            # The defender's best try is the first move the tablebase returns.
            reply = chess.Move.from_uci(after["moves"][0]["uci"])
            result["defence"] = board.san(reply)
            board.push(reply)

    state = save(board, saved["drill"], saved.get("mate_in_at_best"))
    print(json.dumps({**state, **result}, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    sub = parser.add_subparsers(dest="command")
    n = sub.add_parser("new"); n.add_argument("drill", choices=sorted(DRILLS)); n.set_defaults(func=cmd_new)
    m = sub.add_parser("move"); m.add_argument("--uci", required=True); m.set_defaults(func=cmd_move)
    s = sub.add_parser("state")
    args = parser.parse_args()

    if args.list or args.command is None:
        for key, spec in DRILLS.items():
            print(f"  {key:<8} {spec['name']}")
        return
    if args.command == "state":
        print(open(STATE_PATH).read() if os.path.exists(STATE_PATH) else "{}")
        return
    args.func(args)


if __name__ == "__main__":
    main()

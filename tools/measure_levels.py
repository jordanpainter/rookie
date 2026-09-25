#!/usr/bin/env python3
"""Measure the difficulty ladder. Run this after changing LEVELS in coachd.py.

    <data folder>/venv/bin/python3 tools/measure_levels.py anchor
    <data folder>/venv/bin/python3 tools/measure_levels.py pairs
    <data folder>/venv/bin/python3 tools/measure_levels.py positions

Three modes, and the first two are the ones that mean anything:

  anchor     every level plays N games against level 5 (Elo 1320, no slip).
  pairs      every level plays the one below it. This is what shows the ladder
             is ordered, because levels 1 to 3 all lose 12-0 to the anchor and
             are only distinguishable from each other.
  positions  average centipawn loss over sampled positions from real games.
             Kept for the record and *not* to be trusted for ordering: three
             runs gave error bars of +/-21 to +/-28 on values between 61 and
             186, and the same configuration scored 9% blunders one run and 18%
             the next. A ladder is a claim about winning, so measure winning.

It drives the real `Coach.choose_reply()` against a throwaway database, so it
measures the shipped code rather than a copy of its logic. Takes 10-20 minutes.
"""
import os, sqlite3, statistics, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "coachd"))
import chess, chess.engine
import coachd
import paths

DB = paths.data("coach.db")
STOCKFISH = paths.stockfish()
ANCHOR, GAMES, PAIR_GAMES, MAX_PLIES = 5, 12, 14, 140
REF = chess.engine.Limit(depth=12)


def coach(tag, tmp):
    return coachd.Coach(os.path.join(tmp, f"{tag}.db"), os.path.join(tmp, f"{tag}.sock"))


def cp(score, colour):
    v = score.pov(colour)
    return 1200 if v.is_mate() and v.mate() > 0 else (-1200 if v.is_mate() else v.score())


def duel(a, b, judge, a_is_white):
    """One game. Returns a's score."""
    board = chess.Board()
    while not board.is_game_over() and len(board.move_stack) < MAX_PLIES:
        mover = a if (board.turn == chess.WHITE) == a_is_white else b
        mover.board = board
        board.push(mover.choose_reply())
    if board.is_game_over():
        result = board.result()
        if result == "1/2-1/2":
            return 0.5
        return 1.0 if (result == "1-0") == a_is_white else 0.0
    # Unfinished games are adjudicated rather than called draws.
    info = judge.analyse(board, chess.engine.Limit(depth=10))
    score = info["score"].pov(chess.WHITE if a_is_white else chess.BLACK).score(mate_score=10000)
    return 1.0 if score > 150 else (0.0 if score < -150 else 0.5)


def match(a, b, judge, games):
    w = d = l = 0
    for game in range(games):
        s = duel(a, b, judge, a_is_white=(game % 2 == 0))
        w += s == 1.0
        d += s == 0.5
        l += s == 0.0
    return (w + 0.5 * d) / games, f"{w}-{d}-{l}"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "pairs"
    tmp = tempfile.mkdtemp()
    judge = chess.engine.SimpleEngine.popen_uci(STOCKFISH)
    judge.configure({"Skill Level": 20})
    a, b = coach("a", tmp), coach("b", tmp)

    if mode == "anchor":
        b.level = ANCHOR
        print(f"{GAMES} games per level against level {ANCHOR}")
        for level in sorted(coachd.LEVELS):
            if level == ANCHOR:
                continue
            a.level = level
            score, record = match(a, b, judge, GAMES)
            print(f"  level {level}: {score:>4.0%}  {record}", flush=True)

    elif mode == "pairs":
        print(f"{PAIR_GAMES} games per adjacent pair, colours alternated")
        for higher in sorted(coachd.LEVELS)[1:]:
            a.level, b.level = higher, higher - 1
            score, record = match(a, b, judge, PAIR_GAMES)
            print(f"  {higher} v {higher - 1}: higher scores {score:>4.0%}  {record}", flush=True)

    else:
        con = sqlite3.connect(DB)
        fens = [r[0] for r in con.execute(
            "SELECT fen_before FROM moves WHERE fen_before IS NOT NULL "
            "AND ply BETWEEN 10 AND 50 ORDER BY RANDOM() LIMIT 120")]
        cache = {}
        print("average centipawn loss (noisy: see the docstring)")
        for level in sorted(coachd.LEVELS):
            a.level = level
            losses = []
            for fen in fens:
                board = chess.Board(fen)
                a.board = board
                mover = board.turn
                if fen not in cache:
                    cache[fen] = cp(judge.analyse(board, REF)["score"], mover)
                after = board.copy()
                after.push(a.choose_reply())
                losses.append(max(0, cache[fen] - cp(judge.analyse(after, REF)["score"], mover)))
            err = statistics.stdev(losses) / (len(losses) ** 0.5)
            print(f"  level {level}: {sum(losses)/len(losses):>5.0f}cp +/-{err:.0f}  "
                  f"blunders {sum(1 for x in losses if x >= 200)}/{len(losses)}", flush=True)

    judge.quit()
    for c in (a, b):
        c.engine.quit()
        c.opponent.quit()


if __name__ == "__main__":
    main()

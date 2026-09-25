#!/usr/bin/env python3
"""
coachd: one long-lived process holding one warm Stockfish, answering JSON
requests over a Unix socket.

Everything used to spawn a fresh Python and a fresh Stockfish per move. That
was survivable at one move per turn and hopeless for coaching, which needs
several engine queries per move. A warm engine with a warm hash table is also
simply a better engine than one that has just started.

The daemon owns the live game. SQLite is the record; `game-state.json` is
still written every move, but purely as a published view for Chichi to read.

Protocol: one JSON object per line in, one JSON object per line out, then the
connection closes. Ops: ping, new_game, move, state, analyse, shutdown.

Run:  coachd.py [--socket PATH] [--db PATH]
"""
import argparse
import json
import os
import random
import signal
import socket
import sys
import time

import chess
import chess.engine

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import db as database
import features
import puzzles as puzzle_store
import endgames
import openings as opening_book

STOCKFISH_PATH = paths.stockfish()
RUNTIME_DIR = paths.HOME
DEFAULT_SOCKET = os.path.join(RUNTIME_DIR, "coachd.sock")

# Difficulty. Stockfish's own weakening knobs bottom out well above a real
# beginner (Skill Level floors at 0, UCI_Elo at 1320), so difficulty is search
# depth plus a chance of simply not looking at the board. Percentages are
# measured scores against a greedy-capture bot, itself roughly a 300-500 player.
# The ladder. Two mechanisms, split at Stockfish's own floor.
#
# Above 1320 the engine weakens itself properly: UCI_LimitStrength is built for
# this and produces play that is worse without being strange. Below 1320 there
# is nothing built in, and the old answer here was a percentage chance of a
# uniformly random legal move. Measured, that ladder was not one: levels 5 to 8
# came out at 112, 75, 70 and 94 centipawns of average loss, overlapping inside
# their error bars and out of order, because `Skill Level: 0` capped the play
# whatever depth it was given. See DECISIONS.md, 2026-09-04.
#
# What replaces it is a "slip": most moves are played at the engine's floor
# strength, and now and then it plays a real mistake chosen from its own
# candidate list rather than at random. That is how a weak player actually
# loses, a run of sensible moves and then a piece, and it is the thing uniform
# randomness cannot imitate. A random legal move is not weak, it is alien.
#
# Buckets, not per-person calibration: nobody can measure a new user before
# they have played, so the rungs are fixed and you pick the one that fights back.
FLOOR_ELO = 1320
LEVELS = {
    1: {"elo": FLOOR_ELO, "slip": 0.40},
    2: {"elo": FLOOR_ELO, "slip": 0.28},
    3: {"elo": FLOOR_ELO, "slip": 0.18},
    4: {"elo": FLOOR_ELO, "slip": 0.08},
    5: {"elo": FLOOR_ELO, "slip": 0.0},
    6: {"elo": 1600, "slip": 0.0},
    7: {"elo": 1900, "slip": 0.0},
    8: {"elo": 2200, "slip": 0.0},
}
# A slip is a real mistake. The first version capped this at 700, which quietly
# excluded hanging a queen, and hanging a queen is precisely what the levels
# below the floor are meant to imitate. The ceiling now only keeps out moves
# that lose on the spot, which end the game rather than teach anything.
# 200 is where `history.py` starts calling a move a blunder, so a slip is one
# by definition and the level's number means the same thing as the number in
# the Review tab: how often the opponent throws something away.
SLIP_BAND = (200, 1200)
# Enough candidates that a position containing a mistake actually offers one.
SLIP_MULTIPV = 12

# How far ahead a quoted engine line goes: six half-moves, three each. Far enough
# to be a plan, short enough to still be the engine's line rather than noise.
LINE_PLIES = 6

DEFAULT_LEVEL = 2

# The guard speaks up at this much lost value. Phase 3 measured Jordan losing
# roughly 200cp on one move in six while the game was still level, and that the
# damage is concentrated on heavy pieces in the middlegame.
GUARD_THRESHOLD = 200

# Losing value relative to the best move is not enough on its own. In a position
# that is already lost, almost every move is far worse than the one saving line,
# and a guard that fires on 28 of 32 legal moves teaches nothing. So it stays
# quiet when the game was already gone before the move, and when the move leaves
# the game comfortably won anyway.
GUARD_ALREADY_LOST = -150
GUARD_STILL_WINNING = 300


def score_cp(pov_score, color):
    """Centipawns from `color`'s perspective. Mates become large finite values
    so ordinary comparisons still behave."""
    pov = pov_score.pov(color)
    if pov.is_mate():
        mate_in = pov.mate()
        return 10000 - abs(mate_in) * 10 if mate_in > 0 else -10000 + abs(mate_in) * 10
    return pov.score()


MATE_SCORE = 9000


def mate_in(score):
    """Undo score_cp's mate encoding: moves to mate, negative if being mated.

    The encoding was always there and nothing ever read it back, so the coach
    could not see mate at all. In one 53-ply game eight positions had a forced
    mate and it mentioned none of them, twice suggesting a hanging pawn instead
    while mate in two was on the board.
    """
    if score >= MATE_SCORE:
        return (10000 - score) // 10
    if score <= -MATE_SCORE:
        return -((10000 + score) // 10)
    return None


def game_status(board):
    if board.is_checkmate():
        return f"checkmate_{'black' if board.turn == chess.WHITE else 'white'}_wins"
    if board.is_stalemate():
        return "stalemate"
    if board.is_insufficient_material():
        return "draw_insufficient_material"
    if board.can_claim_fifty_moves():
        return "draw_fifty_moves"
    if board.can_claim_threefold_repetition():
        return "draw_repetition"
    if board.is_check():
        return "check"
    return "ongoing"


def is_over(status):
    return status.startswith("checkmate") or status == "stalemate" or status.startswith("draw")


CODE_DIR = os.path.dirname(os.path.abspath(__file__))


def code_version():
    """The newest modification time across the Python half, as an integer.

    A version number somebody has to remember to bump is a version number that
    stops being bumped. The files themselves already know when they changed.
    """
    newest = 0.0
    try:
        for name in os.listdir(CODE_DIR):
            if name.endswith(".py"):
                newest = max(newest, os.path.getmtime(os.path.join(CODE_DIR, name)))
    except OSError:
        return 0
    return int(newest)


# Taken once, at import, because it has to describe the code this process
# actually loaded. Read at call time instead, a daemon running yesterday's code
# would happily report today's files and the staleness check would never fire.
CODE_VERSION = code_version()


class Coach:
    def __init__(self, db_path, socket_path):
        self.conn = database.connect(db_path)
        self.socket_path = socket_path
        # Published beside the socket, not at a fixed path. As a module
        # constant this pointed at the live workspace whatever database the
        # daemon was actually serving, so a throwaway daemon started for a test
        # silently overwrote the real game Chichi reads.
        self.state_path = os.path.join(os.path.dirname(os.path.abspath(socket_path)),
                                       "game-state.json")
        self.started = time.time()
        self.engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH_PATH)
        # The opponent gets its own process. One engine served both roles and
        # was reconfigured between Skill 0 to play and Skill 20 to analyse, so
        # every path had to remember to set it back. UCI_LimitStrength would
        # have made that fragility real: left on, it silently weakens every
        # evaluation the guard and the coaching facts are built from.
        self.opponent = chess.engine.SimpleEngine.popen_uci(STOCKFISH_PATH)
        self.board = chess.Board()
        self.level = int(database.get_setting(self.conn, "level", DEFAULT_LEVEL))
        self.game_id = None
        # Which side the player has. It was white, everywhere, as a constant:
        # the game row said so, the takeback popped until white was to move,
        # and the opponent never opened. Half of chess is the other side.
        self.my_colour = chess.WHITE
        self._resume()

    # ---------- game lifecycle ----------

    def _resume(self):
        """Pick up whatever game was in progress when we last shut down."""
        game_id = database.get_setting(self.conn, "current_game_id")
        if not game_id:
            return
        rows = database.game_moves(self.conn, int(game_id))
        board = chess.Board()
        try:
            for row in rows:
                board.push(chess.Move.from_uci(row["uci"]))
        except ValueError:
            return
        self.game_id = int(game_id)
        self.board = board
        stored = database.game_colour(self.conn, self.game_id)
        self.my_colour = chess.BLACK if stored == "black" else chess.WHITE
        # Republish on the way up. The database is the truth and the file is
        # only a view of it, so a file left behind by anything else is stale
        # from the moment we resume, and Chichi reads the file.
        self.publish()

    def op_new_game(self, req):
        self.level = int(req.get("level", self.level))
        database.set_setting(self.conn, "level", self.level)

        wanted = str(req.get("colour", "white")).lower()
        if wanted == "random":
            wanted = random.choice(("white", "black"))
        self.my_colour = chess.BLACK if wanted == "black" else chess.WHITE

        self.board = chess.Board()
        opponent = f"coachd L{self.level}"
        self.game_id = database.new_game(
            self.conn, "app", level=self.level,
            white="you" if self.my_colour == chess.WHITE else opponent,
            black=opponent if self.my_colour == chess.WHITE else "you",
            my_colour=wanted)
        database.set_setting(self.conn, "current_game_id", self.game_id)

        # Playing black means the opponent opens, so the first thing you see is
        # a move rather than an empty board waiting on you.
        if self.my_colour == chess.BLACK:
            self.push(self.choose_reply(), by_me=False)
        return self.publish()

    def op_state(self, req):
        return self.publish(write=False)

    def op_move(self, req):
        if self.game_id is None:
            return {"error": "No game in progress. Start a new game first."}
        status = game_status(self.board)
        if is_over(status):
            return {"error": "This game is already over. Start a new game."}
        if self.board.turn != self.my_colour:
            return {"error": "It isn't your turn."}

        try:
            move = chess.Move.from_uci(req["uci"])
        except (ValueError, KeyError):
            return {"error": f"'{req.get('uci')}' is not a validly formatted move."}

        # A pawn reaching the last rank isn't legal until a piece is chosen, so
        # ask which one rather than rejecting the move outright.
        if move.promotion is None:
            piece = self.board.piece_at(move.from_square)
            if (piece and piece.piece_type == chess.PAWN
                    and chess.square_rank(move.to_square) in (0, 7)
                    and chess.Move(move.from_square, move.to_square,
                                   promotion=chess.QUEEN) in self.board.legal_moves):
                state = self.publish(write=False)
                state.update({"needs_promotion": True,
                              "from": chess.square_name(move.from_square),
                              "to": chess.square_name(move.to_square)})
                return state

        if move not in self.board.legal_moves:
            return {"error": f"'{req['uci']}' is not a legal move in this position."}

        jordan_san = self.push(move, by_me=True)
        # The board as it stands after his move alone. Both moves used to land
        # in the same frame, so his own move was never visible on its own and
        # the reply read as instantaneous rather than fast.
        mine_only = {"fen": self.board.fen(),
                     "last_move": {"from": chess.square_name(move.from_square),
                                   "to": chess.square_name(move.to_square)}}

        engine_san = None
        if not is_over(game_status(self.board)):
            engine_san = self.push(self.choose_reply(), by_me=False)

        state = self.publish()
        state.update({"jordan_played": jordan_san, "engine_played": engine_san,
                      "after_your_move": mine_only})
        return state

    def push(self, move, by_me):
        san = self.board.san(move)
        database.record_move(self.conn, self.game_id, len(self.board.move_stack),
                             move.uci(), san, self.board.fen(), by_me)
        self.board.push(move)
        return san

    def choose_reply(self):
        """The opponent: floor-strength play, with the occasional real mistake."""
        settings = LEVELS[self.level]
        if settings["slip"] and random.random() < settings["slip"]:
            slip = self.slip_move()
            if slip is not None:
                return slip
        self.opponent.configure({"UCI_LimitStrength": True,
                                 "UCI_Elo": settings["elo"]})
        return self.opponent.play(
            self.board, chess.engine.Limit(time=0.05)).move

    def slip_move(self):
        """A mistake it could plausibly have made, from its own candidate list.

        Every candidate here is a move the engine considered, so it looks like
        something a person would play: a piece developed to the wrong square, a
        capture that loses the exchange. A uniformly random legal move looks
        like nothing at all, which is why the old ladder taught Jordan to expect
        gifts rather than to punish mistakes.
        """
        self.opponent.configure({"UCI_LimitStrength": False})
        try:
            infos = self.opponent.analyse(
                self.board, chess.engine.Limit(time=0.15), multipv=SLIP_MULTIPV)
        except chess.engine.EngineError:
            return None
        scored = []
        for info in infos:
            if not info.get("pv"):
                continue
            scored.append((score_cp(info["score"], self.board.turn), info["pv"][0]))
        if len(scored) < 2:
            return None
        best = max(score for score, _ in scored)
        low, high = SLIP_BAND
        band = [move for score, move in scored if low <= best - score <= high]
        if band:
            return random.choice(band)
        # Nothing in the band: take the worst it looked at, which in a position
        # with only good moves is still only slightly worse. A level should not
        # manufacture a blunder that the position does not contain.
        return min(scored, key=lambda pair: pair[0])[1]

    def op_takeback(self, req):
        """Undo back to Jordan's turn: his move and the engine's reply. Used by
        the blunder guard in Phase 4 as well as the Take Back button."""
        if self.game_id is None or not self.board.move_stack:
            return {"error": "Nothing to take back."}

        first_ply = len(self.board.move_stack)
        self.board.pop()
        # Back to your own turn, whichever side you have. Popping to white was
        # right only while white was the only side you could be.
        if self.board.turn != self.my_colour and self.board.move_stack:
            self.board.pop()

        database.delete_moves_from(self.conn, self.game_id, len(self.board.move_stack))

        # Never hand back a position where it is the opponent's move. It only
        # ever moves in reply to one of yours, so the game would sit there with
        # nothing able to happen: taking back your first move as black emptied
        # the stack, left white to play, and wedged the game behind "It isn't
        # your turn." A fresh reply is the honest undo, and it is a different
        # one, which is the point of taking a move back.
        if self.board.turn != self.my_colour and not is_over(game_status(self.board)):
            self.push(self.choose_reply(), by_me=False)

        state = self.publish()
        state["took_back"] = first_ply - len(self.board.move_stack)
        return state

    # ---------- analysis ----------

    def op_analyse(self, req):
        """Evaluate a position, from the side to move's perspective.

        Answers are cached forever. Stockfish disagrees with itself run to run
        because its hash table carries between searches, which would otherwise
        let the coach tell two different stories about the same game.
        """
        fen = req["fen"]
        seconds = float(req.get("time", 0.3))
        limit_key = f"t{seconds:g}"

        cached = database.cached_analysis(self.conn, fen, limit_key)
        if cached is not None:
            return {"score_cp": cached["score_cp"], "best_uci": cached["best_uci"],
                    "depth": cached["depth"], "cached": True}

        board = chess.Board(fen)
        self.engine.configure({"Skill Level": 20})
        info = self.engine.analyse(board, chess.engine.Limit(time=seconds))
        score = score_cp(info["score"], board.turn)
        best = info["pv"][0].uci() if info.get("pv") else None
        depth = info.get("depth")
        database.store_analysis(self.conn, fen, limit_key, score, best, depth)
        return {"score_cp": score, "best_uci": best, "depth": depth, "cached": False}

    def op_preview(self, req):
        """Judge a move before it is played, so the guard can stop a blunder
        rather than report one.

        The engine decides whether the move is bad; the feature extractor only
        explains what it costs. Doing it the other way round would let a
        heuristic quietly miss a hung rook.
        """
        if self.game_id is None:
            return {"error": "No game in progress."}
        try:
            move = chess.Move.from_uci(req["uci"])
        except (ValueError, KeyError):
            return {"error": f"'{req.get('uci')}' is not a validly formatted move."}
        if move not in self.board.legal_moves:
            return {"error": f"'{req['uci']}' is not a legal move in this position."}

        seconds = float(req.get("time", 0.3))
        before = self.op_analyse({"fen": self.board.fen(), "time": seconds})

        after_board = self.board.copy()
        san = after_board.san(move)
        after_board.push(move)
        after = self.op_analyse({"fen": after_board.fen(), "time": seconds})

        eval_before = before["score_cp"]
        eval_after = -after["score_cp"]          # flip to Jordan's side of the board
        loss = max(0, eval_before - eval_after)
        severity = ("blunder" if loss >= 200 else "mistake" if loss >= 100
                    else "inaccuracy" if loss >= 50 else None)

        warn = (loss >= GUARD_THRESHOLD
                and eval_before >= GUARD_ALREADY_LOST
                and eval_after <= GUARD_STILL_WINNING)

        reply_fact = None
        if after.get("best_uci"):
            try:
                reply_fact = features.explain_reply(
                    self.board, move, chess.Move.from_uci(after["best_uci"]))
            except ValueError:
                reply_fact = None

        return {
            "uci": move.uci(),
            "san": san,
            "loss_cp": loss,
            "severity": severity,
            "warn": warn,
            "eval_before": eval_before,
            "eval_after": eval_after,
            # Only produced when there is something to warn about. A headline on
            # a perfectly good move is just noise pretending to be advice.
            "headline": (features.headline(self.board, move, reply_fact)
                         if warn else None),
            "reply": reply_fact,
            "best_uci": before.get("best_uci"),
            # What the move actually is, so the app can react to the right
            # thing. A word chosen by cause says something; a word chosen at
            # random is just decoration that eventually reads as noise.
            "move_kind": {
                "mate": after_board.is_checkmate(),
                "capture": self.board.is_capture(move),
                "fork": any(f["move"] == move.uci()
                            for f in features.forks(self.board, self.board.turn)),
            },
        }

    def op_piece_focus(self, req):
        """Everything about the piece the player is asking about.

        Asked "how should I respond to the knight?", the coach answered about a
        pawn it had mentioned two messages earlier: nothing told it which knight
        was meant, what that knight threatened, or what the answers to it were,
        so it reached for the last thing it had said. This works that out.

        Whose piece: the opponent's unless `whose` is "mine". Which one: the one
        that moved last if it is of that kind, otherwise the only one; with
        several and nothing to choose between them, all of them, and the coach is
        told to ask.
        """
        board = chess.Board(req["fen"]) if req.get("fen") else self.board
        kinds = {"pawn": chess.PAWN, "knight": chess.KNIGHT, "bishop": chess.BISHOP,
                 "rook": chess.ROOK, "queen": chess.QUEEN, "king": chess.KING}
        kind = kinds.get(str(req.get("piece", "")).lower())
        if kind is None or board.is_game_over():
            return {"error": "no such piece"}
        me = board.turn
        owner = me if req.get("whose") == "mine" else not me
        squares = list(board.pieces(kind, owner))
        if not squares:
            return {"found": [], "note": f"There is no {req.get('piece')} of that side on the board."}
        last = board.move_stack[-1].to_square if board.move_stack else None
        if last in squares:
            squares = [last]
        elif len(squares) > 2:
            squares = squares[:2]

        found = []
        for sq in squares:
            name = chess.square_name(sq)
            entry = {"square": name, "piece": features.piece_name(board.piece_at(sq)),
                     "whose": "theirs" if owner != me else "yours",
                     "moved_last": sq == last,
                     "attacks": [f"{features.piece_name(board.piece_at(t))} on {chess.square_name(t)}"
                                 for t in board.attacks(sq)
                                 if board.piece_at(t) and board.piece_at(t).color != owner],
                     "attacked_by": [f"{features.piece_name(board.piece_at(a))} on {chess.square_name(a)}"
                                     for a in board.attackers(not owner, sq)],
                     "defended_by": [f"{features.piece_name(board.piece_at(a))} on {chess.square_name(a)}"
                                     for a in board.attackers(owner, sq)]}
            if owner != me:
                # The player's real answers to it: take it, hit it, or move
                # what it is hitting. Each judged by the engine with its line.
                threatened = {t for t in board.attacks(sq)
                              if board.piece_at(t) and board.piece_at(t).color == me}
                moves, kinds_of = [], {}
                for m in board.legal_moves:
                    if m.to_square == sq:
                        kinds_of[m] = "takes it"
                    elif m.from_square in threatened:
                        kinds_of[m] = "moves a piece it attacks out of the way"
                    else:
                        probe = board.copy(); probe.push(m)
                        if sq in probe.attacks(m.to_square):
                            kinds_of[m] = "attacks it"
                        # Missing at first, and it was the real answer: asked about
                        # a knight hitting b4, the best move was a3, which guards b4.
                        elif any(len(probe.attackers(me, t)) > len(board.attackers(me, t))
                                 for t in threatened):
                            guarded = [chess.square_name(t) for t in threatened
                                       if len(probe.attackers(me, t)) > len(board.attackers(me, t))]
                            kinds_of[m] = "defends what it attacks (" + ", ".join(guarded) + ")"
                    if m in kinds_of:
                        moves.append(m)
                entry["answers"] = self._judged(board, moves, kinds_of)
            else:
                moves = [m for m in board.legal_moves if m.from_square == sq]
                entry["its_moves"] = self._judged(board, moves, {})
            found.append(entry)

        best = self.op_analyse({"fen": board.fen(), "time": 0.3})
        out = {"found": found}
        if best.get("best_uci"):
            move = chess.Move.from_uci(best["best_uci"])
            out["best_move_overall"] = {"san": board.san(move), "score_cp": best["score_cp"]}
        if len(found) > 1:
            out["note"] = "More than one fits and none moved last. Ask which one they mean."
        return out

    def _judged(self, board, moves, kinds_of, keep=3):
        """The best few of `moves`, each scored by the engine with its line."""
        if not moves:
            return []
        self.engine.configure({"Skill Level": 20})
        infos = self.engine.analyse(board, chess.engine.Limit(time=0.4),
                                    multipv=min(keep, len(moves)), root_moves=moves)
        out = []
        for info in infos:
            if not info.get("pv"):
                continue
            m = info["pv"][0]
            item = {"san": board.san(m), "score_cp": score_cp(info["score"], board.turn),
                    "line": board.variation_san(info["pv"][:LINE_PLIES])}
            if m in kinds_of:
                item["what_it_does"] = kinds_of[m]
            out.append(item)
        return out

    def op_threats(self, req):
        """What the opponent is threatening, computed rather than guessed.

        Every other fact in the packet is about what the player can do, so
        "what is he threatening?" had nothing behind it and was answered out of
        thin air: in one test run, "they have a check with the bishop on b4" on
        move two of a game. A null move hands the position over and asks the
        engine what it would do with it.
        """
        board = chess.Board(req["fen"]) if req.get("fen") else self.board
        if board.is_game_over():
            return {"game_over": True}

        out = {"in_check": board.is_check(),
               "your_pieces_under_attack": features.pressure(board, board.turn)}
        if board.is_check():
            # A null move is illegal in check, and what they threaten next is not
            # the question while the check is still on the board.
            out["checked_by"] = [{"square": chess.square_name(sq),
                                  "piece": features.piece_name(board.piece_at(sq))}
                                 for sq in board.checkers()]
            return out

        probe = board.copy()
        probe.push(chess.Move.null())
        self.engine.configure({"Skill Level": 20})
        info = self.engine.analyse(probe, chess.engine.Limit(time=float(req.get("time", 0.3))))
        if not info.get("pv"):
            return out
        move = info["pv"][0]
        threat = {"san": probe.san(move), "uci": move.uci(),
                  "gives_check": probe.gives_check(move)}
        victim = probe.piece_at(move.to_square)
        if probe.is_capture(move) and victim is not None:
            threat["captures"] = features.piece_name(victim)
            threat["on"] = chess.square_name(move.to_square)
        after = probe.copy()
        after.push(move)
        if "captures" in threat:
            # What matters to the player is whether they get the piece back, not
            # who else of theirs was covering the square.
            threat["you_can_take_back_with"] = sorted(
                after.san(m) for m in after.legal_moves if m.to_square == move.to_square)
        if after.is_checkmate():
            threat["checkmate"] = True
        threat["then_attacks"] = [
            f"{features.piece_name(after.piece_at(t))} on {chess.square_name(t)}"
            for t in after.attacks(move.to_square)
            if after.piece_at(t) and after.piece_at(t).color == board.turn]
        out["their_best"] = threat
        return out

    def op_candidates(self, req):
        """The engine's best few moves in the current position.

        Deliberately not part of the automatic Socratic packet: handing over the
        answers alongside the question defeats the question. This is what gets
        attached when Jordan asks for options himself.
        """
        board = chess.Board(req["fen"]) if req.get("fen") else self.board
        if board.is_game_over():
            return {"candidates": []}
        count = int(req.get("count", 3))
        self.engine.configure({"Skill Level": 20})
        infos = self.engine.analyse(board, chess.engine.Limit(time=float(req.get("time", 0.3))),
                                    multipv=count)
        out = []
        for info in infos:
            if not info.get("pv"):
                continue
            move = info["pv"][0]
            entry = {"san": board.san(move), "uci": move.uci(),
                     "score_cp": score_cp(info["score"], board.turn),
                     # Where the engine expects the game to go after it. It had
                     # always worked this out and only the first move was kept,
                     # so the coach could never talk further ahead than one move
                     # and the reply: every plan it offered was its own guess.
                     "line": board.variation_san(info["pv"][:LINE_PLIES]),
                     **features.move_facts(board, move)}

            # What they answer with, and whether they can simply take it.
            # Told "Bxf7+ is the best move", Jordan asked "he can just take my
            # bishop no?" and was told he could not. Kxf7 was one of three
            # legal replies and he lost the bishop. The move was genuinely the
            # engine's choice; only the reason given for it was invented, and
            # `explain_reply` had the true reason all along.
            after = board.copy()
            after.push(move)
            entry["they_can_capture_it_with"] = sorted(
                after.san(m) for m in after.legal_moves
                if m.to_square == move.to_square)
            if not after.is_game_over():
                reply = self.op_analyse({"fen": after.fen(), "time": 0.2})
                if reply.get("best_uci"):
                    try:
                        entry["their_best_reply"] = features.explain_reply(
                            board, move, chess.Move.from_uci(reply["best_uci"]))
                    except ValueError:
                        pass
            out.append(entry)

        # When the top moves are within noise of each other there is no "best"
        # to report, and the order they come back in shuffles between calls.
        # Saying so beats inventing a preference.
        spread = (max(c["score_cp"] for c in out) - min(c["score_cp"] for c in out)) if out else 0
        equal = spread <= 30

        # The conclusion goes in the data as a finished sentence. A boolean gets
        # ignored; a sentence gets relayed. This is the same reason the blunder
        # guard writes its own headline rather than leaving it to be phrased.
        if not out:
            note = "No moves available."
        elif equal:
            # Telling the model these are equal was not enough: it kept naming
            # the first one as the best. So when they really are equal the
            # payload stops implying an order at all. The scores are noise at
            # this spread and the engine's own ordering shuffles between calls,
            # so an alphabetical list is the more truthful shape.
            out = sorted(out, key=lambda c: c["san"])
            for c in out:
                c.pop("score_cp", None)
            note = ("These are about equal, so there is no best one here. "
                    "They are listed alphabetically, not in any order of merit.")
        else:
            note = f"{out[0]['san']} is clearly the strongest."
        return {"candidates": out, "spread_cp": spread,
                "effectively_equal": equal, "note": note}

    def op_move_facts(self, req):
        """What the moves to particular squares would actually do.

        Asked "should i move it to f4?", the model answered that the bishop
        would attack the pawn on e6. Bf4 does not see e6 at all, and the bishop
        it had suggested developing a move earlier could not move anywhere. It
        was describing a plausible bishop rather than this one, because nothing
        had computed this one. `features.move_facts` already existed and was
        only ever wired into the candidate-list path.

        Unreachable squares are reported too: "no legal move goes there" is an
        answer, and a much better one than a confident sentence about a move
        that cannot be played.
        """
        # A fen may be given: while a drill is on screen the question is about
        # the puzzle, not about whatever game the daemon is holding. Asked "rook
        # to e8 right?" during a Lichess puzzle, the app answered "nothing can go
        # to e8" because it had described the Play tab's board instead.
        board = chess.Board(req["fen"]) if req.get("fen") else self.board
        wanted = [str(sq).lower() for sq in (req.get("squares") or [])][:3]
        judge = bool(req.get("judge"))
        best_cp = None
        if judge and not board.is_game_over():
            best_cp = self.op_analyse({"fen": board.fen(), "time": 0.25})["score_cp"]

        out, reached = [], set()
        for move in board.legal_moves:
            target = chess.square_name(move.to_square)
            if target not in wanted:
                continue
            reached.add(target)
            facts = features.move_facts(board, move)
            facts.update({"san": board.san(move),
                          "from": chess.square_name(move.from_square),
                          "to": target})
            if best_cp is not None:
                after = board.copy()
                after.push(move)
                # Flipped: op_analyse scores from the side to move.
                after_cp = -self.op_analyse({"fen": after.fen(), "time": 0.25})["score_cp"]
                facts["loss_cp"] = max(0, best_cp - after_cp)
                try:
                    facts["their_best_reply"] = features.explain_reply(
                        board, move,
                        chess.Move.from_uci(self.op_analyse(
                            {"fen": after.fen(), "time": 0.2})["best_uci"]))
                except (ValueError, TypeError):
                    pass
            out.append(facts)
        return {"moves": out,
                "no_legal_move_to": [sq for sq in wanted if sq not in reached]}

    # ---------- opening book ----------
    #
    # Served here rather than left to Chichi to fetch. Told to run a script for
    # the line, he ran the wrong one, got "no game in progress", and then wrote
    # a Reti from memory containing "Bg1", which is not a move. Handing him the
    # answer costs one lookup and removes the option of inventing it.

    def op_opening_advice(self, req):
        """What to work on, from his own results rather than a random draw.

        The random pick draws uniformly from 3,329 named lines, 96% of which
        are sub-variations nobody at this level reaches, so "give me an
        opening" answered with things like "Queen's Gambit Declined: Baltic
        Defense, Argentinian Gambit". His own games say which openings keep
        costing him, and the explorer says what players at his rating actually
        do about them. Both beat a lottery.
        """
        import openings, repertoire
        try:
            advice = repertoire.advice(self.conn)
            # Set the Explore board to the line being recommended. The answer
            # says it is there; saying so without doing it is the kind of small
            # lie that costs the whole panel its credibility.
            sides = [advice.get(k) for k in ("as_white", "as_black")]
            worst = min((s for s in sides if s and s.get("a_line_in_the_weak_one")),
                        key=lambda s: s["weakest"]["score_pct"], default=None)
            if worst:
                row = self.conn.execute(
                    "SELECT eco, name, uci, epd FROM openings WHERE name = ? LIMIT 1",
                    (worst["a_line_in_the_weak_one"]["name"],)).fetchone()
                if row:
                    sans, board = openings.line_from(row["uci"])
                    openings.write_state(row, sans, board)
            return advice
        except Exception as exc:
            # An unlinked account, or no games imported yet. The caller falls
            # back to the random pick, which is worse but is not nothing.
            return {"error": str(exc)}

    def op_opening_random(self, req):
        """A real named line to try, and the Explore board set to it."""
        import openings
        row = openings.pick_random(self.conn)
        if row is None:
            return {"error": "No openings imported. Run: openings.sh import"}
        sans, board = openings.line_from(row["uci"])
        openings.write_state(row, sans, board)
        return {"name": row["name"], "eco": row["eco"],
                "line": openings.numbered(sans),
                "moves_san": sans,
                "white_plays": sans[0::2], "black_plays": sans[1::2],
                "next_to_move": "white" if board.turn else "black"}

    def op_opening_here(self, req):
        """What the live game is, by name, and what carries on from it."""
        import openings
        moves = [m.uci() for m in self.board.move_stack]
        if not moves:
            return {"in_game": False}
        sans, _ = openings.line_from(" ".join(moves))
        deepest, at = openings.identify(self.conn, moves)
        out = []
        for row in openings.continuations(self.conn, moves):
            full, _ = openings.line_from(row["uci"])
            out.append({"name": row["name"], "eco": row["eco"],
                        "moves_san": full,
                        "continues_with": full[len(moves):]})
        return {"in_game": True,
                "name": deepest[1] if deepest else None,
                "eco": deepest[0] if deepest else None,
                "named_after": openings.numbered(sans[:at]) if deepest else None,
                "left_book_with": sans[at:],
                "continuations": out}

    def op_opening_search(self, req):
        """Named openings matching a typed query, for the Explore picker.

        Explore had no way to choose an opening at all: the only route in was
        asking Chichi by name, which means knowing the name first. Matching goes
        through `flat()` so "kings indian" finds "King's Indian".
        """
        query = (req.get("query") or "").strip()
        limit = int(req.get("limit", 40))
        if not query:
            # With no query, the shortest lines come first, which meant Amar,
            # Grob and Clemenz: real openings nobody plays. How many named
            # variations a family has is a decent stand-in for how studied it
            # is, and it puts the Sicilian and the French at the top without
            # needing popularity data the database does not have.
            families = {}
            for row in self.conn.execute("SELECT eco, name, uci FROM openings"):
                family = row["name"].split(":")[0].strip()
                entry = families.setdefault(family, {"count": 0, "row": None})
                entry["count"] += 1
                # The family's own row if there is one. Going by shortest line
                # gave "French Defense: Banzai-Leong Gambit" as the face of the
                # French, because it is three plies and the French proper is
                # four.
                best = entry["row"]
                if (best is None
                        or (row["name"] == family and best["name"] != family)
                        or (best["name"] != family and len(row["uci"]) < len(best["uci"]))):
                    entry["row"] = row
            ranked = sorted(families.values(), key=lambda e: -e["count"])[:limit]
            return {"results": [{"eco": e["row"]["eco"], "name": e["row"]["name"]}
                                for e in ranked]}
        else:
            rows = self.conn.execute(
                "SELECT eco, name FROM openings WHERE flat(name) LIKE '%' || flat(?) || '%' "
                "ORDER BY LENGTH(name), name LIMIT ?", (query, limit)).fetchall()
        return {"results": [{"eco": r["eco"], "name": r["name"]} for r in rows]}

    def op_opening_show(self, req):
        """Put a named opening on the Explore board."""
        import openings
        row = openings.find(self.conn, req.get("name") or "")
        if row is None:
            return {"error": f"No opening called {req.get('name')!r}."}
        sans, board = openings.line_from(row["uci"])
        openings.write_state(row, sans, board)
        return {"name": row["name"], "eco": row["eco"], "moves_san": sans}

    def op_opening_next(self, req):
        """The book's next move in a chosen opening, from where the game is.

        Asked from the starting position, `opening_here` says there is no game,
        which is true and was read as "the book has ended" on the very first
        click. The book has not started. This takes the opening Jordan picked
        and answers the only question that matters while playing it: what does
        the line play here.

        The opponent has a vote, so the search is the whole family, not the one
        line he clicked, and the shortest line that still contains the game is
        the nearest book move rather than the deepest theory.
        """
        import openings
        name = (req.get("name") or "").strip()
        family = name.split(":")[0].strip()
        moves = [m.uci() for m in self.board.move_stack]

        rows = self.conn.execute(
            "SELECT eco, name, uci FROM openings WHERE name = ? OR name LIKE ?",
            (family, family + ":%")).fetchall()
        best = None
        for row in rows:
            ucis = row["uci"].split()
            if len(ucis) > len(moves) and ucis[:len(moves)] == moves:
                exact = row["name"] == name
                key = (0 if exact else 1, len(ucis))
                if best is None or key < best[0]:
                    best = (key, row)

        if best is None:
            # Say where it parted and who parted from it. At the lower levels
            # the engine answers 1.e4 with whatever it likes, so a line usually
            # dies because the opponent left it rather than because Jordan did,
            # and "you are out of the Italian Game" reads like an accusation.
            deepest, _ = openings.identify(self.conn, moves) if moves else (None, 0)
            out = {"following": False, "now": deepest[1] if deepest else None}
            longest, cut = None, -1
            for row in rows:
                ucis = row["uci"].split()
                n = 0
                while n < min(len(ucis), len(moves)) and ucis[n] == moves[n]:
                    n += 1
                if n > cut:
                    cut, longest = n, (row, ucis)
            if longest and cut < len(moves):
                row, ucis = longest
                board = chess.Board()
                for uci in moves[:cut]:
                    board.push(chess.Move.from_uci(uci))
                out["diverged_by"] = "white" if board.turn == chess.WHITE else "black"
                out["played_san"] = board.san(chess.Move.from_uci(moves[cut]))
                if cut < len(ucis):
                    out["book_wanted"] = board.san(chess.Move.from_uci(ucis[cut]))
            return out

        row = best[1]
        full, _ = openings.line_from(row["uci"])
        return {"following": True, "name": row["name"],
                "next_san": full[len(moves)], "remaining": full[len(moves):]}

    def op_describe(self, req):
        """The position as a list of checkable facts, for coaching commentary."""
        board = chess.Board(req["fen"]) if req.get("fen") else self.board
        # Mate is an engine fact, not a heuristic, so it is fetched here rather
        # than in features.py and handed in. Answers are cached, so a position
        # seen twice costs nothing.
        mate = None
        if not board.is_game_over():
            analysis = self.op_analyse({"fen": board.fen(),
                                        "time": float(req.get("time", 0.3))})
            mate = mate_in(analysis["score_cp"])
        facts = features.describe(board)
        # Where the pieces were two plies back. A coach narrating what just
        # happened ("you captured their pawn on a4") is describing the board
        # before the capture, and checking that sentence against the board
        # after it makes a true statement look like an invention.
        recent = {}
        if not req.get("fen"):
            probe = board.copy()
            for _ in range(min(2, len(probe.move_stack))):
                probe.pop()
            recent = {chess.square_name(sq): features.piece_name(piece)
                      for sq, piece in probe.piece_map().items()}
        facts["squares_recent"] = recent
        facts["mate_in"] = mate
        # Everything true about the position that earns a sentence, best first.
        # The coach picks from this rather than being told which kind of fact
        # to lead with, which is what made eight turns in a row open the same
        # way. Reuses the facts already computed: describe() walks every legal
        # move looking for forks and is not worth doing twice.
        ranked = features.worth_saying(board, mate_in=mate, facts=facts)
        facts["summary"] = ranked[0]["text"]
        # The ranked list reaches the model without its `text`. Handed a
        # finished English sentence the model reads it out, which is how a
        # ranked list of four true things still produced four turns opening
        # "Your PIECE on SQUARE is hanging to". `summary` above keeps the prose
        # because that one is the app's own line, shown while the model thinks.
        facts["worth_saying"] = [{k: v for k, v in item.items() if k != "text"}
                                 for item in ranked]
        return facts

    # ---------- drills ----------

    def op_puzzle_next(self, req):
        puzzle = puzzle_store.next_puzzle(self.conn, req.get("source"))
        if puzzle is None:
            return {"error": "No puzzles available. Import some first."}
        # The solution never leaves the daemon until it is asked for, so the
        # answer cannot be read off the wire before the attempt.
        self.pending_puzzle = puzzle
        # The board needs the legal moves to accept a tap at all, and the dots
        # are the same affordance the Play tab has.
        board = chess.Board(puzzle["position_fen"])
        legal = {}
        for move in board.legal_moves:
            legal.setdefault(chess.square_name(move.from_square), set()).add(
                chess.square_name(move.to_square))
        payload = {k: v for k, v in puzzle.items()
                   if k not in ("moves", "solution", "solution_san")}
        payload["legal"] = {k: sorted(v) for k, v in legal.items()}
        return payload

    def op_puzzle_try(self, req):
        """Judge an attempt at the puzzle currently being shown."""
        puzzle = getattr(self, "pending_puzzle", None)
        if puzzle is None or puzzle["id"] != req.get("id"):
            return {"error": "That puzzle is not the one in front of you."}

        answer = puzzle["solution"][0] if puzzle["solution"] else None
        board = chess.Board(puzzle["position_fen"])
        correct = req.get("uci") == answer
        also_good = False
        if not correct and answer:
            also_good = self._as_good_as(board, req.get("uci", ""), answer)
            correct = also_good
        result = {
            "id": puzzle["id"],
            "correct": correct,
            "also_good": also_good,
            "answer": answer,
            "answer_san": puzzle.get("solution_san"),
            "played_before": puzzle.get("played_san"),
        }
        if not correct:
            try:
                result["your_move_san"] = board.san(chess.Move.from_uci(req.get("uci", "")))
            except (ValueError, AssertionError):
                result["your_move_san"] = req.get("uci")
        result["schedule"] = puzzle_store.grade(self.conn, puzzle["id"], correct,
                                                req.get("seconds"))
        return result

    # A move this close to the best one is not a wrong answer. Half a pawn is the
    # inaccuracy threshold in history.py, so a move accepted here is one that the
    # game review would not have flagged either.
    PUZZLE_TOLERANCE_CP = 50

    def _as_good_as(self, board, uci, answer):
        """Whether a move other than the stored answer is just as good.

        Only the exact answer used to count. Lichess puzzles are built to have
        one clearly winning move, but a position where the player blundered was
        not: often the lesson is only "don't hang the queen", and several moves
        manage that. Stockfish judges the attempt the same way it judged the
        original move, from the position after each, at the same time budget.
        """
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            return False
        if move not in board.legal_moves:
            return False

        def after(m):
            probe = board.copy()
            probe.push(m)
            if probe.is_checkmate():
                return 100000
            # Scored for the side now to move, which is the opponent.
            return -self.op_analyse({"fen": probe.fen(), "time": 0.3})["score_cp"]

        return after(chess.Move.from_uci(answer)) - after(move) <= self.PUZZLE_TOLERANCE_CP

    # ---------- opening drills ----------

    def op_opening_drill(self, req):
        """Start drilling a named line. You produce your moves; the app plays
        the other side's, straight from the stored line rather than an engine,
        so the drill is the theory and nothing else."""
        row = opening_book.find(self.conn, req.get("name", ""))
        if row is None:
            return {"error": f"No opening called {req.get('name')!r}.",
                    "suggestions": opening_book.suggestions(self.conn, req.get("name", ""))}
        self.drill_line = {"name": row["name"], "eco": row["eco"],
                           "moves": row["uci"].split(), "board": chess.Board(),
                           "side": req.get("side", "white"), "index": 0, "wrong": 0}
        # Drilling as Black means the line's first move is played for you.
        if self.drill_line["side"] == "black":
            self._advance_book()
        return self._drill_state()

    def op_opening_drill_move(self, req):
        state = getattr(self, "drill_line", None)
        if state is None:
            return {"error": "No opening drill in progress."}
        if state["index"] >= len(state["moves"]):
            return {**self._drill_state(), "finished": True}

        expected = state["moves"][state["index"]]
        board = state["board"]
        got = req.get("uci", "")
        if got != expected:
            state["wrong"] += 1
            try:
                got_san = board.san(chess.Move.from_uci(got))
            except (ValueError, AssertionError):
                got_san = got
            return {**self._drill_state(), "correct": False,
                    "you_played": got_san,
                    "expected": board.san(chess.Move.from_uci(expected))}

        played = board.san(chess.Move.from_uci(expected))
        board.push(chess.Move.from_uci(expected))
        state["index"] += 1
        reply = self._advance_book()
        return {**self._drill_state(), "correct": True, "you_played": played, "reply": reply}

    def _advance_book(self):
        """Play the other side's next book move, if the line has one left."""
        state = self.drill_line
        if state["index"] >= len(state["moves"]):
            return None
        board = state["board"]
        move = chess.Move.from_uci(state["moves"][state["index"]])
        san = board.san(move)
        board.push(move)
        state["index"] += 1
        return san

    def _drill_state(self):
        state = self.drill_line
        board = state["board"]
        legal = {}
        for move in board.legal_moves:
            legal.setdefault(chess.square_name(move.from_square), set()).add(
                chess.square_name(move.to_square))
        replay = chess.Board()
        sans = []
        for mv in board.move_stack:
            sans.append(replay.san(mv))
            replay.push(mv)
        return {
            "name": state["name"], "eco": state["eco"], "fen": board.fen(),
            "moves_san": sans, "ply": state["index"], "total": len(state["moves"]),
            "wrong": state["wrong"], "side": state["side"],
            "finished": state["index"] >= len(state["moves"]),
            "legal": {k: sorted(v) for k, v in legal.items()},
        }

    # ---------- endgame drills ----------

    def op_endgame_drills(self, req):
        return {"drills": [{"key": k, "name": v["name"]} for k, v in endgames.DRILLS.items()]}

    def op_endgame_new(self, req):
        drill = req.get("drill", "rook")
        if drill not in endgames.DRILLS:
            return {"error": f"No drill called {drill!r}."}
        board = endgames.random_position(drill)
        info = endgames.lookup(board)
        self.endgame = {"drill": drill, "board": board,
                        "target_plies": info.get("dtm"), "your_plies": 0, "optimal": 0}
        return self._endgame_state()

    def op_endgame_move(self, req):
        state = getattr(self, "endgame", None)
        if state is None:
            return {"error": "No endgame in progress."}
        board = state["board"]
        try:
            move = chess.Move.from_uci(req["uci"])
        except (ValueError, KeyError):
            return {"error": f"'{req.get('uci')}' is not a validly formatted move."}
        if move not in board.legal_moves:
            return {"error": f"'{req['uci']}' is not legal here."}

        # The tablebase returns moves best-first, so its first entry is both the
        # right move for you and the toughest defence for them.
        before = endgames.lookup(board)
        best = before["moves"][0]["uci"] if before.get("moves") else None
        played_san = board.san(move)
        was_optimal = move.uci() == best
        best_san = board.san(chess.Move.from_uci(best)) if best else None
        board.push(move)
        state["your_plies"] += 1
        state["optimal"] += int(was_optimal)

        defence = None
        if endgames.status_of(board) == "ongoing":
            after = endgames.lookup(board)
            if after.get("moves"):
                reply = chess.Move.from_uci(after["moves"][0]["uci"])
                defence = board.san(reply)
                board.push(reply)

        # A finished drill is recorded once, so the day's tally can include it.
        # Endgames kept no record of any kind before this.
        status = endgames.status_of(board)
        if status != "ongoing" and not state.get("recorded"):
            state["recorded"] = True
            database.record_endgame(self.conn, state["drill"], status == "checkmate")

        return {**self._endgame_state(), "you_played": played_san,
                "was_optimal": was_optimal, "best_was": best_san, "defence": defence}

    def _endgame_state(self):
        state = self.endgame
        board = state["board"]
        legal = {}
        for move in board.legal_moves:
            legal.setdefault(chess.square_name(move.from_square), set()).add(
                chess.square_name(move.to_square))
        return {
            "drill": state["drill"],
            "name": endgames.DRILLS[state["drill"]]["name"],
            "fen": board.fen(),
            "status": endgames.status_of(board),
            "target_plies": state["target_plies"],
            "your_plies": state["your_plies"],
            "optimal_moves": state["optimal"],
            "turn": "white" if board.turn == chess.WHITE else "black",
            "legal": {k: sorted(v) for k, v in legal.items()},
            "last_move": (
                {"from": chess.square_name(board.move_stack[-1].from_square),
                 "to": chess.square_name(board.move_stack[-1].to_square)}
                if board.move_stack else None),
            "check_square": (chess.square_name(board.king(board.turn))
                             if board.is_check() and board.king(board.turn) is not None else None),
        }

    def op_puzzle_stats(self, req):
        return puzzle_store.stats(self.conn)

    # ---------- published view ----------

    def legal_map(self):
        """from-square -> the squares it may move to. The board draws its dots
        straight from this, so selecting a piece costs no round trip at all."""
        out = {}
        for move in self.board.legal_moves:
            out.setdefault(chess.square_name(move.from_square), set()).add(
                chess.square_name(move.to_square))
        return {k: sorted(v) for k, v in out.items()}

    def check_square(self):
        if not self.board.is_check():
            return None
        king = self.board.king(self.board.turn)
        return chess.square_name(king) if king is not None else None

    def publish(self, write=True):
        replay = chess.Board()
        sans = []
        for mv in self.board.move_stack:
            sans.append(replay.san(mv))
            replay.push(mv)

        status = game_status(self.board)
        if self.game_id is not None:
            database.set_game_status(self.conn, self.game_id, status)

        state = {
            "moves": [m.uci() for m in self.board.move_stack],
            "moves_san": sans,
            "fen": self.board.fen(),
            "turn": "white" if self.board.turn == chess.WHITE else "black",
            "my_colour": "white" if self.my_colour == chess.WHITE else "black",
            "status": status if self.game_id is not None else "no game yet",
            "level": self.level,
            "legal": self.legal_map(),
            "check_square": self.check_square(),
            "last_move": (
                {"from": chess.square_name(self.board.move_stack[-1].from_square),
                 "to": chess.square_name(self.board.move_stack[-1].to_square)}
                if self.board.move_stack else None
            ),
        }
        if write:
            tmp = self.state_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f, indent=2)
            os.replace(tmp, self.state_path)   # atomic, so Chichi never sees a half-written file
        return state

    # ---------- server ----------

    def op_ping(self, req):
        return {"ok": True, "pid": os.getpid(),
                "uptime_s": round(time.time() - self.started, 1),
                # Which code this daemon is actually running. A daemon outlives
                # the app that started it, so after an update the new app talks
                # to the old daemon: Rookie once offered to download 30,000
                # puzzles that were already there, because the daemon it asked
                # was too old to know the question. The app compares this with
                # its own copy and restarts the daemon when they differ.
                "code": CODE_DIR, "code_version": CODE_VERSION}

    def op_library(self, req):
        """What the data folder actually holds, for the first-launch screen.

        A fresh install can play chess straight away (the engine is bundled) and
        has nothing else: no named openings, so Explore finds nothing, and no
        puzzles, so Drill is empty. The app has to know which of those are
        missing before it can offer to fetch them.
        """
        def count(sql):
            try:
                return self.conn.execute(sql).fetchone()[0]
            except Exception:
                return 0
        return {"openings": count("SELECT COUNT(*) FROM openings"),
                "puzzles": count("SELECT COUNT(*) FROM puzzles WHERE source = 'lichess'"),
                "own_puzzles": count("SELECT COUNT(*) FROM puzzles WHERE source = 'own'"),
                "games": count("SELECT COUNT(*) FROM games")}

    def handle(self, req):
        op = req.get("op")
        handler = getattr(self, f"op_{op}", None) if op else None
        if handler is None:
            return {"error": f"unknown op {op!r}"}
        return handler(req)

    def serve(self):
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.socket_path)
        server.listen(16)
        print(f"coachd listening on {self.socket_path} (pid {os.getpid()})", flush=True)

        self.running = True
        while self.running:
            try:
                conn, _ = server.accept()
            except OSError:
                break
            with conn:
                try:
                    line = conn.makefile("rb").readline()
                    if not line:
                        continue
                    req = json.loads(line)
                    if req.get("op") == "shutdown":
                        self.running = False
                        conn.sendall(b'{"ok": true, "shutting_down": true}\n')
                        continue
                    reply = self.handle(req)
                except Exception as exc:                      # noqa: BLE001
                    reply = {"error": f"{type(exc).__name__}: {exc}"}
                try:
                    conn.sendall((json.dumps(reply) + "\n").encode())
                except BrokenPipeError:
                    pass

        server.close()
        self.close()

    def close(self):
        try:
            self.engine.quit()
            self.opponent.quit()
        except Exception:                                     # noqa: BLE001
            pass
        self.conn.close()
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--db", default=database.DEFAULT_PATH)
    args = parser.parse_args()

    # Refuse to start a second daemon on a live socket; clear a stale one.
    if os.path.exists(args.socket):
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(args.socket)
            probe.close()
            print(f"coachd already running on {args.socket}", file=sys.stderr)
            sys.exit(1)
        except OSError:
            os.unlink(args.socket)

    coach = Coach(args.db, args.socket)

    def stop(signum, frame):
        coach.running = False
        coach.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # The engines are already running by now, and their threads keep Python
    # alive after the main thread dies. A daemon that failed to bind its socket
    # therefore stayed up forever holding two Stockfish processes, and every
    # retry from the app added another: five were found at once. Whatever stops
    # serve(), the engines go with it.
    try:
        coach.serve()
    finally:
        coach.close()


if __name__ == "__main__":
    main()

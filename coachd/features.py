#!/usr/bin/env python3
"""
Facts about a position, computed rather than guessed.

"You lost 180 centipawns" means nothing to a beginner. "Your rook on d4 is
hanging, the bishop takes it for free" is a coaching sentence. This module
produces the second kind: a list of concrete, checkable statements that Chichi
translates into plain language and never invents.

Nothing here decides whether a move is good. That is the engine's job. This
only describes what is on the board.
"""
import chess

VALUES = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
          chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0}

NAMES = {chess.PAWN: "pawn", chess.KNIGHT: "knight", chess.BISHOP: "bishop",
         chess.ROOK: "rook", chess.QUEEN: "queen", chess.KING: "king"}


def piece_name(piece):
    return NAMES[piece.piece_type]


def material(board, colour):
    return sum(VALUES[p.piece_type] for p in board.piece_map().values()
               if p.color == colour)


def hanging(board, colour):
    """Pieces of `colour` that can be taken at a profit right now.

    Two cases count: a piece that is attacked and undefended, and a piece
    attacked by something cheaper than itself. That is not a full static
    exchange evaluation, but it catches what actually loses beginners games.
    """
    found = []
    for square, piece in board.piece_map().items():
        if piece.color != colour or piece.piece_type == chess.KING:
            continue
        attackers = board.attackers(not colour, square)
        if not attackers:
            continue
        defenders = board.attackers(colour, square)
        value = VALUES[piece.piece_type]
        cheapest = min(VALUES[board.piece_at(sq).piece_type] for sq in attackers)

        if not defenders:
            loss, why = value, "undefended"
        elif cheapest < value:
            loss, why = value - cheapest, "attacked by something cheaper"
        else:
            continue

        # Name the pieces, not just the squares. Given only "defended_by: e1"
        # the model guessed "the queen on e1" when it was the king: a gap in
        # the facts is an invitation to invent one.
        def describe_squares(squares):
            out = []
            for sq in sorted(squares):
                other = board.piece_at(sq)
                out.append({"square": chess.square_name(sq),
                            "piece": piece_name(other) if other else "?"})
            return out

        found.append({
            "square": chess.square_name(square),
            "piece": piece_name(piece),
            "value": value,
            "reason": why,
            "attacked_by": describe_squares(attackers),
            "defended_by": describe_squares(defenders),
            "material_at_risk": loss,
        })
    return sorted(found, key=lambda f: -f["material_at_risk"])


def forks(board, colour):
    """Moves `colour` could play that would attack two or more valuable pieces
    *and survive doing it*.

    Attacking two pieces from a square where you are simply captured is not a
    fork, it is a donation. An earlier version of this omitted the survival
    check and cheerfully offered Nd7 in a position where d7 was covered by both
    the enemy king and queen, which the engine correctly called a blunder. The
    two disagreeing is what surfaced the bug.

    A target also has to be worth taking. A later version counted any enemy
    piece worth three or more, so it read a queen attacking a twice-defended
    queen and a defended knight as a fork. It offered Qa7, then Qb7, then Qa7
    again, walking the queen between two squares for the rest of the game while
    the engine called each move an inaccuracy. Neither capture won anything:
    take the knight and the queen falls. So a target now counts only if taking
    it would actually profit, meaning it is undefended, or worth more than the
    piece attacking it. The king is the exception, since it cannot be captured
    at all: a check has to be answered, so whatever else the move hits is still
    there next turn.
    """
    found = []
    board = board.copy()
    board.turn = colour
    for move in board.legal_moves:
        board.push(move)

        attacker = board.piece_at(move.to_square)
        targets = []
        if attacker:
            mine = VALUES[attacker.piece_type]
            for square in board.attacks(move.to_square):
                victim = board.piece_at(square)
                if not victim or victim.color == colour:
                    continue
                # The king cannot be captured, so "is it winnable" does not
                # apply: check forces a reply, and the other target falls next
                # move. Its value is 0, so without this the royal fork, the one
                # a beginner most needs shown, was reported as nothing at all.
                if victim.piece_type == chess.KING:
                    targets.append({"square": chess.square_name(square),
                                    "piece": piece_name(victim), "value": 0})
                    continue
                worth = VALUES[victim.piece_type]
                if worth < 3:
                    continue
                # Defended and no dearer than the attacker means the capture
                # loses material rather than winning it. Not a target.
                if board.attackers(not colour, square) and worth <= mine:
                    continue
                targets.append({"square": chess.square_name(square),
                                "piece": piece_name(victim), "value": worth})

        # Does the forking piece actually stand there? Reuses the same test as
        # everything else, so "safe" means one thing across the whole module.
        survives = not any(h["square"] == chess.square_name(move.to_square)
                           for h in hanging(board, colour))
        board.pop()

        if len(targets) >= 2 and survives:
            # SAN as well as the squares. The coach was given "f3-e5", wrote the
            # correct "Ne5" out of it, and had the answer binned as an invented
            # move because nothing it had been given contained the token.
            found.append({"move": move.uci(), "san": board.san(move),
                          "from": chess.square_name(move.from_square),
                          "to": chess.square_name(move.to_square), "targets": targets})
    return found


CENTRE = {chess.D4, chess.E4, chess.D5, chess.E5}


def move_facts(board, move):
    """What a candidate move actually does, computed.

    Given only a list of move names, the model described a knight going to h3 as
    "developing to a central square". These are the facts it needs so its one
    line of commentary has something true to be built from.
    """
    piece = board.piece_at(move.from_square)
    after = board.copy()
    after.push(move)

    attacked = after.attacks(move.to_square)
    hits = [f"{piece_name(after.piece_at(sq))} on {chess.square_name(sq)}"
            for sq in attacked
            if after.piece_at(sq) and after.piece_at(sq).color != piece.color]

    back_rank = 0 if piece.color == chess.WHITE else 7
    return {
        "piece": piece_name(piece) if piece else "?",
        "is_capture": board.is_capture(move),
        "gives_check": after.is_check(),
        "develops": (chess.square_rank(move.from_square) == back_rank
                     and piece.piece_type not in (chess.PAWN, chess.KING)),
        "lands_in_centre": move.to_square in CENTRE,
        "controls_centre": sorted(chess.square_name(sq) for sq in attacked & CENTRE),
        "attacks": hits,
    }


def placement(board):
    """Where every piece actually is, in prose, for both sides.

    The coaching packet used to name no squares at all. Asked for a question
    about a position it could not see, the model filled the gap from the only
    concrete example within reach, which was the knight on f3 in its own
    instructions. It duly reported that knight on a board where f3 held a pawn
    and the knight had never left g1. Facts beat wording: give it the board.
    """
    order = [chess.KING, chess.QUEEN, chess.ROOK, chess.BISHOP,
             chess.KNIGHT, chess.PAWN]
    out = {}
    for colour, label in ((chess.WHITE, "white"), (chess.BLACK, "black")):
        parts = []
        for kind in order:
            squares = sorted(chess.square_name(sq)
                             for sq in board.pieces(kind, colour))
            if squares:
                noun = NAMES[kind] + ("s" if len(squares) > 1 else "")
                parts.append(f"{noun} {' '.join(squares)}")
        out[label] = ", ".join(parts)
    return out


def stuck(board, colour):
    """Pieces of `colour` that have no legal move at all.

    The coach suggested developing a bishop on f1 that was walled in by its own
    knight on e2 and pawn on g2. "Develop your kingside bishop" is good advice
    about most positions and impossible advice about that one. A piece that
    cannot move is a fact, so it is computed rather than left to be noticed.
    """
    movable = {move.from_square for move in board.legal_moves} \
        if board.turn == colour else set()
    if board.turn != colour:
        probe = board.copy()
        probe.turn = colour
        movable = {move.from_square for move in probe.legal_moves}
    out = []
    for square, piece in board.piece_map().items():
        if piece.color == colour and square not in movable:
            out.append({"square": chess.square_name(square),
                        "piece": piece_name(piece)})
    return sorted(out, key=lambda p: p["square"])


def checks(board, colour):
    """Every move `colour` has that gives check, in SAN.

    Asked "what's the quickest check I can give them?", the coach answered
    "there are no checks available in this position" while Qxc6+ was on the
    board, winning a pawn with the check. Nothing computed checks, so it
    guessed, and a list of checks is four lines to produce.
    """
    if board.turn != colour:
        return []
    return sorted(board.san(move) for move in board.legal_moves
                  if board.gives_check(move))


def mobility(board, colour):
    """Where each of `colour`'s pieces can actually go, square to squares.

    "Your knight on c3 is now blocked by your pawn on d4" names real pieces on
    real squares and is nonsense: knights are not blocked by anything, and that
    one had five moves. The board check cannot catch it because every square in
    it is correct. The only thing that catches it is knowing where the piece can
    go, so that is computed too.

    Kept as a space-separated string per square because this goes into a packet
    a model reads, and sixteen JSON arrays of coordinates is noise.
    """
    probe = board
    if board.turn != colour:
        probe = board.copy()
        probe.turn = colour
    out = {}
    for square, piece in board.piece_map().items():
        if piece.color != colour:
            continue
        targets = sorted(chess.square_name(m.to_square)
                         for m in probe.legal_moves if m.from_square == square)
        out[chess.square_name(square)] = " ".join(targets)
    return out


def pressure(board, colour):
    """Pieces of `colour` an enemy piece attacks, with attackers and defenders.

    `hanging` only reports what can be taken at a profit, so a piece that is
    merely attacked, or not attacked at all, had no attack or defence facts of
    any kind. Asked to say something about a knight on c3 that nothing attacked,
    the coach produced "attacked by the bishop on f5 and defended only by the
    pawn on d4". Neither piece stood anywhere near it. An empty list here means
    nothing of his is under attack, and that is an answer.
    """
    out = []
    for square, piece in board.piece_map().items():
        if piece.color != colour:
            continue
        attackers = board.attackers(not colour, square)
        if not attackers:
            continue
        def name(squares):
            return [{"square": chess.square_name(sq),
                     "piece": piece_name(board.piece_at(sq))} for sq in sorted(squares)]
        out.append({"square": chess.square_name(square),
                    "piece": piece_name(piece),
                    "attacked_by": name(attackers),
                    "defended_by": name(board.attackers(colour, square))})
    return sorted(out, key=lambda p: p["square"])


def attack_map(board):
    """Every occupied square, and the squares that piece attacks.

    For the app to check a sentence against, not for the model to read: it is
    the only way to refute "the bishop on f5 attacks c3" without re-deriving
    chess in Swift.
    """
    return {chess.square_name(sq): " ".join(sorted(chess.square_name(t)
                                                   for t in board.attacks(sq)))
            for sq in board.piece_map()}


def describe(board):
    """Everything worth saying about the position as it stands."""
    mover = board.turn
    return {
        "side_to_move": "white" if mover == chess.WHITE else "black",
        "in_check": board.is_check(),
        "material": {
            "white": material(board, chess.WHITE),
            "black": material(board, chess.BLACK),
            "diff": material(board, mover) - material(board, not mover),
        },
        "your_hanging": hanging(board, mover),
        "their_hanging": hanging(board, not mover),
        "your_forks": forks(board, mover),
        "your_stuck_pieces": stuck(board, mover),
        "your_checks": checks(board, mover),
        "your_mobility": mobility(board, mover),
        "your_pieces_under_attack": pressure(board, mover),
        "attack_map": attack_map(board),
        # Every legal move, in SAN, for the app to check an answer against. Not
        # for the model: it is the candidate list that should steer what gets
        # suggested, and 30-odd moves in the packet is noise. Without it a legal
        # move the coach named while explaining why it was bad ("if you play Qd8,
        # they take your knight") was binned as an invention.
        "legal_san": sorted(board.san(move) for move in board.legal_moves),
        "pieces": placement(board),
        # The same board twice, on purpose: prose for the model to read, and a
        # flat map for the app to check its answer against. Both are built here
        # from one board, so they cannot drift apart.
        "squares": {chess.square_name(sq): piece_name(p)
                    for sq, p in board.piece_map().items()},
    }


def fork_win(fork):
    """What a fork is actually worth.

    With the king among the targets the check forces a reply and the other
    target falls, so the win is the best of the rest. Without a king they save
    the dearer piece and you take the other, so the win is the second best.
    """
    values = sorted((t.get("value", 0) for t in fork["targets"]), reverse=True)
    if any(t.get("value", 0) == 0 for t in fork["targets"]):   # a king is in there
        return values[0]
    return values[1] if len(values) > 1 else 0


def worth_saying(board, mate_in=None, facts=None):
    """Everything true about this position that earns a sentence, best first.

    Ranked by what it costs or wins, in pawns. This exists because the coach
    used to be *told* which kind of fact to lead with, and the answer given was
    "anything of his that is hanging". That put a loose pawn ahead of a fork
    winning a rook, and produced eight turns in a row opening with the same
    sentence about the same kind of nothing.

    Ranking is arithmetic and belongs here. Choosing a sentence from a ranked
    list is not, and belongs to whoever is speaking.
    """
    facts = facts if facts is not None else describe(board)
    mine, theirs = facts["your_hanging"], facts["their_hanging"]
    found = []

    if mate_in is not None and mate_in > 0:
        found.append({"kind": "mate_for_you", "weight": 100, "moves": mate_in,
                      "text": ("You have mate in one. Find it." if mate_in == 1
                               else f"You have mate in {mate_in}.")})
    if mate_in is not None and mate_in < 0:
        found.append({"kind": "mate_against_you", "weight": 100, "moves": abs(mate_in),
                      "text": f"They have mate in {abs(mate_in)} unless you stop it."})
    if facts["in_check"]:
        found.append({"kind": "in_check", "weight": 50, "text": "You are in check."})

    for fork in facts["your_forks"][:2]:
        hits = " and ".join(f"{t['piece']} on {t['square']}" for t in fork["targets"][:2])
        found.append({"kind": "your_fork", "weight": fork_win(fork),
                      "move": fork.get("san") or f"{fork['from']}-{fork['to']}",
                      "targets": fork["targets"],
                      "text": f"You have a fork: {fork['from']}-{fork['to']} hits the {hits}."})

    for loose in mine[:2]:
        first = loose["attacked_by"][0] if loose["attacked_by"] else None
        by = f" to the {first['piece']} on {first['square']}" if first else ""
        found.append({"kind": "your_hanging", "weight": loose["material_at_risk"],
                      "piece": loose["piece"], "square": loose["square"],
                      "attacked_by": loose["attacked_by"],
                      "defended_by": loose["defended_by"],
                      "costs_pawns": loose["material_at_risk"],
                      "text": f"Your {loose['piece']} on {loose['square']} is hanging{by}."})

    for loose in theirs[:2]:
        found.append({"kind": "their_hanging", "weight": loose["material_at_risk"],
                      "piece": loose["piece"], "square": loose["square"],
                      "wins_pawns": loose["material_at_risk"],
                      "text": f"Their {loose['piece']} on {loose['square']} is hanging. "
                              "You can take it."})

    # Sorted, but stably: mate and check carry weights nothing else reaches, so
    # they stay on top without being special-cased twice.
    found.sort(key=lambda f: -f["weight"])

    diff = facts["material"]["diff"]
    if diff >= 3:
        found.append({"kind": "material", "weight": 0, "ahead_by": diff,
                      "text": f"You are up about {diff} pawns of material."})
    elif diff <= -3:
        found.append({"kind": "material", "weight": 0, "behind_by": abs(diff),
                      "text": f"You are down about {abs(diff)} pawns of material."})
    if not found:
        found.append({"kind": "quiet", "weight": 0,
                      "text": "Nothing hanging on either side, and material is level."})
    return found


def summary(board, mate_in=None):
    """One true sentence about the position, computed instantly.

    `mate_in` is passed in rather than worked out here, because it is the one
    fact in this module that only an engine can supply. Positive means the side
    to move mates; negative means it gets mated. Nothing outranks it: a coach
    that answers "their pawn on f7 is hanging" while mate in two is available
    is not wrong, it is useless.

    The model takes anywhere from 5 to 35 seconds to answer, which is too slow
    to be the only thing that happens after a move. This is what appears
    immediately; Chichi's richer line lands on top of it when it arrives.
    """
    return worth_saying(board, mate_in=mate_in)[0]["text"]


def explain_reply(board, move, reply):
    """What the opponent's best answer to `move` actually does to you.

    `board` is the position before `move`. Returns a fact, not an opinion.
    """
    after = board.copy()
    after.push(move)
    if reply not in after.legal_moves:
        return None

    fact = {"reply": reply.uci(), "reply_san": after.san(reply)}
    victim = after.piece_at(reply.to_square)
    if after.is_capture(reply) and victim is not None:
        taker = after.piece_at(reply.from_square)
        defenders = after.attackers(not victim.color, reply.to_square)
        fact.update({
            "captures": piece_name(victim),
            "on": chess.square_name(reply.to_square),
            "with": piece_name(taker) if taker else None,
            "value": VALUES[victim.piece_type],
            "recapturable": bool(defenders - {reply.from_square}),
        })
    after.push(reply)
    if after.is_checkmate():
        fact["checkmate"] = True
    elif after.is_check():
        fact["check"] = True
    return fact


def headline(board, move, reply_fact):
    """One deterministic sentence for the blunder guard. No model involved: a
    warning that has to be trusted cannot be something that was improvised."""
    moved = board.piece_at(move.from_square)
    moved_name = piece_name(moved) if moved else "piece"

    if reply_fact and reply_fact.get("checkmate"):
        return f"{reply_fact['reply_san']} is checkmate."
    if reply_fact and reply_fact.get("captures"):
        taken, on = reply_fact["captures"], reply_fact["on"]
        free = "" if reply_fact.get("recapturable") else " for free"
        if taken == moved_name:
            return f"That hands over the {moved_name} on {on}{free}: {reply_fact['reply_san']}."
        return f"That loses the {taken} on {on}{free}: {reply_fact['reply_san']}."
    if reply_fact and reply_fact.get("check"):
        return f"{reply_fact['reply_san']} comes with check and you end up worse."
    return f"That {moved_name} move loses ground."

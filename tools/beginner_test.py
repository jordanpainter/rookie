#!/usr/bin/env python3
"""Play as an unsure beginner and check everything the coach says.

    ROOKIE_HOME=~/.rookie-bigtest <venv>/bin/python3 tools/beginner_test.py \
        --games 10 --out <folder>

Unlike `play_and_check.py`, this follows the app's own routing: an options
question, a capture question and an opening question are answered by the
engine exactly as `ChatStore.send()` does, and everything else goes to the
model with the packet `ChatStore.withPosition` builds, then through the same
verifiers, so each answer is recorded as the app would show it (or bin it).

Always run it with a throwaway `ROOKIE_HOME`: it starts its own daemon there
and never touches a real game.

The player is a weak engine that sometimes plays a random move, sometimes
takes the coach's suggestion, and asks the kind of thing someone unsure of
the rules asks: where do I move, what do you mean, what does hanging mean.
"""
import argparse, json, os, pathlib, random, re, subprocess, sys, time, urllib.request

CODE = pathlib.Path(__file__).resolve().parent.parent / "coachd"
sys.path.insert(0, str(CODE))
assert os.environ.get("ROOKIE_HOME"), "set ROOKIE_HOME to a throwaway folder"
import chess, chess.engine
import client, features, paths

PERSONA = (CODE.parent / "Sources/ChessCoach/Resources/persona.md").read_text()
PIECES = "king|queen|rook|bishop|knight|pawn"
MOVE = r"(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?"


# ---------- never cook the laptop ----------
#
# On 2026-09-21 a run of this was left going overnight. The lid was closed and
# the Mac slept, but it kept dark-waking every few seconds on battery, the
# paused run carried on during each wake, and in its case the laptop reached
# "Thermal Emergency Sleep" and cycled its screen on and off. So the run now
# checks, before every model turn and every move, that it is plugged in, the lid
# is open, the Mac is not hot and the time limit has not passed, and stops dead
# otherwise. Stopping loses nothing: rows are written after every game.

DEADLINE = None
# Battery is refused by default. The overheating happened with the lid shut in a
# bag, so an override is fine while somebody is sat in front of it: the lid,
# heat and time checks all still apply, and the lid one is the important one.
ALLOW_BATTERY = False


class Unsafe(Exception):
    pass


def safe_to_continue():
    """Raises Unsafe if the run must stop now."""
    lid = subprocess.run(["ioreg", "-r", "-k", "AppleClamshellState", "-d", "4"],
                         capture_output=True, text=True).stdout
    if '"AppleClamshellState" = Yes' in lid:
        raise Unsafe("the lid is closed")
    if not ALLOW_BATTERY:
        power = subprocess.run(["pmset", "-g", "ps"], capture_output=True, text=True).stdout
        if "AC Power" not in power.splitlines()[0]:
            raise Unsafe("running on battery")
    therm = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True).stdout
    if re.search(r"(warning|performance) level\s+(set to|is)\s+[1-9]", therm, re.I) \
            or re.search(r"CPU_Speed_Limit\s*=\s*(?!100)\d+", therm):
        raise Unsafe("the Mac is under thermal pressure")
    if DEADLINE and time.time() > DEADLINE:
        raise Unsafe("the time limit is up")


def call(op, **kw):
    return client.request({"op": op, **kw})


def raw(op, **kw):
    """What the app interpolates: the reply as JSON text."""
    return json.dumps(call(op, **kw), separators=(",", ":"))


# ---------- the model, as the app talks to it ----------

class Ollama:
    def __init__(self, model, rating):
        self.model, self.history = model, []
        self.system = PERSONA + (f"\n\nThe player is rated about {rating} on chess.com."
                                 if rating else "")

    def ask(self, message):
        safe_to_continue()
        user = {"role": "user", "content": message}
        body = json.dumps({"model": self.model, "stream": False, "think": False,
                           "options": {"num_ctx": 16384},
                           "messages": [{"role": "system", "content": self.system}]
                           + self.history + [user]}).encode()
        req = urllib.request.Request("http://127.0.0.1:11434/api/chat", body,
                                     {"Content-Type": "application/json"})
        start = time.time()
        with urllib.request.urlopen(req, timeout=180) as r:
            text = json.load(r)["message"]["content"].strip()
        self.history = (self.history + [user, {"role": "assistant", "content": text}])[-6:]
        return text, time.time() - start


# ---------- ports of ChatStore / Facts / GameStore ----------

def facts_for_model(facts_json, already_said=None, hiding_solution=False):
    obj = json.loads(facts_json)
    for k in ("squares", "squares_recent", "attack_map", "summary"):
        obj.pop(k, None)
    obj.pop("legal_san", None)
    if hiding_solution:
        for k in ("mate_in", "your_checks", "your_forks", "worth_saying"):
            obj.pop(k, None)
    headline = None
    ranked = obj.get("worth_saying")
    if isinstance(ranked, list):
        def key(e):
            return f"{e.get('kind')}:{e.get('square') or e.get('move') or ''}"
        if already_said:
            ranked = [e for e in ranked if key(e) != already_said]
            kind, _, subject = already_said.partition(":")
            listname = {"your_hanging": "your_hanging", "their_hanging": "their_hanging",
                        "your_fork": "your_forks"}.get(kind)
            if listname and isinstance(obj.get(listname), list):
                obj[listname] = [e for e in obj[listname]
                                 if e.get("square") != subject
                                 and f"{e.get('from', '')}-{e.get('to', '')}" != subject]
        obj["worth_saying"] = ranked
        headline = key(ranked[0]) if ranked else None
    return json.dumps(obj, sort_keys=True, separators=(",", ":")), headline


def swift_tuple(packet, headline):
    """`"\\(Facts.forModel(facts))"` in ChatStore: a tuple, printed Swift's way."""
    esc = packet.replace("\\", "\\\\").replace('"', '\\"')
    h = f'Optional("{headline}")' if headline else "nil"
    return f'(packet: "{esc}", headline: {h})'


def squares_mentioned(text):
    out = []
    for m in re.finditer(r"(?<![a-z0-9])[a-h][1-8](?![0-9])", text):
        if m.group(0).lower() not in out:
            out.append(m.group(0).lower())
    return out[:3]


def piece_mentioned(text):
    lower = text.lower()
    for w in ("knight", "bishop", "rook", "queen", "king", "pawn"):
        if w in lower:
            return w
    for letter, name in (("N", "knight"), ("B", "bishop"), ("R", "rook"), ("Q", "queen"), ("K", "king")):
        if re.search(f"{letter}[a-h][1-8]", text):
            return name
    return None


def is_opening_request(t):
    return any(w in t.lower() for w in ("opening", "gambit", "defense", "defence", "variation",
                                         "repertoire", "book line", "theory"))


def is_options_request(t):
    l = t.lower()
    return len(l) <= 60 and any(p in l for p in (
        "option", "what can i play", "what should i play", "candidate", "suggestion",
        "what would you play", "give me a hint", "any ideas", "what are my moves"))


def app_answer(t):
    """`ChatStore.appAnswer`: the app's own words, no model involved."""
    l = t.lower()
    if len(l) > 90:
        return None
    def has(words):
        return any(w in l for w in words)
    if has(["what does chichi", "why are you called", "what's your name", "whats your name"]) \
            or ("chichi" in l and has(["mean", "name", "called"])):
        return "name"
    if has(["who are you", "are you a robot", "are you a bot", "are you human", "are you an ai",
            "do you actually know chess", "are you guessing"]):
        return "what I am"
    if has(["play for me", "play it for me", "do it for me", "can you play"]):
        return "I don't play your moves"
    if "takeback" in l or "undo" in l or re.search(r"\btak(e|ing)\b[^.?]{0,20}\bback\b", l):
        return "the takeback button"
    if has(["easier", "harder", "too hard", "difficulty", "weaker opponent", "stronger opponent"]):
        return "the level picker"
    if has(["board colour", "board color", "change the board", "piece set", "pieces look",
            "different pieces"]):
        return "the settings gear"
    if has(["old games", "past games", "my games", "my history", "my rating"]):
        return "the Review tab"
    if has(["getting any better", "am i improving", "am i getting better", "how am i doing"]):
        return "progress lives in Review"
    return None


def is_threat_question(t):
    l = t.lower()
    if len(l) > 90 or not re.search(r"\b(he|they|him|them|his|their|theirs|opponent)\b", l):
        return False
    return (re.search(r"\b(threatening|threat|threats|plan|planning|up)\b", l) is not None
            or "going to do" in l or "want to do" in l or "doing" in l)


def is_follow_up(t):
    l = t.lower()
    if len(l) > 60 or "should" in l or "where" in l:
        return False
    return any(p in l for p in ("what do you mean", "what does that mean", "what did you mean",
                                "i dont get it", "i don't get it", "dont get it", "explain",
                                "simpler", "which piece", "which one", "how come",
                                "so what do i do", "and then what", "huh")) or l.rstrip("?") == "why"


def is_capture_question(t):
    l = t.lower()
    return (len(l) <= 90
            and re.search(r"\b(take|takes|taking|capture|captures|capturing|recapture|recaptures)\b", l)
            and re.search(r"\b(he|they|him|them|opponent|his|their)\b", l)) is not None


def all_moves(text):
    return set(re.findall(r"\b" + MOVE, text))


def san_tokens(text):
    return set(re.findall(r"\b(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?", text))


def quoted_line_moves(text):
    out = set()
    for m in re.finditer(rf"\d+\.(?:\.\.)?\s*({MOVE})[+#]?(?:\s+({MOVE}))?", text):
        out.update(g for g in m.groups() if g)
    return out


def denied(move, answer):
    """A move named only to say it is not on is not an invented move."""
    for sentence in re.split(r"[.!?]", answer):
        if move in sentence and any(w in sentence.lower() for w in (
                "not possible", "isn't possible", "is not legal", "cannot", "can't",
                "there is no", "there's no", "no longer", "not able")):
            return True
    return False


def invented_move(answer, allowed):
    if not allowed:
        return None
    bare = {a.replace("x", "") for a in allowed}
    for t in sorted(san_tokens(answer) | quoted_line_moves(answer)):
        if t not in allowed and t.replace("x", "") not in bare and not denied(t, answer):
            return t
    return None


def false_relation(line, attack_map):
    if not attack_map:
        return None
    gap = r"(?:(?!\b(?:on|at)\s+[a-h][1-8])(?!\b(?:while|which|instead|whereas)\b)[^.!?,])"
    passive = (r"(?:on|at)\s+([a-h][1-8])" + gap + r"{0,80}?\b(?:attacked|defended|protected|covered)\s+"
               rf"(?:only\s+)?by\s+(?:the\s+|their\s+|your\s+)*(?:{PIECES})\s+(?:on|at)\s+([a-h][1-8])")
    active = (r"(?:on|at)\s+([a-h][1-8])" + gap + r"{0,60}?\b(?:attacks|attacking|defends|defending|hits|covers)\s+"
              rf"(?:the\s+|their\s+|your\s+)*(?:{PIECES})\s+(?:on|at)\s+([a-h][1-8])")
    for pattern, subject_first in ((passive, True), (active, False)):
        for m in re.finditer(pattern, line, re.I):
            a, b = m.group(1).lower(), m.group(2).lower()
            subject, actor = (a, b) if subject_first else (b, a)
            reaches = attack_map.get(actor)
            if reaches is None:
                continue
            if subject not in reaches.split(" "):
                return f"{actor} as attacking or defending {subject}, which it does not"
    return None


def false_immobility(line, mobility):
    if not mobility:
        return None
    pat = (rf"\b({PIECES})s?\s+(?:on|at)\s+([a-h][1-8])[^.!?]{{0,60}}?\b(blocked|trapped|stuck|boxed in|immobile"
           r"|cannot move|can't move|has no moves|no legal moves|nowhere to go)")
    for m in re.finditer(pat, line, re.I):
        piece, sq = m.group(1).lower(), m.group(2).lower()
        targets = mobility.get(sq)
        if not targets:
            continue
        n = len(targets.split(" "))
        if n < 2:
            continue
        return f"a {piece} on {sq} being stuck when it has {n} moves"
    return None


def false_check_offer(line, checks):
    offered = re.search(r"\b(?:you\s+have|you've\s+got|there\s+is|there's)\s+(?:an?\s+)?"
                        r"(?:immediate\s+|free\s+|strong\s+)?check\b", line, re.I)
    if not checks:
        return "a check that is not in the position" if offered else None
    letters = {"king": "K", "queen": "Q", "rook": "R", "bishop": "B", "knight": "N"}
    for m in re.finditer(r"check\s+(?:with|from|by)\s+(?:the\s+|your\s+)*"
                         r"(king|queen|rook|bishop|knight|pawn)", line, re.I):
        kind = m.group(1).lower()
        letter = letters.get(kind)
        ok = any(c[0] == letter if letter else not c[0].isupper() for c in checks)
        if not ok:
            return f"a check given by a {kind}, which has none here"
    return None


def false_claim(line, squares, recent=None, mobility=None, attack_map=None, checks=None):
    recent = recent or {}
    w = (false_immobility(line, mobility or {}) or false_relation(line, attack_map or {})
         or false_check_offer(line, checks if checks is not None else ["x"]))
    if w:
        return w
    if not squares:
        return None
    for m in re.finditer(rf"\b({PIECES})s?\s+(?:on|at)\s+([a-h][1-8])\b", line, re.I):
        c, sq = m.group(1).lower(), m.group(2).lower()
        before = line[max(0, m.start() - 18):m.start()].lower()
        if any(w in before for w in ("no ", "not ", "n't ", "nothing ", "isn't", "no longer")):
            continue
        if squares.get(sq) != c and recent.get(sq) != c:
            return f"a {c} on {sq}"
    return None


def mentions_only(moves, line):
    bare = {m.rstrip("+#") for m in moves}
    for m in re.finditer(r"\b(?:[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x?[a-h][1-8]|O-O(?:-O)?)(?:=[QRBN])?[+#]?", line):
        if m.group(0).rstrip("+#") not in bare:
            return False
    return True


# ---------- independent checks the app does not make ----------

def audit(text, board, candidates):
    """Things worth a human look, beyond what the app bins."""
    notes = []
    squares = {chess.square_name(s): features.piece_name(p) for s, p in board.piece_map().items()}
    mine = {board.san(m).rstrip("+#") for m in board.legal_moves}
    theirs = set()
    if not board.is_check():
        probe = board.copy(); probe.push(chess.Move.null())
        theirs = {probe.san(m).rstrip("+#") for m in probe.legal_moves}
    prose = re.sub(r"(?:\d+\.(?:\.\.)?\s*\S+(?:\s+\S+)?\s*){2,}", " ", text)
    lines = " ".join(c.get("line", "") for c in candidates)
    for tok in re.findall(r"\b" + MOVE, prose):
        if re.fullmatch(r"[a-h][1-8]", tok):
            continue
        if tok.rstrip("+#") not in mine | theirs and tok not in lines:
            notes.append(f"names {tok}: not legal for either side, not in any engine line")
    if "—" in text:
        notes.append("em dash")
    if "!" in text and "mate" not in text.lower():
        notes.append("exclamation mark")
    if re.search(r"^\s*[-*•]\s", text, re.M):
        notes.append("bullet list")
    if re.search(r"centipawn|\bcp\b|engine", text, re.I):
        notes.append("mentions engine/centipawns")
    sentences = len(re.findall(r"[.!?](?:\s|$)", text))
    if sentences > 4:
        notes.append(f"{sentences} sentences")
    jargon = [w for w in ("tempo", "zwischenzug", "prophylaxis", "outpost", "fianchetto", "pin",
                          "skewer", "fork", "hanging", "develop", "initiative", "open file",
                          "back rank", "tactic", "discovered", "x-ray", "en passant")
              if re.search(rf"\b{w}", text, re.I)]
    return notes, jargon


def app_reaction(prev, uci, ply):
    """`GameStore.reaction()`: the word the app picks, now sent in the packet."""
    kind = prev.get("move_kind") or {}
    if kind.get("mate"):
        return "Hell yeah!"
    sev = prev.get("severity")
    if sev is None:
        if prev.get("best_uci") != uci:
            return None
        if kind.get("fork"):
            return "Smart."
        if kind.get("capture"):
            return "Sweet."
        return "Nice." if ply % 2 == 0 else "Clean."
    if sev == "inaccuracy":
        return "Hmm."
    if sev == "mistake":
        return "Whoops." if ply % 2 == 0 else "Shoot."
    if prev.get("loss_cp", 0) >= 400:
        return "Yikes."
    return "Ouch." if ply % 2 == 0 else "Damn."


def plies(board):
    return (board.fullmove_number - 1) * 2 + (0 if board.turn == chess.WHITE else 1)


# ---------- the beginner ----------

WHERE = ["where should I move?", "what do I do here", "im lost, what should i do",
         "which piece should I move?", "is there anything good for me here?",
         "what's the best thing to do", "help, where do i go"]
FOLLOW = ["what do you mean?", "what does that mean?", "why?", "sorry i dont get it",
          "can you explain that simpler?", "which piece?", "ok so what do i do then?"]
DEFINE = {"hanging": "what does hanging mean?", "fork": "whats a fork?", "pin": "what's a pin?",
          "develop": "what does develop mean?", "tempo": "what's a tempo?",
          "check": "how do i get out of check?", "castl": "what is castling?",
          "centre": "why does the centre matter?", "center": "why does the center matter?",
          "trade": "is trading good for me?", "defend": "how do I defend it?"}
SOCRATIC_GUESS = ["the knight?", "idk, does he take it?", "um, nothing?", "i think my queen",
                  "no idea tbh", "he can take my pawn?"]
MISC = ["is my queen safe?", "what is he threatening?", "am I winning?", "any ideas?",
        "can he take my knight?", "what about the bishop?", "what's he going to do next?",
        "what opening is this?", "should I castle?", "what are my options"]
# Jordan asked for someone who "asks what chichi means". Nothing in the packet
# answers any of these, which is the point: they are about the coach, the rules,
# the app, or how the player feels, and a position is no help.
IDENTITY = ["what does chichi mean?", "why are you called chichi?", "are you a robot?",
            "who are you exactly?", "do you actually know chess or are you guessing?"]
RULES = ["can a pawn move backwards?", "how does castling work?", "what is en passant?",
         "can my horse jump over pieces?", "how many points is a bishop worth?",
         "what happens if my pawn gets to the end?"]
APP = ["how do I take that move back?", "where do I see my old games?",
       "can I change the board colours?", "how do I make this easier?",
       "can you play for me?"]
FEELINGS = ["im rubbish at this", "i always lose, whats the point", "should i just resign?",
            "am i getting any better?", "this is too hard"]
INCHECK = ["im in check what do i do", "can i just ignore the check?", "is my king ok?"]
TYPOS = ["wher shud i mov", "whats teh best mvoe", "wat do i do lol", "shud i tak the nite"]


def pick_question(rng, last_coach, socratic_pending, board, last_question=None):
    # In check, a beginner asks about the check and nothing else.
    if board.is_check() and rng.random() < 0.7:
        return rng.choice(INCHECK), "in-check"
    # The same question twice running: does the answer change, or is it the same
    # sentence read back?
    if last_question and rng.random() < 0.12:
        return last_question, "repeat"
    r = rng.random()
    if r < 0.08:
        return rng.choice(IDENTITY), "identity"
    if r < 0.16:
        return rng.choice(RULES), "rules"
    if r < 0.22:
        return rng.choice(APP), "app"
    if r < 0.28:
        return rng.choice(FEELINGS), "feelings"
    if r < 0.34:
        return rng.choice(TYPOS), "typos"
    if last_coach and rng.random() < 0.45:
        lower = last_coach.lower()
        hits = [q for w, q in DEFINE.items() if w in lower]
        if hits and rng.random() < 0.5:
            return rng.choice(hits), "define"
        if socratic_pending and rng.random() < 0.5:
            return rng.choice(SOCRATIC_GUESS), "answer-socratic"
        return rng.choice(FOLLOW), "follow-up"
    r = rng.random()
    if r < 0.5:
        return rng.choice(WHERE), "where"
    if r < 0.7:
        # "should I play X?" about a plausible beginner move, not always a good one.
        mv = rng.choice(list(board.legal_moves))
        return f"should I play {board.san(mv)}?", "named-move"
    return rng.choice(MISC), "misc"


def run_game(n, args, rng, model, log, rows, use_tuple):
    colour = ["white", "black", "random"][n % 3]
    level = rng.choice([1, 1, 2, 2, 3])
    mode = "socratic" if n % 2 else "notes"
    # Every fourth game plays with the guard off, which used to leave every move
    # unrated and the coach silent.
    guard_on = n % 4 != 0
    call("shutdown"); time.sleep(0.5)
    state = call("new_game", level=level, colour=colour)
    me = chess.WHITE if state.get("my_colour", colour) == "white" else chess.BLACK
    board = chess.Board(state["fen"])
    me = board.turn
    log(f"\n===== GAME {n}: {'white' if me else 'black'}, level {level}, "
        f"coaching={mode}, guard={'on' if guard_on else 'off'}")
    player = chess.engine.SimpleEngine.popen_uci(paths.stockfish())
    player.configure({"Skill Level": 0})
    last_headline, last_coach, socratic_pending, advised = None, None, False, None
    last_question = None

    def record(kind, q, packet, text, secs, shown, verdict, candidates, extra=None):
        notes, jargon = audit(text, board, candidates) if text else ([], [])
        rows.append({"game": n, "ply": plies(board), "fen": board.fen(),
                     "kind": kind, "question": q, "answer": text, "shown": shown,
                     "verdict": verdict, "secs": round(secs, 1), "audit": notes,
                     "jargon": jargon, "packet_chars": len(packet or ""),
                     "candidates": [c["san"] for c in candidates], **(extra or {})})
        log(f"   [{kind}] {('Q: ' + q) if q else ''}")
        log(f"      shown: {shown}")
        if verdict != "ok":
            log(f"      ({verdict}; model said: {text})")
        if notes:
            log(f"      audit: {notes}")

    for turn in range(args.moves):
        safe_to_continue()
        if board.is_game_over():
            break
        # Ask something before moving, some of the time.
        if rng.random() < args.ask_rate:
            q, qkind = pick_question(rng, last_coach, socratic_pending, board, last_question)
            last_question = q
            socratic_pending = False
            cands = call("candidates", count=3).get("candidates", [])
            if app_answer(q):
                record(qkind + "/app-answer", q, "", "", 0,
                       f"(the app's own answer about {app_answer(q)})", "computed", cands)
                last_coach = None
            elif is_options_request(q):
                reply = call("candidates", count=3)
                moves = [c["san"] for c in reply["candidates"]]
                lst = ", ".join(moves[:-1]) + " or " + moves[-1] if len(moves) > 1 else moves[0]
                spine = f"{lst}. {reply['note']}"
                prompt = (f"[move options, mode=colour]\nThe player asked what their options were, and has "
                          f"already been shown this, verbatim:\n\"{spine}\"\nWhat each move does, computed: "
                          f"{json.dumps(reply)}\n\nAdd ONE short sentence about what these moves do or what "
                          f"they are for,\nusing only those facts. Do not repeat the move names. Do not say which is\n"
                          f"best; that is already said. Do not mention any move outside\n{', '.join(moves)}.")
                text, secs = model.ask(prompt)
                ok = mentions_only(moves, text) and text and len(text) <= 160
                shown = spine + (" " + text if ok else "")
                record(qkind + "/options", q, prompt, text, secs, shown,
                       "ok" if ok else "dropped sentence", cands)
                last_coach, advised = shown, reply["candidates"][0]["san"]
            elif is_threat_question(q):
                th = call("threats")
                best = th.get("their_best") or {}
                if th.get("in_check"):
                    shown = ("You're in check from "
                             + " and ".join(f"the {c['piece']} on {c['square']}" for c in th.get("checked_by", []))
                             + ", so that comes first: move the king, block it, or take the piece giving it.")
                elif best.get("checkmate"):
                    shown = f"{best['san']} is mate. That is the threat, and it has to be stopped now."
                elif best.get("captures"):
                    back = best.get("you_can_take_back_with") or []
                    shown = (f"They want {best['san']}, taking your {best['captures']} on {best['on']}."
                             + (f" You could take back with {' or '.join(back)}." if back
                                else " Nothing of yours takes back on that square."))
                elif best.get("gives_check"):
                    shown = f"Their best is {best['san']}, which is check."
                elif best:
                    shown = f"Nothing sharp: their best is {best['san']}."
                    if best.get("then_attacks"):
                        shown += " After it, it hits your " + " and your ".join(best["then_attacks"]) + "."
                else:
                    shown = "(no threat facts)"
                loose = [p for p in (th.get("your_pieces_under_attack") or []) if not p["defended_by"]]
                if loose:
                    shown += f" Your {loose[0]['piece']} on {loose[0]['square']} is also sitting there undefended."
                record(qkind + "/threats", q, "", "", 0, shown, "computed", cands)
                last_coach = shown
            elif is_capture_question(q):
                reply = call("candidates", count=3)
                best = reply["candidates"][0]
                takers = best.get("they_can_capture_it_with") or []
                shown = (f"No. After {best['san']} there is no legal capture of that square." if not takers
                         else f"Yes. After {best['san']} they can take with {' or '.join(takers)}. "
                              f"{best['san']} is still the engine's first choice, so it means giving that up on purpose.")
                record(qkind + "/capture", q, "", "", 0, shown, "computed", cands)
                last_coach = shown
            elif is_opening_request(q):
                adv = call("opening_advice")
                shown = f"(computed opening advice) {json.dumps(adv)[:300]}"
                record(qkind + "/opening", q, "", "", 0, shown, "computed", cands)
                last_coach = shown
            else:
                facts = raw("describe")
                fobj = json.loads(facts)
                packet, headline = facts_for_model(facts)
                shown_facts = swift_tuple(packet, headline) if use_tuple else packet
                cand_raw = json.dumps({"candidates": cands}) if cands else raw("candidates", count=3)
                cand_raw = raw("candidates", count=3)
                cands = json.loads(cand_raw).get("candidates", [])
                named = ""
                sq = squares_mentioned(q)
                if sq:
                    named = ("\n\nHE IS ASKING ABOUT THESE MOVES: " + raw("move_facts", squares=sq) +
                             "\nAnswer about the one he means before anything else. Asked \"should I play\n"
                             "b3?\" the reply was \"Qb3 is the strongest move\", which is an answer to a\n"
                             "different question. More than one piece can usually reach a square and\n"
                             "they do different things, so pick the entry that matches what he said. If\n"
                             "the square is under no_legal_move_to, say plainly that nothing can go there.")
                elif piece_mentioned(q):
                    whose = "mine" if ("my " in q.lower() or "mine" in q.lower()) else "theirs"
                    named = ("\n\nTHE PIECE HE IS ASKING ABOUT: " +
                             raw("piece_focus", piece=piece_mentioned(q), whose=whose) +
                             "\nAnswer about this piece. Say what it is doing (what it attacks), then the\n"
                             "best answer from `answers` and why, and if `best_move_overall` is a\n"
                             "different move, say that one is stronger still. Every `line` is the\n"
                             "engine's own continuation: quote it to show the plan, never extend it.")
                played = raw("state")
                fact_moves = " ".join(fobj.get("your_checks", [])
                                     + [f.get("san","") for f in fobj.get("your_forks", [])]
                                     + fobj.get("legal_san", []))
                allowed = all_moves(cand_raw + named + played + q + " " + fact_moves)
                asking = ""
                if is_follow_up(q) and last_coach:
                    asking = (f"\n\nThey are asking about your own last line, which was: \"{last_coach}\"\n"
                              "Answer that. Explain what you meant in plainer words; do not change the subject\n"
                              "to a different piece or start listing moves.")
                prompt = (f"{q}{asking}\n\n[live position, use only if the question is about the game]\n"
                          f"Facts: {shown_facts}\nEngine's best moves here, each with the line it "
                          f"expects to follow: {cand_raw}{named}")
                text, secs = model.ask(prompt)
                wrong = false_claim(text, fobj.get("squares", {}), fobj.get("squares_recent", {}),
                                    fobj.get("your_mobility", {}), fobj.get("attack_map", {}),
                                    fobj.get("your_checks", []))
                inv = None if wrong else invented_move(text, allowed)
                if wrong:
                    shown, verdict = "[BINNED: not on the board]", f"binned: {wrong}"
                elif inv:
                    shown, verdict = "[BINNED: invented move]", f"binned: invented {inv}"
                else:
                    shown, verdict = text, "ok"
                record(qkind, q, prompt, text, secs, shown, verdict, cands)
                last_coach = shown if verdict == "ok" else None
                # A beginner who asked where to go takes the first move they are told.
                advised = None
                if qkind == "where" and verdict == "ok":
                    legal = {board.san(m).rstrip("+#"): m for m in board.legal_moves}
                    for tok in re.findall(r"\b" + MOVE, text):
                        if tok.rstrip("+#") in legal:
                            advised = tok.rstrip("+#"); break
                    rows[-1]["advised"] = advised
                    rows[-1]["advised_rank"] = ([c["san"].rstrip("+#") for c in cands].index(advised)
                                                if advised in [c["san"].rstrip("+#") for c in cands] else None)

        # Choose a move.
        legal = {board.san(m).rstrip("+#"): m for m in board.legal_moves}
        if advised and advised.rstrip("+#") in legal and rng.random() < 0.8:
            mv = legal[advised.rstrip("+#")]
        elif rng.random() < 0.2:
            mv = rng.choice(list(board.legal_moves))
        else:
            mv = player.play(board, chess.engine.Limit(depth=rng.choice([1, 2, 3]))).move
        advised = None
        prev = call("preview", uci=mv.uci())
        if prev.get("warn") and guard_on:
            log(f"   guard: {prev.get('headline')}")
            rows.append({"game": n, "ply": plies(board), "kind": "guard",
                         "fen": board.fen(), "move": board.san(mv), "headline": prev.get("headline"),
                         "loss": prev.get("loss_cp")})
            if rng.random() < 0.5:
                # "Good spot": pick again, with the engine this time.
                mv = player.play(board, chess.engine.Limit(depth=4)).move
                prev = call("preview", uci=mv.uci())
        sev = prev.get("severity")
        verdict = (f"{sev}, it costs about {prev['loss_cp']} centipawns" if sev else
                   "the strongest move in the position" if prev.get("best_uci") == mv.uci()
                   else "a sound move, it gives nothing away")
        mate_reaction = (prev.get("move_kind") or {}).get("mate")
        reaction = app_reaction(prev, mv.uci(), plies(board))
        san = board.san(mv)
        state = call("move", uci=mv.uci())
        if "error" in state:
            log(f"   move rejected: {state['error']}"); break
        board = chess.Board(state["fen"])
        reply = state.get("engine_played")
        log(f"  {san} ({verdict.split(',')[0]}), they: {reply}")
        if board.is_game_over():
            break

        worth = reaction == "Hell yeah!" or verdict.startswith(("the strongest", "mistake", "blunder"))
        if mode == "notes" and not worth:
            continue
        facts = raw("describe")
        fobj = json.loads(facts)
        if fobj.get("in_check"):
            reaction = None
        packet, last_headline = facts_for_model(facts, last_headline)
        prompt = (f"[in-play coaching, mode={mode}]\nPlayed: {san}\n"
                  f"Reaction to open with: {reaction or 'none, do not react at all'}\n"
                  f"Engine's verdict on it: {verdict}\n"
                  f"Opponent replied: {reply or 'nothing yet'}\nPosition facts: {packet}")
        text, secs = model.ask(prompt)
        retried = False
        if mode == "socratic" and "?" not in text:
            again = (prompt + "\n\nYour reply was not a question. Reply again with one question "
                     "about this position, ending in a question mark, and nothing else.")
            retry, extra = model.ask(again)
            secs += extra
            retried = True
            if "?" in retry:
                text = retry
        wrong = false_claim(text, fobj.get("squares", {}), fobj.get("squares_recent", {}),
                            fobj.get("your_mobility", {}), fobj.get("attack_map", {}),
                            fobj.get("your_checks", []))
        if text == last_coach:
            shown, v = "[removed: same as last line]", "duplicate"
        elif wrong:
            shown, v = f"{fobj.get('summary', '')}\n\n⚠️ Dropped a line that described {wrong}.", f"dropped: {wrong}"
        else:
            shown, v = text, "ok"
        record(f"coach-{mode}", None, prompt, text, secs, shown, v, [],
               {"played": san, "move_verdict": verdict.split(",")[0],
                "headline": last_headline, "reaction": reaction, "retried": retried})
        last_coach = shown
        socratic_pending = mode == "socratic"
    player.quit()
    log(f"  result: {board.result(claim_draw=True)} after {plies(board)} plies")


def puzzle_line(m):
    """`ChatStore.puzzleLine`: one move, described without saying if it solves it."""
    does = []
    if m.get("gives_check"):
        does.append("is check")
    if m.get("is_capture"):
        does.append("takes material")
    hit = [a for a in m.get("attacks", []) if not (a.startswith("king") and m.get("gives_check"))]
    if hit:
        does.append("hits the " + " and the ".join(hit))
    if not does and m.get("controls_centre"):
        does.append("covers " + " and ".join(m["controls_centre"]))
    line = f"{m['san']} {' and '.join(does) if does else 'is legal, and does nothing in particular'}."
    r = m.get("their_best_reply")
    if (m.get("loss_cp") or 0) >= 100:
        if r and r.get("captures") and r.get("on"):
            line += f" But they answer {r['reply_san']}, taking the {r['captures']} on {r['on']}."
        elif r:
            line += f" But they answer {r['reply_san']} and you are worse."
        else:
            line += " It gives away more than it wins."
        line += " Look for something else."
    elif r:
        line += f" They answer {r['reply_san']}. Work out what you have after that."
    return line


PUZZLE_ASK = ["whats going on here?", "where should I move?", "i dont see it, whats the idea?",
              "is my king safe here?", "what am i meant to be looking for?"]


def run_puzzles(count, args, rng, model, log, rows, use_tuple):
    """Chat while a drill puzzle is on screen.

    The panel answers against the puzzle's board, not the game's, and must
    describe a move without saying whether it solves the puzzle. Giving the
    answer away is the one thing a drill cannot survive.
    """
    log(f"\n===== PUZZLES: {count}")
    for i in range(count):
        puzzle = call("puzzle_next", source=rng.choice(["own", "lichess"]))
        if "error" in puzzle:
            log(f"  no puzzle: {puzzle['error']}"); return
        fen = puzzle["position_fen"]
        board = chess.Board(fen)
        # What the engine thinks, so "did the answer leak it" is checkable.
        best = call("candidates", count=1, fen=fen).get("candidates") or []
        solution = best[0]["san"] if best else None
        for qi in range(2):
            if qi == 0:
                mv = rng.choice(list(board.legal_moves))
                q = f"should I play {board.san(mv)}?"
                reply = call("move_facts", fen=fen, squares=squares_mentioned(q), judge=True)
                named = piece_mentioned(q)
                wanted = [m for m in reply.get("moves", []) if m.get("piece") == named]
                moves = wanted or reply.get("moves", [])
                shown = (" ".join(puzzle_line(m) for m in moves) if moves
                         else "Nothing can go to " + " or ".join(reply.get("no_legal_move_to", [])) + " here.")
                kind, text, secs, verdict = "puzzle/named-move", "", 0, "computed"
            else:
                q = rng.choice(PUZZLE_ASK)
                facts = raw("describe", fen=fen)
                fobj = json.loads(facts)
                packet, headline = facts_for_model(facts, hiding_solution=True)
                prompt = (f"{q}\n\n[live position, use only if the question is about the game]\n"
                          f"Facts: {packet}\n"
                          "[They are solving a puzzle. Describe what is on the board and what to look at.\n"
                          "Never name a move: not the one that solves it, not any other. The facts that\n"
                          "would give it away have been left out, so do not guess at them either.]")
                text, secs = model.ask(prompt)
                wrong = false_claim(text, fobj.get("squares", {}), fobj.get("squares_recent", {}),
                                    fobj.get("your_mobility", {}), fobj.get("attack_map", {}),
                                    fobj.get("your_checks", []))
                shown = "[BINNED]" if wrong else text
                kind, verdict = "puzzle/open", (f"binned: {wrong}" if wrong else "ok")
            leaked = bool(solution and text and re.search(rf"\b{re.escape(solution.rstrip('+#'))}\b", text))
            rows.append({"game": f"puzzle{i}", "ply": plies(board), "fen": fen, "kind": kind,
                         "question": q, "answer": text, "shown": shown, "verdict": verdict,
                         "secs": round(secs, 1), "audit": audit(text, board, [])[0] if text else [],
                         "jargon": audit(text, board, [])[1] if text else [],
                         "candidates": [c["san"] for c in best], "solution": solution,
                         "leaked_solution": leaked})
            log(f"   [{kind}] Q: {q}")
            log(f"      shown: {shown}")
            if leaked:
                log(f"      !! names the solution ({solution})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=10)
    ap.add_argument("--moves", type=int, default=30)
    ap.add_argument("--ask-rate", type=float, default=0.45)
    ap.add_argument("--model", default="gemma4:12b")
    ap.add_argument("--tuple-packet", action="store_true",
                    help="reproduce the old bug: facts sent as a printed Swift tuple")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--allow-battery", action="store_true",
                    help="run on battery too; only with somebody at the keyboard")
    ap.add_argument("--max-minutes", type=float, default=90,
                    help="hard stop, however far it has got (default 90)")
    ap.add_argument("--puzzles", type=int, default=0, help="drill positions to chat over, after the games")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = pathlib.Path(args.out); out.mkdir(parents=True, exist_ok=True)
    global DEADLINE, ALLOW_BATTERY
    DEADLINE = time.time() + args.max_minutes * 60
    ALLOW_BATTERY = args.allow_battery
    try:
        safe_to_continue()
    except Unsafe as why:
        sys.exit(f"not starting: {why}")
    rng = random.Random(args.seed)
    rating = json.loads(pathlib.Path(paths.data("config.json")).read_text()).get("ratings", {}).get("rapid")
    rows = []
    with open(out / "log.txt", "w", buffering=1) as fh:
        def log(m): fh.write(m + "\n")
        for n in range(1, args.games + 1):
            model = Ollama(args.model, rating)
            try:
                run_game(n, args, rng, model, log, rows, args.tuple_packet)
            except Unsafe as why:
                log(f"\n===== STOPPED: {why}")
                (out / "rows.json").write_text(json.dumps(rows, indent=1))
                call("shutdown")
                sys.exit(f"stopped: {why}")
            except Exception as exc:
                log(f"  GAME FAILED: {exc!r}")
            (out / "rows.json").write_text(json.dumps(rows, indent=1))
        if args.puzzles:
            model = Ollama(args.model, rating)
            try:
                run_puzzles(args.puzzles, args, rng, model, log, rows, not args.tuple_packet)
            except Unsafe as why:
                log(f"\n===== STOPPED: {why}")
            except Exception as exc:
                log(f"  PUZZLES FAILED: {exc!r}")
            (out / "rows.json").write_text(json.dumps(rows, indent=1))
    call("shutdown")
    print(f"done: {len(rows)} rows")


if __name__ == "__main__":
    main()

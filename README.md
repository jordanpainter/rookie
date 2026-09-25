<p align="center">
  <img src="docs/media/icon.png" width="160" alt="Rookie: a hand-drawn rook holding a cheat sheet, on a green chessboard">
</p>

<h1 align="center">Rookie</h1>

<p align="center">
  <b>A chess app that explains what just happened</b>
</p>

For people who are still learning. It plays, it warns you before you hang a
piece, it reviews your real games, and it drills the tactics you actually get
wrong.

Everything runs on your own Mac. No account, no server, no subscription.

## Meet Chichi

<img src="art/chichi/chichi-jump-board.gif" width="128" align="right" alt="Chichi, a pixel-art rook holding a cheat sheet, jumping on a chessboard">

Chichi is the coach. He is the club player who wanders over, looks at the board
for three seconds, says the one thing that matters, and goes back to his own
game. Short, plain, specific: "that knight's attacked twice and defended once, so
it comes off next move unless it moves or gets help."

The name does not mean much. It sounds like "cheat sheet", which is what he is
holding.

**He does not read the board himself, and that is the point.** Every fact he is
given has been worked out by Stockfish first: what is hanging, every check you
have, where every piece can go, what attacks what, whether there is mate. His job
is turning that into a sentence. Then the sentence is checked back against the
board before you ever see it, and anything that names a piece on the wrong
square, calls a piece stuck when it has moves, invents an attack, offers a check
that does not exist, or names a move the engine never suggested is binned rather
than shown. Some questions skip him entirely because they have exactly one right
answer: what your options are, whether they can take that piece, what they are
threatening, and which opening to work on.

## What you can do with it

**Play.** A game against Stockfish at eight levels, from "actually beatable" to
"stop it". Play either colour. Take moves back.

- **The blunder guard** stops a move that drops material and tells you what it
  would cost, before it happens. Play it anyway if you meant it.
- **The coaching dial** is Mute, Notes or Socratic. Notes remarks on moves worth
  remarking on. Socratic holds the board and asks you a question about the move
  you just played.
- **Ask anything, any time.** Where should I move, what is he threatening, should
  I play Bf4, why was that bad, what does hanging mean, how does castling work.

**Explore.** Over 3,300 named openings, searchable. Step through a line move by
move, hide the moves and drill it from memory, or tell the Play tab to steer a
real game towards it and it will tell you who left the book first.

**Review.** Link a chess.com account and it imports every game you have played,
analyses them, and shows what they cost you: which openings keep going wrong,
which mistakes repeat, how your rating actually moved.

**Drill.** Three sets of puzzles: tactics built from **your own blunders** in
those games, 30,000 from the Lichess set filtered to your rating, and tablebase
endgames worth knowing. Chichi will describe what a move does without telling you
whether it solves it.

**Settings** (the gear, top right): your chess.com account, which side you play,
board themes and piece sets, including a hand-drawn one.

## Installing it

You need an Apple Silicon Mac on macOS 14 or later, and about 10 GB free.

1. Download `Rookie.zip` from [Releases](../../releases), unzip it, and drag
   Rookie to your Applications folder.
2. **The first open needs a right-click.** Rookie is not signed with an Apple
   developer certificate, so double-clicking it gets you "Apple could not verify
   it". Right-click the app, choose **Open**, then **Open** again in the dialog.
   Only the first launch needs this. (If you double-clicked first, it is in
   System Settings → Privacy & Security → **Open Anyway**.)
3. Install [Ollama](https://ollama.com/download). It runs the coach's model on
   your machine and it is free.
4. Open Rookie. It will offer to fetch what it still needs: the model (about
   8 GB, once), the opening list, and the puzzles. You can skip all of it and
   just play; the checklist comes back next launch.

Rookie is built and tested against `gemma4:12b`. If that is too much model for
your Mac, Settings has a picker listing whatever you already have in Ollama:
a smaller one gives you a blunter coach, and the chess itself is worked out by
the engine either way.

That is the whole install. Rookie carries its own Python and its own copy of
Stockfish, so there is nothing else to set up.

## Privacy

Nothing you play is uploaded anywhere. The coach runs locally through Ollama.
The only things that leave your Mac are the downloads above and, if you ask for
them, public data you already have: your own chess.com games, and the Lichess
opening explorer's move statistics.

## Building it yourself

```sh
./setup.sh        # Stockfish, Python, Ollama, the model, openings, puzzles
swift build && .build/debug/ChessCoach
./build-app.sh    # makes dist/Rookie.app and dist/Rookie.zip
```

`setup.sh` skips anything already installed. The Swift app is in `Sources/`, the
engine and analysis half is the Python in `coachd/`, and they talk over a Unix
socket: `coachd` holds one warm Stockfish and answers questions about the
position, and nothing about a move is ever left to the model.

## Licence

GPL-3.0. See `LICENSE`, and `NOTICE.md` for the bundled components and the piece
sets, each with its own licence and author.

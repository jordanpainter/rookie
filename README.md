<p align="center">
  <img src="docs/media/icon.png" width="160" alt="Rookie: a hand-drawn rook holding a cheat sheet, on a green chessboard">
</p>

<h1 align="center">Rookie</h1>

<p align="center">
  <b>An open source chess coach for macOS</b>
</p>

For people who are still learning. It plays, it warns you before you hang a
piece, it reviews your real games, and it drills the tactics you actually get
wrong.

Everything runs on your own Mac. No account, no server, no subscription.

<p align="center">
  <video src="docs/media/demo.mp4" width="760" autoplay loop muted playsinline></video>
</p>

## Background

I'm not very good at chess. And it bothers me. So this is what I came up with.

You play bots that are actually beatable, drill puzzles built from your own old
blunders rather than a stranger's, and get told what you just did wrong while
you can still do something about it.

## Meet Chichi

<img src="art/chichi/chichi-jump-board.gif" width="128" align="right" alt="Chichi, a pixel-art rook holding a cheat sheet, jumping on a chessboard">

Chichi is the coach, and he talks like the decent player sitting next to you:
"that knight's attacked twice and defended once, so it comes off next move
unless it moves or gets help". Ask him anything mid-game, in plain English, and
he answers about the position in front of you.

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
analyses them, and shows what they cost you: where the blunders happen, which
pieces you drop, how the games actually end.

<p align="center">
  <img src="docs/media/review.png" width="700" alt="The Review tab: 348 games, 48% win rate, a blunder every 5 moves, and bar charts of how games end and which pieces get blundered">
</p>

**Drill.** Three sets of puzzles: tactics built from **your own blunders** in
those games, 30,000 from the Lichess set filtered to your rating, and tablebase
endgames worth knowing. Chichi will describe what a move does without telling you
whether it solves it.

<p align="center">
  <img src="docs/media/drill.png" width="700" alt="The Drill tab showing a puzzle built from one of the player's own games, with Your blunders, Lichess and Endgames to choose from">
</p>

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

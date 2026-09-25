# Licences

Rookie is free software under the **GNU General Public License, version 3**
(`LICENSE`). It has to be: the chess engine and the chess library it ships with are
both GPL-3.0, and so is anything distributed with them.

## Bundled in Rookie.app

| Component | Licence |
|---|---|
| [Stockfish](https://stockfishchess.org) 18, the chess engine | GPL-3.0 |
| [python-chess](https://github.com/niklasf/python-chess), move generation and engine control | GPL-3.0 |
| Python 3.14, from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) | [PSF License](https://docs.python.org/3/license.html) |

## Piece sets

In `Sources/ChessCoach/Resources/pieces/`, taken from
[lichess-org/lila](https://github.com/lichess-org/lila/tree/master/public/piece).

| Set | Author | Licence |
|---|---|---|
| `doodle` | Jordan Painter, drawn for Rookie (sources in `art/doodle/`) | GPL-3.0, as the rest of Rookie |
| `chessnut` | via lichess | Apache 2.0 |
| `rhosgfx` | [RhosGFX](https://rhosgfx.itch.io/) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (public domain) |
| `celtic` | via lichess | MIT |
| `fantasy` | via lichess | MIT |

Lichess's GPL sets (`cburnett`, `merida`, `mono`, GPLv2 or later) were left out
while this project was not GPL, and are compatible with it now. The fifteen
CC BY-NC-SA sets are not: a non-commercial clause cannot be combined with the GPL.
Lichess's full licence table is in
[COPYING.md](https://github.com/lichess-org/lila/blob/master/COPYING.md).

## Data

- Puzzles: [Lichess puzzle database](https://database.lichess.org/#puzzles), public domain.
- Openings: [lichess-org/chess-openings](https://github.com/lichess-org/chess-openings), CC0.
- Endgame tablebase: queried live from [Lichess](https://tablebase.lichess.ovh), not redistributed.
- Game history: pulled from the [chess.com public API](https://www.chess.com/news/view/published-data-api).

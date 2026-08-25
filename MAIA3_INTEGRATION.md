# Maia 3 on-device integration

## Status

Maia 3 is bundled and enabled as a real on-device opponent. It does not call a
server, run Python on iOS, use random chess moves or delegate play to Stockfish.
Stockfish remains the only objective analysis and coaching engine.

The project owner explicitly authorized adoption of AGPL-3.0-only for the
combined application. The root `LICENSE`, `NOTICE`, in-app legal notice and
corresponding source were updated together with this integration.

## Audited upstream material

- Official source: <https://github.com/CSSLab/maia3>
- Vendored source commit: `1e13597c42d4858b7cfd7cfdae01e297263364b2`
- Official model: <https://huggingface.co/UofTCSSLab/Maia3-5M>
- Model revision: `b6559de2398d7140b985f28fd2c19fb5e47ddabe`
- Checkpoint: `maia3-5m.pt`, 20,968,049 bytes
- Checkpoint SHA-256: `ba14208b2992d85502f5fb501934abf6aaaeb355e9f3fdf90e326911f562524f`
- License: GNU AGPL-3.0-only

The preferred checkpoint and audited Python source are retained under
`Vendor/Maia3/source`. `Scripts/convert_maia3_coreml.py` verifies the checkpoint
hash and reproduces the bundled Core ML package.

## Core ML model

- deployment target: iOS 16;
- precision: FP16;
- package size: approximately 11 MB;
- inputs: eight positions (`1 × 64 × 96`), self rating and opponent rating;
- output: 4,352 move-policy logits;
- loading: lazy on the first Maia turn, then reused by the actor;
- compute units: Core ML `.all`, allowing iOS to choose CPU/GPU/Neural Engine.

The official PyTorch model uses RMSNorm, which was decomposed into the
equivalent primitive formula for Core ML conversion. Before conversion, eager
PyTorch and the exported graph are required to match exactly. The app smoke
test loads the packaged model and runs a real starting-position prediction.

## Position and move semantics

Each position is encoded from the side-to-move perspective exactly as upstream:
black-to-move boards are rank-mirrored and colors are swapped. Up to the eight
most recent logical FEN positions are used; short histories are left-padded by
the earliest available position.

Both Maia rating inputs use the selected approximate level from 600 through
2600 in steps of 100. The UI deliberately does not present this as an exact
FIDE, Chess.com or Lichess equivalence.

Only ChessKit-generated legal moves are mapped into Maia's vocabulary. Illegal
logits are never sampled. The selected move is validated again against the
current ChessKit position before it reaches the game session, covering
castling, en passant and all four promotion kinds.

Policy selection uses Temperature `1.0` and TopP `0.95`, matching a human-like
distribution instead of always taking argmax. An optional seed produces a
stable value derived from the current FEN; tests may inject the random source.

## Cancellation and failures

Core ML does not expose interruption of an individual synchronous prediction.
Cancellation therefore invalidates the Maia generation before and after
inference. `BoardController` additionally checks its own generation, FEN and
turn before applying a move. A late result can consume compute briefly but
cannot mutate a newer or finished game.

Missing resources, malformed output, an invalid position, an empty legal set or
an illegal selected move produce a visible engine error and leave the logical
game unchanged.

## Distribution note

AGPL requires preservation of notices and availability of complete
corresponding source. Apple distribution terms may add restrictions depending
on the chosen channel. Relicensing the repository does not by itself guarantee
App Store acceptance or eliminate the need to review the applicable Apple
agreements before submission.

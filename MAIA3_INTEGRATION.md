# Maia 3 integration assessment

## Status

Maia 3 is **not bundled or enabled** in this release. The opponent-engine
architecture, persistence schema, legal-move validator and deterministic policy
sampler are ready, but the official model cannot be redistributed without an
explicit licensing decision by the project owner.

The new-game screen exposes Maia 3 as locked so the limitation is visible. It
does not run random moves, relabel Stockfish, call a remote service or depend on
Python at runtime.

## Verified upstream facts

- Official source: <https://github.com/CSSLab/maia3>
- Audited upstream commit: `1e13597c42d4858b7cfd7cfdae01e297263364b2`
- Official model: <https://huggingface.co/UofTCSSLab/Maia3-5M>
- Audited model revision: `b6559de2398d7140b985f28fd2c19fb5e47ddabe`
- Official checkpoint: `maia3-5m.pt`, 20,968,049 bytes
- Audited SHA-256: `ba14208b2992d85502f5fb501934abf6aaaeb355e9f3fdf90e326911f562524f`
- The source repository identifies its license as **GNU AGPL-3.0**.
- The model card says to consult the repository for the code/weights license; it
  does not grant a separate permissive license for the checkpoint.

Converting the checkpoint does not erase its license. A converted Core ML model
would still be a redistributed copy derived from the official weights.

## Core ML feasibility result

A local, uncommitted feasibility conversion was performed with the official 5M
checkpoint, PyTorch 2.8 CPU and coremltools 9.0:

- fixed inputs: eight historical positions (`1 × 64 × 96`) plus self/opponent
  rating;
- outputs: 4,352 move logits, three WDL logits and one ponder output;
- deployment target: iOS 16;
- precision: FP16;
- converted package size: approximately 11 MB;
- all checkpoint keys loaded with no missing or unexpected parameters;
- traced PyTorch output matched eager PyTorch output exactly before conversion.

PyTorch `RMSNorm` had to be decomposed into equivalent primitive operations for
Core ML conversion. Core ML execution equivalence and latency still need to be
measured on macOS/iPhone because Linux cannot load Apple's Core ML runtime.

This shows that Core ML is the preferred technical route; ONNX Runtime is not
needed at present and therefore no additional runtime dependency was added.

## Required decision before enabling Maia

Before committing a converted model or Maia-derived inference implementation,
the project owner should do one of the following:

1. obtain a separate redistribution license or written exception for the Maia 3
   code and Maia3-5M weights that is compatible with the intended iOS channel; or
2. explicitly adopt and satisfy AGPL-3.0 for the combined distributed work,
   including review of App Store terms, complete corresponding source and all
   notices; or
3. select a genuinely compatible human-like model with documented model-weight
   redistribution terms.

This is a licensing risk assessment, not legal advice. The project should obtain
qualified legal review before choosing option 2.

## Integration work remaining after permission

Once redistribution is authorized, enabling Maia is intentionally localized:

1. add the verified `.mlpackage` resource and attribution/license texts;
2. implement `ChessPlayingEngine` with lazy `MLModel` loading and instance reuse;
3. tokenize up to eight recorded positions from `ChessPlayingRequest.moveHistory`;
4. condition both rating inputs on the selected 600–2600 level;
5. mask logits with ChessKit legal moves, then sample with temperature `1.0` and
   TopP `0.95` using an injected seeded random source;
6. validate the sampled UCI move again through `OpponentMoveValidator` before
   returning it;
7. enable `OpponentEngineKind.maia3.isPlayableInThisBuild` and add an on-device
   smoke test for the official model.

Stockfish remains the sole source of objective centipawn evaluation, coaching,
blunder classification, best lines and full-game analysis.

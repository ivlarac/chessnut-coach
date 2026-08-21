# Stockfish version pin

Chessnut Coach phase 4 is pinned to the official Stockfish 18 release.

- Release: Stockfish 18
- Tag: `sf_18`
- Commit: `cb3d4ee9b47d0c5aae855b12379378ea1439675c`
- Source: `Vendor/Stockfish` git submodule
- Licence: GNU GPL v3 or later

## NNUE networks

| File | Size | SHA-256 |
| --- | ---: | --- |
| `nn-c288c895ea92.nnue` | 108,919,594 bytes | `c288c895ea924429ea9092e3f36b2b3c1f00f2a3a4c759ff7e57e79e3b43e4a7` |
| `nn-37f18f62d772.nnue` | 3,519,630 bytes | `37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d` |

The networks are not committed because the large network exceeds GitHub's 100 MiB per-file limit. `Scripts/fetch_stockfish_networks.sh` downloads them from the official Stockfish network endpoint and verifies their complete SHA-256 values before use.

The Xcode build compiles the pinned C++ sources into the application and bundles the verified NNUE files. Runtime analysis is local and does not require a server.

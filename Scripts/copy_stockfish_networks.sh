#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:?SRCROOT is required}"
DEST="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?resource path required}"

bash "$ROOT/Scripts/fetch_stockfish_networks.sh"
mkdir -p "$DEST"
cp -f "$ROOT/StockfishNetworks/nn-c288c895ea92.nnue" "$DEST/"
cp -f "$ROOT/StockfishNetworks/nn-37f18f62d772.nnue" "$DEST/"

echo "Bundled Stockfish 18 NNUE networks"

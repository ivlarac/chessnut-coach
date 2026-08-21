#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/StockfishNetworks"
mkdir -p "$DEST"

fetch_and_verify() {
  local name="$1"
  local sha="$2"
  local expected_size="$3"
  local path="$DEST/$name"

  if [ -f "$path" ]; then
    local current_sha
    current_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    local current_size
    current_size="$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path")"
    if [ "$current_sha" = "$sha" ] && [ "$current_size" = "$expected_size" ]; then
      echo "$name already verified"
      return
    fi
    rm -f "$path"
  fi

  echo "Downloading $name..."
  curl --fail --location --retry 3 --output "$path.tmp" "https://tests.stockfishchess.org/api/nn/$name"

  local downloaded_sha
  downloaded_sha="$(shasum -a 256 "$path.tmp" | awk '{print $1}')"
  local downloaded_size
  downloaded_size="$(stat -f%z "$path.tmp" 2>/dev/null || stat -c%s "$path.tmp")"

  if [ "$downloaded_sha" != "$sha" ] || [ "$downloaded_size" != "$expected_size" ]; then
    rm -f "$path.tmp"
    echo "Integrity check failed for $name" >&2
    exit 1
  fi

  mv "$path.tmp" "$path"
  echo "$name verified"
}

fetch_and_verify \
  "nn-c288c895ea92.nnue" \
  "c288c895ea924429ea9092e3f36b2b3c1f00f2a3a4c759ff7e57e79e3b43e4a7" \
  "108919594"

fetch_and_verify \
  "nn-37f18f62d772.nnue" \
  "37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d" \
  "3519630"

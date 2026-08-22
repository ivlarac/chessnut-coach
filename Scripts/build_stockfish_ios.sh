#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:?SRCROOT is required}"
STOCKFISH="$ROOT/Vendor/Stockfish"
OUT_ROOT="${DERIVED_FILE_DIR:?DERIVED_FILE_DIR is required}/stockfish18"
FINAL_LIB="$OUT_ROOT/libStockfish18.a"

if [ ! -f "$STOCKFISH/src/engine.cpp" ]; then
  echo "Initializing pinned Stockfish 18 submodule..."
  git -C "$ROOT" submodule update --init --recursive Vendor/Stockfish
fi

EXPECTED_COMMIT="cb3d4ee9b47d0c5aae855b12379378ea1439675c"
ACTUAL_COMMIT="$(git -C "$STOCKFISH" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]; then
  echo "Stockfish source mismatch: expected $EXPECTED_COMMIT, got $ACTUAL_COMMIT" >&2
  exit 1
fi

bash "$ROOT/Scripts/fetch_stockfish_networks.sh"
mkdir -p "$OUT_ROOT"

ARCH_LIST="${ARCHS:-arm64}"
SOURCE_SIGNATURE="$({
  shasum -a 256 \
    "$ROOT/Scripts/build_stockfish_ios.sh" \
    "$ROOT/ChessnutCoach/StockfishBridge.h" \
    "$ROOT/ChessnutCoach/StockfishBridge.mm" \
    "$ROOT/ChessnutCoach/StockfishBuildConfig.h"
} | shasum -a 256 | awk '{print $1}')"
KEY="$EXPECTED_COMMIT|${SDK_NAME:-unknown}|$ARCH_LIST|${CONFIGURATION:-Debug}|$SOURCE_SIGNATURE"
STAMP="$OUT_ROOT/build-key.txt"
if [ -f "$FINAL_LIB" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$KEY" ]; then
  echo "Stockfish 18 static library is up to date"
  exit 0
fi

rm -rf "$OUT_ROOT/objects"
mkdir -p "$OUT_ROOT/objects"

CXX="$(xcrun --find clang++)"
LIBTOOL="$(xcrun --find libtool)"
LIPO="$(xcrun --find lipo)"

if [[ "${PLATFORM_NAME:-}" == *simulator* ]]; then
  MIN_FLAG="-mios-simulator-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
else
  MIN_FLAG="-miphoneos-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
fi

SOURCES=()
while IFS= read -r source; do
  case "$(basename "$source")" in
    main.cpp|tune.cpp) continue ;;
  esac
  SOURCES+=("$source")
done < <(find "$STOCKFISH/src" -name '*.cpp' -type f | sort)
SOURCES+=("$ROOT/ChessnutCoach/StockfishBridge.mm")

THIN_LIBS=()
for ARCH in $ARCH_LIST; do
  ARCH_DIR="$OUT_ROOT/objects/$ARCH"
  mkdir -p "$ARCH_DIR"
  OBJECTS=()

  for SOURCE in "${SOURCES[@]}"; do
    RELATIVE="${SOURCE#$ROOT/}"
    OBJECT_NAME="$(printf '%s' "$RELATIVE" | tr '/.' '__').o"
    OBJECT="$ARCH_DIR/$OBJECT_NAME"

    "$CXX" \
      -c "$SOURCE" \
      -o "$OBJECT" \
      -arch "$ARCH" \
      -isysroot "$SDKROOT" \
      "$MIN_FLAG" \
      -std=gnu++20 \
      -stdlib=libc++ \
      -fexceptions \
      -fvisibility=hidden \
      -I "$STOCKFISH/src" \
      -include "$ROOT/ChessnutCoach/StockfishBuildConfig.h" \
      -Wno-comma \
      ${GCC_OPTIMIZATION_LEVEL:+-O$GCC_OPTIMIZATION_LEVEL}

    OBJECTS+=("$OBJECT")
  done

  THIN="$OUT_ROOT/libStockfish18-$ARCH.a"
  "$LIBTOOL" -static -o "$THIN" "${OBJECTS[@]}"
  THIN_LIBS+=("$THIN")
done

if [ "${#THIN_LIBS[@]}" -eq 1 ]; then
  cp "${THIN_LIBS[0]}" "$FINAL_LIB"
else
  "$LIPO" -create "${THIN_LIBS[@]}" -output "$FINAL_LIB"
fi

printf '%s' "$KEY" > "$STAMP"
echo "Built $FINAL_LIB"

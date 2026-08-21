// SPDX-License-Identifier: GPL-3.0-or-later
// Chessnut Coach Stockfish 18 integration.

#ifndef CHESSNUT_COACH_STOCKFISH_BRIDGE_H
#define CHESSNUT_COACH_STOCKFISH_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CCStockfishEngine CCStockfishEngine;

enum {
    CCStockfishScoreNone = 0,
    CCStockfishScoreCentipawns = 1,
    CCStockfishScoreMate = 2,
    CCStockfishScoreTablebase = 3,
};

CCStockfishEngine *CCStockfishCreate(
    const char *resourceDirectory,
    int32_t threads,
    int32_t hashMB,
    char *error,
    size_t errorCap
);

void CCStockfishDestroy(CCStockfishEngine *engine);
void CCStockfishStop(CCStockfishEngine *engine);

bool CCStockfishSearch(
    CCStockfishEngine *engine,
    const char *fen,
    uint64_t nodeLimit,
    int32_t depthLimit,
    int32_t *scoreKind,
    int32_t *scoreValue,
    int32_t *depth,
    uint64_t *nodes,
    char *bestMove,
    size_t bestCap,
    char *error,
    size_t errorCap
);

const char *CCStockfishVersion(void);

#ifdef __cplusplus
}
#endif

#endif

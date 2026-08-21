// Build configuration injected into the unmodified official Stockfish 18 sources.
#ifndef CHESSNUT_COACH_STOCKFISH_BUILD_CONFIG_H
#define CHESSNUT_COACH_STOCKFISH_BUILD_CONFIG_H

// The official NNUE files are application resources instead of bytes embedded
// again in C++ object files.
#define NNUE_EMBEDDING_OFF 1

#if defined(__LP64__)
#define IS_64BIT 1
#endif

#if defined(__aarch64__)
#define USE_NEON 8
#define USE_POPCNT 1
#elif defined(__x86_64__)
#define USE_SSE2 1
#endif

#endif

// SPDX-License-Identifier: GPL-3.0-or-later
// Chessnut Coach Stockfish 18 integration.
// Links against the unmodified official Stockfish 18 source pinned in Vendor/Stockfish.

#include "StockfishBridge.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "bitboard.h"
#include "engine.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "ucioption.h"

namespace {

constexpr std::uint64_t kBigNetworkSize = 108919594;
constexpr std::uint64_t kSmallNetworkSize = 3519630;
constexpr const char *kBigNetworkName = "nn-c288c895ea92.nnue";
constexpr const char *kSmallNetworkName = "nn-37f18f62d772.nnue";
constexpr const char *kStartFEN =
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

std::once_flag gInitialization;

void initializeStockfish() {
    std::call_once(gInitialization, [] {
        Stockfish::Bitboards::init();
        Stockfish::Position::init();
    });
}

void writeString(std::string_view value, char *destination, std::size_t capacity) {
    if (destination == nullptr || capacity == 0) return;
    const auto count = std::min(value.size(), capacity - 1);
    if (count > 0) std::memcpy(destination, value.data(), count);
    destination[count] = '\0';
}

bool fail(std::string_view message, char *error, std::size_t capacity) {
    writeString(message, error, capacity);
    return false;
}

std::string appendPath(std::string_view directory, std::string_view component) {
    std::string result(directory);
    if (!result.empty() && result.back() != '/') result.push_back('/');
    result.append(component);
    return result;
}

bool fileHasSize(const std::string& path, std::uint64_t expected) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    const auto size = file.tellg();
    return size >= 0 && static_cast<std::uint64_t>(size) == expected;
}

void setOption(Stockfish::Engine& engine, std::string_view name, std::string_view value) {
    std::istringstream command("name " + std::string(name) + " value " + std::string(value));
    engine.get_options().setoption(command);
}

void clearCallbacks(Stockfish::Engine& engine) {
    engine.set_on_update_no_moves({});
    engine.set_on_update_full({});
    engine.set_on_iter({});
    engine.set_on_bestmove({});
    engine.set_on_verify_networks({});
}

struct NativeResult {
    int32_t scoreKind = CCStockfishScoreNone;
    int32_t scoreValue = 0;
    int32_t depth = 0;
    std::uint64_t nodes = 0;
    std::string bestMove;
    bool hasScore = false;
};

void recordScore(const Stockfish::Score& score, NativeResult& result) {
    if (score.is<Stockfish::Score::InternalUnits>()) {
        result.scoreKind = CCStockfishScoreCentipawns;
        result.scoreValue = score.get<Stockfish::Score::InternalUnits>().value;
    } else if (score.is<Stockfish::Score::Mate>()) {
        result.scoreKind = CCStockfishScoreMate;
        result.scoreValue = score.get<Stockfish::Score::Mate>().plies;
    } else {
        const auto tb = score.get<Stockfish::Score::Tablebase>();
        result.scoreKind = CCStockfishScoreTablebase;
        result.scoreValue = tb.plies == 0 ? (tb.win ? 1 : -1) : tb.plies;
    }
    result.hasScore = true;
}

} // namespace

struct CCStockfishEngine {
    std::unique_ptr<Stockfish::Engine> engine;
    std::mutex operationMutex;
    std::atomic_bool searching{false};
};

CCStockfishEngine *CCStockfishCreate(
    const char *resourceDirectory,
    int32_t threads,
    int32_t hashMB,
    char *error,
    size_t errorCap
) {
    if (error != nullptr && errorCap > 0) error[0] = '\0';

    if (resourceDirectory == nullptr || *resourceDirectory == '\0') {
        fail("No se encontró el directorio de recursos de Stockfish.", error, errorCap);
        return nullptr;
    }
    if (threads < 1 || threads > 8 || hashMB < 1 || hashMB > 512) {
        fail("Configuración de Stockfish no válida.", error, errorCap);
        return nullptr;
    }

    try {
        const std::string directory(resourceDirectory);
        if (!fileHasSize(appendPath(directory, kBigNetworkName), kBigNetworkSize)) {
            fail("Falta la red NNUE grande de Stockfish 18 o tiene un tamaño incorrecto.", error, errorCap);
            return nullptr;
        }
        if (!fileHasSize(appendPath(directory, kSmallNetworkName), kSmallNetworkSize)) {
            fail("Falta la red NNUE pequeña de Stockfish 18 o tiene un tamaño incorrecto.", error, errorCap);
            return nullptr;
        }

        initializeStockfish();
        auto session = std::make_unique<CCStockfishEngine>();
        session->engine = std::make_unique<Stockfish::Engine>(
            appendPath(directory, "stockfish-ios")
        );
        setOption(*session->engine, "Threads", std::to_string(threads));
        setOption(*session->engine, "Hash", std::to_string(hashMB));
        setOption(*session->engine, "MultiPV", "1");
        setOption(*session->engine, "Skill Level", "20");
        setOption(*session->engine, "UCI_LimitStrength", "false");
        return session.release();
    } catch (const std::exception& exception) {
        fail(std::string("No se pudo iniciar Stockfish: ") + exception.what(), error, errorCap);
        return nullptr;
    } catch (...) {
        fail("No se pudo iniciar Stockfish por un error nativo desconocido.", error, errorCap);
        return nullptr;
    }
}

void CCStockfishDestroy(CCStockfishEngine *engine) {
    if (engine == nullptr) return;
    try {
        if (engine->engine) engine->engine->stop();
        std::lock_guard lock(engine->operationMutex);
        engine->engine.reset();
    } catch (...) {}
    delete engine;
}

void CCStockfishStop(CCStockfishEngine *engine) {
    if (engine == nullptr || !engine->engine || !engine->searching.load()) return;
    try { engine->engine->stop(); } catch (...) {}
}

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
) {
    if (error != nullptr && errorCap > 0) error[0] = '\0';
    if (bestMove != nullptr && bestCap > 0) bestMove[0] = '\0';
    if (scoreKind) *scoreKind = CCStockfishScoreNone;
    if (scoreValue) *scoreValue = 0;
    if (depth) *depth = 0;
    if (nodes) *nodes = 0;

    if (engine == nullptr || !engine->engine) {
        return fail("Stockfish no está inicializado.", error, errorCap);
    }
    if (nodeLimit == 0 && depthLimit <= 0) {
        return fail("El análisis necesita un límite de nodos o profundidad.", error, errorCap);
    }

    try {
        std::lock_guard operationLock(engine->operationMutex);
        engine->searching.store(true);

        NativeResult result;
        std::mutex resultMutex;

        engine->engine->set_on_update_no_moves([&](const Stockfish::Engine::InfoShort& info) {
            std::lock_guard resultLock(resultMutex);
            recordScore(info.score, result);
            if (info.score.is<Stockfish::Score::Mate>()
                && info.score.get<Stockfish::Score::Mate>().plies == 0) {
                result.scoreValue = -1;
            }
            result.depth = info.depth;
        });
        engine->engine->set_on_update_full([&](const Stockfish::Engine::InfoFull& info) {
            std::lock_guard resultLock(resultMutex);
            recordScore(info.score, result);
            result.depth = info.depth;
            result.nodes = static_cast<std::uint64_t>(info.nodes);
        });
        engine->engine->set_on_iter([](const Stockfish::Engine::InfoIter&) {});
        engine->engine->set_on_bestmove([&](std::string_view move, std::string_view) {
            std::lock_guard resultLock(resultMutex);
            if (move != "0000" && move != "(none)") result.bestMove = std::string(move);
        });
        engine->engine->set_on_verify_networks([](std::string_view) {});

        engine->engine->stop();
        engine->engine->wait_for_search_finished();

        const std::string requestedFEN =
            (fen == nullptr || *fen == '\0') ? std::string(kStartFEN) : std::string(fen);
        const auto positionError = engine->engine->set_position(
            requestedFEN,
            std::vector<std::string>{}
        );
        if (positionError.has_value()) {
            engine->searching.store(false);
            clearCallbacks(*engine->engine);
            return fail(
                std::string("FEN no válida: ") + positionError->what(),
                error,
                errorCap
            );
        }

        Stockfish::Search::LimitsType limits;
        limits.startTime = Stockfish::now();
        limits.nodes = nodeLimit;
        limits.depth = depthLimit;
        engine->engine->go(limits);
        engine->engine->wait_for_search_finished();

        engine->searching.store(false);

        std::lock_guard resultLock(resultMutex);
        if (!result.hasScore) {
            clearCallbacks(*engine->engine);
            return fail("Stockfish terminó sin producir una evaluación.", error, errorCap);
        }

        if (scoreKind) *scoreKind = result.scoreKind;
        if (scoreValue) *scoreValue = result.scoreValue;
        if (depth) *depth = result.depth;
        if (nodes) *nodes = result.nodes;
        writeString(result.bestMove, bestMove, bestCap);

        clearCallbacks(*engine->engine);
        return true;
    } catch (const std::exception& exception) {
        engine->searching.store(false);
        try { clearCallbacks(*engine->engine); } catch (...) {}
        return fail(std::string("El análisis de Stockfish falló: ") + exception.what(), error, errorCap);
    } catch (...) {
        engine->searching.store(false);
        try { clearCallbacks(*engine->engine); } catch (...) {}
        return fail("El análisis de Stockfish falló por un error nativo desconocido.", error, errorCap);
    }
}

const char *CCStockfishVersion(void) {
    return "Stockfish 18";
}

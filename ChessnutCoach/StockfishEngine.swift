import Foundation

enum StockfishEngineError: LocalizedError, Sendable {
    case initialization(String)
    case search(String)

    var errorDescription: String? {
        switch self {
        case let .initialization(message), let .search(message):
            message
        }
    }
}

enum StockfishScore: Equatable, Sendable {
    case centipawns(Int)
    case mate(Int)
    case tablebase(Int)

    var displayText: String {
        switch self {
        case let .centipawns(value):
            String(format: "%+.2f", Double(value) / 100.0)
        case let .mate(plies):
            let moves = max(1, (abs(plies) + 1) / 2)
            return plies >= 0 ? "Mate en \(moves)" : "Recibe mate en \(moves)"
        case let .tablebase(plies):
            return plies >= 0 ? "Tablebase: gana" : "Tablebase: pierde"
        }
    }
}

struct StockfishAnalysis: Equatable, Sendable {
    let version: String
    let bestMove: String
    let score: StockfishScore
    let depth: Int
    let nodes: UInt64

    var summary: String {
        "\(version) · \(bestMove) · \(score.displayText) · profundidad \(depth) · \(nodes) nodos"
    }
}

actor StockfishEngine {
    private var handle: OpaquePointer?

    let defaultNodeLimit: UInt64

    init(defaultNodeLimit: UInt64 = 60_000) {
        self.defaultNodeLimit = defaultNodeLimit
    }

    func version() -> String {
        String(cString: CCStockfishVersion())
    }

    func analyze(fen: String, nodeLimit: UInt64? = nil) throws -> StockfishAnalysis {
        let native = try ensureEngine()

        var scoreKind: Int32 = 0
        var scoreValue: Int32 = 0
        var depth: Int32 = 0
        var nodes: UInt64 = 0
        var bestMove = [CChar](repeating: 0, count: 32)
        var error = [CChar](repeating: 0, count: 512)

        let succeeded = fen.withCString { fenPointer in
            bestMove.withUnsafeMutableBufferPointer { bestBuffer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    CCStockfishSearch(
                        native,
                        fenPointer,
                        nodeLimit ?? defaultNodeLimit,
                        0,
                        &scoreKind,
                        &scoreValue,
                        &depth,
                        &nodes,
                        bestBuffer.baseAddress,
                        bestBuffer.count,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }

        guard succeeded else {
            throw StockfishEngineError.search(String(cString: error))
        }

        let score: StockfishScore
        switch scoreKind {
        case Int32(CCStockfishScoreCentipawns):
            score = .centipawns(Int(scoreValue))
        case Int32(CCStockfishScoreMate):
            score = .mate(Int(scoreValue))
        case Int32(CCStockfishScoreTablebase):
            score = .tablebase(Int(scoreValue))
        default:
            throw StockfishEngineError.search("Stockfish devolvió un tipo de evaluación desconocido.")
        }

        return StockfishAnalysis(
            version: version(),
            bestMove: String(cString: bestMove),
            score: score,
            depth: Int(depth),
            nodes: nodes
        )
    }

    func stop() {
        if let handle {
            CCStockfishStop(handle)
        }
    }

    private func ensureEngine() throws -> OpaquePointer {
        if let handle {
            return handle
        }

        guard let resourcePath = Bundle.main.resourceURL?.path else {
            throw StockfishEngineError.initialization("No se pudo localizar el directorio de recursos de la aplicación.")
        }

        var error = [CChar](repeating: 0, count: 512)
        let created = resourcePath.withCString { pathPointer in
            error.withUnsafeMutableBufferPointer { errorBuffer in
                CCStockfishCreate(
                    pathPointer,
                    1,
                    32,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }

        guard let created else {
            throw StockfishEngineError.initialization(String(cString: error))
        }

        handle = created
        return created
    }
}

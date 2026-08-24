import ChessKit
import Foundation

enum AnalysisPositionReference: Hashable, Codable, Sendable {
    case mainline(ply: Int)
    case variation(nodeID: UUID)
}

struct AnalysisVariationNode: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let parentNodeID: UUID?
    let rootPly: Int
    let san: String
    let uci: String
    let from: String
    let to: String
    let promotion: String?
    let fenBefore: String
    let fenAfter: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        parentNodeID: UUID?,
        rootPly: Int,
        san: String,
        uci: String,
        from: String,
        to: String,
        promotion: String?,
        fenBefore: String,
        fenAfter: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentNodeID = parentNodeID
        self.rootPly = rootPly
        self.san = san
        self.uci = uci
        self.from = from
        self.to = to
        self.promotion = promotion
        self.fenBefore = fenBefore
        self.fenAfter = fenAfter
        self.createdAt = createdAt
    }
}

enum AnalysisVariationError: LocalizedError, Equatable, Sendable {
    case unknownPosition
    case invalidSquare
    case wrongSideToMove
    case illegalMove
    case promotionRequired
    case invalidPromotion

    var errorDescription: String? {
        switch self {
        case .unknownPosition:
            "La posición de análisis ya no está disponible."
        case .invalidSquare:
            "La casilla seleccionada no es válida."
        case .wrongSideToMove:
            "Solo puedes mover una pieza del bando al que le corresponde jugar."
        case .illegalMove:
            "Ese movimiento no es legal en la posición actual."
        case .promotionRequired:
            "Elige dama, torre, alfil o caballo para completar la promoción."
        case .invalidPromotion:
            "La pieza elegida no es válida para una promoción."
        }
    }
}

struct AnalysisVariationTree: Equatable, Sendable {
    private(set) var nodes: [AnalysisVariationNode]

    init(nodes: [AnalysisVariationNode] = []) {
        self.nodes = nodes
    }

    func node(id: UUID) -> AnalysisVariationNode? {
        nodes.first { $0.id == id }
    }

    func fen(
        for reference: AnalysisPositionReference,
        in game: GameRecord
    ) -> String? {
        switch reference {
        case let .mainline(ply):
            guard (0...game.moves.count).contains(ply) else { return nil }
            return GameReplay.fen(for: game, afterPly: ply)
        case let .variation(nodeID):
            return node(id: nodeID)?.fenAfter
        }
    }

    func children(of reference: AnalysisPositionReference) -> [AnalysisVariationNode] {
        let children: [AnalysisVariationNode]
        switch reference {
        case let .mainline(ply):
            children = nodes.filter { $0.parentNodeID == nil && $0.rootPly == ply }
        case let .variation(nodeID):
            children = nodes.filter { $0.parentNodeID == nodeID }
        }
        return children.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func roots() -> [AnalysisVariationNode] {
        nodes
            .filter { $0.parentNodeID == nil }
            .sorted { lhs, rhs in
                if lhs.rootPly == rhs.rootPly {
                    if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.rootPly < rhs.rootPly
            }
    }

    func path(to nodeID: UUID) -> [AnalysisVariationNode] {
        var result: [AnalysisVariationNode] = []
        var nextID: UUID? = nodeID
        var visited: Set<UUID> = []

        while let id = nextID, !visited.contains(id), let current = node(id: id) {
            visited.insert(id)
            result.append(current)
            nextID = current.parentNodeID
        }
        return result.reversed()
    }

    func parentReference(of nodeID: UUID) -> AnalysisPositionReference? {
        guard let current = node(id: nodeID) else { return nil }
        if let parentNodeID = current.parentNodeID {
            return .variation(nodeID: parentNodeID)
        }
        return .mainline(ply: current.rootPly)
    }

    func legalTargets(
        from sourceNotation: String,
        at reference: AnalysisPositionReference,
        in game: GameRecord
    ) -> [String] {
        guard Self.isSquareNotation(sourceNotation),
              let fen = fen(for: reference, in: game),
              let position = Position(fen: fen)
        else { return [] }

        let source = Square(sourceNotation)
        guard position.pieces.contains(where: {
            $0.square == source && $0.color == position.sideToMove
        }) else { return [] }

        return Board(position: position)
            .legalMoves(forPieceAt: source)
            .map(\.notation)
            .sorted()
    }

    func requiresPromotion(
        from sourceNotation: String,
        to targetNotation: String,
        at reference: AnalysisPositionReference,
        in game: GameRecord
    ) -> Bool {
        guard Self.isSquareNotation(sourceNotation), Self.isSquareNotation(targetNotation),
              let fen = fen(for: reference, in: game),
              let position = Position(fen: fen)
        else { return false }

        var board = Board(position: position)
        guard board.move(
            pieceAt: Square(sourceNotation),
            to: Square(targetNotation)
        ) != nil else { return false }
        if case .promotion = board.state { return true }
        return false
    }

    @discardableResult
    mutating func applyMove(
        from sourceNotation: String,
        to targetNotation: String,
        promotion: Piece.Kind? = nil,
        at reference: AnalysisPositionReference,
        in game: GameRecord,
        createdAt: Date = Date()
    ) throws -> AnalysisVariationNode {
        guard Self.isSquareNotation(sourceNotation), Self.isSquareNotation(targetNotation) else {
            throw AnalysisVariationError.invalidSquare
        }
        guard let fenBefore = fen(for: reference, in: game),
              let position = Position(fen: fenBefore)
        else { throw AnalysisVariationError.unknownPosition }

        let source = Square(sourceNotation)
        let target = Square(targetNotation)
        guard position.pieces.contains(where: {
            $0.square == source && $0.color == position.sideToMove
        }) else { throw AnalysisVariationError.wrongSideToMove }

        var board = Board(position: position)
        guard let initialMove = board.move(pieceAt: source, to: target) else {
            throw AnalysisVariationError.illegalMove
        }

        let san: String
        let promotionSymbol: String?
        if case let .promotion(promotionMove) = board.state {
            guard let promotion else { throw AnalysisVariationError.promotionRequired }
            guard Self.promotionKinds.contains(promotion) else {
                throw AnalysisVariationError.invalidPromotion
            }
            let completedMove = board.completePromotion(of: promotionMove, to: promotion)
            san = completedMove.san
            promotionSymbol = promotion.promotionSymbol
        } else {
            guard promotion == nil else { throw AnalysisVariationError.invalidPromotion }
            san = initialMove.san
            promotionSymbol = nil
        }

        let parentNodeID: UUID?
        let rootPly: Int
        switch reference {
        case let .mainline(ply):
            parentNodeID = nil
            rootPly = ply
        case let .variation(nodeID):
            guard let parent = node(id: nodeID) else {
                throw AnalysisVariationError.unknownPosition
            }
            parentNodeID = parent.id
            rootPly = parent.rootPly
        }

        let uci = sourceNotation + targetNotation + (promotionSymbol?.lowercased() ?? "")
        let fenAfter = board.position.fen

        if let existing = children(of: reference).first(where: {
            $0.uci == uci && $0.fenAfter == fenAfter
        }) {
            return existing
        }

        let created = AnalysisVariationNode(
            parentNodeID: parentNodeID,
            rootPly: rootPly,
            san: san,
            uci: uci,
            from: sourceNotation,
            to: targetNotation,
            promotion: promotionSymbol,
            fenBefore: fenBefore,
            fenAfter: fenAfter,
            createdAt: createdAt
        )
        nodes.append(created)
        return created
    }

    @discardableResult
    mutating func deleteBranch(startingAt nodeID: UUID) -> Set<UUID> {
        guard node(id: nodeID) != nil else { return [] }
        var idsToDelete: Set<UUID> = [nodeID]
        var changed = true
        while changed {
            changed = false
            for candidate in nodes where
                candidate.parentNodeID.map(idsToDelete.contains) == true
                && !idsToDelete.contains(candidate.id)
            {
                idsToDelete.insert(candidate.id)
                changed = true
            }
        }
        nodes.removeAll { idsToDelete.contains($0.id) }
        return idsToDelete
    }

    private static let promotionKinds: [Piece.Kind] = [.queen, .rook, .bishop, .knight]

    private static func isSquareNotation(_ value: String) -> Bool {
        guard value.count == 2,
              let file = value.first,
              let rank = value.last
        else { return false }
        return ("a"..."h").contains(String(file)) && ("1"..."8").contains(String(rank))
    }
}

struct AnalysisRequestToken: Equatable, Sendable {
    let generation: Int
    let fen: String
}

struct AnalysisRequestTracker: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var currentFEN: String?

    mutating func begin(fen: String) -> AnalysisRequestToken {
        generation += 1
        currentFEN = fen
        return AnalysisRequestToken(generation: generation, fen: fen)
    }

    mutating func invalidate() {
        generation += 1
        currentFEN = nil
    }

    func accepts(_ token: AnalysisRequestToken) -> Bool {
        token.generation == generation && token.fen == currentFEN
    }
}

struct AnalysisPlayConfiguration: Equatable, Sendable {
    let humanSide: PlayerSide
    let strength: StockfishStrength

    init(humanSide: PlayerSide, strength: StockfishStrength) {
        self.humanSide = humanSide
        self.strength = strength
    }
}

protocol AnalysisMoveSearching: Sendable {
    func bestMove(
        fen: String,
        nodeLimit: UInt64,
        strength: StockfishStrength
    ) async throws -> String
}

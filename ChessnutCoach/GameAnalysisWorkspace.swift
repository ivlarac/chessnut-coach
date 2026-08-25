import ChessKit
import Combine
import Foundation

enum AnalysisWorkspaceMode: Equatable, Sendable {
    case original
    case variation
    case playingStockfish

    var displayText: String {
        switch self {
        case .original: "Partida original"
        case .variation: "Variante"
        case .playingStockfish: "Jugando contra Stockfish"
        }
    }
}

struct AnalysisPromotionRequest: Equatable, Sendable {
    let from: String
    let to: String
}

struct AnalysisVariationDisplayRow: Identifiable, Equatable, Sendable {
    let node: AnalysisVariationNode
    let depth: Int
    let sequenceSAN: String

    var id: UUID { node.id }
}

@MainActor
final class GameAnalysisWorkspace: ObservableObject {
    @Published private(set) var game: GameRecord
    @Published private(set) var currentReference: AnalysisPositionReference
    @Published private(set) var isExploring = false
    @Published private(set) var selectedSource: String?
    @Published private(set) var legalTargets: [String] = []
    @Published private(set) var promotionRequest: AnalysisPromotionRequest?
    @Published private(set) var playConfiguration: AnalysisPlayConfiguration?
    @Published private(set) var playStartFEN: String?
    @Published private(set) var isEngineThinking = false
    @Published private(set) var status = "Selecciona una posición para analizarla."

    private(set) var tree: AnalysisVariationTree

    private let engine: any AnalysisMoveSearching
    private let onSave: (GameRecord) -> Void
    private let onInteractiveSearchStarted: () -> Void
    private let onPositionChanged: (String, Int?) -> Void
    private var engineMoveTask: Task<Void, Never>?
    private var engineGeneration = 0

    init(
        game: GameRecord,
        initialPly: Int,
        engine: any AnalysisMoveSearching,
        onSave: @escaping (GameRecord) -> Void,
        onInteractiveSearchStarted: @escaping () -> Void = {},
        onPositionChanged: @escaping (String, Int?) -> Void = { _, _ in }
    ) {
        self.game = game
        currentReference = .mainline(ply: min(max(0, initialPly), game.moves.count))
        tree = AnalysisVariationTree(nodes: game.analysisVariations)
        self.engine = engine
        self.onSave = onSave
        self.onInteractiveSearchStarted = onInteractiveSearchStarted
        self.onPositionChanged = onPositionChanged
    }

    var currentFEN: String {
        tree.fen(for: currentReference, in: game) ?? game.initialFEN
    }

    var mode: AnalysisWorkspaceMode {
        if playConfiguration != nil { return .playingStockfish }
        if case .variation = currentReference { return .variation }
        return .original
    }

    var canMovePieces: Bool {
        guard isExploring,
              promotionRequest == nil,
              !isEngineThinking,
              !isTerminalPosition
        else { return false }

        guard let playConfiguration else { return true }
        return sideToMove == playConfiguration.humanSide.pieceColor
    }

    var sideToMove: Piece.Color? {
        Position(fen: currentFEN)?.sideToMove
    }

    var isTerminalPosition: Bool {
        guard let position = Position(fen: currentFEN) else { return true }
        switch Board(position: position).state {
        case .checkmate, .draw:
            return true
        case .active, .check, .promotion:
            return false
        }
    }

    var rootVariants: [AnalysisVariationNode] { tree.roots() }

    var currentMainlinePly: Int? {
        if case let .mainline(ply) = currentReference { return ply }
        return nil
    }

    var variationRows: [AnalysisVariationDisplayRow] {
        var rows: [AnalysisVariationDisplayRow] = []
        for root in tree.roots() {
            appendDisplayRows(node: root, depth: 0, sequence: [], to: &rows)
        }
        return rows
    }

    func children(of reference: AnalysisPositionReference) -> [AnalysisVariationNode] {
        tree.children(of: reference)
    }

    func path(to nodeID: UUID) -> [AnalysisVariationNode] {
        tree.path(to: nodeID)
    }

    func selectMainline(ply: Int) {
        guard playConfiguration == nil else { return }
        stopEngineSearch()
        currentReference = .mainline(ply: min(max(0, ply), game.moves.count))
        isExploring = false
        clearSelection()
        status = "Partida original · posición \(min(max(0, ply), game.moves.count))/\(game.moves.count)."
        notifyPositionChanged()
    }

    func selectVariation(nodeID: UUID) {
        guard playConfiguration == nil else { return }
        guard tree.node(id: nodeID) != nil else { return }
        stopEngineSearch()
        currentReference = .variation(nodeID: nodeID)
        isExploring = true
        clearSelection()
        status = "Variante seleccionada. Puedes continuarla o volver atrás para crear otra rama."
        notifyPositionChanged()
    }

    func exploreCurrentPosition() {
        guard game.allowsAnalysis, playConfiguration == nil else { return }
        isExploring = true
        clearSelection()
        status = "Explorando variante · mueve una pieza legal."
    }

    func leaveVariation() {
        guard playConfiguration == nil else { return }
        switch currentReference {
        case .mainline:
            isExploring = false
        case let .variation(nodeID):
            let rootPly = tree.node(id: nodeID)?.rootPly ?? 0
            currentReference = .mainline(ply: rootPly)
            isExploring = false
        }
        clearSelection()
        status = "Partida original."
        notifyPositionChanged()
    }

    func moveBackward() {
        guard playConfiguration == nil else { return }
        stopEngineSearch()
        switch currentReference {
        case let .mainline(ply):
            selectMainline(ply: max(0, ply - 1))
        case let .variation(nodeID):
            guard let parent = tree.parentReference(of: nodeID) else { return }
            currentReference = parent
            isExploring = true
            clearSelection()
            status = "Has retrocedido en la variante. Un movimiento diferente creará una rama hermana."
            notifyPositionChanged()
        }
    }

    func moveForward(through nodeID: UUID) {
        guard playConfiguration == nil else { return }
        guard tree.children(of: currentReference).contains(where: { $0.id == nodeID }) else { return }
        selectVariation(nodeID: nodeID)
    }

    func handleSquareTap(_ notation: String) {
        guard canMovePieces else { return }

        if selectedSource == notation {
            clearSelection()
            status = "Selección cancelada."
            return
        }

        if let selectedSource, legalTargets.contains(notation) {
            performMove(from: selectedSource, to: notation)
            return
        }

        selectSource(notation)
    }

    func handleMove(from source: String, to target: String) {
        guard canMovePieces, source != target else { return }
        let targets = tree.legalTargets(
            from: source,
            at: currentReference,
            in: game
        )
        guard targets.contains(target) else {
            selectSource(source)
            status = "El destino \(target) no es legal para la pieza de \(source)."
            return
        }
        performMove(from: source, to: target)
    }

    func completePromotion(to kind: Piece.Kind) {
        guard let promotionRequest else { return }
        performMove(
            from: promotionRequest.from,
            to: promotionRequest.to,
            promotion: kind
        )
    }

    func cancelPromotion() {
        promotionRequest = nil
        clearSelection()
        status = "Promoción cancelada."
    }

    func deleteBranch(startingAt nodeID: UUID) {
        guard playConfiguration == nil else { return }
        guard let node = tree.node(id: nodeID) else { return }
        let deleted = tree.deleteBranch(startingAt: nodeID)
        if case let .variation(currentID) = currentReference, deleted.contains(currentID) {
            currentReference = node.parentNodeID.map {
                AnalysisPositionReference.variation(nodeID: $0)
            }
                ?? .mainline(ply: node.rootPly)
        }
        persistTree()
        clearSelection()
        status = "Variante eliminada sin modificar la partida original."
        notifyPositionChanged()
    }

    func startPlaying(_ configuration: AnalysisPlayConfiguration) {
        guard game.allowsAnalysis else { return }
        stopEngineSearch()
        playConfiguration = configuration
        playStartFEN = currentFEN
        isExploring = true
        clearSelection()
        status = "Partida de análisis desde la posición elegida."
        scheduleEngineMoveIfNeeded()
    }

    func stopPlaying() {
        stopEngineSearch()
        playConfiguration = nil
        playStartFEN = nil
        isExploring = true
        clearSelection()
        status = "Partida de análisis terminada. La línea queda guardada como variante."
    }

    func cancelAllWork() {
        stopEngineSearch()
        clearSelection()
    }

    /// Keeps an already presented detail screen in sync with the persisted
    /// record. Timed games are saved while active, so the same screen can
    /// legitimately observe the record transition from playing to archived.
    func synchronize(with updatedGame: GameRecord) {
        guard updatedGame.id == game.id, updatedGame != game else { return }

        let wasAnalysisAvailable = game.allowsAnalysis
        game = updatedGame
        tree = AnalysisVariationTree(nodes: updatedGame.analysisVariations)

        if !updatedGame.allowsAnalysis {
            stopEngineSearch()
            playConfiguration = nil
            playStartFEN = nil
            currentReference = .mainline(ply: updatedGame.moves.count)
            isExploring = false
            status = "Partida en curso · finalízala para explorar variantes."
        } else if !wasAnalysisAvailable {
            currentReference = .mainline(ply: 0)
            isExploring = false
            status = "Partida finalizada. Selecciona una posición para analizarla."
        } else {
            switch currentReference {
            case let .mainline(ply):
                currentReference = .mainline(
                    ply: min(max(0, ply), updatedGame.moves.count)
                )
            case let .variation(nodeID):
                if tree.node(id: nodeID) == nil {
                    currentReference = .mainline(ply: 0)
                    isExploring = false
                }
            }
        }

        clearSelection()
        if updatedGame.allowsAnalysis {
            notifyPositionChanged()
        }
    }

    private func selectSource(_ notation: String) {
        let targets = tree.legalTargets(
            from: notation,
            at: currentReference,
            in: game
        )
        guard !targets.isEmpty else {
            clearSelection()
            status = "Esa pieza no puede moverse en la posición actual."
            return
        }
        selectedSource = notation
        legalTargets = targets
        status = "Pieza en \(notation) · elige un destino legal."
    }

    private func appendDisplayRows(
        node: AnalysisVariationNode,
        depth: Int,
        sequence: [String],
        to rows: inout [AnalysisVariationDisplayRow]
    ) {
        let updatedSequence = sequence + [node.san]
        rows.append(
            AnalysisVariationDisplayRow(
                node: node,
                depth: depth,
                sequenceSAN: updatedSequence.joined(separator: " ")
            )
        )
        for child in tree.children(of: .variation(nodeID: node.id)) {
            appendDisplayRows(
                node: child,
                depth: depth + 1,
                sequence: updatedSequence,
                to: &rows
            )
        }
    }

    private func performMove(
        from source: String,
        to target: String,
        promotion: Piece.Kind? = nil
    ) {
        if promotion == nil,
           tree.requiresPromotion(
               from: source,
               to: target,
               at: currentReference,
               in: game
           )
        {
            promotionRequest = AnalysisPromotionRequest(from: source, to: target)
            status = "Elige la pieza para promocionar en \(target)."
            return
        }

        do {
            let created = try tree.applyMove(
                from: source,
                to: target,
                promotion: promotion,
                at: currentReference,
                in: game
            )
            currentReference = .variation(nodeID: created.id)
            isExploring = true
            promotionRequest = nil
            persistTree()
            clearSelection()
            status = "Variante · \(created.san) guardado."
            notifyPositionChanged()

            if isTerminalPosition {
                status = "La posición finaliza por mate o tablas. Termina la partida de análisis para volver."
            } else {
                scheduleEngineMoveIfNeeded()
            }
        } catch {
            promotionRequest = nil
            clearSelection()
            status = error.localizedDescription
        }
    }

    private func persistTree() {
        game.analysisVariations = tree.nodes
        onSave(game)
    }

    private func clearSelection() {
        selectedSource = nil
        legalTargets = []
    }

    private func notifyPositionChanged() {
        onPositionChanged(currentFEN, currentMainlinePly)
    }

    private func scheduleEngineMoveIfNeeded() {
        guard let playConfiguration,
              !isTerminalPosition,
              sideToMove != playConfiguration.humanSide.pieceColor,
              engineMoveTask == nil
        else { return }

        engineGeneration += 1
        let requestedGeneration = engineGeneration
        let requestedFEN = currentFEN
        isEngineThinking = true
        status = "Stockfish está calculando su jugada…"
        onInteractiveSearchStarted()

        engineMoveTask = Task { [weak self, engine] in
            do {
                let uci = try await engine.bestMove(
                    fen: requestedFEN,
                    nodeLimit: 80_000,
                    strength: playConfiguration.strength
                )
                try Task.checkCancellation()
                guard let self,
                      self.engineGeneration == requestedGeneration,
                      self.currentFEN == requestedFEN,
                      self.playConfiguration == playConfiguration,
                      let move = OTBExpectedMove(uci: uci)
                else { return }

                self.engineMoveTask = nil
                self.isEngineThinking = false
                self.performMove(
                    from: move.from.notation,
                    to: move.to.notation,
                    promotion: move.promotion
                )
            } catch is CancellationError {
                // A different position or an explicit stop superseded this search.
            } catch {
                guard let self, self.engineGeneration == requestedGeneration else { return }
                self.engineMoveTask = nil
                self.isEngineThinking = false
                self.status = "Stockfish no pudo mover: \(error.localizedDescription)"
            }
        }
    }

    private func stopEngineSearch() {
        engineGeneration += 1
        engineMoveTask?.cancel()
        engineMoveTask = nil
        isEngineThinking = false
    }
}

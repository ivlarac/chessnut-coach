import ChessKit
import SwiftUI
import UniformTypeIdentifiers

struct GameLibraryView: View {
    @ObservedObject var library: GameLibrary
    @ObservedObject var board: BoardController
    @State private var gamePendingDeletion: GameRecord?

    var body: some View {
        List {
            if let errorMessage = library.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if library.games.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Sin partidas guardadas")
                        .font(.headline)
                    Text("La primera partida aparecerá aquí automáticamente al registrar un movimiento.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(library.games) { game in
                    NavigationLink {
                        GameDetailView(game: game, library: library)
                    } label: {
                        GameSummaryRow(
                            game: game,
                            isCurrent: game.id == board.currentGameID
                        )
                    }
                    .swipeActions {
                        Button("Borrar", role: .destructive) {
                            gamePendingDeletion = game
                        }
                    }
                }
            }
        }
        .navigationTitle("Partidas")
        .refreshable {
            library.reload()
        }
        .confirmationDialog(
            "¿Borrar esta partida?",
            isPresented: Binding(
                get: { gamePendingDeletion != nil },
                set: { if !$0 { gamePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: gamePendingDeletion
        ) { game in
            Button("Borrar definitivamente", role: .destructive) {
                board.deleteArchivedGame(game)
                gamePendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) {
                gamePendingDeletion = nil
            }
        } message: { game in
            if game.id == board.currentGameID {
                Text("Es la partida actual. Al borrarla también se reiniciará la sesión del tablero.")
            } else {
                Text("Esta acción elimina la partida y todos sus movimientos del dispositivo.")
            }
        }
    }
}

private struct GameSummaryRow: View {
    let game: GameRecord
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(displayName(game.whitePlayer)) – \(displayName(game.blackPlayer))")
                    .font(.headline)
                Spacer()
                Text(game.result.pgnValue)
                    .font(.headline.monospaced())
            }

            Text(game.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("\(game.fullMoveCount) jugadas", systemImage: "arrow.left.arrow.right")
                Label(formatDuration(game.duration), systemImage: "clock")
                if game.mode == .solo {
                    Label("Solitario", systemImage: "person.fill")
                }
                if isCurrent && game.status == .playing {
                    Label("Actual", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(game.status.displayText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}

struct GameDetailView: View {
    let game: GameRecord
    @State private var selectedPly: Int
    @State private var boardPerspective = ChessBoardPerspective.whiteAtBottom
    @State private var isExporting = false
    @State private var isPlaySetupPresented = false
    @State private var exportError: String?
    @State private var exportDocument: PGNFileDocument
    @State private var shareFileURL: URL?
    @State private var branchPendingDeletion: AnalysisVariationNode?
    @StateObject private var analysis: ArchivedGameAnalysisController
    @StateObject private var workspace: GameAnalysisWorkspace

    @MainActor
    init(game: GameRecord, library: GameLibrary) {
        self.game = game
        let initialPly = game.status == .finished ? 0 : game.moves.count
        let analysisController = ArchivedGameAnalysisController()
        _selectedPly = State(initialValue: initialPly)
        _exportDocument = State(initialValue: PGNFileDocument(text: PGNExporter.pgn(for: game)))
        _shareFileURL = State(initialValue: try? PGNShareFile.make(for: game))
        _analysis = StateObject(wrappedValue: analysisController)
        _workspace = StateObject(
            wrappedValue: GameAnalysisWorkspace(
                game: game,
                initialPly: initialPly,
                engine: StockfishEngine.shared,
                onSave: { library.upsert($0) },
                onInteractiveSearchStarted: {
                    analysisController.cancelFullGameAnalysis()
                },
                onPositionChanged: { fen, ply in
                    analysisController.analyze(fen: fen, ply: ply)
                }
            )
        )
    }

    var body: some View {
        List {
            Section("Resumen") {
                LabeledContent("Blancas", value: game.whitePlayer)
                LabeledContent("Negras", value: game.blackPlayer)
                LabeledContent("Fecha") {
                    Text(game.startedAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Resultado", value: game.result.displayText)
                LabeledContent("Jugadas", value: "\(game.fullMoveCount) (\(game.moveCount) medios movimientos)")
                LabeledContent("Duración", value: formatDuration(game.duration))
                LabeledContent("Modo", value: game.mode.displayText)
                if game.mode == .solo {
                    LabeledContent("Tu color", value: game.humanSide?.displayText ?? "—")
                    let opponent = game.opponentEngine
                        ?? .stockfish(game.engineStrength ?? .full)
                    LabeledContent("Motor rival", value: opponent.displayName)
                    LabeledContent("Nivel", value: opponent.strengthDisplayText)
                }
            }

            Section(game.status == .finished ? "Análisis" : "Reproducción") {
                if game.status == .finished {
                    HStack {
                        Label(workspace.mode.displayText, systemImage: modeSymbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(modeColor)
                        Spacer()
                        Button {
                            boardPerspective = boardPerspective.opposite
                        } label: {
                            Label("Girar", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        EvaluationBarView(
                            evaluation: analysis.evaluation,
                            isAnalyzing: analysis.isAnalyzing
                        )
                        .frame(width: 42)

                        AnalysisBoardView(
                            fen: workspace.currentFEN,
                            perspective: boardPerspective,
                            selectedSource: workspace.selectedSource,
                            legalTargets: workspace.legalTargets,
                            isInteractive: workspace.canMovePieces,
                            onTap: workspace.handleSquareTap,
                            onMove: workspace.handleMove
                        )
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                    LabeledContent("Evaluación") {
                        if analysis.isAnalyzing {
                            ProgressView()
                        } else {
                            Text(analysis.evaluation?.displayText ?? "—")
                                .font(.body.monospacedDigit())
                        }
                    }
                    LabeledContent("Mejor movimiento", value: analysis.bestMove)
                    Text(analysis.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(workspace.status)
                        .font(.footnote)
                        .foregroundStyle(workspace.mode == .playingStockfish ? Color.orange : Color.secondary)

                    if workspace.isEngineThinking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Stockfish está realizando su jugada…")
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    if workspace.mode == .playingStockfish {
                        Button(role: .destructive) {
                            workspace.stopPlaying()
                        } label: {
                            Label("Terminar partida de análisis", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        if workspace.isExploring {
                            Button {
                                workspace.leaveVariation()
                                selectedPly = workspace.currentMainlinePly ?? selectedPly
                            } label: {
                                Label("Volver a la partida original", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                analysis.cancelFullGameAnalysis()
                                workspace.exploreCurrentPosition()
                            } label: {
                                Label("Explorar variante", systemImage: "arrow.triangle.branch")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            analysis.cancelFullGameAnalysis()
                            isPlaySetupPresented = true
                        } label: {
                            Label("Jugar contra Stockfish desde aquí", systemImage: "cpu")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    AnalysisBoardView(
                        fen: workspace.currentFEN,
                        perspective: boardPerspective,
                        selectedSource: nil,
                        legalTargets: [],
                        isInteractive: false,
                        onTap: { _ in },
                        onMove: { _, _ in }
                    )
                        .aspectRatio(1, contentMode: .fit)
                        .listRowInsets(EdgeInsets())

                    Text("Finaliza la partida para activar el análisis posición a posición con Stockfish.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if workspace.mode == .original {
                    Stepper(value: mainlinePlyBinding, in: 0...game.moves.count) {
                        if let move = GameReplay.move(for: game, atPly: selectedPly) {
                            Text(savedMoveNotation(for: move))
                        } else {
                            Text("Posición inicial")
                        }
                    }
                } else if case let .variation(nodeID) = workspace.currentReference {
                    LabeledContent("Línea actual") {
                        Text(workspace.path(to: nodeID).map(\.san).joined(separator: " "))
                            .font(.subheadline.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                }

                HStack {
                    Button {
                        if workspace.isExploring {
                            workspace.moveBackward()
                            selectedPly = workspace.currentMainlinePly ?? selectedPly
                        } else {
                            selectMainline(ply: max(0, selectedPly - 1))
                        }
                    } label: {
                        Label("Anterior", systemImage: "backward.end")
                    }
                    .disabled(workspace.currentReference == .mainline(ply: 0))

                    Spacer()

                    Text(positionCounterText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        if workspace.isExploring, let first = currentChildren.first {
                            workspace.moveForward(through: first.id)
                        } else {
                            selectMainline(ply: min(game.moves.count, selectedPly + 1))
                        }
                    } label: {
                        Label("Siguiente", systemImage: "forward.end")
                    }
                    .disabled(
                        workspace.isExploring
                            ? currentChildren.isEmpty
                            : selectedPly == game.moves.count
                    )
                }
                .buttonStyle(.borderless)
                .disabled(workspace.mode == .playingStockfish)

                if workspace.isExploring, currentChildren.count > 1 {
                    Text("Continuaciones disponibles")
                        .font(.caption.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(currentChildren) { child in
                                Button(child.san) {
                                    analysis.cancelFullGameAnalysis()
                                    workspace.moveForward(through: child.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            if game.status == .finished {
                Section("Variantes") {
                    if workspace.variationRows.isEmpty {
                        Text("Todavía no hay variantes. Sitúate en una posición y pulsa «Explorar variante».")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.variationRows) { row in
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: CGFloat(row.depth) * 12)
                                Button {
                                    analysis.cancelFullGameAnalysis()
                                    workspace.selectVariation(nodeID: row.node.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.depth == 0 ? "Desde ply \(row.node.rootPly) · \(row.node.san)" : "↳ \(row.node.san)")
                                            .font(.subheadline.monospaced().weight(.semibold))
                                        Text(row.sequenceSAN)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if workspace.currentReference == .variation(nodeID: row.node.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }

                                Button(role: .destructive) {
                                    branchPendingDeletion = row.node
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Eliminar variante desde \(row.node.san)")
                            }
                        }
                        .disabled(workspace.mode == .playingStockfish)
                    }
                }
            }

            if game.status == .finished {
                Section("Análisis completo") {
                    if analysis.isAnalyzingFullGame {
                        ProgressView(value: analysis.fullGameProgress) {
                            Text("Analizando toda la partida con Stockfish 18")
                        } currentValueLabel: {
                            Text("\(Int((analysis.fullGameProgress * 100).rounded())) %")
                                .font(.caption.monospacedDigit())
                        }

                        Button(role: .destructive) {
                            analysis.cancelFullGameAnalysis()
                        } label: {
                            Label("Detener análisis completo", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            analysis.analyzeFullGame(game)
                        } label: {
                            Label(
                                analysis.fullGameAnalyses.isEmpty ? "Análisis completo" : "Reanalizar partida",
                                systemImage: "chart.xyaxis.line"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isExploring)
                    }

                    Text(analysis.fullGameStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !analysis.fullGameAnalyses.isEmpty {
                        FullGameEvaluationGraph(
                            samples: analysis.fullGameAnalyses,
                            selectedPly: mainlinePlyBinding,
                            totalPly: game.moves.count
                        )
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                        if let selectedAnalysis = analysis.fullGameAnalysis(at: selectedPly) {
                            HStack {
                                Text(selectedPly == 0 ? "Posición inicial" : "Medio movimiento \(selectedPly)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(selectedAnalysis.evaluation.displayText)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                        }

                        Text("La línea central representa 0,00. Una evaluación favorable a blancas hace subir el área blanca sobre la mitad negra; una favorable a negras hace bajar el área negra sobre la mitad blanca. Toca o arrastra sobre la gráfica para saltar a esa posición.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Movimientos") {
                if game.moves.isEmpty {
                    Text("No hay movimientos registrados.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedMoveRows) { row in
                        GameMoveRow(
                            row: row,
                            selectedPly: selectedPly,
                            selectMove: { selectMainline(ply: $0) }
                        )
                    }
                }
            }

            Section("Exportar") {
                Button {
                    exportDocument = PGNFileDocument(text: PGNExporter.pgn(for: game))
                    isExporting = true
                } label: {
                    Label("Guardar archivo PGN", systemImage: "square.and.arrow.down")
                }

                if let shareFileURL {
                    ShareLink(
                        item: shareFileURL,
                        subject: Text("Partida Chessnut Coach"),
                        message: Text("\(game.whitePlayer) – \(game.blackPlayer)")
                    ) {
                        Label("Compartir archivo PGN", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        do {
                            shareFileURL = try PGNShareFile.make(for: game)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        Label("Preparar archivo PGN", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationTitle("Detalle")
        .task {
            if game.status == .finished {
                analysis.analyze(
                    fen: workspace.currentFEN,
                    ply: workspace.currentMainlinePly
                )
            }
        }
        .onDisappear {
            analysis.cancel()
            workspace.cancelAllWork()
        }
        .sheet(isPresented: $isPlaySetupPresented) {
            AnalysisPlaySetupView { configuration in
                workspace.startPlaying(configuration)
            }
        }
        .confirmationDialog(
            "Elige pieza para la promoción",
            isPresented: Binding(
                get: { workspace.promotionRequest != nil },
                set: { if !$0 { workspace.cancelPromotion() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Dama") { workspace.completePromotion(to: .queen) }
            Button("Torre") { workspace.completePromotion(to: .rook) }
            Button("Alfil") { workspace.completePromotion(to: .bishop) }
            Button("Caballo") { workspace.completePromotion(to: .knight) }
            Button("Cancelar", role: .cancel) { workspace.cancelPromotion() }
        }
        .alert(
            "¿Eliminar esta variante?",
            isPresented: Binding(
                get: { branchPendingDeletion != nil },
                set: { if !$0 { branchPendingDeletion = nil } }
            ),
            presenting: branchPendingDeletion
        ) { node in
            Button("Eliminar rama", role: .destructive) {
                workspace.deleteBranch(startingAt: node.id)
                branchPendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) { branchPendingDeletion = nil }
        } message: { _ in
            Text("Se eliminará esta continuación y sus subvariantes. La partida original y las demás ramas no cambiarán.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .portableGameNotation,
            defaultFilename: PGNExporter.suggestedFilename(for: game)
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert("No se pudo exportar", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(exportError ?? "Error desconocido")
        }
    }

    private var mainlinePlyBinding: Binding<Int> {
        Binding(
            get: { selectedPly },
            set: { selectMainline(ply: $0) }
        )
    }

    private var currentChildren: [AnalysisVariationNode] {
        workspace.children(of: workspace.currentReference)
    }

    private var positionCounterText: String {
        if let ply = workspace.currentMainlinePly {
            return "\(ply)/\(game.moves.count)"
        }
        guard case let .variation(nodeID) = workspace.currentReference else { return "—" }
        return "Variante · \(workspace.path(to: nodeID).count) jugadas"
    }

    private var modeSymbol: String {
        switch workspace.mode {
        case .original: "book.closed"
        case .variation: "arrow.triangle.branch"
        case .playingStockfish: "cpu"
        }
    }

    private var modeColor: Color {
        switch workspace.mode {
        case .original: .secondary
        case .variation: .accentColor
        case .playingStockfish: .orange
        }
    }

    private func selectMainline(ply: Int) {
        selectedPly = min(max(0, ply), game.moves.count)
        workspace.selectMainline(ply: selectedPly)
    }

    private var savedMoveRows: [SavedMoveRow] {
        var rows: [SavedMoveRow] = []

        for move in game.moves {
            let notation = moveNotationComponents(for: move)

            if let lastIndex = rows.indices.last,
               rows[lastIndex].moveNumber == notation.moveNumber {
                if notation.isWhiteMove {
                    rows[lastIndex].whiteMove = move
                } else {
                    rows[lastIndex].blackMove = move
                }
            } else {
                rows.append(
                    SavedMoveRow(
                        id: move.id,
                        moveNumber: notation.moveNumber,
                        whiteMove: notation.isWhiteMove ? move : nil,
                        blackMove: notation.isWhiteMove ? nil : move
                    )
                )
            }
        }

        return rows
    }

    private func savedMoveNotation(for move: GameMoveRecord) -> String {
        let notation = moveNotationComponents(for: move)
        let prefix = notation.isWhiteMove ? "\(notation.moveNumber)." : "\(notation.moveNumber)..."
        return "\(prefix) \(move.san)"
    }

    private func moveNotationComponents(for move: GameMoveRecord) -> (moveNumber: Int, isWhiteMove: Bool) {
        let fields = move.fenBefore.split(separator: " ")
        let fallbackMoveNumber = max(1, (move.ply + 1) / 2)
        let moveNumber = fields.count > 5 ? Int(fields[5]) ?? fallbackMoveNumber : fallbackMoveNumber
        let isWhiteMove = fields.count > 1 ? fields[1] != "b" : !move.ply.isMultiple(of: 2)
        return (moveNumber, isWhiteMove)
    }
}

private struct SavedMoveRow: Identifiable {
    let id: UUID
    let moveNumber: Int
    var whiteMove: GameMoveRecord?
    var blackMove: GameMoveRecord?
}

private struct GameMoveRow: View {
    let row: SavedMoveRow
    let selectedPly: Int
    let selectMove: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.whiteMove == nil ? "\(row.moveNumber)..." : "\(row.moveNumber).")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)

            moveCell(row.whiteMove)
            moveCell(row.blackMove)
        }
    }

    @ViewBuilder
    private func moveCell(_ move: GameMoveRecord?) -> some View {
        if let move {
            Button {
                selectMove(move.ply)
            } label: {
                Text(move.san)
                    .font(.body.monospaced())
                    .foregroundColor(selectedPly == move.ply ? .accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalysisBoardView: View {
    let fen: String
    let perspective: ChessBoardPerspective
    let selectedSource: String?
    let legalTargets: [String]
    let isInteractive: Bool
    let onTap: (String) -> Void
    let onMove: (String, String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let squareSize = geometry.size.width / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { displayRank in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { displayFile in
                            let position = perspective.boardPosition(
                                displayRankIndex: displayRank,
                                displayFileIndex: displayFile
                            )
                            let notation = squareNotation(
                                rankIndex: position.rankIndex,
                                fileIndex: position.fileIndex
                            )
                            let isLightSquare = perspective.isLightSquare(
                                displayRankIndex: displayRank,
                                displayFileIndex: displayFile
                            )

                            ZStack {
                                (isLightSquare ? Color.boardLight : Color.boardDark)

                                if selectedSource == notation {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.28))
                                        .overlay {
                                            Rectangle().stroke(Color.accentColor, lineWidth: 2)
                                        }
                                }

                                if let piece = GameReplay.piece(
                                    in: fen,
                                    rankIndex: position.rankIndex,
                                    fileIndex: position.fileIndex
                                ) {
                                    Image(piece.assetName)
                                        .resizable()
                                        .renderingMode(.original)
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: squareSize, height: squareSize)
                                }

                                if legalTargets.contains(notation) {
                                    Circle()
                                        .fill(Color.green.opacity(0.9))
                                        .frame(width: squareSize * 0.22, height: squareSize * 0.22)
                                        .shadow(radius: 1)
                                        .accessibilityHidden(true)
                                }

                                coordinateLabels(
                                    notation: notation,
                                    displayRank: displayRank,
                                    displayFile: displayFile,
                                    isLightSquare: isLightSquare
                                )
                            }
                            .frame(width: squareSize, height: squareSize)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard isInteractive else { return }
                                onTap(notation)
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 10)
                                    .onEnded { value in
                                        let fileOffset = Int((value.translation.width / squareSize).rounded())
                                        let rankOffset = Int((value.translation.height / squareSize).rounded())
                                        let targetDisplayFile = displayFile + fileOffset
                                        let targetDisplayRank = displayRank + rankOffset
                                        guard isInteractive,
                                              (0..<8).contains(targetDisplayFile),
                                              (0..<8).contains(targetDisplayRank)
                                        else { return }

                                        let targetPosition = perspective.boardPosition(
                                            displayRankIndex: targetDisplayRank,
                                            displayFileIndex: targetDisplayFile
                                        )
                                        onMove(
                                            notation,
                                            squareNotation(
                                                rankIndex: targetPosition.rankIndex,
                                                fileIndex: targetPosition.fileIndex
                                            )
                                        )
                                    }
                            )
                            .accessibilityLabel(
                                isInteractive ? "Casilla \(notation)" : "Casilla \(notation), solo lectura"
                            )
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel(isInteractive ? "Tablero de análisis interactivo" : "Tablero de análisis")
    }

    @ViewBuilder
    private func coordinateLabels(
        notation: String,
        displayRank: Int,
        displayFile: Int,
        isLightSquare: Bool
    ) -> some View {
        let labelColor = isLightSquare ? Color.boardDark : Color.boardLight
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if displayFile == 0, let rank = notation.last { Text(String(rank)) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if displayRank == 7, let file = notation.first { Text(String(file)) }
            }
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(labelColor.opacity(0.9))
        .padding(2)
        .accessibilityHidden(true)
    }

    private func squareNotation(rankIndex: Int, fileIndex: Int) -> String {
        let files = Array("abcdefgh")
        return "\(files[fileIndex])\(8 - rankIndex)"
    }
}

private struct AnalysisPlaySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var humanSide = PlayerSide.white
    @State private var stockfishLevel = 4

    let onStart: (AnalysisPlayConfiguration) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Tu color") {
                    Picker("Color", selection: $humanSide) {
                        Text("Blancas").tag(PlayerSide.white)
                        Text("Negras").tag(PlayerSide.black)
                    }
                    .pickerStyle(.segmented)

                    Text("Se respetará el turno del FEN. Si le corresponde jugar a Stockfish, moverá primero automáticamente.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Nivel de Stockfish") {
                    Stepper(
                        value: $stockfishLevel,
                        in: StockfishStrength.minimumLevel...StockfishStrength.maximumLevel
                    ) {
                        LabeledContent("Nivel", value: "\(stockfishLevel)")
                    }

                    Slider(
                        value: Binding(
                            get: { Double(stockfishLevel) },
                            set: { stockfishLevel = Int($0.rounded()) }
                        ),
                        in: Double(StockfishStrength.minimumLevel)...Double(StockfishStrength.maximumLevel),
                        step: 1
                    )

                    HStack {
                        Text("1 · Menor")
                        Spacer()
                        Text("20 · Máxima")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(StockfishStrength(level: stockfishLevel).technicalDetailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Partida de análisis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Empezar") {
                        onStart(
                            AnalysisPlayConfiguration(
                                humanSide: humanSide,
                                strength: StockfishStrength(level: stockfishLevel)
                            )
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct PGNFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.portableGameNotation] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private enum PGNShareFile {
    static func make(for game: GameRecord) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChessnutCoach-PGN", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(PGNExporter.suggestedFilename(for: game))
        try PGNExporter.data(for: game).write(to: url, options: .atomic)
        return url
    }
}

private extension UTType {
    static let portableGameNotation = UTType(
        exportedAs: "com.ivlarac.chessnutcoach.pgn",
        conformingTo: .plainText
    )
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return "\(hours) h \(minutes) min"
    }
    if minutes > 0 {
        return "\(minutes) min \(remainingSeconds) s"
    }
    return "\(remainingSeconds) s"
}

private extension GameLifecycleStatus {
    var displayText: String {
        switch self {
        case .playing: "En juego"
        case .finished: "Finalizada"
        case .aborted: "Cancelada"
        }
    }
}

private extension Color {
    static let boardLight = Color(red: 0.91, green: 0.82, blue: 0.68)
    static let boardDark = Color(red: 0.49, green: 0.34, blue: 0.23)
}

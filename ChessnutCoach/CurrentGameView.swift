import SwiftUI

struct CurrentGameView: View {
    private enum FinishAction: String {
        case resign
        case draw
        case abort
    }

    @ObservedObject var board: BoardController
    @State private var finishAction: FinishAction?
    @State private var isFinishDialogPresented = false
    @State private var isNewGamePresented = false
    @State private var boardPerspective = ChessBoardPerspective.whiteAtBottom
    @State private var automaticBoardRotationEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    gameCard
                    connectionCard
                    screenBoardCard
                    if board.hasActiveGame {
                        assistanceCard
                        historyCard
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chessnut Coach")
            .confirmationDialog(
                finishDialogTitle,
                isPresented: $isFinishDialogPresented,
                titleVisibility: .visible
            ) {
                finishDialogButtons
            }
            .confirmationDialog(
                "Elige pieza para la promoción",
                isPresented: Binding(
                    get: { board.screenPromotionRequest != nil },
                    set: { if !$0 { board.cancelScreenPromotion() } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(ScreenPromotionChoice.allCases) { choice in
                    Button(choice.displayText) {
                        board.completeScreenPromotion(choice)
                    }
                }
                Button("Cancelar", role: .cancel) {
                    board.cancelScreenPromotion()
                }
            }
            .sheet(isPresented: $isNewGamePresented) {
                NewGameSetupView(
                    whitePlayerName: board.whitePlayerName,
                    blackPlayerName: board.blackPlayerName,
                    whiteAssistance: board.whiteAssistanceMode,
                    blackAssistance: board.blackAssistanceMode,
                    isPhysicalBoardConnected: board.isConnected
                ) { launch in
                    automaticBoardRotationEnabled = launch.automaticBoardRotation
                    board.newGame(configuration: launch.configuration)
                    synchronizeInitialBoardPerspective(for: launch.configuration)
                    synchronizeAutomaticBoardPerspective()
                }
            }
            .onChange(of: board.moveCount) { _ in
                synchronizeAutomaticBoardPerspective()
            }
        }
    }

    private var connectionCard: some View {
        CoachCard("Tablero físico", systemImage: "dot.radiowaves.left.and.right") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusPill(
                        text: board.isConnected ? "Conectado" : "Desconectado",
                        systemImage: board.isConnected ? "checkmark.circle.fill" : "circle",
                        color: board.isConnected ? .green : .secondary
                    )
                    Text(board.boardDisplayName)
                        .font(.headline)
                    Text(board.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let battery = board.batteryPercentage {
                    Label("\(battery)%", systemImage: batterySymbol(for: battery))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(battery > 20 ? Color.primary : Color.red)
                }
            }

            if board.isConnected {
                if !board.supportsLEDs {
                    Label(
                        "Este tablero no ofrece LEDs físicos; las ayudas se mostrarán en el tablero virtual.",
                        systemImage: "lightbulb.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    if board.supportsBattery {
                        Button("Actualizar batería") {
                            board.refreshBattery()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Desconectar", role: .destructive) {
                        board.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if board.isScanningForBoards {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Buscando tableros cercanos…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !board.discoveredBoards.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(board.discoveredBoards) { device in
                            Button {
                                board.connect(to: device)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(device.manufacturer)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "link")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Button {
                    board.discoveredBoards.isEmpty ? board.connect() : board.scanForBoards()
                } label: {
                    Label(
                        board.discoveredBoards.isEmpty ? "Buscar tableros" : "Buscar de nuevo",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(board.isScanningForBoards)
            }
        }
    }

    private var screenBoardCard: some View {
        CoachCard("Tablero en pantalla", systemImage: "checkerboard.rectangle") {
            HStack(spacing: 12) {
                Label(
                    screenBoardModeText,
                    systemImage: isScreenBoardInteractive ? "hand.tap" : "eye"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    boardPerspective = boardPerspective.opposite
                } label: {
                    Label("Girar", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Alterna qué color se muestra en la parte inferior")
            }

            OnScreenChessBoard(
                board: board,
                perspective: boardPerspective,
                isInteractive: isScreenBoardInteractive
            )
                .aspectRatio(1, contentMode: .fit)

            if board.isConnected {
                Text("Mueve las piezas únicamente en el tablero físico. El tablero virtual refleja la posición y las ayudas, pero no admite movimientos mientras Bluetooth esté conectado.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if board.hasActiveGame {
                Label(
                    board.isEngineTurn
                        ? "\(board.opponentDisplayName) moverá automáticamente sus piezas cuando termine de calcular."
                        : "Toca una pieza y después su destino, o arrástrala directamente.",
                    systemImage: board.isEngineTurn ? "cpu" : "hand.tap"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("El tablero estará listo para jugar cuando configures una nueva partida.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !board.screenHints.isEmpty {
                Label(
                    "Los puntos verdes reproducen el patrón de ayuda: fijo, parpadeo lento o parpadeo rápido.",
                    systemImage: "circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)
            }
        }
    }

    private var gameCard: some View {
        CoachCard(board.hasActiveGame ? "Partida en curso" : "Partida", systemImage: "flag.checkered") {
            if !board.hasActiveGame {
                emptyGameState
            } else {
                activeGameContent
            }
        }
    }

    private var emptyGameState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkerboard.rectangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.coachAccent)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("No hay ninguna partida en curso")
                    .font(.headline)
                Text("Configura jugadores, rival y ayudas antes de comenzar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                isNewGamePresented = true
            } label: {
                Label("Nueva partida", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Abre la configuración de jugadores y tipo de partida")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var activeGameContent: some View {
        VStack(spacing: 12) {
            playerSummary(
                title: "Blancas",
                name: board.whitePlayerName,
                symbolColor: .white
            )
            Divider()
            playerSummary(
                title: "Negras",
                name: board.blackPlayerName,
                symbolColor: .black
            )
        }

        if board.isSoloGame {
                HStack {
                    StatusPill(
                        text: "Solitario · \(board.humanSide?.displayText ?? "—")",
                        systemImage: "person.fill",
                        color: .coachAccent
                    )
                    Spacer()
                    Text(board.opponentEngineConfiguration?.strengthDisplayText ?? board.opponentDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
        } else {
            StatusPill(
                text: "Contra persona",
                systemImage: "person.2.fill",
                color: .coachAccent
            )
        }

        HStack(spacing: 8) {
                metric(
                    title: "Turno",
                    value: board.hasActiveGame ? board.sideToMoveLabel : "—"
                )
                metric(
                    title: "Tablero",
                    value: board.hasActiveGame
                        ? (!board.isConnected ? "Pantalla" : (board.isBoardSynchronized ? "Listo" : "Moviendo"))
                        : "Sin partida"
                )
                metric(
                    title: "Resultado",
                    value: board.hasActiveGame ? board.gameResultLabel : "No iniciada"
                )
        }

        Text(board.gameStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        if let liftedSquare = board.liftedSquare {
                Label(
                    board.isConnected
                        ? "Pieza levantada: \(liftedSquare)"
                        : "Pieza seleccionada: \(liftedSquare)",
                    systemImage: board.isConnected ? "hand.raised" : "hand.tap"
                )
                .font(.subheadline.weight(.medium))
            }

        if !board.legalTargets.isEmpty {
                Text("Destinos: \(board.legalTargets.joined(separator: ", "))")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

        if board.isPromotionPending {
                Label(
                    board.isConnected
                        ? "Sustituye físicamente el peón por la pieza elegida para completar la promoción."
                        : "Elige en pantalla la pieza a la que quieres promocionar.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

        if board.isEngineThinking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("\(board.opponentDisplayName) está pensando…")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let suggestion = board.engineSuggestion {
                Label(
                    board.isConnected
                        ? "Jugada de \(board.opponentDisplayName): \(suggestion.displayText)"
                        : "\(board.opponentDisplayName): \(suggestion.displayText)",
                    systemImage: "cpu"
                )
                .font(.headline)
                .foregroundStyle(Color.coachAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Jugada de \(board.opponentDisplayName), de \(suggestion.move.from.notation) a \(suggestion.move.to.notation)")
        }

        if board.isUndoAllowed && !board.isGameFinished && board.moveCount > 0 {
                Button {
                    board.undoLastMove()
                } label: {
                    Label("Deshacer última jugada", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!board.canUndoMove)

                Text(
                    board.isConnected
                        ? "También puedes deshacer devolviendo físicamente la última jugada a la posición anterior."
                        : "En modo pantalla el movimiento se deshace inmediatamente."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !board.isGameFinished {
                Menu {
                    Button("Tablas por acuerdo") {
                        presentFinishDialog(.draw)
                    }
                    Button("Rendirse", role: .destructive) {
                        presentFinishDialog(.resign)
                    }
                    Button("Cancelar sin resultado", role: .destructive) {
                        presentFinishDialog(.abort)
                    }
                } label: {
                    Label("Finalizar partida…", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
        }
    }

    private var assistanceCard: some View {
        CoachCard("Ayuda por bando", systemImage: "lightbulb.max.fill") {
            assistancePicker(
                title: "Blancas",
                mode: board.whiteAssistanceMode,
                selection: whiteAssistanceBinding
            )
            .disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .black)

            Divider()

            assistancePicker(
                title: "Negras",
                mode: board.blackAssistanceMode,
                selection: blackAssistanceBinding
            )
            .disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .white)

            if board.isConnected && !board.supportsLEDs {
                Text("Este tablero no puede mostrar ayudas con LEDs físicos; las ayudas configuradas aparecerán como puntos verdes en el tablero virtual.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !board.activeHintSummary.isEmpty {
                Label(board.activeHintSummary, systemImage: "light.beacon.max")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.coachAccent)
            }

            Text("Calidad Stockfish: fijo hasta 50 cp, lento entre 51 y 200 cp y rápido por encima de 200 cp.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var historyCard: some View {
        CoachCard("Últimas jugadas", systemImage: "list.number") {
            if board.moveHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Sin movimientos")
                        .font(.headline)
                    Text("El historial aparecerá al empezar la partida.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(board.moveHistory.suffix(8).enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if board.moveHistory.count > 8 {
                    Text("\(board.moveHistory.count - 8) movimientos anteriores en la partida guardada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func playerSummary(
        title: String,
        name: String,
        symbolColor: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .foregroundStyle(symbolColor)
                .shadow(color: .primary.opacity(0.35), radius: symbolColor == .white ? 1 : 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 62, alignment: .leading)
            Spacer(minLength: 8)
            Text(name)
                .font(.body.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(name)")
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func assistancePicker(
        title: String,
        mode: AssistanceMode,
        selection: Binding<AssistanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Picker("Ayuda para \(title.lowercased())", selection: selection) {
                Text("No").tag(AssistanceMode.off)
                Text("Legales").tag(AssistanceMode.legalMoves)
                Text("Blunder").tag(AssistanceMode.blunders)
                Text("Calidad").tag(AssistanceMode.stockfishQuality)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Ayuda para \(title.lowercased())")
            Text(mode.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var finishDialogButtons: some View {
        switch finishAction {
        case .resign:
            Button("Confirmar abandono", role: .destructive) {
                board.resignCurrentSide()
                finishAction = nil
            }
        case .draw:
            Button("Confirmar tablas") {
                board.agreeDraw()
                finishAction = nil
            }
        case .abort:
            Button("Cancelar partida", role: .destructive) {
                board.abortGame()
                finishAction = nil
            }
        case nil:
            EmptyView()
        }
    }

    private var whiteAssistanceBinding: Binding<AssistanceMode> {
        Binding(
            get: { board.whiteAssistanceMode },
            set: { board.setWhiteAssistanceMode($0) }
        )
    }

    private var blackAssistanceBinding: Binding<AssistanceMode> {
        Binding(
            get: { board.blackAssistanceMode },
            set: { board.setBlackAssistanceMode($0) }
        )
    }

    private var isScreenBoardInteractive: Bool {
        board.hasActiveGame
            && !board.isConnected
            && !board.isEngineTurn
            && !board.isGameFinished
    }

    private var screenBoardModeText: String {
        if board.isConnected { return "Referencia visual · Solo lectura" }
        if !board.hasActiveGame { return "Preparado · Sin partida" }
        if board.isEngineTurn { return "Esperando a \(board.opponentDisplayName)" }
        return "Tablero interactivo"
    }

    private var finishDialogTitle: String {
        switch finishAction {
        case .resign:
            board.isSoloGame
                ? "¿Confirmar que abandonas la partida?"
                : "¿Confirmar que \(board.sideToMoveLabel.lowercased()) abandonan?"
        case .draw:
            "¿Confirmar tablas por acuerdo?"
        case .abort:
            "¿Cancelar esta partida sin resultado?"
        case nil:
            "Finalizar partida"
        }
    }

    private func presentFinishDialog(_ action: FinishAction) {
        finishAction = action
        isFinishDialogPresented = true
    }

    private func synchronizeInitialBoardPerspective(for configuration: NewGameConfiguration) {
        guard configuration.mode == .solo else { return }

        boardPerspective = configuration.humanSide == .black
            ? ChessBoardPerspective.whiteAtBottom.opposite
            : .whiteAtBottom
    }

    private func synchronizeAutomaticBoardPerspective() {
        guard automaticBoardRotationEnabled,
              board.hasActiveGame,
              !board.isSoloGame
        else { return }

        boardPerspective = board.moveCount.isMultiple(of: 2)
            ? .whiteAtBottom
            : ChessBoardPerspective.whiteAtBottom.opposite
    }

    private func batterySymbol(for percentage: Int) -> String {
        switch percentage {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        case 11...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

private struct OnScreenChessBoard: View {
    @ObservedObject var board: BoardController
    let perspective: ChessBoardPerspective
    let isInteractive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            GeometryReader { geometry in
                let squareSize = geometry.size.width / 8
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.25)

                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { displayRank in
                        HStack(spacing: 0) {
                            ForEach(0..<8, id: \.self) { displayFile in
                                let position = perspective.boardPosition(
                                    displayRankIndex: displayRank,
                                    displayFileIndex: displayFile
                                )
                                let notation = board.squareNotation(
                                    rankIndex: position.rankIndex,
                                    fileIndex: position.fileIndex
                                )
                                let hintPattern = board.screenHintPattern(for: notation)
                                let isLightSquare = perspective.isLightSquare(
                                    displayRankIndex: displayRank,
                                    displayFileIndex: displayFile
                                )

                                ZStack {
                                    (isLightSquare ? Self.lightSquare : Self.darkSquare)

                                    if board.liftedSquare == notation {
                                        Rectangle()
                                            .fill(Color.coachAccent.opacity(0.28))
                                            .overlay {
                                                Rectangle()
                                                    .stroke(Color.coachAccent, lineWidth: 2)
                                            }
                                    }

                                    if let piece = GameReplay.piece(
                                        in: board.logicalPlacement,
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

                                    if let hintPattern, hintPattern.isLit(at: tick) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: squareSize * 0.24, height: squareSize * 0.24)
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
                                    board.handleScreenSquareTap(notation)
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
                                            let target = board.squareNotation(
                                                rankIndex: targetPosition.rankIndex,
                                                fileIndex: targetPosition.fileIndex
                                            )
                                            board.handleScreenMove(from: notation, to: target)
                                        }
                                )
                                .accessibilityLabel(
                                    isInteractive
                                        ? "Casilla \(notation)"
                                        : "Casilla \(notation), solo lectura"
                                )
                            }
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
        .accessibilityLabel(
            isInteractive
                ? "Tablero de ajedrez interactivo"
                : "Tablero de ajedrez de referencia, solo lectura"
        )
        .allowsHitTesting(isInteractive)
    }

    @ViewBuilder
    private func coordinateLabels(
        notation: String,
        displayRank: Int,
        displayFile: Int,
        isLightSquare: Bool
    ) -> some View {
        let labelColor = isLightSquare ? Self.darkSquare : Self.lightSquare

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if displayFile == 0, let rank = notation.last {
                    Text(String(rank))
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if displayRank == 7, let file = notation.first {
                    Text(String(file))
                }
            }
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(labelColor.opacity(0.9))
        .padding(2)
        .accessibilityHidden(true)
    }

    private static let lightSquare = Color(red: 0.91, green: 0.82, blue: 0.68)
    private static let darkSquare = Color(red: 0.49, green: 0.34, blue: 0.23)
}

private struct NewGameSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewGameDraft

    let isPhysicalBoardConnected: Bool
    let onStart: (NewGameLaunch) -> Void

    init(
        whitePlayerName: String,
        blackPlayerName: String,
        whiteAssistance: AssistanceMode,
        blackAssistance: AssistanceMode,
        isPhysicalBoardConnected: Bool,
        onStart: @escaping (NewGameLaunch) -> Void
    ) {
        _draft = State(
            initialValue: NewGameDraft(
                whitePlayerName: whitePlayerName,
                blackPlayerName: blackPlayerName,
                whiteAssistance: whiteAssistance,
                blackAssistance: blackAssistance
            )
        )
        self.isPhysicalBoardConnected = isPhysicalBoardConnected
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de partida") {
                    Picker("Rival", selection: $draft.mode) {
                        ForEach(GameMode.allCases) { mode in
                            Text(mode.displayText).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.mode == .solo {
                        Label(
                            isPhysicalBoardConnected
                                ? "Jugarás en el tablero físico; la pantalla mostrará la posición y la respuesta del motor rival."
                                : "Jugarás directamente en el tablero de la pantalla y el motor rival moverá sus piezas automáticamente.",
                            systemImage: "cpu"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            isPhysicalBoardConnected
                                ? "Ambos jugadores moverán en el tablero físico conectado."
                                : "Ambos jugadores moverán directamente en el tablero de la pantalla.",
                            systemImage: "person.2.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if draft.mode == .solo {
                    Section("Motor rival") {
                        Picker("Motor", selection: $draft.opponentEngineKind) {
                            ForEach(OpponentEngineKind.allCases) { engine in
                                HStack {
                                    Text(engine.displayName)
                                    if !engine.isPlayableInThisBuild {
                                        Image(systemName: "lock.fill")
                                    }
                                }
                                .tag(engine)
                            }
                        }

                        Text(draft.opponentEngineKind.styleDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if draft.opponentEngineKind == .maia3 {
                            Label(
                                "No disponible en esta compilación. El código y los pesos oficiales son AGPL-3.0; incorporarlos requiere resolver expresamente la licencia y la distribución de la app.",
                                systemImage: "lock.trianglebadge.exclamationmark"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Jugadores") {
                    if draft.mode == .twoPlayer {
                        playerNameField(
                            title: "Blancas",
                            prompt: "Nombre de blancas",
                            text: $draft.whitePlayerName
                        )
                        playerNameField(
                            title: "Negras",
                            prompt: "Nombre de negras",
                            text: $draft.blackPlayerName
                        )
                    } else {
                        TextField("Tu nombre", text: $draft.humanPlayerName, prompt: Text("Jugador"))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Tu nombre")

                        Picker("Tu color", selection: $draft.sideChoice) {
                            ForEach(HumanSideChoice.allCases) { choice in
                                Text(choice.displayText).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)

                        if draft.sideChoice == .random {
                            Text("El color se sorteará al comenzar.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !draft.canStart {
                        Label(
                            "Introduce un nombre válido para cada jugador.",
                            systemImage: "exclamationmark.circle"
                        )
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if draft.mode == .solo && draft.opponentEngineKind == .stockfish18 {
                    Section("Nivel de Stockfish") {
                        Stepper(
                            value: $draft.stockfishLevel,
                            in: StockfishStrength.minimumLevel...StockfishStrength.maximumLevel
                        ) {
                            LabeledContent("Nivel", value: "\(draft.stockfishLevel)")
                        }

                        Slider(
                            value: Binding(
                                get: { Double(draft.stockfishLevel) },
                                set: { draft.stockfishLevel = Int($0.rounded()) }
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

                        Text(StockfishStrength(level: draft.stockfishLevel).technicalDetailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                } else if draft.mode == .solo && draft.opponentEngineKind == .maia3 {
                    Section("Nivel humano aproximado") {
                        Stepper(
                            value: $draft.maia3Rating,
                            in: Maia3Strength.minimumRating...Maia3Strength.maximumRating,
                            step: Maia3Strength.ratingStep
                        ) {
                            LabeledContent("Rating del modelo", value: "≈ \(draft.maia3Rating)")
                        }

                        Text("Rango previsto: 600–2600 en pasos de 100. No equivale exactamente a rating FIDE, Chess.com o Lichess.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.mode == .solo {
                    Section("Ayuda para ti") {
                        setupAssistancePicker(
                            title: "Tu ayuda",
                            selection: $draft.humanAssistance
                        )

                        Label(
                            soloTurnExplanation,
                            systemImage: "lightbulb.max"
                        )
                        .font(.footnote)
                    }
                } else {
                    Section("Ayuda por bando") {
                        setupAssistancePicker(
                            title: "Blancas",
                            selection: $draft.whiteAssistance
                        )

                        Divider()

                        setupAssistancePicker(
                            title: "Negras",
                            selection: $draft.blackAssistance
                        )
                    }

                    Section("Opciones") {
                        Toggle("Permitir deshacer movimiento", isOn: $draft.allowUndo)

                        Text("Con tablero físico se deshace devolviendo la jugada; en pantalla el cambio es inmediato.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Girar automáticamente por turno", isOn: $draft.automaticBoardRotation)

                        Text("El color al que le toca mover se mostrará abajo. El giro manual seguirá disponible.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Resumen") {
                    LabeledContent("Partida", value: draft.mode.displayText)
                    LabeledContent("Jugadores", value: playersSummary)
                    if draft.mode == .solo {
                        LabeledContent("Motor", value: draft.opponentEngineConfiguration.displayName)
                    }
                    LabeledContent(
                        "Tablero",
                        value: isPhysicalBoardConnected ? "Físico conectado" : "En pantalla"
                    )

                    Button {
                        guard let launch = draft.makeLaunch() else { return }
                        onStart(launch)
                        dismiss()
                    } label: {
                        Label("Comenzar partida", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!draft.canLaunch)
                    .accessibilityHint("Inicia la partida con la configuración mostrada")
                }
            }
            .navigationTitle("Nueva partida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private var soloTurnExplanation: String {
        let opponent = draft.opponentEngineConfiguration.displayName
        switch draft.sideChoice {
        case .white:
            "Después de cada jugada tuya, \(opponent) responderá; en pantalla la respuesta se ejecutará automáticamente."
        case .black:
            "\(opponent) moverá primero; en pantalla su primera jugada se ejecutará automáticamente."
        case .random:
            "Si te corresponden negras, \(opponent) moverá primero. En modo pantalla sus jugadas se ejecutan automáticamente."
        }
    }

    private var playersSummary: String {
        switch draft.mode {
        case .twoPlayer:
            "\(draft.whitePlayerName.trimmingCharacters(in: .whitespacesAndNewlines)) – \(draft.blackPlayerName.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .solo:
            "\(draft.humanPlayerName.trimmingCharacters(in: .whitespacesAndNewlines)) – \(draft.opponentEngineConfiguration.displayName)"
        }
    }

    private func playerNameField(
        title: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Nombre de \(title.lowercased())")
        }
    }

    private func setupAssistancePicker(
        title: String,
        selection: Binding<AssistanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Picker(title, selection: selection) {
                Text("No").tag(AssistanceMode.off)
                Text("Legales").tag(AssistanceMode.legalMoves)
                Text("Blunder").tag(AssistanceMode.blunders)
                Text("Calidad").tag(AssistanceMode.stockfishQuality)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selection.wrappedValue.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

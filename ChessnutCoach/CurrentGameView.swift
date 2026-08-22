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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    connectionCard
                    if !board.isConnected {
                        screenBoardCard
                    }
                    gameCard
                    assistanceCard
                    historyCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chessnut Coach")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNewGamePresented = true
                    } label: {
                        Label("Nueva partida", systemImage: "plus.circle.fill")
                    }
                }
            }
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
                    whiteAssistance: board.whiteAssistanceMode,
                    blackAssistance: board.blackAssistanceMode
                ) { configuration in
                    board.newGame(configuration: configuration)
                }
            }
        }
    }

    private var connectionCard: some View {
        CoachCard(board.boardDisplayName, systemImage: "dot.radiowaves.left.and.right") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusPill(
                        text: board.isConnected ? "Conectado" : "Desconectado",
                        systemImage: board.isConnected ? "checkmark.circle.fill" : "circle",
                        color: board.isConnected ? .green : .secondary
                    )
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
                        "Este tablero no ofrece LEDs; la partida y la detección de jugadas siguen disponibles sin ayudas luminosas.",
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
                .buttonStyle(.borderedProminent)
                .disabled(board.isScanningForBoards)
            }
        }
    }

    private var screenBoardCard: some View {
        CoachCard("Tablero en pantalla", systemImage: "checkerboard.rectangle") {
            OnScreenChessBoard(board: board)
                .aspectRatio(1, contentMode: .fit)

            if board.hasActiveGame {
                Label(
                    board.isEngineTurn
                        ? "Stockfish moverá automáticamente sus piezas cuando termine de calcular."
                        : "Toca una pieza y después su destino, o arrástrala directamente.",
                    systemImage: board.isEngineTurn ? "cpu" : "hand.tap"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("Inicia una partida para jugar directamente aquí mientras el tablero físico esté desconectado.")
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
        CoachCard("Partida actual", systemImage: "checkerboard.rectangle") {
            VStack(spacing: 12) {
                playerField(
                    title: "Blancas",
                    symbolColor: .white,
                    selection: whitePlayerBinding
                )
                .disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .black)
                Divider()
                playerField(
                    title: "Negras",
                    symbolColor: .black,
                    selection: blackPlayerBinding
                )
                .disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .white)
            }

            if !board.hasActiveGame {
                StatusPill(
                    text: "Sin partida iniciada",
                    systemImage: "pause.circle.fill",
                    color: .secondary
                )
            } else if board.isSoloGame {
                HStack {
                    StatusPill(
                        text: "Solitario · \(board.humanSide?.displayText ?? "—")",
                        systemImage: "person.fill",
                        color: .coachAccent
                    )
                    Spacer()
                    Text(board.engineStrength?.displayText ?? "Stockfish")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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

            if board.hasActiveGame, let liftedSquare = board.liftedSquare {
                Label(
                    board.isConnected
                        ? "Pieza levantada: \(liftedSquare)"
                        : "Pieza seleccionada: \(liftedSquare)",
                    systemImage: board.isConnected ? "hand.raised" : "hand.tap"
                )
                .font(.subheadline.weight(.medium))
            }

            if board.hasActiveGame && !board.legalTargets.isEmpty {
                Text("Destinos: \(board.legalTargets.joined(separator: ", "))")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if board.hasActiveGame && board.isPromotionPending {
                Label(
                    board.isConnected
                        ? "Sustituye físicamente el peón por la pieza elegida para completar la promoción."
                        : "Elige en pantalla la pieza a la que quieres promocionar.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if board.hasActiveGame && board.isEngineThinking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Stockfish está pensando…")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if board.hasActiveGame, let suggestion = board.engineSuggestion {
                Label(
                    board.isConnected
                        ? "Jugada de Stockfish: \(suggestion.displayText)"
                        : "Stockfish: \(suggestion.displayText)",
                    systemImage: "cpu"
                )
                .font(.headline)
                .foregroundStyle(Color.coachAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Jugada de Stockfish, de \(suggestion.move.from.notation) a \(suggestion.move.to.notation)")
            }

            Button {
                isNewGamePresented = true
            } label: {
                Label("Nueva partida · Persona o Stockfish", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if board.hasActiveGame && board.isUndoAllowed && !board.isGameFinished && board.moveCount > 0 {
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

            if board.hasActiveGame && !board.isGameFinished {
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
    }

    private var assistanceCard: some View {
        CoachCard("Ayuda por bando", systemImage: "lightbulb.max.fill") {
            assistancePicker(
                title: "Blancas",
                mode: board.whiteAssistanceMode,
                selection: whiteAssistanceBinding
            )
            .disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .black) || (board.isConnected && !board.supportsLEDs))

            Divider()

            assistancePicker(
                title: "Negras",
                mode: board.blackAssistanceMode,
                selection: blackAssistanceBinding
            )
            .disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .white) || (board.isConnected && !board.supportsLEDs))

            if board.isConnected && !board.supportsLEDs {
                Text("Las ayudas por LED no están disponibles con el tablero conectado actualmente.")
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

    private func playerField(
        title: String,
        symbolColor: Color,
        selection: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .foregroundStyle(symbolColor)
                .shadow(color: .primary.opacity(0.35), radius: symbolColor == .white ? 1 : 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 62, alignment: .leading)
            TextField("Jugador", text: selection)
                .textInputAutocapitalization(.words)
                .multilineTextAlignment(.trailing)
        }
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

    private var whitePlayerBinding: Binding<String> {
        Binding(
            get: { board.whitePlayerName },
            set: { board.setWhitePlayerName($0) }
        )
    }

    private var blackPlayerBinding: Binding<String> {
        Binding(
            get: { board.blackPlayerName },
            set: { board.setBlackPlayerName($0) }
        )
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            GeometryReader { geometry in
                let squareSize = geometry.size.width / 8
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.25)

                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { rank in
                        HStack(spacing: 0) {
                            ForEach(0..<8, id: \.self) { file in
                                let notation = board.squareNotation(rankIndex: rank, fileIndex: file)
                                let hintPattern = board.screenHintPattern(for: notation)

                                ZStack {
                                    ((rank + file).isMultiple(of: 2) ? Self.lightSquare : Self.darkSquare)

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
                                        rankIndex: rank,
                                        fileIndex: file
                                    ) {
                                        Text(piece.textSymbol)
                                            .font(.system(size: squareSize * 0.74, design: .serif))
                                            .foregroundStyle(piece.color == .white ? Color.white : Color.black)
                                            .shadow(
                                                color: (piece.color == .white ? Color.black : Color.white).opacity(0.7),
                                                radius: 1
                                            )
                                            .minimumScaleFactor(0.5)
                                    }

                                    if let hintPattern, hintPattern.isLit(at: tick) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: squareSize * 0.24, height: squareSize * 0.24)
                                            .shadow(radius: 1)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(width: squareSize, height: squareSize)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    board.handleScreenSquareTap(notation)
                                }
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 10)
                                        .onEnded { value in
                                            let fileOffset = Int((value.translation.width / squareSize).rounded())
                                            let rankOffset = Int((value.translation.height / squareSize).rounded())
                                            let targetFile = file + fileOffset
                                            let targetRank = rank + rankOffset
                                            guard (0..<8).contains(targetFile),
                                                  (0..<8).contains(targetRank)
                                            else { return }

                                            let target = board.squareNotation(
                                                rankIndex: targetRank,
                                                fileIndex: targetFile
                                            )
                                            board.handleScreenMove(from: notation, to: target)
                                        }
                                )
                                .accessibilityLabel("Casilla \(notation)")
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
        .accessibilityLabel("Tablero de ajedrez interactivo")
    }

    private static let lightSquare = Color(red: 0.91, green: 0.82, blue: 0.68)
    private static let darkSquare = Color(red: 0.49, green: 0.34, blue: 0.23)
}

private struct NewGameSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = GameMode.twoPlayer
    @State private var sideChoice = HumanSideChoice.white
    @State private var stockfishLevel = 4
    @State private var humanAssistance: AssistanceMode
    @State private var whiteAssistance: AssistanceMode
    @State private var blackAssistance: AssistanceMode
    @State private var allowUndo = false

    let onStart: (NewGameConfiguration) -> Void

    init(
        whiteAssistance: AssistanceMode,
        blackAssistance: AssistanceMode,
        onStart: @escaping (NewGameConfiguration) -> Void
    ) {
        _humanAssistance = State(initialValue: whiteAssistance)
        _whiteAssistance = State(initialValue: whiteAssistance)
        _blackAssistance = State(initialValue: blackAssistance)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("¿Contra quién quieres jugar?") {
                    Picker("Rival", selection: $mode) {
                        ForEach(GameMode.allCases) { mode in
                            Text(mode.displayText).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .solo {
                        Label(
                            "Con Chessnut conectado ejecutarás físicamente la jugada indicada. Si está desconectado, Stockfish moverá automáticamente sus piezas en la pantalla.",
                            systemImage: "cpu"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Puedes jugar con ambos bandos en el Chessnut o directamente en el tablero de la pantalla cuando esté desconectado.",
                            systemImage: "person.2.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Permitir deshacer movimiento", isOn: $allowUndo)

                        Text("Con el Chessnut podrás devolver físicamente la jugada; en pantalla se deshará inmediatamente.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if mode == .solo {
                    Section("Tu color") {
                        Picker("Color", selection: $sideChoice) {
                            ForEach(HumanSideChoice.allCases) { choice in
                                Text(choice.displayText).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)

                        if sideChoice == .random {
                            Text("El color se sorteará al pulsar Empezar y se mostrará en la partida actual.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

                    Section("Ayuda para ti") {
                        setupAssistancePicker(
                            title: "Tu ayuda",
                            selection: $humanAssistance
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
                            selection: $whiteAssistance
                        )

                        Divider()

                        setupAssistancePicker(
                            title: "Negras",
                            selection: $blackAssistance
                        )
                    }
                }
            }
            .navigationTitle("Nueva partida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Empezar") {
                        let humanSide = sideChoice.resolvedSide()
                        let assistance = mode == .solo
                            ? AssistanceSettings(
                                white: humanSide == .white ? humanAssistance : .off,
                                black: humanSide == .black ? humanAssistance : .off
                            )
                            : AssistanceSettings(
                                white: whiteAssistance,
                                black: blackAssistance
                            )

                        onStart(
                            NewGameConfiguration(
                                mode: mode,
                                humanSide: humanSide,
                                strength: StockfishStrength(level: stockfishLevel),
                                assistance: assistance,
                                allowUndo: mode == .twoPlayer && allowUndo
                            )
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var soloTurnExplanation: String {
        switch sideChoice {
        case .white:
            "Después de cada jugada tuya, Stockfish responderá; en pantalla la respuesta se ejecutará automáticamente."
        case .black:
            "Stockfish moverá primero; en pantalla su primera jugada se ejecutará automáticamente."
        case .random:
            "Si te corresponden negras, Stockfish moverá primero. En modo pantalla sus jugadas se ejecutan automáticamente."
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

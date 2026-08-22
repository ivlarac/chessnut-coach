import ChessKit
import Combine
import EasyLinkSwiftSDK
import Foundation

struct SoloEngineSuggestion: Equatable, Sendable {
    let move: OTBExpectedMove
    let evaluation: StockfishScore

    var displayText: String { move.displayText }
}

@MainActor
final class BoardController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Desconectado"
    @Published private(set) var boardPlacement = ""
    @Published private(set) var batteryPercentage: Int?

    @Published private(set) var logicalPlacement = OTBGameSession().logicalPlacement
    @Published private(set) var gameStatus = "Conecta el tablero y coloca las piezas en la posición inicial."
    @Published private(set) var sideToMoveLabel = "Blancas"
    @Published private(set) var liftedSquare: String?
    @Published private(set) var legalTargets: [String] = []
    @Published private(set) var lastMove: String?
    @Published private(set) var isBoardSynchronized = false
    @Published private(set) var moveHistory: [String] = []
    @Published private(set) var moveCount = 0
    @Published private(set) var gameResultLabel = "En juego"
    @Published private(set) var isGameFinished = false
    @Published private(set) var isPromotionPending = false
    @Published private(set) var whitePlayerName = "Blancas"
    @Published private(set) var blackPlayerName = "Negras"
    @Published private(set) var gameMode = GameMode.twoPlayer
    @Published private(set) var humanSide: PlayerSide?
    @Published private(set) var engineStrength: StockfishStrength?
    @Published private(set) var engineSuggestion: SoloEngineSuggestion?
    @Published private(set) var isEngineThinking = false

    @Published private(set) var assistanceSettings = AssistanceSettings()
    @Published private(set) var activeHintSummary = ""

    var whiteAssistanceMode: AssistanceMode { assistanceSettings.white }
    var blackAssistanceMode: AssistanceMode { assistanceSettings.black }
    var currentGameID: UUID { gameSession.gameRecord.id }
    var isSoloGame: Bool { gameMode == .solo }
    var isEngineTurn: Bool {
        gameMode == .solo && humanSide?.pieceColor != gameSession.sideToMove && !gameSession.isFinished
    }

    private var client: EasyLinkClient?
    private var connectionTask: Task<Void, Never>?
    private var reconnectionTask: Task<Void, Never>?
    private var disconnectionTask: Task<Void, Never>?
    private var resumeValidationTask: Task<Void, Never>?
    private var fenTask: Task<Void, Never>?
    private var fenDebounceTask: Task<Void, Never>?
    private var ledTask: Task<Void, Never>?
    private var coachingTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var engineMoveTask: Task<Void, Never>?
    private var gameSession = OTBGameSession()
    private let stockfishCoach = StockfishMoveCoach()
    private weak var gameLibrary: GameLibrary?

    private var currentStockfishHints: [StockfishMoveHint] = []
    private var currentStockfishHintFEN: String?
    private var currentStockfishHintSource: Square?
    private var shouldMaintainConnection = false
    private var lifecycle = ChessnutSessionLifecycle()
    private var assistanceGeneration = 0
    private var engineMoveGeneration = 0
    private var physicalSnapshotRevision = 0

    // Chessnut can emit several physical snapshots while a hand is moving a
    // piece. Never let LED writes block consumption of that realtime stream:
    // keep only the newest snapshot and process it after a very short settle.
    private var latestPhysicalPlacement = ""
    private var lastProcessedPlacement = ""
    private let fenSettleDelay: Duration = .milliseconds(100)
    private let ledTickDelay: Duration = .milliseconds(250)
    private let reconnectDelay: Duration = .seconds(2)
    private let resumeSnapshotDelay: Duration = .milliseconds(500)

    private var logicalFEN: String {
        gameSession.board.position.fen
    }

    init(library: GameLibrary? = nil) {
        gameLibrary = library

        if let savedGame = library?.resumableGame,
           let restoredSession = try? OTBGameSession(restoring: savedGame) {
            gameSession = restoredSession
            gameStatus = "Partida recuperada. Conecta el tablero y coloca la posición guardada para continuar."
        }

        publishGameState()
    }

    func connect() {
        shouldMaintainConnection = true
        startConnection(isReconnect: false)
    }

    private func startConnection(isReconnect: Bool) {
        guard shouldMaintainConnection,
              connectionTask == nil,
              !isConnected
        else { return }

        reconnectionTask?.cancel()
        reconnectionTask = nil
        status = isReconnect ? "Reconectando Chessnut Air…" : "Buscando Chessnut Air…"

        connectionTask = Task { [weak self] in
            guard let self else { return }

            let transport = MonitoredEasyLinkTransport(profile: .classic)
            let client = EasyLinkClient(profile: .classic, transport: transport)

            do {
                try await client.connect()
                try await client.enableRealtimeUpdates()

                guard !Task.isCancelled, self.shouldMaintainConnection else {
                    await client.disconnect()
                    return
                }

                self.client = client
                self.isConnected = true
                self.status = isReconnect
                    ? "Reconectado · validando posición del tablero…"
                    : "Conectado · esperando posición del tablero…"
                self.prepareForFreshPhysicalSnapshot()
                self.startDisconnectionStream(transport: transport, client: client)
                self.startFENStream(client: client)
            } catch {
                await client.disconnect()
                guard !Task.isCancelled else { return }
                self.client = nil
                self.isConnected = false
                self.status = "Conexión perdida · nuevo intento en breve"
            }

            self.connectionTask = nil

            if !self.isConnected, self.shouldMaintainConnection {
                self.scheduleReconnect()
            }
        }
    }

    func disconnect() {
        shouldMaintainConnection = false
        connectionTask?.cancel()
        connectionTask = nil
        reconnectionTask?.cancel()
        reconnectionTask = nil
        disconnectionTask?.cancel()
        disconnectionTask = nil
        resumeValidationTask?.cancel()
        resumeValidationTask = nil
        fenTask?.cancel()
        fenTask = nil
        fenDebounceTask?.cancel()
        fenDebounceTask = nil
        ledTask?.cancel()
        ledTask = nil
        cancelEngineMoveRequest(clearSuggestion: false)
        invalidateTransientAssistance(turnOffLEDs: false)

        guard let client else {
            resetConnectionState()
            return
        }

        self.client = nil

        Task { [weak self] in
            try? await client.setLEDs(.allOff)
            await client.disconnect()
            self?.resetConnectionState()
        }
    }

    func handleAppPhase(_ phase: ChessnutAppPhase) {
        let directive = lifecycle.transition(to: phase)

        if directive.invalidateTransientAssistance {
            invalidateTransientAssistance(turnOffLEDs: isConnected)
        }

        if directive.probeConnection, shouldMaintainConnection {
            if isConnected {
                probeConnectionAndRequestFreshSnapshot(
                    shouldRequestSnapshot: directive.requestFreshBoardSnapshot
                )
            } else {
                scheduleReconnect(immediately: true)
            }
        }
    }

    func refreshBattery() {
        guard let client else { return }

        Task { [weak self] in
            await self?.refreshBattery(using: client)
        }
    }

    func newGame(configuration: NewGameConfiguration = NewGameConfiguration()) {
        invalidateTransientAssistance(turnOffLEDs: isConnected)
        cancelEngineMoveRequest(clearSuggestion: true)
        assistanceSettings = configuration.assistance

        let engineName = "Stockfish 18"
        let humanName = normalizedHumanName(
            configuration.humanSide == .white ? whitePlayerName : blackPlayerName
        )
        let white = configuration.mode == .solo
            ? (configuration.humanSide == .white ? humanName : engineName)
            : normalizedNonEnginePlayerName(whitePlayerName, fallback: "Blancas")
        let black = configuration.mode == .solo
            ? (configuration.humanSide == .black ? humanName : engineName)
            : normalizedNonEnginePlayerName(blackPlayerName, fallback: "Negras")
        if !gameSession.isFinished,
           (!gameSession.moves.isEmpty || gameSession.gameRecord.mode == .solo) {
            if gameSession.moves.isEmpty {
                gameLibrary?.delete(gameSession.gameRecord)
            } else {
                gameSession.abort()
                persistCurrentGameIfNeeded()
            }
        }

        gameSession.reset(
            whitePlayer: white,
            blackPlayer: black,
            mode: configuration.mode,
            humanSide: configuration.mode == .solo ? configuration.humanSide : nil,
            engineStrength: configuration.mode == .solo ? configuration.strength : nil,
            engineName: configuration.mode == .solo ? engineName : nil
        )
        lastProcessedPlacement = ""
        activeHintSummary = ""
        publishGameState()
        gameStatus = configuration.mode == .solo
            ? "Partida en solitario preparada. Coloca todas las piezas en la posición inicial."
            : "Nueva partida. Coloca todas las piezas en la posición inicial."
        persistCurrentGameIfNeeded()

        guard let client, !boardPlacement.isEmpty else { return }
        schedulePhysicalPlacement(boardPlacement, client: client, force: true)
    }

    func setWhiteAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.white = mode
        refreshCurrentAssistanceIfNeeded()
        scheduleStockfishPrewarmIfNeeded()
    }

    func setBlackAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.black = mode
        refreshCurrentAssistanceIfNeeded()
        scheduleStockfishPrewarmIfNeeded()
    }

    func setWhitePlayerName(_ name: String) {
        guard !(gameMode == .solo && humanSide == .black) else { return }
        whitePlayerName = name
        gameSession.updatePlayers(white: name, black: blackPlayerName)
        persistCurrentGameIfNeeded()
    }

    func setBlackPlayerName(_ name: String) {
        guard !(gameMode == .solo && humanSide == .white) else { return }
        blackPlayerName = name
        gameSession.updatePlayers(white: whitePlayerName, black: name)
        persistCurrentGameIfNeeded()
    }

    func resignCurrentSide() {
        guard !gameSession.isFinished else { return }
        let resigningColor = gameMode == .solo
            ? (humanSide?.pieceColor ?? gameSession.sideToMove)
            : gameSession.sideToMove
        let result = gameSession.resign(color: resigningColor)
        publishGameState()
        persistCurrentGameIfNeeded()
        gameStatus = result.displayText
        turnOffAutomaticLEDs()
        cancelEngineMoveRequest(clearSuggestion: true)
    }

    func agreeDraw() {
        guard !gameSession.isFinished else { return }
        let result = gameSession.agreeDraw()
        publishGameState()
        persistCurrentGameIfNeeded()
        gameStatus = result.displayText
        turnOffAutomaticLEDs()
        cancelEngineMoveRequest(clearSuggestion: true)
    }

    func abortGame() {
        guard !gameSession.isFinished else { return }
        gameSession.abort()
        publishGameState()
        persistCurrentGameIfNeeded()
        gameStatus = "Partida cancelada sin resultado."
        turnOffAutomaticLEDs()
        cancelEngineMoveRequest(clearSuggestion: true)
    }

    func deleteArchivedGame(_ game: GameRecord) {
        if game.id == gameSession.gameRecord.id {
            invalidateTransientAssistance(turnOffLEDs: isConnected)
            cancelEngineMoveRequest(clearSuggestion: true)
            gameSession.reset(
                whitePlayer: normalizedNonEnginePlayerName(whitePlayerName, fallback: "Blancas"),
                blackPlayer: normalizedNonEnginePlayerName(blackPlayerName, fallback: "Negras")
            )
            lastProcessedPlacement = ""
            publishGameState()
            gameStatus = "Partida borrada. Coloca las piezas en la posición inicial para comenzar otra."
        }

        gameLibrary?.delete(game)
    }

    func squareNotation(rankIndex: Int, fileIndex: Int) -> String {
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return "—" }
        let file = Square.File(fileIndex + 1)
        let rank = Square.Rank(8 - rankIndex)
        return Square(file, rank).notation
    }

    func lightLED(rankIndex: Int, fileIndex: Int) {
        guard let client else { return }
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            var leds = LEDBoard.allOff
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red

            do {
                try await client.setLEDs(leds)
                let notation = self?.squareNotation(rankIndex: rankIndex, fileIndex: fileIndex) ?? "?"
                self?.status = "LED activo en \(notation)"
            } catch is CancellationError {
                // Another board event took priority over the manual test.
            } catch {
                self?.status = "Error LEDs: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    func blinkLED(rankIndex: Int, fileIndex: Int) {
        guard let client else { return }
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            var leds = LEDBoard.allOff
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red

            do {
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    try await client.setLEDs(leds)
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                    try await client.setLEDs(.allOff)
                    try await Task.sleep(for: .milliseconds(300))
                }

                self?.status = "Prueba de parpadeo completada"
            } catch is CancellationError {
                // A newer LED request owns the board now.
            } catch {
                self?.status = "Error parpadeo: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    func demoLEDPatterns() {
        guard let client else { return }

        invalidateTransientAssistance(turnOffLEDs: false)

        let hints = [
            LEDHint(square: .a1, pattern: .steady),
            LEDHint(square: .b1, pattern: .slowBlink),
            LEDHint(square: .c1, pattern: .fastBlink),
        ]

        activeHintSummary = "a1 fijo · b1 lento · c1 rápido"
        status = "Prueba simultánea de patrones LED"
        startLEDHints(hints, client: client)
    }

    func ledsOff() {
        guard let client else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            do {
                try await client.setLEDs(.allOff)
                self?.status = "LEDs apagados"
            } catch {
                self?.status = "Error LEDs: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    private func startDisconnectionStream(
        transport: MonitoredEasyLinkTransport,
        client: EasyLinkClient
    ) {
        disconnectionTask?.cancel()
        disconnectionTask = Task { [weak self] in
            for await event in transport.connectionEvents {
                guard !Task.isCancelled else { return }

                switch event {
                case .disconnected:
                    self?.handleUnexpectedDisconnect(client: client)
                    return
                }
            }
        }
    }

    private func handleUnexpectedDisconnect(client disconnectedClient: EasyLinkClient) {
        guard shouldMaintainConnection,
              let client,
              client === disconnectedClient
        else { return }

        self.client = nil
        isConnected = false
        batteryPercentage = nil
        status = "Chessnut desconectado · reconectando…"

        disconnectionTask?.cancel()
        disconnectionTask = nil
        fenTask?.cancel()
        fenTask = nil
        fenDebounceTask?.cancel()
        fenDebounceTask = nil
        resumeValidationTask?.cancel()
        resumeValidationTask = nil
        invalidateTransientAssistance(turnOffLEDs: false)
        cancelEngineMoveRequest(clearSuggestion: false)
        prepareForFreshPhysicalSnapshot()
        Task {
            await disconnectedClient.disconnect()
        }
        scheduleReconnect()
    }

    private func handleClientFailure(_ error: Error, client failedClient: EasyLinkClient) {
        guard !(error is CancellationError),
              let client,
              client === failedClient
        else { return }

        handleUnexpectedDisconnect(client: failedClient)
    }

    private func scheduleReconnect(immediately: Bool = false) {
        guard shouldMaintainConnection,
              !isConnected,
              connectionTask == nil,
              reconnectionTask == nil
        else { return }

        reconnectionTask = Task { [weak self] in
            guard let self else { return }

            do {
                if !immediately {
                    try await Task.sleep(for: self.reconnectDelay)
                }
                try Task.checkCancellation()
                self.reconnectionTask = nil
                self.startConnection(isReconnect: true)
            } catch is CancellationError {
                // A manual disconnect or a newer connection attempt won.
            } catch {
                self.reconnectionTask = nil
            }
        }
    }

    private func prepareForFreshPhysicalSnapshot() {
        boardPlacement = ""
        latestPhysicalPlacement = ""
        lastProcessedPlacement = ""
        isBoardSynchronized = false
        activeHintSummary = ""
        gameStatus = "Conexión activa. Esperando la posición actual del Chessnut para recuperar la partida."
    }

    private func probeConnectionAndRequestFreshSnapshot(shouldRequestSnapshot: Bool) {
        guard let client else { return }

        resumeValidationTask?.cancel()
        let startingRevision = physicalSnapshotRevision

        resumeValidationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let battery = try await client.batteryStatus(timeout: .seconds(3))
                try Task.checkCancellation()
                guard self.client === client else { return }
                self.batteryPercentage = battery.percentage

                if shouldRequestSnapshot {
                    try await client.enableRealtimeUpdates()
                    try await Task.sleep(for: self.resumeSnapshotDelay)
                    try Task.checkCancellation()
                    guard self.client === client else { return }

                    if self.physicalSnapshotRevision > startingRevision,
                       !self.latestPhysicalPlacement.isEmpty {
                        self.schedulePhysicalPlacement(
                            self.latestPhysicalPlacement,
                            client: client,
                            force: true
                        )
                    } else {
                        self.isBoardSynchronized = false
                        self.status = "Conectado · esperando posición actual del tablero…"
                        self.gameStatus = "Mueve o levanta una pieza para validar la posición física tras volver a la app."
                    }
                }
            } catch is CancellationError {
                // A newer lifecycle transition superseded this validation.
            } catch {
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func startFENStream(client: EasyLinkClient) {
        fenTask?.cancel()
        fenTask = Task { [weak self] in
            for await placement in client.fenUpdates {
                guard !Task.isCancelled else { return }
                self?.receivePhysicalPlacement(placement, client: client)
            }
        }
    }

    private func receivePhysicalPlacement(_ placement: String, client: EasyLinkClient) {
        boardPlacement = placement
        physicalSnapshotRevision += 1

        guard placement != latestPhysicalPlacement else { return }

        latestPhysicalPlacement = placement
        schedulePhysicalPlacement(placement, client: client)
    }

    private func schedulePhysicalPlacement(
        _ placement: String,
        client: EasyLinkClient,
        force: Bool = false
    ) {
        fenDebounceTask?.cancel()

        fenDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.fenSettleDelay ?? .milliseconds(100))
                try Task.checkCancellation()
                guard let self else { return }

                guard force || placement == self.latestPhysicalPlacement else { return }
                guard force || placement != self.lastProcessedPlacement else { return }

                await self.processStablePhysicalPlacement(placement, client: client)
            } catch is CancellationError {
                // Expected whenever a newer physical snapshot supersedes this one.
            } catch {
                self?.gameStatus = "Error procesando el tablero: \(error.localizedDescription)"
            }
        }
    }

    private func processStablePhysicalPlacement(_ placement: String, client: EasyLinkClient) async {
        guard placement == latestPhysicalPlacement else { return }

        lastProcessedPlacement = placement

        invalidateTransientAssistance(turnOffLEDs: false)

        let wasEngineTurn = isEngineTurn
        let physicalPlacement = placement.split(separator: " ").first.map(String.init) ?? placement
        let event: OTBGameEvent
        if wasEngineTurn,
           engineSuggestion == nil,
           physicalPlacement != gameSession.logicalPlacement {
            event = .invalid("Espera a que Stockfish proponga su jugada antes de mover sus piezas.")
        } else {
            event = gameSession.process(
                physicalPlacement: placement,
                requiredMove: wasEngineTurn ? engineSuggestion?.move : nil
            )
        }

        if case .moveCompleted = event, wasEngineTurn {
            cancelEngineMoveRequest(clearSuggestion: true)
        }
        publishGameState()
        if case .moveCompleted = event {
            persistCurrentGameIfNeeded()
        }

        do {
            switch event {
            case .synchronized:
                clearStockfishHints()
                if gameSession.isFinished {
                    gameStatus = gameSession.result.displayText
                } else if gameSession.isPromotionPending {
                    gameStatus = "Promoción pendiente. Sustituye físicamente el peón por la pieza elegida."
                } else {
                    if isEngineTurn {
                        gameStatus = engineSuggestion.map {
                            "Turno de Stockfish: ejecuta \($0.displayText) en el tablero."
                        } ?? "Stockfish está calculando su jugada…"
                    } else {
                        gameStatus = lastMove == nil
                            ? "Tablero sincronizado. Levanta una pieza de las blancas para empezar."
                            : "Movimiento registrado. Turno de \(sideToMoveLabel.lowercased())."
                    }
                }
                try await client.setLEDs(.allOff)
                if isEngineTurn {
                    scheduleEngineMoveIfNeeded(client: client)
                } else {
                    scheduleStockfishPrewarmIfNeeded()
                }

            case let .pieceLifted(source, legalTargets):
                clearStockfishHints()
                if wasEngineTurn, let suggestion = engineSuggestion {
                    gameStatus = "Jugada de Stockfish: lleva \(suggestion.displayText)."
                    activeHintSummary = "Origen fijo · destino intermitente"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else if legalTargets.isEmpty {
                    gameStatus = "\(source.notation) no tiene movimientos legales."
                    try await client.setLEDs(.allOff)
                } else {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)

                    switch mode {
                    case .off:
                        gameStatus = "Pieza levantada en \(source.notation). Ayuda desactivada para \(sideToMoveLabel.lowercased())."
                        try await client.setLEDs(.allOff)

                    case .legalMoves:
                        let hints = AssistanceHintPlanner.hints(for: legalTargets, mode: mode)
                        gameStatus = "Pieza levantada en \(source.notation). LEDs fijos = destinos legales."
                        activeHintSummary = hintSummary(hints)
                        startLEDHints(hints, client: client)

                    case .stockfishQuality, .blunders:
                        gameStatus = "Pieza levantada en \(source.notation). Stockfish 18 está valorando sus destinos…"
                        activeHintSummary = "Stockfish 18 analizando \(source.notation)…"
                        try await client.setLEDs(.allOff)
                        startStockfishCoaching(
                            source: source,
                            legalTargets: legalTargets,
                            mode: mode,
                            client: client
                        )
                    }
                }

            case let .moveCompleted(move):
                clearStockfishHints()
                if gameSession.isFinished {
                    gameStatus = "Registrado \(move.san). \(gameSession.result.displayText)"
                } else {
                    gameStatus = "Registrado \(move.san) (\(move.coordinateNotation)). Turno de \(sideToMoveLabel.lowercased())."
                }
                try await client.setLEDs(.allOff)
                if isEngineTurn {
                    scheduleEngineMoveIfNeeded(client: client)
                } else {
                    scheduleStockfishPrewarmIfNeeded()
                }

            case let .promotionRequired(square, legalKinds):
                clearStockfishHints()
                let pieces = legalKinds.compactMap(\.promotionSymbol).joined(separator: ", ")
                gameStatus = "Promoción en \(square.notation): sustituye el peón por \(pieces)."
                try await client.setLEDs(ledBoard(for: [square]))

            case let .intermediate(message):
                gameStatus = message
                if wasEngineTurn, let suggestion = engineSuggestion {
                    gameStatus = "Completa la jugada de Stockfish \(suggestion.displayText)."
                    activeHintSummary = "Origen fijo · destino intermitente"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else if !gameSession.legalTargets.isEmpty {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)

                    switch mode {
                    case .off:
                        try await client.setLEDs(.allOff)

                    case .legalMoves:
                        let hints = AssistanceHintPlanner.hints(
                            for: gameSession.legalTargets,
                            mode: mode
                        )
                        activeHintSummary = hintSummary(hints)
                        startLEDHints(hints, client: client)

                    case .stockfishQuality, .blunders:
                        if currentStockfishHintFEN == logicalFEN,
                           currentStockfishHintSource == gameSession.liftedSquare,
                           !currentStockfishHints.isEmpty {
                            let hints = currentStockfishHints.compactMap { $0.ledHint(for: mode) }
                            activeHintSummary = stockfishHintSummary(currentStockfishHints, mode: mode)
                            startLEDHints(hints, client: client)
                        } else {
                            try await client.setLEDs(.allOff)
                        }
                    }
                }

            case let .invalid(message):
                clearStockfishHints()
                gameStatus = message
                if wasEngineTurn, let suggestion = engineSuggestion {
                    activeHintSummary = "Stockfish: \(suggestion.displayText)"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else {
                    try await client.setLEDs(.allOff)
                }
            }
        } catch {
            status = "Conexión BLE interrumpida: \(error.localizedDescription)"
            handleClientFailure(error, client: client)
        }
    }

    private func refreshCurrentAssistanceIfNeeded() {
        guard let client,
              let source = gameSession.liftedSquare,
              !gameSession.legalTargets.isEmpty,
              !gameSession.isFinished,
              !isEngineTurn
        else { return }

        invalidateTransientAssistance(turnOffLEDs: false)

        let mode = assistanceSettings.mode(for: gameSession.sideToMove)
        switch mode {
        case .off:
            Task { [weak self] in
                do {
                    try await client.setLEDs(.allOff)
                } catch {
                    self?.handleClientFailure(error, client: client)
                }
            }

        case .legalMoves:
            let hints = AssistanceHintPlanner.hints(for: gameSession.legalTargets, mode: mode)
            activeHintSummary = hintSummary(hints)
            startLEDHints(hints, client: client)

        case .stockfishQuality, .blunders:
            activeHintSummary = "Stockfish 18 analizando \(source.notation)…"
            startStockfishCoaching(
                source: source,
                legalTargets: gameSession.legalTargets,
                mode: mode,
                client: client
            )
        }
    }

    private func scheduleStockfishPrewarmIfNeeded() {
        prewarmTask?.cancel()
        prewarmTask = nil

        guard !gameSession.isFinished,
              !isEngineTurn,
              gameSession.liftedSquare == nil,
              assistanceSettings.mode(for: gameSession.sideToMove).requiresStockfishAnalysis
        else { return }

        let fen = logicalFEN
        let coach = stockfishCoach
        prewarmTask = Task {
            await coach.prepare(fen: fen)
        }
    }

    private func startStockfishCoaching(
        source: Square,
        legalTargets: [Square],
        mode: AssistanceMode,
        client: EasyLinkClient
    ) {
        coachingTask?.cancel()
        clearStockfishHints()

        let fen = logicalFEN
        let coach = stockfishCoach
        let generation = assistanceGeneration

        coachingTask = Task { [weak self] in
            do {
                let result = try await coach.evaluate(
                    fen: fen,
                    source: source,
                    legalTargets: legalTargets
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.gameSession.liftedSquare == source,
                      self.assistanceSettings.mode(for: self.gameSession.sideToMove) == mode,
                      mode.requiresStockfishAnalysis,
                      self.isConnected
                else { return }

                self.currentStockfishHints = result.hints
                self.currentStockfishHintFEN = fen
                self.currentStockfishHintSource = source
                let hints = result.hints.compactMap { $0.ledHint(for: mode) }
                self.activeHintSummary = self.stockfishHintSummary(result.hints, mode: mode)
                self.gameStatus = self.stockfishCoachingStatus(for: mode)
                self.startLEDHints(hints, client: client)
            } catch is CancellationError {
                // The piece was returned/moved or a newer assistance request won.
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.gameSession.liftedSquare == source
                else { return }

                self.clearStockfishHints()
                self.activeHintSummary = ""
                self.gameStatus = "No se pudo analizar \(source.notation) con Stockfish 18: \(error.localizedDescription)"
                do {
                    try await client.setLEDs(.allOff)
                } catch {
                    self.handleClientFailure(error, client: client)
                }
            }
        }
    }

    private func startLEDHints(_ hints: [LEDHint], client: EasyLinkClient) {
        ledTask?.cancel()
        let generation = assistanceGeneration

        guard !hints.isEmpty else {
            activeHintSummary = ""
            return
        }

        let hasBlinkingPattern = hints.contains { $0.pattern != .steady }

        if !hasBlinkingPattern {
            ledTask = Task { [weak self] in
                guard let self else { return }

                do {
                    guard self.assistanceGeneration == generation else { return }
                    try await client.setLEDs(self.ledBoard(for: hints.map(\.square)))
                    guard self.assistanceGeneration == generation else {
                        try await client.setLEDs(.allOff)
                        return
                    }
                } catch is CancellationError {
                    // A newer LED request owns the board now.
                } catch {
                    self.status = "Conectado · error LEDs: \(error.localizedDescription)"
                    self.handleClientFailure(error, client: client)
                }
            }
            return
        }

        ledTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0

            do {
                while !Task.isCancelled {
                    guard self.assistanceGeneration == generation else { return }
                    let activeSquares = LEDHintFrameComposer.activeSquares(for: hints, tick: tick)
                    try await client.setLEDs(self.ledBoard(for: activeSquares))
                    tick += 1
                    try await Task.sleep(for: self.ledTickDelay)
                }
            } catch is CancellationError {
                // The next board state or LED request takes ownership immediately.
            } catch {
                self.status = "Conectado · error patrones LED: \(error.localizedDescription)"
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func scheduleEngineMoveIfNeeded(client: EasyLinkClient) {
        guard isEngineTurn,
              gameSession.isSynchronized,
              engineMoveTask == nil
        else { return }

        if let suggestion = engineSuggestion {
            activeHintSummary = "Stockfish: \(suggestion.displayText)"
            gameStatus = "Turno de Stockfish: ejecuta \(suggestion.displayText) en el tablero."
            startEngineMoveLEDs(suggestion.move, client: client)
            return
        }

        engineMoveGeneration += 1
        let generation = engineMoveGeneration
        let fen = logicalFEN
        let strength = gameSession.gameRecord.engineStrength ?? .full
        isEngineThinking = true
        gameStatus = "Stockfish está calculando su jugada (\(strength.displayText))…"

        engineMoveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.engineMoveGeneration == generation {
                    self.engineMoveTask = nil
                    self.isEngineThinking = false
                }
            }

            do {
                let analysis = try await StockfishEngine.shared.analyze(
                    fen: fen,
                    nodeLimit: 80_000,
                    strength: strength
                )
                try Task.checkCancellation()
                guard self.engineMoveGeneration == generation,
                      self.logicalFEN == fen,
                      self.isEngineTurn,
                      let expectedMove = OTBExpectedMove(uci: analysis.bestMove)
                else { return }

                let suggestion = SoloEngineSuggestion(
                    move: expectedMove,
                    evaluation: analysis.score
                )
                self.engineSuggestion = suggestion
                self.gameStatus = "Turno de Stockfish: ejecuta \(suggestion.displayText) en el tablero."
                self.activeHintSummary = "Stockfish: \(suggestion.displayText) · origen fijo · destino intermitente"
                if self.client === client, self.isConnected {
                    self.startEngineMoveLEDs(expectedMove, client: client)
                }
            } catch is CancellationError {
                // A new game or completed engine move superseded this search.
            } catch {
                guard self.engineMoveGeneration == generation else { return }
                self.gameStatus = "No se pudo obtener la jugada de Stockfish: \(error.localizedDescription)"
            }
        }
    }

    private func startEngineMoveLEDs(_ move: OTBExpectedMove, client: EasyLinkClient) {
        startLEDHints(
            [
                LEDHint(square: move.from, pattern: .steady),
                LEDHint(square: move.to, pattern: .slowBlink),
            ],
            client: client
        )
    }

    private func cancelEngineMoveRequest(clearSuggestion: Bool) {
        engineMoveGeneration += 1
        engineMoveTask?.cancel()
        engineMoveTask = nil
        isEngineThinking = false
        if clearSuggestion {
            engineSuggestion = nil
        }
    }

    private func hintSummary(_ hints: [LEDHint]) -> String {
        hints
            .map { "\($0.square.notation) \($0.pattern.displayText)" }
            .joined(separator: " · ")
    }

    private func stockfishHintSummary(
        _ hints: [StockfishMoveHint],
        mode: AssistanceMode
    ) -> String {
        hints.map { $0.detailText(for: mode) }.joined(separator: " · ")
    }

    private func stockfishCoachingStatus(for mode: AssistanceMode) -> String {
        switch mode {
        case .stockfishQuality:
            "Stockfish 18: fijo = bueno (≤50 cp), lento = aceptable (≤200 cp), rápido = blunder."
        case .blunders:
            "Stockfish 18: destinos legales fijos; blunders (>200 cp) parpadean rápido."
        case .off, .legalMoves:
            ""
        }
    }

    private func clearStockfishHints() {
        currentStockfishHints = []
        currentStockfishHintFEN = nil
        currentStockfishHintSource = nil
    }

    private func invalidateTransientAssistance(turnOffLEDs: Bool) {
        assistanceGeneration += 1
        coachingTask?.cancel()
        coachingTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        ledTask?.cancel()
        ledTask = nil
        clearStockfishHints()
        activeHintSummary = ""

        guard turnOffLEDs, let client else { return }
        let generation = assistanceGeneration

        Task { [weak self] in
            guard let self,
                  self.assistanceGeneration == generation,
                  self.client === client
            else { return }

            do {
                try await client.setLEDs(.allOff)
                guard self.assistanceGeneration == generation else {
                    self.refreshCurrentAssistanceIfNeeded()
                    return
                }
            } catch {
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func ledBoard(for squares: [Square]) -> LEDBoard {
        var leds = LEDBoard.allOff

        for square in squares {
            let rankIndex = 8 - square.rank.value
            let fileIndex = square.file.number - 1
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red
        }

        return leds
    }

    private func publishGameState() {
        logicalPlacement = gameSession.logicalPlacement
        sideToMoveLabel = gameSession.sideToMove == .white ? "Blancas" : "Negras"
        liftedSquare = gameSession.liftedSquare?.notation
        legalTargets = gameSession.legalTargets.map(\.notation).sorted()
        lastMove = gameSession.lastMove.map { "\($0.san) · \($0.coordinateNotation)" }
        isBoardSynchronized = gameSession.isSynchronized
        moveCount = gameSession.moves.count
        moveHistory = formattedMoveHistory(gameSession.moves)
        gameResultLabel = gameSession.result.displayText
        isGameFinished = gameSession.isFinished
        isPromotionPending = gameSession.isPromotionPending
        whitePlayerName = gameSession.gameRecord.whitePlayer
        blackPlayerName = gameSession.gameRecord.blackPlayer
        gameMode = gameSession.gameRecord.mode
        humanSide = gameSession.gameRecord.humanSide
        engineStrength = gameSession.gameRecord.engineStrength
    }

    private func formattedMoveHistory(_ moves: [GameMoveRecord]) -> [String] {
        guard !moves.isEmpty else { return [] }

        var rows: [String] = []
        var index = 0

        while index < moves.count {
            let moveNumber = (index / 2) + 1
            let white = moves[index].san
            let black = index + 1 < moves.count ? moves[index + 1].san : ""
            rows.append("\(moveNumber). \(white)\(black.isEmpty ? "" : "   \(black)")")
            index += 2
        }

        return rows
    }

    private func persistCurrentGameIfNeeded() {
        guard !gameSession.moves.isEmpty || gameSession.gameRecord.mode == .solo else { return }
        gameLibrary?.upsert(gameSession.gameRecord)
    }

    private func normalizedHumanName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("stockfish"),
              trimmed.localizedCaseInsensitiveCompare("Blancas") != .orderedSame,
              trimmed.localizedCaseInsensitiveCompare("Negras") != .orderedSame
        else {
            return "Jugador"
        }
        return trimmed
    }

    private func normalizedNonEnginePlayerName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.localizedCaseInsensitiveContains("stockfish") else {
            return fallback
        }
        return trimmed
    }

    private func turnOffAutomaticLEDs() {
        invalidateTransientAssistance(turnOffLEDs: isConnected)
    }

    private func refreshBattery(using client: EasyLinkClient) async {
        do {
            let battery = try await client.batteryStatus(timeout: .seconds(3))
            batteryPercentage = battery.percentage
        } catch {
            batteryPercentage = nil
        }
    }

    private func resetConnectionState() {
        isConnected = false
        status = "Desconectado"
        boardPlacement = ""
        batteryPercentage = nil
        latestPhysicalPlacement = ""
        lastProcessedPlacement = ""
        physicalSnapshotRevision = 0
        isBoardSynchronized = false
        clearStockfishHints()
        activeHintSummary = ""
        gameStatus = "Conecta el tablero para continuar la partida."
    }
}

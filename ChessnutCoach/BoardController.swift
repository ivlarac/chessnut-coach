import ChessKit
import Combine
import EasyLinkSwiftSDK
import Foundation

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

    @Published private(set) var assistanceSettings = AssistanceSettings()
    @Published private(set) var activeHintSummary = ""

    var whiteAssistanceMode: AssistanceMode { assistanceSettings.white }
    var blackAssistanceMode: AssistanceMode { assistanceSettings.black }

    private var client: EasyLinkClient?
    private var connectionTask: Task<Void, Never>?
    private var fenTask: Task<Void, Never>?
    private var fenDebounceTask: Task<Void, Never>?
    private var ledTask: Task<Void, Never>?
    private var gameSession = OTBGameSession()

    // Chessnut can emit several physical snapshots while a hand is moving a
    // piece. Never let LED writes block consumption of that realtime stream:
    // keep only the newest snapshot and process it after a very short settle.
    private var latestPhysicalPlacement = ""
    private var lastProcessedPlacement = ""
    private let fenSettleDelay: Duration = .milliseconds(100)
    private let ledTickDelay: Duration = .milliseconds(250)

    func connect() {
        guard connectionTask == nil, !isConnected else { return }

        status = "Buscando Chessnut Air…"

        connectionTask = Task { [weak self] in
            guard let self else { return }

            let client = EasyLinkClient(profile: .classic)

            do {
                try await client.connect()
                try await client.enableRealtimeUpdates()

                guard !Task.isCancelled else {
                    await client.disconnect()
                    return
                }

                self.client = client
                self.isConnected = true
                self.status = "Conectado"
                self.startFENStream(client: client)
            } catch {
                await client.disconnect()
                self.client = nil
                self.isConnected = false
                self.status = "Error: \(error.localizedDescription)"
            }

            self.connectionTask = nil
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        fenTask?.cancel()
        fenTask = nil
        fenDebounceTask?.cancel()
        fenDebounceTask = nil
        ledTask?.cancel()
        ledTask = nil
        activeHintSummary = ""

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

    func refreshBattery() {
        guard let client else { return }

        Task { [weak self] in
            await self?.refreshBattery(using: client)
        }
    }

    func newGame() {
        gameSession.reset()
        lastProcessedPlacement = ""
        activeHintSummary = ""
        publishGameState()
        gameStatus = "Nueva partida. Coloca todas las piezas en la posición inicial."

        guard let client, !boardPlacement.isEmpty else { return }
        schedulePhysicalPlacement(boardPlacement, client: client, force: true)
    }

    func setWhiteAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.white = mode
        refreshCurrentAssistanceIfNeeded()
    }

    func setBlackAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.black = mode
        refreshCurrentAssistanceIfNeeded()
    }

    func resignCurrentSide() {
        guard !gameSession.isFinished else { return }
        let resigningColor = gameSession.sideToMove
        let result = gameSession.resign(color: resigningColor)
        publishGameState()
        gameStatus = result.displayText
        turnOffAutomaticLEDs()
    }

    func agreeDraw() {
        guard !gameSession.isFinished else { return }
        let result = gameSession.agreeDraw()
        publishGameState()
        gameStatus = result.displayText
        turnOffAutomaticLEDs()
    }

    func abortGame() {
        guard !gameSession.isFinished else { return }
        gameSession.abort()
        publishGameState()
        gameStatus = "Partida cancelada sin resultado."
        turnOffAutomaticLEDs()
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

        ledTask?.cancel()
        activeHintSummary = ""
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
            }
        }
    }

    func blinkLED(rankIndex: Int, fileIndex: Int) {
        guard let client else { return }
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return }

        ledTask?.cancel()
        activeHintSummary = ""
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
            }
        }
    }

    func demoLEDPatterns() {
        guard let client else { return }

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

        ledTask?.cancel()
        activeHintSummary = ""
        ledTask = Task { [weak self] in
            do {
                try await client.setLEDs(.allOff)
                self?.status = "LEDs apagados"
            } catch {
                self?.status = "Error LEDs: \(error.localizedDescription)"
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

        ledTask?.cancel()
        ledTask = nil
        activeHintSummary = ""

        let event = gameSession.process(physicalPlacement: placement)
        publishGameState()

        do {
            switch event {
            case .synchronized:
                if gameSession.isFinished {
                    gameStatus = gameSession.result.displayText
                } else if gameSession.isPromotionPending {
                    gameStatus = "Promoción pendiente. Sustituye físicamente el peón por la pieza elegida."
                } else {
                    gameStatus = lastMove == nil
                        ? "Tablero sincronizado. Levanta una pieza de las blancas para empezar."
                        : "Movimiento registrado. Turno de \(sideToMoveLabel.lowercased())."
                }
                try await client.setLEDs(.allOff)

            case let .pieceLifted(source, legalTargets):
                if legalTargets.isEmpty {
                    gameStatus = "\(source.notation) no tiene movimientos legales."
                    try await client.setLEDs(.allOff)
                } else {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)
                    let hints = AssistanceHintPlanner.hints(for: legalTargets, mode: mode)

                    switch mode {
                    case .off:
                        gameStatus = "Pieza levantada en \(source.notation). Ayuda desactivada para \(sideToMoveLabel.lowercased())."
                        try await client.setLEDs(.allOff)

                    case .legalMoves:
                        gameStatus = "Pieza levantada en \(source.notation). LEDs fijos = destinos legales."
                        activeHintSummary = hintSummary(hints, includeQuality: false)
                        startLEDHints(hints, client: client)

                    case .simulatedQuality:
                        gameStatus = "Pieza levantada en \(source.notation). Calidad simulada: fijo = mejor, lento = jugable, rápido = evitar."
                        activeHintSummary = hintSummary(hints, includeQuality: true)
                        startLEDHints(hints, client: client)
                    }
                }

            case let .moveCompleted(move):
                if gameSession.isFinished {
                    gameStatus = "Registrado \(move.san). \(gameSession.result.displayText)"
                } else {
                    gameStatus = "Registrado \(move.san) (\(move.coordinateNotation)). Turno de \(sideToMoveLabel.lowercased())."
                }
                try await client.setLEDs(.allOff)

            case let .promotionRequired(square, legalKinds):
                let pieces = legalKinds.compactMap(\.promotionSymbol).joined(separator: ", ")
                gameStatus = "Promoción en \(square.notation): sustituye el peón por \(pieces)."
                try await client.setLEDs(ledBoard(for: [square]))

            case let .intermediate(message):
                gameStatus = message
                if !gameSession.legalTargets.isEmpty {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)
                    let hints = AssistanceHintPlanner.hints(for: gameSession.legalTargets, mode: mode)

                    if hints.isEmpty {
                        try await client.setLEDs(.allOff)
                    } else {
                        activeHintSummary = hintSummary(
                            hints,
                            includeQuality: mode == .simulatedQuality
                        )
                        startLEDHints(hints, client: client)
                    }
                }

            case let .invalid(message):
                gameStatus = message
                try await client.setLEDs(.allOff)
            }
        } catch {
            status = "Conectado · error LEDs: \(error.localizedDescription)"
        }
    }

    private func refreshCurrentAssistanceIfNeeded() {
        guard let client,
              gameSession.liftedSquare != nil,
              !gameSession.legalTargets.isEmpty,
              !gameSession.isFinished
        else { return }

        ledTask?.cancel()
        ledTask = nil
        activeHintSummary = ""

        let mode = assistanceSettings.mode(for: gameSession.sideToMove)
        let hints = AssistanceHintPlanner.hints(for: gameSession.legalTargets, mode: mode)

        if hints.isEmpty {
            Task {
                try? await client.setLEDs(.allOff)
            }
            return
        }

        activeHintSummary = hintSummary(hints, includeQuality: mode == .simulatedQuality)
        startLEDHints(hints, client: client)
    }

    private func startLEDHints(_ hints: [LEDHint], client: EasyLinkClient) {
        ledTask?.cancel()

        guard !hints.isEmpty else {
            activeHintSummary = ""
            return
        }

        let hasBlinkingPattern = hints.contains { $0.pattern != .steady }

        if !hasBlinkingPattern {
            ledTask = Task { [weak self] in
                guard let self else { return }

                do {
                    try await client.setLEDs(self.ledBoard(for: hints.map(\.square)))
                } catch is CancellationError {
                    // A newer LED request owns the board now.
                } catch {
                    self.status = "Conectado · error LEDs: \(error.localizedDescription)"
                }
            }
            return
        }

        ledTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0

            do {
                while !Task.isCancelled {
                    let activeSquares = LEDHintFrameComposer.activeSquares(for: hints, tick: tick)
                    try await client.setLEDs(self.ledBoard(for: activeSquares))
                    tick += 1
                    try await Task.sleep(for: self.ledTickDelay)
                }
            } catch is CancellationError {
                // The next board state or LED request takes ownership immediately.
            } catch {
                self.status = "Conectado · error patrones LED: \(error.localizedDescription)"
            }
        }
    }

    private func hintSummary(_ hints: [LEDHint], includeQuality: Bool) -> String {
        hints.map { hint in
            if includeQuality {
                return "\(hint.square.notation) \(hint.pattern.displayText)/\(hint.pattern.simulatedQualityText)"
            }
            return "\(hint.square.notation) \(hint.pattern.displayText)"
        }
        .joined(separator: " · ")
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

    private func turnOffAutomaticLEDs() {
        activeHintSummary = ""
        guard let client else { return }
        ledTask?.cancel()
        ledTask = Task {
            try? await client.setLEDs(.allOff)
        }
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
        isBoardSynchronized = false
        activeHintSummary = ""
        gameStatus = "Conecta el tablero para continuar la partida."
    }
}

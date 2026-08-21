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

                // Do not query the battery automatically here. The SDK
                // serializes commands and a slow/unsupported battery response
                // could otherwise delay the first LED guidance by seconds.
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
        publishGameState()
        gameStatus = "Nueva partida. Coloca todas las piezas en la posición inicial."

        guard let client, !boardPlacement.isEmpty else { return }
        schedulePhysicalPlacement(boardPlacement, client: client, force: true)
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
                try? await client.setLEDs(.allOff)
            } catch {
                self?.status = "Error parpadeo: \(error.localizedDescription)"
            }
        }
    }

    func ledsOff() {
        guard let client else { return }

        ledTask?.cancel()
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
        // Publish raw hardware state immediately for diagnostics, but do not do
        // any awaited BLE work here. This lets the stream keep draining and
        // prevents stale FEN snapshots from building up behind LED commands.
        boardPlacement = placement
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

                // If another FEN arrived during the settle window, this task is
                // obsolete. Only the newest stable physical position matters.
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

        // Automatic guidance takes priority over any manual LED diagnostic.
        ledTask?.cancel()
        ledTask = nil

        let event = gameSession.process(physicalPlacement: placement)
        publishGameState()

        do {
            switch event {
            case .synchronized:
                gameStatus = lastMove == nil
                    ? "Tablero sincronizado. Levanta una pieza de las blancas para empezar."
                    : "Movimiento registrado. Turno de \(sideToMoveLabel.lowercased())."
                try await client.setLEDs(.allOff)

            case let .pieceLifted(source, legalTargets):
                if legalTargets.isEmpty {
                    gameStatus = "\(source.notation) no tiene movimientos legales."
                    try await client.setLEDs(.allOff)
                } else {
                    gameStatus = "Pieza levantada en \(source.notation). Los LEDs muestran sus destinos legales."
                    try await client.setLEDs(ledBoard(for: legalTargets))
                }

            case let .moveCompleted(move):
                gameStatus = "Registrado \(move.san) (\(move.coordinateNotation)). Turno de \(sideToMoveLabel.lowercased())."
                try await client.setLEDs(.allOff)

            case let .intermediate(message):
                gameStatus = message
                if !gameSession.legalTargets.isEmpty {
                    try await client.setLEDs(ledBoard(for: gameSession.legalTargets))
                }

            case let .invalid(message):
                gameStatus = message
                try await client.setLEDs(.allOff)
            }
        } catch {
            status = "Conectado · error LEDs: \(error.localizedDescription)"
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
        gameStatus = "Conecta el tablero para continuar la partida."
    }
}

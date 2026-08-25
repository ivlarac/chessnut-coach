import Foundation

enum GameTimeCategory: String, Codable, Sendable {
    case bullet
    case blitz
    case rapid
    case classical

    var displayText: String {
        switch self {
        case .bullet: "Bullet"
        case .blitz: "Blitz"
        case .rapid: "Rápida"
        case .classical: "Clásica"
        }
    }
}

enum GameTimeControl: Equatable, Codable, Sendable {
    case unlimited
    case fischer(initialSeconds: Int, incrementSeconds: Int)

    var isTimed: Bool {
        if case .fischer = self { return true }
        return false
    }

    var initialSeconds: Int? {
        guard case let .fischer(initialSeconds, _) = self else { return nil }
        return initialSeconds
    }

    var incrementSeconds: Int? {
        guard case let .fischer(_, incrementSeconds) = self else { return nil }
        return incrementSeconds
    }

    var category: GameTimeCategory? {
        guard case let .fischer(initialSeconds, incrementSeconds) = self else { return nil }
        let estimatedSeconds = initialSeconds + (40 * incrementSeconds)
        return switch estimatedSeconds {
        case ..<180: .bullet
        case ..<600: .blitz
        case ..<1_800: .rapid
        default: .classical
        }
    }

    var notation: String {
        guard case let .fischer(initialSeconds, incrementSeconds) = self else {
            return "Ilimitado"
        }
        return "\(initialSeconds / 60)+\(incrementSeconds)"
    }

    var summaryText: String {
        guard let category else { return notation }
        return "\(notation) · \(category.displayText)"
    }

    var pgnValue: String? {
        guard case let .fischer(initialSeconds, incrementSeconds) = self else { return nil }
        return "\(initialSeconds)+\(incrementSeconds)"
    }
}

enum GameTimeLimits {
    static let initialMinutes = 1...180
    static let incrementSeconds = 0...180

    static func customControl(initialMinutes: Int, incrementSeconds: Int) -> GameTimeControl? {
        guard Self.initialMinutes.contains(initialMinutes),
              Self.incrementSeconds.contains(incrementSeconds)
        else { return nil }
        return .fischer(
            initialSeconds: initialMinutes * 60,
            incrementSeconds: incrementSeconds
        )
    }
}

enum GameTimePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case unlimited
    case oneZero
    case twoOne
    case threeZero
    case threeTwo
    case fiveZero
    case fiveThree
    case tenZero
    case tenFive
    case fifteenTen
    case thirtyZero
    case thirtyTwenty
    case custom

    var id: String { rawValue }

    var timeControl: GameTimeControl? {
        switch self {
        case .unlimited: .unlimited
        case .oneZero: .fischer(initialSeconds: 60, incrementSeconds: 0)
        case .twoOne: .fischer(initialSeconds: 120, incrementSeconds: 1)
        case .threeZero: .fischer(initialSeconds: 180, incrementSeconds: 0)
        case .threeTwo: .fischer(initialSeconds: 180, incrementSeconds: 2)
        case .fiveZero: .fischer(initialSeconds: 300, incrementSeconds: 0)
        case .fiveThree: .fischer(initialSeconds: 300, incrementSeconds: 3)
        case .tenZero: .fischer(initialSeconds: 600, incrementSeconds: 0)
        case .tenFive: .fischer(initialSeconds: 600, incrementSeconds: 5)
        case .fifteenTen: .fischer(initialSeconds: 900, incrementSeconds: 10)
        case .thirtyZero: .fischer(initialSeconds: 1_800, incrementSeconds: 0)
        case .thirtyTwenty: .fischer(initialSeconds: 1_800, incrementSeconds: 20)
        case .custom: nil
        }
    }

    var notation: String {
        switch self {
        case .custom: "Personalizado"
        default: timeControl?.notation ?? "Personalizado"
        }
    }

    var categoryText: String {
        switch self {
        case .unlimited: "Sin reloj"
        case .custom: "Configurable"
        default: timeControl?.category?.displayText ?? ""
        }
    }
}

enum GameClockPauseReason: String, Codable, Sendable {
    case initialSetup
    case engineMoveTransfer
    case undoSynchronization

    var displayText: String {
        switch self {
        case .initialSetup: "Esperando posición inicial"
        case .engineMoveTransfer: "Esperando traslado de la jugada del motor"
        case .undoSynchronization: "Esperando recolocación tras deshacer"
        }
    }
}

struct GameClockSnapshot: Equatable, Codable, Sendable {
    let whiteRemaining: TimeInterval
    let blackRemaining: TimeInterval
    let activeSide: PlayerSide?
    let wasRunning: Bool
    let pauseReason: GameClockPauseReason?
}

/// Materialized clock values immediately after a completed move. Unlike the
/// live clock state, this value never depends on `Date()` and is safe to show
/// later while replaying or analysing the game.
struct GameMoveClockStamp: Equatable, Codable, Sendable {
    let whiteRemaining: TimeInterval
    let blackRemaining: TimeInterval

    func remaining(for side: PlayerSide) -> TimeInterval {
        max(0, side == .white ? whiteRemaining : blackRemaining)
    }
}

struct GameClockState: Equatable, Codable, Sendable {
    let timeControl: GameTimeControl
    private(set) var whiteRemaining: TimeInterval
    private(set) var blackRemaining: TimeInterval
    private(set) var activeSide: PlayerSide?
    private(set) var runningSince: Date?
    private(set) var pauseReason: GameClockPauseReason?
    private(set) var moveSnapshots: [GameClockSnapshot]

    init(timeControl: GameTimeControl) {
        self.timeControl = timeControl
        let initial = TimeInterval(timeControl.initialSeconds ?? 0)
        whiteRemaining = initial
        blackRemaining = initial
        activeSide = nil
        runningSince = nil
        pauseReason = timeControl.isTimed ? .initialSetup : nil
        moveSnapshots = []
    }

    var isEnabled: Bool { timeControl.isTimed }
    var isRunning: Bool { runningSince != nil }

    func remaining(for side: PlayerSide, at date: Date) -> TimeInterval {
        let stored = side == .white ? whiteRemaining : blackRemaining
        guard activeSide == side, let runningSince else { return max(0, stored) }
        return max(0, stored - max(0, date.timeIntervalSince(runningSince)))
    }

    func timedOutSide(at date: Date) -> PlayerSide? {
        guard isEnabled, let activeSide,
              remaining(for: activeSide, at: date) <= 0
        else { return nil }
        return activeSide
    }

    mutating func start(side: PlayerSide = .white, at date: Date) {
        guard isEnabled, timedOutSide(at: date) == nil else { return }
        materialize(at: date)
        activeSide = side
        runningSince = date
        pauseReason = nil
    }

    mutating func pause(at date: Date, reason: GameClockPauseReason) {
        guard isEnabled else { return }
        materialize(at: date)
        runningSince = nil
        pauseReason = reason
    }

    mutating func resume(at date: Date) {
        guard isEnabled, activeSide != nil, timedOutSide(at: date) == nil else { return }
        runningSince = date
        pauseReason = nil
    }

    @discardableResult
    mutating func completeMove(by side: PlayerSide, at date: Date) -> Bool {
        guard isEnabled, activeSide == side else { return false }
        let wasRunning = runningSince != nil
        materialize(at: date)
        guard remaining(for: side, at: date) > 0 else { return false }

        moveSnapshots.append(
            GameClockSnapshot(
                whiteRemaining: whiteRemaining,
                blackRemaining: blackRemaining,
                activeSide: activeSide,
                wasRunning: wasRunning,
                pauseReason: pauseReason
            )
        )

        let increment = TimeInterval(timeControl.incrementSeconds ?? 0)
        if side == .white {
            whiteRemaining += increment
            activeSide = .black
        } else {
            blackRemaining += increment
            activeSide = .white
        }
        runningSince = date
        pauseReason = nil
        return true
    }

    @discardableResult
    mutating func undoLastMove(at date: Date) -> Bool {
        guard let snapshot = moveSnapshots.popLast() else { return false }
        whiteRemaining = max(0, snapshot.whiteRemaining)
        blackRemaining = max(0, snapshot.blackRemaining)
        activeSide = snapshot.activeSide
        pauseReason = snapshot.pauseReason
        runningSince = snapshot.wasRunning ? date : nil
        return true
    }

    mutating func stop(at date: Date) {
        guard isEnabled else { return }
        materialize(at: date)
        activeSide = nil
        runningSince = nil
        pauseReason = nil
    }

    private mutating func materialize(at date: Date) {
        guard let activeSide, let runningSince else { return }
        let elapsed = max(0, date.timeIntervalSince(runningSince))
        if activeSide == .white {
            whiteRemaining = max(0, whiteRemaining - elapsed)
        } else {
            blackRemaining = max(0, blackRemaining - elapsed)
        }
        self.runningSince = date
    }
}

enum GameClockFormatter {
    static func string(for remaining: TimeInterval) -> String {
        let remaining = max(0, remaining)
        if remaining < 10 {
            let tenths = Int((remaining * 10).rounded(.down))
            return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
        }

        let totalSeconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// Adds a short, cancellable presentation delay when a playing engine finds a
/// move faster than a human would reasonably respond. The engine's real search
/// time counts towards this target, and the target shrinks automatically in
/// time trouble so the artificial delay cannot consume the remaining clock.
enum EngineMovePacing {
    static func targetResponseTime(
        timeControl: GameTimeControl,
        remaining: TimeInterval?,
        completedMoveCount: Int
    ) -> TimeInterval {
        let openingFactor = completedMoveCount < 6 ? 0.75 : 1.0
        let nominal: TimeInterval

        switch timeControl {
        case .unlimited:
            nominal = 0.8
        case let .fischer(initialSeconds, incrementSeconds):
            nominal = min(
                4.0,
                max(
                    0.4,
                    (Double(initialSeconds) / 240.0)
                        + (Double(incrementSeconds) * 0.1)
                )
            )
        }

        let phased = nominal * openingFactor
        guard let remaining else { return phased }
        return min(phased, max(0, remaining * 0.15))
    }

    static func additionalDelay(
        timeControl: GameTimeControl,
        remaining: TimeInterval?,
        completedMoveCount: Int,
        computationDuration: TimeInterval
    ) -> TimeInterval {
        max(
            0,
            targetResponseTime(
                timeControl: timeControl,
                remaining: remaining,
                completedMoveCount: completedMoveCount
            ) - max(0, computationDuration)
        )
    }
}

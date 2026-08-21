import EasyLinkSwiftSDK
import Foundation

enum EasyLinkConnectionEvent: Equatable, Sendable {
    case disconnected
}

/// Broadcasts transport disconnections without competing with EasyLinkClient's
/// notification consumer. EasyLinkClient intentionally exposes only FEN updates,
/// while the app also needs the underlying disconnect signal to reconnect.
final class MonitoredEasyLinkTransport: EasyLinkTransport, @unchecked Sendable {
    let notifications: AsyncStream<EasyLinkNotification>
    let connectionEvents: AsyncStream<EasyLinkConnectionEvent>

    private let underlying: EasyLinkTransport
    private let notificationContinuation: AsyncStream<EasyLinkNotification>.Continuation
    private let connectionEventContinuation: AsyncStream<EasyLinkConnectionEvent>.Continuation
    private var forwardingTask: Task<Void, Never>?

    convenience init(profile: BoardProfile, deviceID: UUID? = nil) {
        self.init(
            wrapping: CoreBluetoothEasyLinkTransport(
                profile: profile,
                deviceID: deviceID
            )
        )
    }

    init(wrapping underlying: EasyLinkTransport) {
        self.underlying = underlying

        var notificationContinuation: AsyncStream<EasyLinkNotification>.Continuation!
        notifications = AsyncStream { notificationContinuation = $0 }
        let capturedNotificationContinuation = notificationContinuation!
        self.notificationContinuation = capturedNotificationContinuation

        var connectionEventContinuation: AsyncStream<EasyLinkConnectionEvent>.Continuation!
        connectionEvents = AsyncStream { connectionEventContinuation = $0 }
        let capturedConnectionEventContinuation = connectionEventContinuation!
        self.connectionEventContinuation = capturedConnectionEventContinuation

        forwardingTask = Task { [
            underlying,
            capturedNotificationContinuation,
            capturedConnectionEventContinuation
        ] in
            for await notification in underlying.notifications {
                guard !Task.isCancelled else { return }
                capturedNotificationContinuation.yield(notification)

                if case .disconnected = notification {
                    capturedConnectionEventContinuation.yield(.disconnected)
                }
            }
        }
    }

    deinit {
        forwardingTask?.cancel()
        notificationContinuation.finish()
        connectionEventContinuation.finish()
    }

    func connect() async throws {
        try await underlying.connect()
    }

    func disconnect() async {
        await underlying.disconnect()
    }

    func write(_ command: [UInt8]) async throws {
        try await underlying.write(command)
    }
}

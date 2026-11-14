import Foundation

/// Reconnect delay and the CONNACK time the silent-feed watchdog is allowed to trust.
///
/// CONNACK only means the broker accepted the socket. Resetting the delay there made a
/// refused subscription (SUBACK 0x80) retry the certificate and TLS handshake every 5 s.
/// The delay resets when the subscription is granted or a payload carries device state.
///
/// The watchdog must not keep the previous session's CONNACK time across disconnect or
/// into the next handshake: that age is already past the silence limit, so it would
/// abort the new attempt before this socket reaches CONNACK.
struct MQTTLinkState {
    static let initialDelay: TimeInterval = 5
    static let maxDelay: TimeInterval = 60

    private(set) var reconnectDelay: TimeInterval
    /// Set only after CONNACK of the attempt that is still current. Nil while
    /// disconnected and for the whole handshake of the next attempt.
    private(set) var connectedAt: Date?

    init() {
        reconnectDelay = Self.initialDelay
        connectedAt = nil
    }

    /// Settings save, launch, and wake start the ladder over.
    mutating func resetForNewSession() {
        reconnectDelay = Self.initialDelay
        connectedAt = nil
    }

    /// Call before opening a socket, including when the previous client pointer is already nil.
    mutating func beginAttempt() {
        connectedAt = nil
    }

    /// CONNACK accepted. Does not touch `reconnectDelay`.
    mutating func transportConnected(at date: Date) {
        connectedAt = date
    }

    /// SUBACK granted, or a message that carried device state, on the current client.
    mutating func sessionHealthy() {
        reconnectDelay = Self.initialDelay
    }

    mutating func disconnected() {
        connectedAt = nil
    }

    /// Delay to arm for this reconnect. The next failure waits twice as long, capped at 60 s.
    mutating func takeReconnectDelay() -> TimeInterval {
        let current = reconnectDelay
        reconnectDelay = min(current * 2, Self.maxDelay)
        return current
    }

    /// True only when a client is in hand and its CONNACK time belongs to that same attempt.
    /// A handshake (`clientExists`, no stamp yet) and a cleared stamp must not be judged silent.
    func silentWatchdogShouldReconnect(
        clientExists: Bool,
        now: Date,
        lastDataAt: Date?,
        silentReconnects: Int,
        silentAfter: TimeInterval,
        silentMax: TimeInterval
    ) -> Bool {
        guard clientExists, let connectedAt else { return false }
        return Self.feedIsSilent(
            now: now,
            connectedAt: connectedAt,
            lastDataAt: lastDataAt,
            silentReconnects: silentReconnects,
            silentAfter: silentAfter,
            silentMax: silentMax)
    }

    /// Silence limit doubles per silent reconnect: 3, 6, 12, 24 min, then the 30 min cap.
    /// Measured from the later of CONNACK and the last device payload.
    static func feedIsSilent(
        now: Date,
        connectedAt: Date,
        lastDataAt: Date?,
        silentReconnects: Int,
        silentAfter: TimeInterval,
        silentMax: TimeInterval
    ) -> Bool {
        let steps = min(max(silentReconnects, 0), 8)
        // 2^steps for steps in 0...8. Same ladder as pow(2, steps): 1, 2, 4, …, 256.
        let limit = min(silentAfter * Double(1 << steps), silentMax)
        let since = max(connectedAt, lastDataAt ?? connectedAt)
        return now.timeIntervalSince(since) >= limit
    }
}

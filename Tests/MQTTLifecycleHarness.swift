import Foundation

// Reproducible checks for the two MQTT lifecycle fixes. Foundation only.
// Run from the repo root: make test-mqtt-lifecycle

private let silentAfter: TimeInterval = 180
private let silentMax: TimeInterval = 1800
private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

private func t(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

/// Controller order for SUBACK 0x80: CONNACK does not heal the delay, then the link ends.
private func refusedSubscription(_ link: inout MQTTLinkState, at date: Date) -> TimeInterval {
    link.beginAttempt()
    link.transportConnected(at: date)
    link.disconnected()
    return link.takeReconnectDelay()
}

private func watchdog(_ link: MQTTLinkState, clientExists: Bool, now: Date, lastDataAt: Date?, silentReconnects: Int) -> Bool {
    link.silentWatchdogShouldReconnect(
        clientExists: clientExists,
        now: now,
        lastDataAt: lastDataAt,
        silentReconnects: silentReconnects,
        silentAfter: silentAfter,
        silentMax: silentMax)
}

private func testRefusedSubscriptionBackoff() {
    var link = MQTTLinkState()
    var delays: [TimeInterval] = []
    for i in 0..<6 {
        delays.append(refusedSubscription(&link, at: t(Double(i))))
        check(link.connectedAt == nil, "refusal \(i) leaves no CONNACK stamp")
    }
    check(delays == [5, 10, 20, 40, 60, 60], "refusals back off \(delays), not a flat 5s")

    // Repeating CONNACK on the next attempt still must not collapse the ladder.
    link.beginAttempt()
    link.transportConnected(at: t(100))
    link.transportConnected(at: t(101))
    check(link.reconnectDelay == 60, "CONNACK leaves the capped delay at 60, got \(link.reconnectDelay)")
    check(link.connectedAt == t(101), "CONNACK stamp is the latest accept")
}

private func testHealthResetsBackoff() {
    var link = MQTTLinkState()
    _ = refusedSubscription(&link, at: t(0))
    _ = refusedSubscription(&link, at: t(1))
    check(link.reconnectDelay == 20, "two refusals leave the next delay at 20")

    link.beginAttempt()
    link.transportConnected(at: t(2))
    check(link.reconnectDelay == 20, "CONNACK before SUBACK keeps 20")
    link.sessionHealthy()
    check(link.reconnectDelay == 5, "granted subscription resets to 5")
    link.disconnected()
    check(link.takeReconnectDelay() == 5, "the disconnect after a healthy subscribe waits 5s")
    check(link.reconnectDelay == 10, "that disconnect still advances the next delay to 10")

    link.beginAttempt()
    link.transportConnected(at: t(3))
    link.sessionHealthy()
    check(link.reconnectDelay == 5, "device data resets a delay of 10 back to 5")
}

private func testStaleStampDoesNotAbortHandshake() {
    var link = MQTTLinkState()
    let connected = t(0)
    link.transportConnected(at: connected)
    let lastData = t(30)
    let later = t(600)
    check(watchdog(link, clientExists: true, now: later, lastDataAt: lastData, silentReconnects: 0),
          "a real session with no data for 10 min is silent")

    // onDisconnect.
    link.disconnected()
    check(link.connectedAt == nil, "disconnect clears the CONNACK stamp")
    check(!watchdog(link, clientExists: false, now: later, lastDataAt: lastData, silentReconnects: 0),
          "no client and no stamp is not a silent session")

    // New socket, handshake not at CONNACK yet. This is the window the old stamp used to abort.
    link.beginAttempt()
    check(!watchdog(link, clientExists: true, now: later, lastDataAt: lastData, silentReconnects: 0),
          "handshake with a live client and no stamp is not aborted")

    // Leftover stamp, which onDisconnect used to keep, plus stopMQTTClient returning
    // before clearing because the pointer was already nil.
    var leftover = MQTTLinkState()
    leftover.transportConnected(at: connected)
    check(watchdog(leftover, clientExists: true, now: later, lastDataAt: lastData, silentReconnects: 0),
          "keeping the old stamp would abort the next socket")
    leftover.beginAttempt()
    check(!watchdog(leftover, clientExists: true, now: later, lastDataAt: lastData, silentReconnects: 0),
          "beginAttempt clears a stamp even when the client pointer is already nil")

    link.transportConnected(at: t(610))
    check(!watchdog(link, clientExists: true, now: t(620), lastDataAt: lastData, silentReconnects: 0),
          "silence is measured from the new CONNACK, not the old payload")
    check(watchdog(link, clientExists: true, now: t(610 + 180), lastDataAt: lastData, silentReconnects: 0),
          "the new session is silent only after its own 3 min")
}

private func testSilenceLadder() {
    let up = t(0)
    func silent(_ now: TimeInterval, _ reconnects: Int, _ lastData: TimeInterval?) -> Bool {
        MQTTLinkState.feedIsSilent(
            now: t(now),
            connectedAt: up,
            lastDataAt: lastData.map(t),
            silentReconnects: reconnects,
            silentAfter: silentAfter,
            silentMax: silentMax)
    }
    check(!silent(179, 0, nil), "179s is under the 3 min limit")
    check(silent(180, 0, nil), "180s meets the 3 min limit")
    check(!silent(359, 1, nil), "second silent reconnect waits 6 min")
    check(silent(360, 1, nil), "360s meets the 6 min limit")
    check(!silent(1439, 3, nil), "24 min ladder is not capped yet")
    check(silent(1440, 3, nil), "1440s meets 24 min")
    check(!silent(1799, 4, nil), "30 min cap holds the fifth step")
    check(silent(1800, 4, nil), "1800s meets the 30 min cap")
    check(silent(1800, 8, nil) == silent(1800, 20, nil), "steps past 8 stay on the cap")
    check(!silent(200, 0, 100), "data 100s after CONNACK restarts the 3 min window")
    check(silent(100 + 180, 0, 100), "window ends 3 min after that data")
    check(silent(180, 0, -50), "data from before CONNACK does not extend the window")
}

private func testFreshSessionResets() {
    var link = MQTTLinkState()
    _ = refusedSubscription(&link, at: t(0))
    _ = refusedSubscription(&link, at: t(1))
    link.transportConnected(at: t(2))
    link.resetForNewSession()
    check(link.reconnectDelay == 5, "launch, settings save, and wake start the delay over")
    check(link.connectedAt == nil, "a fresh session has no CONNACK stamp")
}

private func closureBody(_ source: String, startingAt marker: String) -> String? {
    guard let start = source.range(of: marker) else { return nil }
    guard let brace = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var idx = brace.lowerBound
    while idx < source.endIndex {
        let ch = source[idx]
        if ch == "{" { depth += 1 }
        if ch == "}" {
            depth -= 1
            if depth == 0 { return String(source[brace.lowerBound...idx]) }
        }
        idx = source.index(after: idx)
    }
    return nil
}

private func functionBody(_ source: String, named name: String) -> String? {
    guard let start = source.range(of: "func \(name)(") else { return nil }
    guard let brace = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var idx = brace.lowerBound
    while idx < source.endIndex {
        let ch = source[idx]
        if ch == "{" { depth += 1 }
        if ch == "}" {
            depth -= 1
            if depth == 0 { return String(source[brace.lowerBound...idx]) }
        }
        idx = source.index(after: idx)
    }
    return nil
}

private func range(of needle: String, in body: String) -> String.Index? {
    body.range(of: needle)?.lowerBound
}

private func testControllerWiring() {
    let root = FileManager.default.currentDirectoryPath
    let controllerURL = URL(fileURLWithPath: root).appendingPathComponent("Sources/StatusBarController.swift")
    let clientURL = URL(fileURLWithPath: root).appendingPathComponent("Sources/MQTTClient.swift")
    guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
          let client = try? String(contentsOf: clientURL, encoding: .utf8) else {
        check(false, "read Sources from the repo root (cwd is \(root))")
        return
    }

    check(!controller.contains("reconnDelay"), "controller no longer stores reconnDelay")
    check(!controller.contains("mqttConnectedAt"), "controller no longer stores mqttConnectedAt")

    guard let connect = functionBody(controller, named: "startMQTT"),
          let stop = functionBody(controller, named: "stopMQTTClient"),
          let handle = functionBody(controller, named: "handleMQTTMessage"),
          let suback = functionBody(client, named: "subackLocked") else {
        check(false, "locate startMQTT, stopMQTTClient, handleMQTTMessage, subackLocked")
        return
    }

    if let onConnectBody = functionBody(connect, named: "onConnect") ?? closureBody(connect, startingAt: "client.onConnect") {
        check(onConnectBody.contains("transportConnected"), "CONNACK records transportConnected")
        check(!onConnectBody.contains("sessionHealthy"), "CONNACK does not call sessionHealthy")
    } else {
        check(false, "locate the onConnect closure")
    }
    if let begin = range(of: "beginAttempt()", in: connect),
       let assigned = range(of: "mqttClient = client", in: connect),
       let opened = range(of: "client.connect(", in: connect) {
        check(begin < assigned && assigned < opened, "stamp is cleared before the client exists and before connect")
    } else {
        check(false, "startMQTT markers for beginAttempt, assignment, connect")
    }
    if let onConnect = range(of: "client.onConnect", in: connect),
       let onSubscribed = range(of: "client.onSubscribed", in: connect),
       let healthy = range(of: "sessionHealthy()", in: connect) {
        check(onConnect < onSubscribed && onSubscribed < healthy, "sessionHealthy belongs to onSubscribed, after onConnect")
    } else {
        check(false, "onConnect / onSubscribed markers")
    }
    check(connect.contains("mqttClient === client"), "callbacks ignore a client that is no longer current")
    if let cleared = connect.range(of: "disconnected()") {
        let rest = connect[cleared.upperBound...]
        check(rest.contains("guard self.mqttWanted else { return }"),
              "disconnect clears the stamp before the mqttWanted return")
    } else {
        check(false, "onDisconnect clear-before-return markers")
    }

    if let begin = range(of: "beginAttempt()", in: stop),
       let packet = range(of: "lastMQTTPacketAt = nil", in: stop),
       let early = range(of: "guard let c = mqttClient else { return }", in: stop) {
        check(begin < early && packet < early, "nil-client return still drops the CONNACK stamp and packet clock")
    } else {
        check(false, "stopMQTTClient early-return markers")
    }
    check(stop.contains("onSubscribed = nil"), "stop drops the subscribe callback with the others")

    check(handle.contains("sessionHealthy()"), "device data marks the session healthy")
    if let parsed = range(of: "guard let fields", in: handle),
       let healthy = range(of: "sessionHealthy()", in: handle) {
        check(parsed < healthy, "a payload with no device state does not reset the delay")
    } else {
        check(false, "handleMQTTMessage parse-before-healthy markers")
    }

    guard let refusal = suback.range(of: "code == 0x80") else {
        check(false, "SUBACK still treats 0x80 as refusal")
        return
    }
    let refusalBranch = String(suback[refusal.lowerBound..<suback.endIndex])
    guard let elseRange = refusalBranch.range(of: "} else {") else {
        check(false, "SUBACK has a granted branch")
        return
    }
    let refused = String(refusalBranch[..<elseRange.lowerBound])
    let granted = String(refusalBranch[elseRange.upperBound...])
    check(refused.contains("failLocked"), "SUBACK 0x80 still fails the connection")
    check(!refused.contains("onSubscribed"), "SUBACK 0x80 does not report a healthy subscription")
    check(granted.contains("onSubscribed"), "a granted SUBACK reports onSubscribed")
}

@main
enum MQTTLifecycleHarnessMain {
    static func main() {
        testRefusedSubscriptionBackoff()
        testHealthResetsBackoff()
        testStaleStampDoesNotAbortHandshake()
        testSilenceLadder()
        testFreshSessionResets()
        testControllerWiring()

        if failures == 0 {
            print("all mqtt lifecycle checks passed")
        } else {
            print("\(failures) mqtt lifecycle checks failed")
            exit(1)
        }
    }
}

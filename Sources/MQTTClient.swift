import Foundation
import Network

// Minimal MQTT 3.1.1 client — subscribe-only, TLS, no external dependencies.
final class MQTTClient {

    // MARK: – Callbacks (always called on main queue)
    var onMessage:    ((String, [String: Any]) -> Void)?
    var onConnect:    (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onActivity:   (() -> Void)?   // any inbound packet (PUBLISH, PINGRESP, …)

    // MARK: – Private state
    private let io = DispatchQueue(label: "com.efstatus.mqtt")
    private static let maxBuffer = 1_048_576

    private var connection: NWConnection?
    private var pingTimer:  Timer?
    private var buffer =    Data()
    private var nextPktId:  UInt16 = 1
    private var isRunning   = false
    private var didNotifyDisconnect = false

    // MARK: – Configuration (stored for reconnect)
    private(set) var host     = ""
    private(set) var port:    Int = 8883
    private(set) var username = ""
    private(set) var password = ""
    private(set) var clientId = ""
    private let keepAlive:    UInt16 = 60

    // MARK: – Connect / Disconnect

    func connect(host: String, port: Int, username: String, password: String, clientId: String) {
        io.async {
            self.teardownLocked()
            self.host     = host
            self.port     = port
            self.username = username
            self.password = password
            self.clientId = clientId
            self.isRunning = true
            self.didNotifyDisconnect = false
            self.openConnectionLocked()
        }
    }

    private func openConnectionLocked() {
        guard (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            failLocked(NSError(domain: "MQTT", code: 0,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid MQTT port \(port)"]))
            return
        }
        let params   = NWParameters.tls
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.io.async {
                guard self.connection === conn, self.isRunning else { return }
                switch state {
                case .ready:
                    self.sendLocked(self.connectPacket())
                    self.startReceivingLocked(conn)
                case .failed(let err):
                    self.failLocked(err)
                case .cancelled:
                    self.failLocked(nil)
                default: break
                }
            }
        }
        conn.start(queue: io)
    }

    func subscribe(to topic: String) {
        io.async {
            guard self.isRunning else { return }
            let id = self.pktId()
            var pl = Data()
            pl += mqttStr(topic)
            pl.append(0x00)   // QoS 0
            self.sendLocked(self.packet(type: 0x82, varHeader: u16be(id), payload: pl))
        }
    }

    func disconnect() {
        io.async {
            self.isRunning = false
            if self.connection != nil {
                self.sendLocked(Data([0xE0, 0x00]))
            }
            self.didNotifyDisconnect = true   // intentional; do not fire onDisconnect
            self.teardownLocked()
        }
    }

    // MARK: – MQTT CONNECT

    private func connectPacket() -> Data {
        var vh = Data()
        vh += Data([0x00, 0x04]) + Data("MQTT".utf8)  // protocol name
        vh.append(0x04)                                 // protocol level 3.1.1
        vh.append(0xC2)                                 // flags: clean+user+pass
        vh += u16be(keepAlive)

        var pl = Data()
        pl += mqttStr(clientId)
        pl += mqttStr(username)
        pl += mqttStr(password)

        return packet(type: 0x10, varHeader: vh, payload: pl)
    }

    // MARK: – Receive loop

    private func startReceivingLocked(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            self.io.async {
                guard self.connection === conn, self.isRunning else { return }
                if let err {
                    self.failLocked(err)
                    return
                }
                if let data, !data.isEmpty {
                    if self.buffer.count + data.count > Self.maxBuffer {
                        self.failLocked(NSError(domain: "MQTT", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "MQTT receive buffer exceeded"]))
                        return
                    }
                    self.buffer.append(data)
                }
                if !self.processBufferLocked() { return }
                if done {
                    self.failLocked(nil)
                    return
                }
                self.startReceivingLocked(conn)
            }
        }
    }

    /// Returns false when the connection was torn down for a malformed frame.
    @discardableResult
    private func processBufferLocked() -> Bool {
        while buffer.count >= 2 {
            var mul = 1, rem = 0, i = 1
            var lengthComplete = false
            while i < min(5, buffer.count) {
                let b = Int(buffer[i])
                rem += (b & 0x7F) * mul
                mul *= 128
                i += 1
                if b & 0x80 == 0 {
                    lengthComplete = true
                    break
                }
            }
            if i == 5 && !lengthComplete {
                failLocked(NSError(domain: "MQTT", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Malformed MQTT remaining length"]))
                return false
            }
            guard lengthComplete else { return true }

            if rem < 0 || rem > Self.maxBuffer {
                failLocked(NSError(domain: "MQTT", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "MQTT frame exceeds buffer limit"]))
                return false
            }

            let hdrLen = i
            let total  = hdrLen + rem
            guard buffer.count >= total else { return true }

            let pkt = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            dispatchLocked(pkt, hdrLen: hdrLen)
        }
        return true
    }

    private func dispatchLocked(_ pkt: Data, hdrLen: Int) {
        DispatchQueue.main.async { self.onActivity?() }
        switch pkt[0] & 0xF0 {
        case 0x20: connackLocked(pkt)
        case 0x30: publishLocked(pkt, hdrLen: hdrLen)
        case 0x90: break  // SUBACK
        case 0xD0: break  // PINGRESP
        default:   break
        }
    }

    private func connackLocked(_ pkt: Data) {
        guard pkt.count >= 4 else { return }
        if pkt[3] == 0 {
            startPingTimer()
            DispatchQueue.main.async { self.onConnect?() }
        } else {
            let err = NSError(domain: "MQTT", code: Int(pkt[3]),
                              userInfo: [NSLocalizedDescriptionKey: "CONNACK rejected (code \(pkt[3]))"])
            failLocked(err)
        }
    }

    private func publishLocked(_ pkt: Data, hdrLen: Int) {
        var off = hdrLen
        guard pkt.count > off + 1 else { return }
        let topicLen = Int(pkt[off]) << 8 | Int(pkt[off + 1])
        off += 2
        guard topicLen >= 0, pkt.count >= off + topicLen else { return }
        let topic = String(data: pkt[off ..< off + topicLen], encoding: .utf8) ?? ""
        off += topicLen

        // Skip packet ID if QoS > 0
        if (pkt[0] >> 1) & 0x03 > 0 {
            guard pkt.count >= off + 2 else { return }
            off += 2
        }

        guard off <= pkt.count else { return }
        let payload = pkt[off...]

        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        DispatchQueue.main.async { self.onMessage?(topic, json) }
    }

    // MARK: – Keepalive

    private func startPingTimer() {
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(
                withTimeInterval: Double(self.keepAlive) / 2,
                repeats: true
            ) { [weak self] _ in
                self?.io.async { self?.sendLocked(Data([0xC0, 0x00])) }
            }
        }
    }

    // MARK: – Helpers

    private func sendLocked(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    private func failLocked(_ error: Error?) {
        guard isRunning || connection != nil else { return }
        isRunning = false
        teardownLocked()
        notifyDisconnectOnce(error)
    }

    private func notifyDisconnectOnce(_ error: Error?) {
        guard !didNotifyDisconnect else { return }
        didNotifyDisconnect = true
        DispatchQueue.main.async { self.onDisconnect?(error) }
    }

    private func teardownLocked() {
        let conn = connection
        connection = nil
        buffer.removeAll()
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = nil
        }
        conn?.cancel()
    }

    private func packet(type: UInt8, varHeader: Data, payload: Data) -> Data {
        Data([type]) + encLen(varHeader.count + payload.count) + varHeader + payload
    }

    private func encLen(_ n: Int) -> Data {
        var d = Data(), v = n
        repeat {
            var b = UInt8(v % 128); v /= 128
            if v > 0 { b |= 0x80 }
            d.append(b)
        } while v > 0
        return d
    }

    private func pktId() -> UInt16 {
        nextPktId = nextPktId == .max ? 1 : nextPktId + 1
        return nextPktId
    }
}

private func mqttStr(_ s: String) -> Data {
    let bytes = Data(s.utf8)
    let count = min(bytes.count, Int(UInt16.max))
    return u16be(UInt16(count)) + bytes.prefix(count)
}

private func u16be(_ n: UInt16) -> Data { Data([UInt8(n >> 8), UInt8(n & 0xFF)]) }

private func +(l: Data, r: Data) -> Data  { var d = l; d.append(r); return d }
private func +=(l: inout Data, r: Data)   { l.append(r) }

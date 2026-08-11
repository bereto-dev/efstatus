import Foundation
import Network

// Minimal MQTT 3.1.1 client — subscribe-only, TLS, no external dependencies.
final class MQTTClient {

    // MARK: – Callbacks (always called on main queue)
    var onMessage:    ((String, [String: Any]) -> Void)?
    var onConnect:    (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    // MARK: – Private state
    private var connection: NWConnection?
    private var pingTimer:  Timer?
    private var buffer =    Data()
    private var nextPktId:  UInt16 = 1
    private var isRunning   = false

    // MARK: – Configuration (stored for reconnect)
    private(set) var host     = ""
    private(set) var port:    Int = 8883
    private(set) var username = ""
    private(set) var password = ""
    private(set) var clientId = ""
    private let keepAlive:    UInt16 = 60

    // MARK: – Connect / Disconnect

    func connect(host: String, port: Int, username: String, password: String, clientId: String) {
        self.host     = host
        self.port     = port
        self.username = username
        self.password = password
        self.clientId = clientId
        isRunning = true
        openConnection()
    }

    private func openConnection() {
        let params   = NWParameters.tls
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnect()
                self.startReceiving()
            case .failed(let err):
                self.teardown()
                DispatchQueue.main.async { self.onDisconnect?(err) }
            case .cancelled:
                self.teardown()
                DispatchQueue.main.async { self.onDisconnect?(nil) }
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    func subscribe(to topic: String) {
        let id = pktId()
        var pl = Data()
        pl += mqttStr(topic)
        pl.append(0x00)   // QoS 0
        send(packet(type: 0x82, varHeader: u16be(id), payload: pl))
    }

    func disconnect() {
        isRunning = false
        send(Data([0xE0, 0x00]))
        teardown()
    }

    // MARK: – MQTT CONNECT

    private func sendConnect() {
        var vh = Data()
        vh += Data([0x00, 0x04]) + Data("MQTT".utf8)  // protocol name
        vh.append(0x04)                                 // protocol level 3.1.1
        vh.append(0xC2)                                 // flags: clean+user+pass
        vh += u16be(keepAlive)

        var pl = Data()
        pl += mqttStr(clientId)
        pl += mqttStr(username)
        pl += mqttStr(password)

        send(packet(type: 0x10, varHeader: vh, payload: pl))
    }

    // MARK: – Receive loop

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            self.processBuffer()
            if !done && err == nil { self.startReceiving() }
        }
    }

    private func processBuffer() {
        while buffer.count >= 2 {
            // Decode variable remaining-length
            var mul = 1, rem = 0, i = 1
            while i < min(5, buffer.count) {
                let b = Int(buffer[i])
                rem += (b & 0x7F) * mul
                mul *= 128; i += 1
                if b & 0x80 == 0 { break }
                if i == 5 { buffer.removeAll(); return }   // malformed
            }
            let hdrLen  = i
            let total   = hdrLen + rem
            guard buffer.count >= total else { return }

            let pkt = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))   // dropFirst resets startIndex to 0
            dispatch(pkt, hdrLen: hdrLen)
        }
    }

    private func dispatch(_ pkt: Data, hdrLen: Int) {
        switch pkt[0] & 0xF0 {
        case 0x20: connack(pkt)
        case 0x30: publish(pkt, hdrLen: hdrLen)
        case 0x90: break  // SUBACK
        case 0xD0: break  // PINGRESP
        default:   break
        }
    }

    private func connack(_ pkt: Data) {
        guard pkt.count >= 4 else { return }
        if pkt[3] == 0 {
            startPingTimer()
            DispatchQueue.main.async { self.onConnect?() }
        } else {
            let err = NSError(domain: "MQTT", code: Int(pkt[3]),
                              userInfo: [NSLocalizedDescriptionKey: "CONNACK rejected (code \(pkt[3]))"])
            teardown()
            DispatchQueue.main.async { self.onDisconnect?(err) }
        }
    }

    private func publish(_ pkt: Data, hdrLen: Int) {
        var off = hdrLen
        guard pkt.count > off + 1 else { return }
        let topicLen = Int(pkt[off]) << 8 | Int(pkt[off + 1])
        off += 2
        guard pkt.count >= off + topicLen else { return }
        let topic = String(data: pkt[off ..< off + topicLen], encoding: .utf8) ?? ""
        off += topicLen

        // Skip packet ID if QoS > 0
        if (pkt[0] >> 1) & 0x03 > 0 { off += 2 }

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
                self?.send(Data([0xC0, 0x00]))
            }
        }
    }

    // MARK: – Helpers

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    private func teardown() {
        DispatchQueue.main.async { self.pingTimer?.invalidate(); self.pingTimer = nil }
        connection?.cancel()
        connection = nil
        buffer.removeAll()
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

    private func mqttStr(_ s: String) -> Data { u16be(UInt16(s.utf8.count)) + Data(s.utf8) }
    private func u16be(_ n: UInt16) -> Data   { Data([UInt8(n >> 8), UInt8(n & 0xFF)]) }

    private func pktId() -> UInt16 {
        nextPktId = nextPktId == .max ? 1 : nextPktId + 1
        return nextPktId
    }
}

private func +(l: Data, r: Data) -> Data  { var d = l; d.append(r); return d }
private func +=(l: inout Data, r: Data)   { l.append(r) }

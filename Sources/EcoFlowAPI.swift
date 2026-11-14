import Foundation
import CryptoKit

struct EFStatus {
    let inW: Double
    let outW: Double
    let soc: Int?
    let remainWh: Int?
    let capacityWh: Int?
    let deviceLabel: String
    /// Smoothed (inW - outW) used for time estimates so they don't jump with every watt flicker.
    var smoothedNetW: Double? = nil
    /// Per-pack breakdown, filled only when an extra battery is attached (main pack first).
    var packs: [BatteryPack] = []
    /// Net power at the packs (+ charging, − discharging), set only with an extra battery attached:
    /// there, port watts can't tell external power from the transfer between packs.
    var batteryW: Double? = nil

    var socLabel: String { soc.map { "\($0)%" } ?? "—" }
    var socProgress: Double { soc.map { Double($0) / 100.0 } ?? 0 }

    private var netW: Double { smoothedNetW ?? batteryW ?? (inW - outW) }

    var timeToEmptyMin: Int? {
        let net = -netW
        guard let r = remainWh, net > 1 else { return nil }
        return Int(Double(r) / net * 60)
    }

    var timeToFullMin: Int? {
        let net = netW
        guard let r = remainWh, let c = capacityWh, net > 1, c > r else { return nil }
        return Int(Double(c - r) / net * 60)
    }

    func fmtTime(_ min: Int) -> String {
        let h = min / 60, m = min % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var timeLabel: String {
        if let t = timeToFullMin  { return "Full in \(fmtTime(t))" }
        if let t = timeToEmptyMin { return "\(fmtTime(t)) remaining" }
        return inW == 0 ? "No input power" : "Calculating…"
    }

    var hasTimeEstimate: Bool { timeToFullMin != nil || timeToEmptyMin != nil }
}

/// One battery pack: the main unit's built-in pack or an attached extra battery.
struct BatteryPack {
    let name: String
    let soc: Int?
    let remainWh: Int?
    let capacityWh: Int?
}

struct MQTTCredentials {
    let url:      String
    let port:     Int
    let username: String
    let password: String
    let clientId: String
    let topic:    String
}

final class EcoFlowAPI {
    let accessKey: String
    let secretKey: String
    let serial:    String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    init(accessKey: String, secretKey: String, serial: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.serial    = serial
    }

    // MARK: – REST

    /// Every quota key parseStatus can read, across supported models.
    static let relevantKeys: [String] = [
        "pd.wattsInSum", "pd.wattsOutSum", "pd.wattsOut", "pd.soc",
        "inv.inputWatts", "inv.outputWatts", "mppt.inWatts",
        "bms_emsStatus.lcdShowSoc", "bms_bmsStatus.soc",
        "bms_bmsStatus.remainCap", "bms_bmsStatus.designCap", "bms_bmsStatus.vol", "bms_bmsStatus.amp",
        "bmsMaster.f32ShowSoc", "bmsMaster.soc", "bmsMaster.inputWatts", "bmsMaster.outputWatts",
        "cmsBattSoc", "ems.soc", "soc", "powInSumW", "powOutSumW",
        "wattsInSum", "wattsOutSum", "inputWatts", "outputWatts", "inputPower", "outputPower",
    ] + slavePrefixes.flatMap { p in ["soc", "remainCap", "designCap", "vol", "amp"].map { p + $0 } }

    /// Where an attached extra battery reports: bms_slave on a DELTA 2,
    /// bms_slave_bmsSlaveStatus_N on a DELTA 2 Max (up to two extra batteries).
    static let slavePrefixes = ["bms_slave.", "bms_slave_bmsSlaveStatus_1.", "bms_slave_bmsSlaveStatus_2."]

    /// Full quota (~260 fields). Used on connect, manual refresh and diagnostics.
    func fetchAllQuota() async throws -> [String: Any] {
        let json = try await ecoflowJSON(method: "GET", path: "/iot-open/sign/device/quota/all",
                                         query: ["sn": serial])
        return try quotaData(json)
    }

    /// Only the requested keys (~300 bytes instead of ~6.6 KB).
    func fetchQuota(keys: [String]) async throws -> [String: Any] {
        let body: [String: Any] = ["sn": serial, "params": ["quotas": keys]]
        let json = try await ecoflowJSON(method: "POST", path: "/iot-open/sign/device/quota", body: body)
        return try quotaData(json)
    }

    /// Live check used by Setup. Requires a non-empty quota so a wrong SN cannot pass.
    func verifyCredentials() async throws {
        if try await fetchAllQuota().isEmpty {
            throw ecoError(code: 1, message: "No data for this serial number. Check the device SN.")
        }
    }

    private func quotaData(_ json: [String: Any]) throws -> [String: Any] {
        try requireOK(json)
        guard let q = json["data"] as? [String: Any] else { throw ecoError(code: 1, message: "API error") }
        return q
    }

    // MARK: – MQTT credentials

    func fetchMQTTCredentials() async throws -> MQTTCredentials {
        let json = try await ecoflowJSON(method: "GET", path: "/iot-open/sign/certification")
        try requireOK(json)
        guard
            let d        = json["data"] as? [String: Any],
            let url      = d["url"] as? String,
            let port     = Self.intValue(d["port"]),
            let username = d["certificateAccount"] as? String,
            let password = d["certificatePassword"] as? String
        else {
            throw ecoError(code: 2, message: "MQTT certification failed")
        }
        let clientId = "ANDROID_\(username)_\(Int.random(in: 100_000...999_999))"
        let topic    = "/open/\(username)/\(serial)/quota"
        return MQTTCredentials(url: url, port: port, username: username,
                               password: password, clientId: clientId, topic: topic)
    }

    // MARK: – Diagnostics

    func fetchRawFields() async throws -> String {
        let q = try await fetchAllQuota()
        var lines = ["EFStatus Diagnostic — \(serial)", "Fields: \(q.count)", ""]
        for key in q.keys.sorted() {
            if let n = q[key] as? NSNumber { lines.append("\(key): \(n)") }
        }
        lines.append(""); lines.append("Array/object fields:")
        for key in q.keys.sorted() {
            if q[key] is [Any] || q[key] is [String: Any] { lines.append("  \(key)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: – MQTT message normalization

    // The open MQTT feed sends module fields without the REST prefix and names the module
    // in `typeCode`; map them back so MQTT and REST share one key space.
    private static let typeCodePrefix: [String: String] = [
        "pdStatus":   "pd.",
        "invStatus":  "inv.",
        "mpptStatus": "mppt.",
        "bmsStatus":  "bms_bmsStatus.",
        "emsStatus":  "bms_emsStatus.",
        "bmsInfo":    "bms_bmsInfo.",
        "kitInfo":    "bms_kitInfo.",
        "bmsSlaveStatus":   "bms_slave.",
        "bmsSlaveStatus_1": "bms_slave_bmsSlaveStatus_1.",
        "bmsSlaveStatus_2": "bms_slave_bmsSlaveStatus_2.",
    ]

    /// Numeric fields of an MQTT quota message, keyed like the REST quota. Nil for
    /// command/ack messages that carry no device state.
    static func normalizeMQTT(_ json: [String: Any]) -> [String: Any]? {
        guard let params = (json["params"] ?? json["param"]) as? [String: Any] else { return nil }
        let typeCode = json["typeCode"] as? String
        if typeCode == nil && json["instructCode"] != nil { return nil }
        let prefix = typeCode.flatMap { typeCodePrefix[$0] } ?? ""
        var out: [String: Any] = [:]
        for (k, v) in params where v is NSNumber {
            out[k.contains(".") ? k : prefix + k] = v
        }
        return out.isEmpty ? nil : out
    }

    // MARK: – Status parsing (shared by REST and MQTT)

    static func parseStatus(from q: [String: Any]) -> EFStatus {
        func d(_ k: String) -> Double { (q[k] as? NSNumber)?.doubleValue ?? 0 }
        func dOpt(_ keys: String...) -> Double? { keys.compactMap { (q[$0] as? NSNumber)?.doubleValue }.first }

        let soc: Int? = dOpt("bms_emsStatus.lcdShowSoc", "bmsMaster.f32ShowSoc", "bmsMaster.soc",
                             "cmsBattSoc", "pd.soc", "ems.soc", "soc", "bms_bmsStatus.soc").map { Int($0.rounded()) }

        let isDelta2 = q["mppt.inWatts"] != nil || q["inv.inputWatts"] != nil
        let isDelta3 = q["bmsMaster.inputWatts"] != nil || q["powInSumW"] != nil

        var inW: Double
        let outW: Double
        if isDelta2 {
            // pd.wattsInSum is the device's own total of every input (AC + solar + car).
            inW  = dOpt("pd.wattsInSum") ?? (d("mppt.inWatts") + d("inv.inputWatts"))
            outW = dOpt("pd.wattsOutSum", "inv.outputWatts", "pd.wattsOut") ?? 0
        } else if isDelta3 {
            inW  = dOpt("bmsMaster.inputWatts", "powInSumW", "wattsInSum", "inputWatts", "inputPower") ?? 0
            outW = dOpt("bmsMaster.outputWatts", "powOutSumW", "wattsOutSum", "outputWatts", "outputPower") ?? 0
        } else {
            inW  = dOpt("pd.wattsInSum") ?? 0
            outW = dOpt("pd.wattsOutSum") ?? 0
        }

        // Wh from BMS mAh × mV
        let vol      = dOpt("bms_bmsStatus.vol")
        var remainWh = zip2(dOpt("bms_bmsStatus.remainCap"), vol).map { Int($0 * $1 / 1_000_000) }
        var capWh    = zip2(dOpt("bms_bmsStatus.designCap"), vol).map { Int($0 * $1 / 1_000_000) }

        // Extra batteries report through the main unit. A pack counts only when it reports a real
        // capacity and voltage, so a missing or zeroed slave leaves the main-only numbers untouched.
        var extras: [BatteryPack] = []
        var extraPrefixes: [String] = []
        for p in slavePrefixes {
            guard let design = dOpt(p + "designCap"), design > 0,
                  let v = dOpt(p + "vol"), v > 0 else { continue }
            let cap  = Int(design * v / 1_000_000)
            let pSoc = dOpt(p + "soc").map { Int($0.rounded()) }
            let rem  = dOpt(p + "remainCap").map { Int($0 * v / 1_000_000) } ?? pSoc.map { cap * $0 / 100 }
            extras.append(BatteryPack(name: "EXTRA", soc: pSoc, remainWh: rem, capacityWh: cap))
            extraPrefixes.append(p)
        }
        var packs: [BatteryPack] = []
        if !extras.isEmpty, let mainRem = remainWh, let mainCap = capWh,
           extras.allSatisfy({ $0.remainWh != nil }) {
            if extras.count > 1 {
                extras = extras.enumerated().map { i, e in
                    BatteryPack(name: "EXTRA \(i + 1)", soc: e.soc, remainWh: e.remainWh, capacityWh: e.capacityWh)
                }
            }
            let mainSoc = dOpt("bms_bmsStatus.soc").map { Int($0.rounded()) }
            packs    = [BatteryPack(name: "MAIN", soc: mainSoc, remainWh: mainRem, capacityWh: mainCap)] + extras
            remainWh = packs.reduce(0) { $0 + ($1.remainWh ?? 0) }
            capWh    = packs.reduce(0) { $0 + ($1.capacityWh ?? 0) }
        }

        var batteryW: Double? = nil
        if !packs.isEmpty {
            // A discharging DELTA 2 counts what the extra battery feeds it as input: on battery,
            // pd.wattsInSum read 74 W, exactly bms_slave.outputWatts, with AC and solar at 0 W.
            // Read the external ports instead. Each is measured directly, so no pair of messages
            // arriving out of step can fake input during an outage.
            if isDelta2 && extraPrefixes.contains("bms_slave.") {
                inW = d("inv.inputWatts") + d("mppt.inWatts")
            }
            // Time estimates from the packs' own net power (mA × mV): it covers every pack and the
            // inverter's losses. Port watts stay the fallback if any pack lacks current or voltage.
            let flows = (["bms_bmsStatus."] + extraPrefixes).map { p in
                zip2(dOpt(p + "amp"), dOpt(p + "vol")).map { $0.0 * $0.1 / 1_000_000 }
            }
            if !flows.contains(where: { $0 == nil }) { batteryW = flows.reduce(0) { $0 + ($1 ?? 0) } }
        }

        let deviceLabel = isDelta3 ? "DELTA 3" : isDelta2 ? "DELTA 2" : "ECOFLOW"

        return EFStatus(inW: inW, outW: outW, soc: soc,
                        remainWh: remainWh, capacityWh: capWh, deviceLabel: deviceLabel,
                        packs: packs, batteryW: batteryW)
    }

    private static func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    // MARK: – Transport

    private func ecoflowJSON(method: String, path: String,
                             query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        let req = try signedRequest(method: method, path: path, query: query, body: body)
        let (data, response) = try await Self.session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let apiMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ecoError(code: http.statusCode, message: apiMsg ?? "EcoFlow HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ecoError(code: 1, message: "Invalid EcoFlow response")
        }
        return json
    }

    private func requireOK(_ json: [String: Any]) throws {
        let ok: Bool
        if let s = json["code"] as? String {
            ok = s == "0"
        } else if let n = json["code"] as? NSNumber {
            ok = n.intValue == 0
        } else {
            ok = false
        }
        guard ok else {
            throw ecoError(code: 1, message: (json["message"] as? String) ?? "API error")
        }
    }

    private func ecoError(code: Int, message: String) -> NSError {
        NSError(domain: "EcoFlow", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let s = raw as? String { return Int(s) }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: – Signing

    // EcoFlow signs "k=v&…" of every query/body parameter (flattened, ASCII-sorted),
    // followed by accessKey, nonce and timestamp. Requests that omit them are rejected.
    private func signedRequest(method: String, path: String,
                               query: [String: String], body: [String: Any]?) throws -> URLRequest {
        var comps = URLComponents(string: "https://api.ecoflow.com\(path)")
        if !query.isEmpty {
            comps?.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = comps?.url else { throw URLError(.badURL) }

        var pairs = query.map { ($0.key, $0.value) }
        if let body { Self.flatten(body, prefix: "", into: &pairs) }
        let params = pairs.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }

        let nonce     = String(Int.random(in: 100_000...999_999))
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let raw = (params + ["accessKey=\(accessKey)", "nonce=\(nonce)", "timestamp=\(timestamp)"])
            .joined(separator: "&")

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue(accessKey, forHTTPHeaderField: "accessKey")
        req.setValue(nonce,     forHTTPHeaderField: "nonce")
        req.setValue(timestamp, forHTTPHeaderField: "timestamp")
        req.setValue(hmac(key: secretKey, data: raw), forHTTPHeaderField: "sign")
        if let body {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static func flatten(_ value: Any, prefix: String, into out: inout [(String, String)]) {
        switch value {
        case let dict as [String: Any]:
            for (k, v) in dict { flatten(v, prefix: prefix.isEmpty ? k : "\(prefix).\(k)", into: &out) }
        case let arr as [Any]:
            for (i, v) in arr.enumerated() { flatten(v, prefix: "\(prefix)[\(i)]", into: &out) }
        default:
            out.append((prefix, "\(value)"))
        }
    }

    private func hmac(key: String, data: String) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac    = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

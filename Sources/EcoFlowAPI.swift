import Foundation
import CryptoKit

struct EFStatus {
    let inW: Double
    let outW: Double
    let soc: Int
    let remainWh: Int?
    let capacityWh: Int?
    let deviceLabel: String

    var timeToEmptyMin: Int? {
        let net = outW - inW
        guard let r = remainWh, net > 0 else { return nil }
        return Int(Double(r) / net * 60)
    }

    var timeToFullMin: Int? {
        let net = inW - outW
        guard let r = remainWh, let c = capacityWh, net > 0 else { return nil }
        return Int(Double(c - r) / net * 60)
    }

    func fmtTime(_ min: Int) -> String {
        let h = min / 60, m = min % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var timeLabel: String {
        if let t = timeToFullMin  { return "⚡ Full in \(fmtTime(t))" }
        if let t = timeToEmptyMin { return "🔋 \(fmtTime(t)) remaining" }
        return inW == 0 ? "No input power" : "Calculating…"
    }
}

struct MQTTCredentials {
    let url:      String
    let port:     Int
    let username: String
    let password: String
    let clientId: String
    let topic:    String
}

class EcoFlowAPI {
    let accessKey: String
    let secretKey: String
    let serial:    String

    init(accessKey: String, secretKey: String, serial: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.serial    = serial
    }

    // MARK: – REST: full quota fetch

    func fetchStatus() async throws -> (quota: [String: Any], status: EFStatus) {
        let quota = try await fetchQuota()
        return (quota, EcoFlowAPI.parseStatus(from: quota))
    }

    private func fetchQuota() async throws -> [String: Any] {
        let req = try signedRequest(path: "/iot-open/sign/device/quota/all?sn=\(serial)")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = json["code"] as? String, code == "0",
            let q    = json["data"] as? [String: Any]
        else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw NSError(domain: "EcoFlow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? "API error"])
        }
        return q
    }

    // MARK: – MQTT credentials

    func fetchMQTTCredentials() async throws -> MQTTCredentials {
        let req = try signedRequest(path: "/iot-open/sign/certification")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = json["code"] as? String, code == "0",
            let d    = json["data"] as? [String: Any],
            let url      = d["url"]                  as? String,
            let portStr  = d["port"]                 as? String,
            let port     = Int(portStr),
            let username = d["certificateAccount"]   as? String,
            let password = d["certificatePassword"]  as? String
        else {
            throw NSError(domain: "EcoFlow", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "MQTT certification failed"])
        }
        let clientId = "ANDROID_\(username)_\(Int.random(in: 100_000...999_999))"
        let topic    = "/app/device/property/\(serial)"
        return MQTTCredentials(url: url, port: port, username: username,
                               password: password, clientId: clientId, topic: topic)
    }

    // MARK: – Diagnostics

    func fetchRawFields() async throws -> String {
        let q = try await fetchQuota()
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

    // MARK: – Status parsing (static — used by both REST and MQTT)

    static func parseStatus(from q: [String: Any]) -> EFStatus {
        func d(_ k: String) -> Double { (q[k] as? NSNumber)?.doubleValue ?? 0 }
        func dOpt(_ keys: String...) -> Double? { keys.compactMap { (q[$0] as? NSNumber)?.doubleValue }.first }

        // SOC
        let soc = Int(
            dOpt("bms_emsStatus.lcdShowSoc") ??
            dOpt("bmsMaster.f32ShowSoc") ??
            dOpt("bmsMaster.soc", "cmsBattSoc") ??
            dOpt("ems.soc", "soc", "pd.soc") ??
            dOpt("bms_bmsStatus.soc") ?? 0
        )

        // Device generation
        let isDelta2 = q["mppt.inWatts"] != nil || q["inv.inputWatts"] != nil
        let isDelta3 = q["bmsMaster.inputWatts"] != nil || q["powInSumW"] != nil

        // Input watts
        let solar = d("mppt.inWatts")
        let inW: Double
        if isDelta2 {
            inW = solar + d("inv.inputWatts")
        } else if isDelta3 {
            inW = dOpt("bmsMaster.inputWatts", "powInSumW", "wattsInSum", "inputWatts", "inputPower") ?? 0
        } else {
            inW = dOpt("pd.wattsInSum") ?? 0
        }

        // Output watts
        let outW: Double
        if isDelta2 {
            outW = dOpt("pd.wattsOutSum", "inv.outputWatts", "pd.wattsOut") ?? 0
        } else if isDelta3 {
            outW = dOpt("bmsMaster.outputWatts", "powOutSumW", "wattsOutSum", "outputWatts", "outputPower") ?? 0
        } else {
            outW = dOpt("pd.wattsOutSum") ?? 0
        }

        // Remaining / capacity Wh from BMS mAh × mV
        let remainCap = dOpt("bms_bmsStatus.remainCap")
        let designCap = dOpt("bms_bmsStatus.designCap")
        let vol       = dOpt("bms_bmsStatus.vol")
        let remainWh  = (remainCap != nil && vol != nil) ? Int(remainCap! * vol! / 1_000_000) : nil
        let capWh     = (designCap != nil && vol != nil) ? Int(designCap!  * vol! / 1_000_000) : nil

        let deviceLabel = isDelta3 ? "DELTA 3" : isDelta2 ? "DELTA 2" : "ECOFLOW"

        return EFStatus(inW: inW, outW: outW, soc: soc,
                        remainWh: remainWh, capacityWh: capWh, deviceLabel: deviceLabel)
    }

    // MARK: – Signing

    private func signedRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.ecoflow.com\(path)") else { throw URLError(.badURL) }
        let nonce     = String(Int.random(in: 100_000...999_999))
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let raw       = "accessKey=\(accessKey)&nonce=\(nonce)&timestamp=\(timestamp)"
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(accessKey, forHTTPHeaderField: "accessKey")
        req.setValue(nonce,     forHTTPHeaderField: "nonce")
        req.setValue(timestamp, forHTTPHeaderField: "timestamp")
        req.setValue(hmac(key: secretKey, data: raw), forHTTPHeaderField: "sign")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func hmac(key: String, data: String) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac    = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

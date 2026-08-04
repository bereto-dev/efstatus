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


class EcoFlowAPI {
    let accessKey: String
    let secretKey: String
    let serial: String

    init(accessKey: String, secretKey: String, serial: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.serial    = serial
    }

    func fetchStatus() async throws -> EFStatus {
        let nonce     = String(Int.random(in: 100000...999999))
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let raw       = "accessKey=\(accessKey)&nonce=\(nonce)&timestamp=\(timestamp)"
        let sig       = hmac(key: secretKey, data: raw)

        guard let url = URL(string: "https://api.ecoflow.com/iot-open/sign/device/quota/all?sn=\(serial)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(accessKey, forHTTPHeaderField: "accessKey")
        req.setValue(nonce,     forHTTPHeaderField: "nonce")
        req.setValue(timestamp, forHTTPHeaderField: "timestamp")
        req.setValue(sig,       forHTTPHeaderField: "sign")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        func d(_ key: String) -> Double { (q[key] as? NSNumber)?.doubleValue ?? 0 }
        func dOpt(_ keys: String...) -> Double? { keys.compactMap { (q[$0] as? NSNumber)?.doubleValue }.first }

        // SOC — Delta 2 / Delta 3 / fallbacks
        let soc = Int(
            dOpt("bms_emsStatus.lcdShowSoc") ??        // Delta 2
            dOpt("bmsMaster.f32ShowSoc") ??            // Delta 3
            dOpt("bmsMaster.soc", "cmsBattSoc") ??     // Delta 3 alt
            dOpt("ems.soc", "soc", "pd.soc") ??        // generic
            dOpt("bms_bmsStatus.soc") ?? 0             // Delta 2 fallback
        )

        // Detect device generation by field presence
        let isDelta2 = q["mppt.inWatts"] != nil || q["inv.inputWatts"] != nil
        let isDelta3 = q["bmsMaster.inputWatts"] != nil || q["powInSumW"] != nil

        // Input watts — never mix Delta 2 and Delta 3 fields (pd.wattsInSum is stale on Delta 2)
        let inW: Double
        if isDelta2 {
            inW = d("mppt.inWatts") + d("inv.inputWatts")
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

        // Remaining Wh — Delta 2 uses mAh×mV, Delta 3 may provide remainTime + power
        let remainCap = dOpt("bms_bmsStatus.remainCap")
        let designCap = dOpt("bms_bmsStatus.designCap")
        let vol       = dOpt("bms_bmsStatus.vol")
        let remainWh  = (remainCap != nil && vol != nil) ? Int(remainCap! * vol! / 1_000_000) : nil
        let capWh     = (designCap != nil && vol != nil) ? Int(designCap!  * vol! / 1_000_000) : nil

        let deviceLabel = isDelta3 ? "DELTA 3" : isDelta2 ? "DELTA 2" : "ECOFLOW"

        return EFStatus(inW: inW, outW: outW, soc: soc, remainWh: remainWh, capacityWh: capWh, deviceLabel: deviceLabel)
    }

    private func hmac(key: String, data: String) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac    = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

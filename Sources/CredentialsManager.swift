import Foundation

struct Credentials {
    let accessKey: String
    let secretKey: String
    let serial: String
}

enum CredentialsManager {
    private static let suite = UserDefaults.standard

    static func save(_ c: Credentials) {
        suite.set(c.accessKey, forKey: "accessKey")
        suite.set(c.secretKey, forKey: "secretKey")
        suite.set(c.serial,    forKey: "serial")
    }

    static func load() -> Credentials? {
        guard
            let ak = suite.string(forKey: "accessKey"), !ak.isEmpty,
            let sk = suite.string(forKey: "secretKey"), !sk.isEmpty,
            let sn = suite.string(forKey: "serial"),    !sn.isEmpty
        else { return nil }
        return Credentials(accessKey: ak, secretKey: sk, serial: sn)
    }

    static func clear() {
        suite.removeObject(forKey: "accessKey")
        suite.removeObject(forKey: "secretKey")
        suite.removeObject(forKey: "serial")
    }
}

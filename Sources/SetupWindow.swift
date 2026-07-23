import Cocoa

class SetupWindow: NSWindow {
    var onSave: ((Credentials) -> Void)?

    private let accessKeyField = NSTextField()
    private let secretKeyField = NSTextField()
    private let serialField    = NSTextField()
    private let statusLabel    = NSTextField(labelWithString: "")

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        title = "EFStatus — Setup"
        isReleasedWhenClosed = false
        center()
        buildUI()
        if let c = CredentialsManager.load() {
            accessKeyField.stringValue = c.accessKey
            secretKeyField.stringValue = c.secretKey
            serialField.stringValue    = c.serial
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        let v = NSView(frame: contentView!.bounds)
        v.wantsLayer = true
        contentView = v

        func label(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 13)
            return f
        }

        let title = NSTextField(labelWithString: "EFStatus")
        title.font = .boldSystemFont(ofSize: 18)

        let sub = NSTextField(labelWithString: "Enter your EcoFlow API credentials to get started.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        accessKeyField.placeholderString = "Access Key"
        secretKeyField.placeholderString = "Secret Key"
        serialField.placeholderString    = "Device Serial Number"

        for f in [accessKeyField, secretKeyField] {
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        serialField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        statusLabel.font      = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = ""

        let saveBtn = NSButton(title: "Save & Connect", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        let helpBtn = NSButton(title: "Get API credentials →", target: self, action: #selector(openDocs))
        helpBtn.bezelStyle  = .inline
        helpBtn.isBordered  = false
        helpBtn.font        = .systemFont(ofSize: 11)
        helpBtn.contentTintColor = .linkColor

        let stack = NSStackView(views: [
            title, sub,
            label("Access Key"),  accessKeyField,
            label("Secret Key"),  secretKeyField,
            label("Serial Number"), serialField,
            helpBtn, statusLabel, saveBtn
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 6
        stack.edgeInsets  = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for f in [accessKeyField, secretKeyField, serialField] {
            f.widthAnchor.constraint(equalToConstant: 372).isActive = true
        }
        stack.setCustomSpacing(2,  after: sub)
        stack.setCustomSpacing(12, after: saveBtn)

        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }

    @objc private func save() {
        let ak = accessKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        let sk = secretKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        let sn = serialField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ak.isEmpty, !sk.isEmpty, !sn.isEmpty else {
            statusLabel.stringValue = "All fields are required."
            return
        }
        let creds = Credentials(accessKey: ak, secretKey: sk, serial: sn)
        CredentialsManager.save(creds)
        onSave?(creds)
        close()
    }

    @objc private func openDocs() {
        NSWorkspace.shared.open(URL(string: "https://developer.ecoflow.com")!)
    }
}

import Cocoa

class AboutWindow: NSWindow {

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        title = "About EFStatus"
        isReleasedWhenClosed = false
        center()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: contentView!.bounds)
        contentView = root

        // App name + icon row
        let appName = NSTextField(labelWithString: "EFStatus")
        appName.font = .boldSystemFont(ofSize: 20)

        let appSub = NSTextField(wrappingLabelWithString:
            "A lightweight macOS menu bar app that shows real-time EcoFlow Delta 2 battery status — no phone app needed, no Node.js, no cloud subscriptions.")
        appSub.font = .systemFont(ofSize: 12)
        appSub.textColor = .secondaryLabelColor

        // Origin
        let originHeader = sectionHeader("Origin")
        let originBody = NSTextField(wrappingLabelWithString:
            "Built by Roberto Pacheco because the EcoFlow Delta 2 doesn't surface consumption statistics in real time — and as his primary office backup power, he needed that data at a glance without picking up his phone.")
        originBody.font = .systemFont(ofSize: 12)
        originBody.textColor = .secondaryLabelColor

        // Support
        let supportHeader = sectionHeader("Support")
        let coffeeBtn = linkButton(title: "☕  Buy Me a Coffee", url: "https://buymeacoffee.com/bereto")
        let devBtn    = linkButton(title: "🌐  devteam.partners", url: "https://devteam.partners/about-us")

        let stack = NSStackView(views: [
            appName, appSub,
            div(),
            originHeader, originBody,
            div(),
            supportHeader, coffeeBtn, devBtn,
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            appSub.widthAnchor.constraint(equalToConstant: 332),
            originBody.widthAnchor.constraint(equalToConstant: 332),
        ])

        // Resize window to fit content
        root.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        setContentSize(NSSize(width: 380, height: h))
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = .systemFont(ofSize: 10, weight: .semibold)
        f.textColor = .tertiaryLabelColor
        return f
    }

    private func div() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 332).isActive = true
        return v
    }

    private func linkButton(title: String, url: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle  = .inline
        b.isBordered  = false
        b.font        = .systemFont(ofSize: 12)
        b.contentTintColor = .linkColor
        b.identifier  = NSUserInterfaceItemIdentifier(url)
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let urlStr = sender.identifier?.rawValue,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }
}

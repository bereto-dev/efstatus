import Cocoa

private let PANEL_W: CGFloat = 220
private let PAD:     CGFloat = 12

class PopupPanel: NSPanel {

    private let batteryLabel = label("ECOFLOW", size: 9,  weight: .semibold, alpha: 0.45)
    private let percentLabel = label("—",       size: 26, weight: .bold,     alpha: 1)
    private let whLabel      = label("",        size: 11, weight: .regular,  alpha: 0.5)
    private let progressBar  = ProgressBar()
    private let timeBoltView = makeTimeBolt()
    private let timeLabel    = label("",        size: 11, weight: .medium,   alpha: 0.75)

    private let inTitleLabel  = label("INPUT",  size: 9,  weight: .semibold, alpha: 0.45)
    private let inWLabel      = label("— W",    size: 13, weight: .bold,     alpha: 1)
    private let outTitleLabel = label("OUTPUT", size: 9,  weight: .semibold, alpha: 0.45)
    private let outWLabel     = label("— W",    size: 13, weight: .bold,     alpha: 1)

    private let refreshButton = RefreshButton()
    var onRefresh: (() -> Void)?

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: 160),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel    = true
        level              = .popUpMenu
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        contentView = root

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        inWLabel.textColor  = NSColor(red: 0.25, green: 0.90, blue: 0.50, alpha: 1)
        outWLabel.textColor = NSColor(red: 1.00, green: 0.42, blue: 0.38, alpha: 1)

        // Header row: BATTERY label + updated timestamp + refresh button
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshButton.onTap = { [weak self] in self?.onRefresh?() }
        let headerRow = hstack([batteryLabel, headerSpacer, refreshButton], spacing: 4, align: .centerY)

        // Percent row
        let pctRow = hstack([percentLabel, whLabel], spacing: 6, align: .lastBaseline)

        // Progress bar
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 5).isActive = true

        // Divider
        let div = Divider()

        // Watts row — two columns pushed to each edge
        let inCol  = vstack([inTitleLabel,  inWLabel],  spacing: 1)
        let outCol = vstack([outTitleLabel, outWLabel], spacing: 1)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let wattsRow = hstack([inCol, spacer, outCol], spacing: 0, align: .top)

        let timeRow = hstack([timeBoltView, timeLabel], spacing: 4, align: .centerY)

        let stack = NSStackView(views: [
            headerRow,
            pctRow,
            progressBar,
            timeRow,
            div,
            wattsRow,
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 6
        stack.edgeInsets  = NSEdgeInsets(top: PAD, left: PAD, bottom: PAD, right: PAD)
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
            div.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
            wattsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
        ])
    }

    func update(_ st: EFStatus) {
        batteryLabel.stringValue = st.deviceLabel
        percentLabel.stringValue = "\(st.soc)%"
        whLabel.stringValue      = st.remainWh != nil ? "\(st.remainWh!) Wh" : ""
        progressBar.progress     = Double(st.soc) / 100.0
        timeLabel.stringValue    = st.timeLabel
        inWLabel.stringValue     = "\(Int(st.inW)) W"
        outWLabel.stringValue    = "\(Int(st.outW)) W"
        timeLabel.textColor      = NSColor.white.withAlphaComponent(0.75)
        timeBoltView.isHidden    = !st.hasTimeEstimate
        refreshButton.setLoading(false)

        contentView?.layoutSubtreeIfNeeded()
        let fit = contentView!.fittingSize
        setContentSize(NSSize(width: PANEL_W, height: fit.height))
    }

    func setRefreshing() {
        percentLabel.stringValue = "—"
        whLabel.stringValue      = ""
        progressBar.progress     = 0
        timeLabel.stringValue    = "Updating…"
        timeLabel.textColor      = NSColor.white.withAlphaComponent(0.4)
        inWLabel.stringValue     = "— W"
        outWLabel.stringValue    = "— W"
        refreshButton.setLoading(true)
    }
}

// MARK: – Helpers

private func makeTimeBolt() -> NSImageView {
    let iv = NSImageView()
    let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    iv.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    iv.contentTintColor = NSColor.white.withAlphaComponent(0.75)
    iv.translatesAutoresizingMaskIntoConstraints = false
    return iv
}

private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font      = .systemFont(ofSize: size, weight: weight)
    f.textColor = NSColor.white.withAlphaComponent(alpha)
    return f
}

private func hstack(_ views: [NSView], spacing: CGFloat, align: NSLayoutConstraint.Attribute) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment   = align == .lastBaseline ? .lastBaseline : .centerY
    s.spacing     = spacing
    return s
}

private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment   = .leading
    s.spacing     = spacing
    return s
}

// MARK: – CardView / ProgressBar / Divider

private class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.97).setFill()
        path.fill()
    }
}

class ProgressBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.12).setFill()
        bg.fill()
        let w = bounds.width * CGFloat(min(max(progress, 0), 1))
        if w > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 3, yRadius: 3)
            NSColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 1).setFill()
            fill.fill()
        }
    }
}

private class Divider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: -1, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        bounds.fill()
    }
}

class RefreshButton: NSView {
    var onTap: (() -> Void)?
    private let imageView = NSImageView()
    private var isLoading = false
    private var spinTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        imageView.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?
            .withSymbolConfiguration(cfg)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        if loading {
            imageView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            startSpin()
        } else {
            stopSpin()
            imageView.contentTintColor = NSColor.white.withAlphaComponent(0.4)
            imageView.layer?.removeAllAnimations()
        }
    }

    private func startSpin() {
        imageView.wantsLayer = true
        guard let layer = imageView.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position    = CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        let rotation = CABasicAnimation(keyPath: "transform.rotation")
        rotation.fromValue   = 0
        rotation.toValue     = -CGFloat.pi * 2
        rotation.duration    = 0.8
        rotation.repeatCount = .infinity
        layer.add(rotation, forKey: "spin")
    }

    private func stopSpin() {
        imageView.layer?.removeAnimation(forKey: "spin")
    }

    @objc private func tapped() {
        guard !isLoading else { return }
        onTap?()
    }
}

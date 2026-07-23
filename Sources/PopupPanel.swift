import Cocoa

private let PANEL_W: CGFloat = 220
private let PAD:     CGFloat = 12

class PopupPanel: NSPanel {

    private let batteryLabel = label("BATTERY", size: 9,  weight: .semibold, alpha: 0.45)
    private let percentLabel = label("—",       size: 26, weight: .bold,     alpha: 1)
    private let whLabel      = label("",        size: 11, weight: .regular,  alpha: 0.5)
    private let progressBar  = ProgressBar()
    private let timeLabel    = label("",        size: 11, weight: .medium,   alpha: 0.75)

    private let inTitleLabel  = label("INPUT",  size: 9,  weight: .semibold, alpha: 0.45)
    private let inWLabel      = label("— W",    size: 13, weight: .bold,     alpha: 1)
    private let outTitleLabel = label("OUTPUT", size: 9,  weight: .semibold, alpha: 0.45)
    private let outWLabel     = label("— W",    size: 13, weight: .bold,     alpha: 1)

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

        let stack = NSStackView(views: [
            batteryLabel,
            pctRow,
            progressBar,
            timeLabel,
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
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
            div.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
            wattsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -PAD * 2),
        ])
    }

    func update(_ st: EFStatus) {
        percentLabel.stringValue = "\(st.soc)%"
        whLabel.stringValue      = st.remainWh != nil ? "\(st.remainWh!) Wh" : ""
        progressBar.progress     = Double(st.soc) / 100.0
        timeLabel.stringValue    = st.timeLabel
        inWLabel.stringValue     = "\(Int(st.inW)) W"
        outWLabel.stringValue    = "\(Int(st.outW)) W"

        contentView?.layoutSubtreeIfNeeded()
        let fit = contentView!.fittingSize
        setContentSize(NSSize(width: PANEL_W, height: fit.height + 12))
    }
}

// MARK: – Helpers

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

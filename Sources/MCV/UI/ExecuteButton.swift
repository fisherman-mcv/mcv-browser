import AppKit

/// Кругла кнопка виконання команди: 36×36 → 40×40 на hover (0.2s ease),
/// акцентний фон, біла стрілка — точно за макетом командного рядка.
final class ExecuteButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        title = ""
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Run")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        contentTintColor = .white

        widthConstraint = widthAnchor.constraint(equalToConstant: 36)
        heightConstraint = heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])

        applyStyle()
        NotificationCenter.default.addObserver(self, selector: #selector(applyStyle),
                                                name: .mcvThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyStyle() {
        layer?.backgroundColor = Theme.accent.cgColor
        layer?.cornerRadius = widthConstraint.constant / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { resize(to: 40) }
    override func mouseExited(with event: NSEvent) { resize(to: 36) }

    private func resize(to size: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.commandBar
            ctx.allowsImplicitAnimation = true
            widthConstraint.animator().constant = size
            heightConstraint.animator().constant = size
            layer?.cornerRadius = size / 2
            superview?.superview?.layoutSubtreeIfNeeded()
        }
    }
}

/// Діамантовий бейдж-логотип "F" під кутом 45° зліва в командному рядку.
final class LogoBadge: NSView {
    init(size: CGFloat = 20) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        layer?.cornerRadius = 5
        layer?.backgroundColor = Theme.accent.cgColor
        layer?.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)

        let label = NSTextField(labelWithString: "F")
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.transform = CATransform3DMakeRotation(-.pi / 4, 0, 0, 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

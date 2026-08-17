import AppKit

/// Одна вкладка в панелі: активна — заповнена картка Theme.bgCard, неактивна —
/// прозора з текстом textSecondary. Хрестик закриття видимий тільки на hover
/// (NSTrackingArea), індикатор завантаження — пульсуюча крапка 6×6.
final class TabChipView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let loadingDot = NSView()
    private var trackingArea: NSTrackingArea?
    private var isActive = false
    private var widthConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        widthConstraint = widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        widthConstraint.isActive = true

        loadingDot.wantsLayer = true
        loadingDot.translatesAutoresizingMaskIntoConstraints = false
        loadingDot.layer?.cornerRadius = 3
        loadingDot.layer?.backgroundColor = Theme.accent.cgColor
        loadingDot.isHidden = true

        titleLabel.font = Theme.Typo.tabTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isBordered = false
        closeButton.wantsLayer = true
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(closeConfig)
        closeButton.image?.isTemplate = true
        closeButton.contentTintColor = Theme.textSecondary
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(loadingDot)
        addSubview(titleLabel)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            loadingDot.widthAnchor.constraint(equalToConstant: 6),
            loadingDot.heightAnchor.constraint(equalToConstant: 6),
            loadingDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.md),
            loadingDot.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: loadingDot.trailingAnchor, constant: Theme.Spacing.sm),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -Theme.Spacing.sm),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.md),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(selfTapped))
        addGestureRecognizer(click)
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragged(_:))))

        NotificationCenter.default.addObserver(self, selector: #selector(repaint),
                                                name: .mcvThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(title: String, isActive: Bool, isLoading: Bool) {
        self.isActive = isActive
        titleLabel.stringValue = title
        loadingDot.isHidden = !isLoading
        if isLoading { startPulse() } else { loadingDot.layer?.removeAllAnimations() }
        repaint()
    }

    @objc private func repaint() {
        layer?.cornerRadius = Theme.Radius.card
        layer?.backgroundColor = isActive
            ? NSColor.white.withAlphaComponent(Theme.isDark ? 0.12 : 0.55).cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = isActive ? Theme.textPrimary : Theme.textSecondary
        titleLabel.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .medium)
        loadingDot.layer?.backgroundColor = Theme.accent.cgColor
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        loadingDot.layer?.add(pulse, forKey: "pulse")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.animator().alphaValue = 0
    }

    @objc private func selfTapped() { onSelect?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func dragged(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: alphaValue = 0.55
        case .ended:
            alphaValue = 1
            onDragEnded?(recognizer.location(in: nil))
        default: alphaValue = 1
        }
    }
}

/// Панель вкладок: горизонтальний скрол чіпів + кнопка "+".
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onGroup: ((Int, Int) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let newButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true

        stack.orientation = .horizontal
        stack.spacing = Theme.Spacing.xs
        // left:78 лишає місце під traffic lights (вікно без рамки, fullSizeContentView)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 78, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        newButton.title = ""
        newButton.isBordered = false
        newButton.wantsLayer = true
        let plusConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(plusConfig)
        newButton.image?.isTemplate = true
        newButton.contentTintColor = Theme.textSecondary
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.toolTip = "New Tab (⌘T)"
        newButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(newButton)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -4),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -140),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 24),
            newButton.heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func reload(items: [(title: String, loading: Bool)], current: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let chip = TabChipView()
            chip.configure(title: item.title, isActive: index == current, isLoading: item.loading)
            chip.onSelect = { [weak self] in self?.onSelect?(index) }
            chip.onClose = { [weak self] in self?.onClose?(index) }
            chip.onDragEnded = { [weak self] point in
                guard let self else { return }
                let local = self.stack.convert(point, from: nil)
                let target = self.stack.arrangedSubviews.enumerated().min {
                    abs($0.element.frame.midX - local.x) < abs($1.element.frame.midX - local.x)
                }?.offset
                if let target {
                    let targetView = self.stack.arrangedSubviews[target]
                    if abs(targetView.frame.midX - local.x) < min(34, targetView.frame.width * 0.25), target != index {
                        self.onGroup?(index, target)
                    } else {
                        self.onMove?(index, target)
                    }
                }
            }
            stack.addArrangedSubview(chip)
        }
    }

    @objc private func newTapped() { onNew?() }
}

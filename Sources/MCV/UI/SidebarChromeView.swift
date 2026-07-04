import AppKit

struct SidebarTabModel {
    let favicon: NSImage?
    let isActive: Bool
    let isLoading: Bool
    let isPinned: Bool
    let isPlayingAudio: Bool
    let hasUnread: Bool
}

/// Одна іконка вкладки: тільки фавікон, без назви. Індикатори — маленькі
/// накладки: 📌 закріплена (зверху зліва), ⏳/🔊/● статус (знизу справа,
/// пріоритет: завантаження → звук → непрочитане). Клік — вибір,
/// правий клік — контекстне меню (закрити/закріпити/дублювати).
final class SidebarTabIconView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onDuplicate: (() -> Void)?

    private let iconView = NSImageView()
    private let statusBadge = NSTextField(labelWithString: "")
    private let pinBadge = NSTextField(labelWithString: "📌")
    private var trackingArea: NSTrackingArea?

    /// Трохи більше за самі traffic-light-кружечки (12px), не повний розмір
    /// класичного фавікона — панель має лишатись вузькою.
    static let size: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])

        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.translatesAutoresizingMaskIntoConstraints = false

        statusBadge.font = .systemFont(ofSize: 7)
        statusBadge.isHidden = true
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.wantsLayer = true
        statusBadge.drawsBackground = false

        pinBadge.font = .systemFont(ofSize: 6)
        pinBadge.isHidden = true
        pinBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(statusBadge)
        addSubview(pinBadge)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            statusBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),

            pinBadge.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinBadge.topAnchor.constraint(equalTo: topAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
        toolTip = nil
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(_ model: SidebarTabModel) {
        if let favicon = model.favicon {
            iconView.image = favicon
            iconView.contentTintColor = nil
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = Theme.textSecondary
        }

        layer?.backgroundColor = model.isActive
            ? NSColor.white.withAlphaComponent(Theme.isDark ? 0.16 : 0.55).cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 6

        pinBadge.isHidden = !model.isPinned

        if model.isLoading {
            statusBadge.stringValue = "⏳"
            statusBadge.isHidden = false
        } else if model.isPlayingAudio {
            statusBadge.stringValue = "🔊"
            statusBadge.isHidden = false
        } else if model.hasUnread {
            statusBadge.stringValue = "●"
            statusBadge.textColor = Theme.accent
            statusBadge.isHidden = false
        } else {
            statusBadge.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            animator().alphaValue = 0.85
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            animator().alphaValue = 1
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Закріпити/Відкріпити", action: #selector(pinTapped), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Дублювати", action: #selector(dupTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Закрити вкладку", action: #selector(closeTapped), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func tapped() { onSelect?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func pinTapped() { onTogglePin?() }
    @objc private func dupTapped() { onDuplicate?() }
}

/// Документ-в'ю для NSScrollView зі звичайною (не перевернутою) системою
/// координат прилипає вмістом до низу, коли контенту менше за висоту
/// скролу. Фліпаємо, щоб фавіконки росли зверху вниз, як очікується.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Кругла кнопка-траффік-лайт: своя, а не системна — репозиціонування
/// реальних window buttons AppKit синхронно скидає назад на кожен layout
/// pass, тож для стабільної вертикальної колонки надійніше намалювати свою,
/// підключену до тих самих `performClose/Miniaturize/Zoom`.
private final class TrafficLightButton: NSButton {
    private let dotColor: NSColor
    private var trackingArea: NSTrackingArea?
    private let glyphLabel = NSTextField(labelWithString: "")

    init(dotColor: NSColor, glyph: String) {
        self.dotColor = dotColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isBordered = false
        title = ""
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 12),
        ])
        layer?.cornerRadius = 6
        layer?.backgroundColor = dotColor.cgColor

        glyphLabel.stringValue = glyph
        glyphLabel.font = .systemFont(ofSize: 8, weight: .bold)
        glyphLabel.textColor = NSColor.black.withAlphaComponent(0.6)
        glyphLabel.alignment = .center
        glyphLabel.alphaValue = 0
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { glyphLabel.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { glyphLabel.animator().alphaValue = 0 }
}

/// Тонка вертикальна панель (36px): traffic lights зверху, нижче —
/// стовпчик фавіконок, "+" внизу. Той самий матеріал/без рамки, що й
/// фон вікна — панель зливається в одну поверхню замість окремої картки.
final class SidebarChromeView: NSView {
    static let width: CGFloat = 36
    static let trafficLightsReservedHeight: CGFloat = 78

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onTogglePin: ((Int) -> Void)?
    var onDuplicateTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let stack = FlippedStackView()
    private let addButton = NSButton()
    private let closeDot = TrafficLightButton(dotColor: NSColor(hex: "#FF5F57"), glyph: "×")
    private let minimizeDot = TrafficLightButton(dotColor: NSColor(hex: "#FEBC2E"), glyph: "−")
    private let zoomDot = TrafficLightButton(dotColor: NSColor(hex: "#28C840"), glyph: "+")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        // Той самий .sidebar material, що й база вікна (BrowserWindowController) —
        // без рамки/тіні, тож панель виглядає продовженням вікна, не окремою карткою.
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.orientation = .vertical
        stack.spacing = Theme.Spacing.sm
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let plusConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Нова вкладка")?
            .withSymbolConfiguration(plusConfig)
        addButton.image?.isTemplate = true
        addButton.contentTintColor = Theme.textSecondary
        addButton.isBordered = false
        addButton.title = ""
        addButton.target = self
        addButton.action = #selector(newTapped)
        addButton.toolTip = "Нова вкладка (⌘T)"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let trafficLights = NSStackView(views: [closeDot, minimizeDot, zoomDot])
        trafficLights.orientation = .vertical
        trafficLights.spacing = 8
        trafficLights.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(trafficLights)
        effect.addSubview(scroll)
        effect.addSubview(addButton)
        NSLayoutConstraint.activate([
            trafficLights.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            trafficLights.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.trafficLightsReservedHeight),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -Theme.Spacing.xs),

            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: Theme.Spacing.xs),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            addButton.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            addButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Theme.Spacing.sm),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Підключає кружечки до реальних дій вікна (закрити/згорнути/розгорнути)
    /// — виглядають і поводяться як traffic lights, лишаючись у своєму layout.
    func attachWindowControls(_ window: NSWindow) {
        closeDot.target = window
        closeDot.action = #selector(NSWindow.performClose(_:))
        minimizeDot.target = window
        minimizeDot.action = #selector(NSWindow.performMiniaturize(_:))
        zoomDot.target = window
        zoomDot.action = #selector(NSWindow.performZoom(_:))
    }

    func reload(_ models: [SidebarTabModel]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, model) in models.enumerated() {
            let icon = SidebarTabIconView()
            icon.configure(model)
            icon.onSelect = { [weak self] in self?.onSelectTab?(index) }
            icon.onClose = { [weak self] in self?.onCloseTab?(index) }
            icon.onTogglePin = { [weak self] in self?.onTogglePin?(index) }
            icon.onDuplicate = { [weak self] in self?.onDuplicateTab?(index) }
            stack.addArrangedSubview(icon)
        }
    }

    @objc private func newTapped() { onNewTab?() }
}

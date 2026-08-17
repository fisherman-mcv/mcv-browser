import AppKit

struct SidebarTabModel {
    let tabIndex: Int
    let favicon: NSImage?
    let isActive: Bool
    let isLoading: Bool
    let isPinned: Bool
    let isPlayingAudio: Bool
    let hasUnread: Bool
    var groupID: UUID? = nil
    var groupTitle: String? = nil
    var groupCount: Int = 0
    var groupColor: NSColor? = nil
    var isGroup: Bool = false
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
    var onDragEnded: ((NSPoint) -> Void)?
    var onToggleGroup: (() -> Void)?
    var onCloseGroup: (() -> Void)?
    var onHibernateGroup: (() -> Void)?
    var onBookmarkGroup: (() -> Void)?
    var onColorGroup: ((Int) -> Void)?
    var onUngroup: (() -> Void)?

    private let iconView = NSImageView()
    private let statusBadge = NSTextField(labelWithString: "")
    private let pinBadge = NSTextField(labelWithString: "📌")
    private let miniFavicon = NSImageView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isGroup = false
    private var model: SidebarTabModel?

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
        addSubview(miniFavicon)

        let closeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(closeConfig)
        closeButton.image?.isTemplate = true
        closeButton.contentTintColor = Theme.textPrimary
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close Tab"
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        miniFavicon.imageScaling = .scaleProportionallyDown
        miniFavicon.wantsLayer = true
        miniFavicon.layer?.cornerRadius = 2
        miniFavicon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            statusBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),

            pinBadge.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinBadge.topAnchor.constraint(equalTo: topAnchor),
            miniFavicon.trailingAnchor.constraint(equalTo: trailingAnchor),
            miniFavicon.bottomAnchor.constraint(equalTo: bottomAnchor),
            miniFavicon.widthAnchor.constraint(equalToConstant: 9),
            miniFavicon.heightAnchor.constraint(equalToConstant: 9),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        toolTip = nil
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .mcvThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(_ model: SidebarTabModel) {
        self.model = model
        isGroup = model.isGroup
        miniFavicon.isHidden = !model.isGroup || model.favicon == nil
        miniFavicon.image = model.favicon
        if model.isGroup {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: model.groupTitle)
            iconView.contentTintColor = model.groupColor ?? Theme.textPrimary
            toolTip = "\(model.groupTitle ?? "Tab Group") · \(model.groupCount) tabs"
        } else if let favicon = model.favicon {
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

        pinBadge.isHidden = model.isGroup || !model.isPinned
        closeButton.isHidden = model.isGroup || model.isPinned
        closeButton.alphaValue = 0

        if model.isGroup {
            statusBadge.stringValue = "\(model.groupCount)"
            statusBadge.textColor = model.groupColor ?? Theme.textPrimary
            statusBadge.isHidden = false
        } else if model.isLoading {
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

    @objc private func themeChanged() { if let model { configure(model) } }

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
            if !closeButton.isHidden { closeButton.animator().alphaValue = 1 }
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            animator().alphaValue = 1
            closeButton.animator().alphaValue = 0
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if isGroup {
            menu.addItem(withTitle: "Expand/Collapse Group", action: #selector(groupTapped), keyEquivalent: "").target = self
            let colors = NSMenu(title: "Group Color")
            let automatic = colors.addItem(withTitle: "Automatic (Theme)", action: #selector(colorGroupTapped(_:)), keyEquivalent: "")
            automatic.target = self
            automatic.tag = -1
            colors.addItem(.separator())
            for (index, color) in ["Cyan", "Violet", "Rose", "Amber", "Emerald", "Blue"].enumerated() {
                let item = colors.addItem(withTitle: color, action: #selector(colorGroupTapped(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = Self.colorSwatch(index)
            }
            let colorItem = NSMenuItem(title: "Group Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Hibernate Group", action: #selector(hibernateGroupTapped), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Bookmark Group", action: #selector(bookmarkGroupTapped), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Ungroup", action: #selector(ungroupTapped), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Close Group", action: #selector(closeGroupTapped), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        menu.addItem(withTitle: "Pin/Unpin", action: #selector(pinTapped), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Duplicate", action: #selector(dupTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTapped), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func tapped() { isGroup ? onToggleGroup?() : onSelect?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func pinTapped() { onTogglePin?() }
    @objc private func dupTapped() { onDuplicate?() }
    @objc private func groupTapped() { onToggleGroup?() }
    @objc private func closeGroupTapped() { onCloseGroup?() }
    @objc private func hibernateGroupTapped() { onHibernateGroup?() }
    @objc private func bookmarkGroupTapped() { onBookmarkGroup?() }
    @objc private func colorGroupTapped(_ sender: NSMenuItem) { onColorGroup?(sender.tag) }
    @objc private func ungroupTapped() { onUngroup?() }

    private static func colorSwatch(_ index: Int) -> NSImage {
        let colors = ["#66D9EF", "#A78BFA", "#FB7185", "#FBBF24", "#34D399", "#60A5FA"]
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        (NSColor(hex: colors[index])).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }
    @objc private func dragged(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: alphaValue = 0.5
        case .ended:
            alphaValue = 1
            onDragEnded?(recognizer.location(in: nil))
        default: alphaValue = 1
        }
    }
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
    var onSpotlight: (() -> Void)?
    var onSettings: (() -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    var onGroupTabs: ((Int, Int) -> Void)?
    var onToggleGroup: ((UUID) -> Void)?
    var onCloseGroup: ((UUID) -> Void)?
    var onHibernateGroup: ((UUID) -> Void)?
    var onBookmarkGroup: ((UUID) -> Void)?
    var onColorGroup: ((UUID, Int) -> Void)?
    var onUngroup: ((UUID) -> Void)?

    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let stack = FlippedStackView()
    private let spotlightButton = NSButton()
    private let newTabButton = NSButton()
    private let settingsButton = NSButton()
    private let actionStack = NSStackView()
    private let addButton = NSButton()
    private let actionHubIcon = NSImageView()
    private var actionsExpanded = false
    private let branding = CyberpunkBrandingView()
    private let closeDot = TrafficLightButton(dotColor: NSColor(hex: "#FF5F57"), glyph: "×")
    private let minimizeDot = TrafficLightButton(dotColor: NSColor(hex: "#FEBC2E"), glyph: "−")
    private let zoomDot = TrafficLightButton(dotColor: NSColor(hex: "#28C840"), glyph: "+")
    private var lastSnapshot: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        // hudWindow + withinWindow — той самий рецепт, що й у CardSurface для
        // командного рядка/палітри тощо: withinWindow блендить із тим, що вже
        // позаду в межах вікна (наше власне темне тло), а не з реальним
        // робочим столом (behindWindow), який тягнув колір шпалер напряму —
        // звідси й був синюватий відтінок, що не збігався з рештою UI.
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
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

        configureActionButton(addButton, symbol: "plus", description: "Actions")
        addButton.image = nil
        addButton.target = self
        addButton.action = #selector(toggleActions)
        addButton.toolTip = "Actions"

        let hubConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        actionHubIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(hubConfig)
        actionHubIcon.image?.isTemplate = true
        actionHubIcon.contentTintColor = Theme.textSecondary
        actionHubIcon.imageScaling = .scaleNone
        actionHubIcon.translatesAutoresizingMaskIntoConstraints = false
        actionHubIcon.wantsLayer = true
        addButton.addSubview(actionHubIcon)
        NSLayoutConstraint.activate([
            actionHubIcon.centerXAnchor.constraint(equalTo: addButton.centerXAnchor),
            actionHubIcon.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            actionHubIcon.widthAnchor.constraint(equalToConstant: 16),
            actionHubIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        configureActionButton(settingsButton, symbol: "gearshape", description: "Settings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "Settings (⌘,)"

        configureActionButton(spotlightButton, symbol: "magnifyingglass", description: "Spotlight")
        spotlightButton.target = self
        spotlightButton.action = #selector(spotlightTapped)
        spotlightButton.toolTip = "Spotlight URL Bar (⌘E)"

        configureActionButton(newTabButton, symbol: "plus", description: "New Tab")
        newTabButton.target = self
        newTabButton.action = #selector(newTapped)
        newTabButton.toolTip = "New Tab (⌘T)"

        actionStack.orientation = .vertical
        actionStack.spacing = Theme.Spacing.sm
        actionStack.alignment = .centerX
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.alphaValue = 0
        actionStack.isHidden = true
        [settingsButton, spotlightButton, newTabButton].forEach(actionStack.addArrangedSubview)

        let trafficLights = NSStackView(views: [closeDot, minimizeDot, zoomDot])
        trafficLights.orientation = .vertical
        trafficLights.spacing = 8
        trafficLights.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(trafficLights)
        branding.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(branding)
        effect.addSubview(scroll)
        effect.addSubview(actionStack)
        effect.addSubview(addButton)
        NSLayoutConstraint.activate([
            trafficLights.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            trafficLights.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            branding.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            branding.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -116),
            branding.widthAnchor.constraint(equalToConstant: 24),
            branding.heightAnchor.constraint(equalToConstant: 132),

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
            actionStack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            actionStack.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -Theme.Spacing.sm),
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
        zoomDot.action = #selector(NSWindow.toggleFullScreen(_:))
    }

    func reload(_ models: [SidebarTabModel]) {
        let snapshot = models.map { model in
            let imageID = model.favicon.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
            return [String(model.tabIndex), imageID, model.isActive ? "1" : "0",
                    model.isLoading ? "1" : "0", model.isPinned ? "1" : "0",
                    model.isPlayingAudio ? "1" : "0", model.hasUnread ? "1" : "0",
                    model.groupID?.uuidString ?? "-", model.groupTitle ?? "-",
                    String(model.groupCount), model.isGroup ? "1" : "0"].joined(separator: ":")
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for model in models {
            let icon = SidebarTabIconView()
            icon.configure(model)
            icon.onSelect = { [weak self] in self?.onSelectTab?(model.tabIndex) }
            icon.onClose = { [weak self] in self?.onCloseTab?(model.tabIndex) }
            icon.onTogglePin = { [weak self] in self?.onTogglePin?(model.tabIndex) }
            icon.onDuplicate = { [weak self] in self?.onDuplicateTab?(model.tabIndex) }
            if let groupID = model.groupID {
                icon.onToggleGroup = { [weak self] in self?.onToggleGroup?(groupID) }
                icon.onCloseGroup = { [weak self] in self?.onCloseGroup?(groupID) }
                icon.onHibernateGroup = { [weak self] in self?.onHibernateGroup?(groupID) }
                icon.onBookmarkGroup = { [weak self] in self?.onBookmarkGroup?(groupID) }
                icon.onColorGroup = { [weak self] color in self?.onColorGroup?(groupID, color) }
                icon.onUngroup = { [weak self] in self?.onUngroup?(groupID) }
            }
            icon.onDragEnded = { [weak self] point in
                guard let self, !model.isGroup else { return }
                let local = self.stack.convert(point, from: nil)
                guard let target = self.stack.arrangedSubviews.enumerated().min(by: {
                    abs($0.element.frame.midY - local.y) < abs($1.element.frame.midY - local.y)
                })?.offset, models.indices.contains(target) else { return }
                let targetModel = models[target]
                if abs(self.stack.arrangedSubviews[target].frame.midY - local.y) < 7,
                   targetModel.tabIndex != model.tabIndex {
                    self.onGroupTabs?(model.tabIndex, targetModel.tabIndex)
                } else {
                    self.onMoveTab?(model.tabIndex, targetModel.tabIndex)
                }
            }
            stack.addArrangedSubview(icon)
        }
    }

    private func configureActionButton(_ button: NSButton, symbol: String, description: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = Theme.textSecondary
        button.isBordered = false
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @objc private func toggleActions() { setActionsExpanded(!actionsExpanded) }

    private func setActionsExpanded(_ expanded: Bool) {
        guard expanded != actionsExpanded else { return }
        actionsExpanded = expanded
        if expanded { actionStack.isHidden = false }

        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            actionStack.animator().alphaValue = expanded ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.actionsExpanded else { return }
            self.actionStack.isHidden = true
        }
        if !reducedMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.14
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            actionHubIcon.layer?.add(transition, forKey: "mcv.actionHubSymbol")
        }
        let hubConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        actionHubIcon.image = NSImage(
            systemSymbolName: expanded ? "xmark" : "plus",
            accessibilityDescription: expanded ? "Close Actions" : "Actions"
        )?.withSymbolConfiguration(hubConfig)
        actionHubIcon.image?.isTemplate = true
        addButton.toolTip = expanded ? "Close Actions" : "Actions"
    }

    @objc private func newTapped() {
        onNewTab?()
    }
    @objc private func spotlightTapped() {
        onSpotlight?()
    }
    @objc private func settingsTapped() {
        onSettings?()
    }
}

/// Bespoke 5×7 dot-matrix wordmark: Nothing-inspired geometry with sparse
/// cyberpunk signal pixels. Drawing it ourselves keeps it crisp and avoids a
/// bundled/font-install dependency.
private final class CyberpunkBrandingView: NSView {
    private let glyphs: [Character: [String]] = [
        "M":["10001","11011","10101","10101","10001","10001","10001"],
        "C":["01111","10000","10000","10000","10000","10000","01111"],
        "B":["11110","10001","10001","11110","10001","10001","11110"],
        "R":["11110","10001","10001","11110","10100","10010","10001"],
        "O":["01110","10001","10001","10001","10001","10001","01110"],
        "W":["10001","10001","10001","10101","10101","10101","01010"],
        "S":["01111","10000","10000","01110","00001","00001","11110"],
        "E":["11111","10000","10000","11110","10000","10000","11111"]
    ]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                                name: .mcvThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let word = Array("MCBROWSER")
        let cell: CGFloat = 1.55
        let advance = cell * 6
        let totalWidth = CGFloat(word.count) * advance - cell
        let totalHeight = cell * 7

        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: -.pi / 2)
        let originX = -totalWidth / 2
        let originY = -totalHeight / 2

        for (glyphIndex, character) in word.enumerated() {
            guard let rows = glyphs[character] else { continue }
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "1" {
                    let isSignal = (glyphIndex * 7 + row * 5 + column) % 23 == 0
                    let color = isSignal
                        ? Theme.accent.withAlphaComponent(0.92)
                        : Theme.textSecondary.withAlphaComponent(Theme.isDark ? 0.52 : 0.62)
                    color.setFill()
                    let x = originX + CGFloat(glyphIndex) * advance + CGFloat(column) * cell
                    let y = originY + CGFloat(row) * cell
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: cell * 0.64, height: cell * 0.64)).fill()
                }
            }
        }

        // Small asymmetric rails make the wordmark feel engineered rather
        // than like ordinary rotated text.
        Theme.accent.withAlphaComponent(0.48).setFill()
        NSBezierPath(rect: NSRect(x: originX - 5, y: originY + 1, width: 3.5, height: 0.8)).fill()
        NSBezierPath(rect: NSRect(x: originX + totalWidth + 1.5, y: originY + totalHeight - 1.8,
                                  width: 5, height: 0.8)).fill()
        context.restoreGState()
    }
}

import AppKit

/// Базова скляна поверхня: справжній Liquid Glass (NSGlassEffectView) на
/// macOS 26+, фолбек на NSVisualEffectView для старших систем — плюс тонка
/// обвідка й опційна тінь поверх, керовані дизайн-токенами з Theme.
/// Контент додається у `contentHost`; стиль сам оновлюється на зміну теми.
class CardSurface: NSView {
    let contentHost = NSView()
    private let backgroundContainer = NSView()
    private let outline = NSView()
    private let cornerRadius: CGFloat
    private let hasShadow: Bool

    init(cornerRadius: CGFloat, shadow: Bool = false) {
        self.cornerRadius = cornerRadius
        self.hasShadow = shadow
        super.init(frame: .zero)
        wantsLayer = true

        backgroundContainer.wantsLayer = true
        backgroundContainer.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundContainer)
        NSLayoutConstraint.activate([
            backgroundContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundContainer.topAnchor.constraint(equalTo: topAnchor),
            backgroundContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = contentHost
            glass.translatesAutoresizingMaskIntoConstraints = false
            backgroundContainer.addSubview(glass)
            pin(glass, to: backgroundContainer)
            pin(contentHost, to: glass)
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.translatesAutoresizingMaskIntoConstraints = false
            backgroundContainer.addSubview(effect)
            pin(effect, to: backgroundContainer)
            backgroundContainer.addSubview(contentHost)
            pin(contentHost, to: backgroundContainer)
        }

        // Тонка обвідка поверх скла — окремий шар, не залежить від реалізації
        // блюру вище, інакше межі капсули губляться на світлому контенті.
        outline.wantsLayer = true
        outline.layer?.cornerRadius = cornerRadius
        outline.layer?.borderWidth = 1
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        pin(outline, to: self)

        applyStyle()
        NotificationCenter.default.addObserver(self, selector: #selector(applyStyle),
                                                name: .mcvThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func applyStyle() {
        outline.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        if hasShadow {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 16
            layer?.shadowOffset = CGSize(width: 0, height: -6)
            layer?.masksToBounds = false
        }
    }

    /// Рамка стає акцентною при фокусі командного рядка (0.15s).
    func setFocused(_ focused: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            outline.layer?.borderColor = (focused
                ? Theme.accent
                : NSColor.white.withAlphaComponent(0.18)).cgColor
            outline.layer?.borderWidth = focused ? 1.5 : 1
        }
    }

    private func pin(_ view: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

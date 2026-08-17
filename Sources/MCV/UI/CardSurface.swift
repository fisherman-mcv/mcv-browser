import AppKit

/// Базова скляна поверхня: справжній Liquid Glass (NSGlassEffectView) на
/// macOS 26+, фолбек на NSVisualEffectView для старших систем. Без статичної
/// рамки — вона зайва навколо суцільного скла; рамка з'являється лише
/// тимчасово, як індикатор фокусу (див. `setFocused`), а не як прикраса.
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

        // Resolve Liquid Glass dynamically so the same source also compiles
        // with the macOS 14 SDK used by public CI. The class exists only in
        // newer AppKit; the fallback remains the authoritative old-SDK path.
        if #available(macOS 26.0, *),
           let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassType.init(frame: .zero)
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            glass.setValue(contentHost, forKey: "contentView")
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

        // Рамка-індикатор фокусу — невидима (width 0), доки не викликано
        // setFocused(true). Ніякої статичної обвідки навколо скла.
        outline.wantsLayer = true
        outline.layer?.cornerRadius = cornerRadius
        outline.layer?.borderWidth = 0
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
        if hasShadow {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = Theme.isDark ? 0.4 : 0.14
            layer?.shadowRadius = 16
            layer?.shadowOffset = CGSize(width: 0, height: -6)
            layer?.masksToBounds = false
        }
    }

    /// Рамка з'являється лише як тимчасовий індикатор фокусу командного
    /// рядка (0.15s), не як стала прикраса.
    func setFocused(_ focused: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            outline.layer?.borderColor = Theme.accent.cgColor
            outline.layer?.borderWidth = focused ? 1.5 : 0
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

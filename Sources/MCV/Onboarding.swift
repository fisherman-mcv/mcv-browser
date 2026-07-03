import AppKit

/// Плаваюча картка без рамки вікна: перший запуск MCV — 5 кроків,
/// анімовані переходи (fade + slide з overshoot), живий typewriter-демо
/// командного рядка, дрейфуючі градієнтні плями на фоні. Завершується
/// колбеком `onFinish`, після чого відкривається основне вікно браузера.
final class OnboardingWindowController: NSObject {
    private let panel: KeyPanel
    private let view: OnboardingView
    var onFinish: (() -> Void)?

    override init() {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        view = OnboardingView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.isMovableByWindowBackground = true
        panel.center()
        panel.contentView = view

        view.onFinish = { [weak self] in
            ConfigStore.shared.update { $0.hasCompletedOnboarding = true }
            self?.dismiss()
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        view.playIntro()
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.onFinish?()
        })
    }
}

// MARK: - Дрейфуючі градієнтні плями (амбієнтний фон)

private final class DriftingBlob: CAGradientLayer {
    init(color: NSColor, diameter: CGFloat) {
        super.init()
        type = .radial
        colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor]
        locations = [0, 1]
        startPoint = CGPoint(x: 0.5, y: 0.5)
        endPoint = CGPoint(x: 1, y: 1)
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        cornerRadius = diameter / 2
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not supported") }

    func drift(from: CGPoint, to: CGPoint, duration: CFTimeInterval) {
        position = from
        let anim = CABasicAnimation(keyPath: "position")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(anim, forKey: "drift")
        position = to
    }
}

// MARK: - Крок

private struct Step {
    let eyebrow: String
    let title: String
    let subtitle: String
}

private let steps: [Step] = [
    Step(eyebrow: "MCV BROWSER",
         title: "Менше кліків.\nБільше результату.",
         subtitle: "Командний браузер для тих, хто будує — не просто споживає."),
    Step(eyebrow: "ЯДРО",
         title: "Кожна дія — команда.",
         subtitle: "⌘E відкриває палітру. g, ddg, calc, tran — і працюй, не відриваючи рук від клавіатури."),
    Step(eyebrow: "ВИГЛЯД",
         title: "Обери тему.",
         subtitle: "Завжди можна змінити командою dark або light."),
    Step(eyebrow: "БЕЗПЕКА",
         title: "Обери режим захисту.",
         subtitle: "Safe блокує трекери й рекламу. Secure — повна ізоляція, без кук і JS."),
    Step(eyebrow: "ГОТОВО",
         title: "Усе налаштовано.",
         subtitle: "⌘E будь-де — команди. ⇧⌘S — sidebar лише з фавіконками. ⌥Space — Mini MCV поверх усього."),
]

// MARK: - Основне полотно

final class OnboardingView: NSView {
    var onFinish: (() -> Void)?

    private var index = 0
    private let card = NSView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let stageHost = NSView()
    private let dotsStack = NSStackView()
    private let continueButton = PillButton(title: "Продовжити")
    private let skipButton = NSButton()
    private let backButton = NSButton()
    private var contentTopConstraint: NSLayoutConstraint!
    private var typewriterTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildBackground()
        buildCard()
        renderStep(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func playIntro() {
        card.alphaValue = 0
        card.layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            card.animator().alphaValue = 1
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(0.94, 0.94, 1)
        scale.toValue = CATransform3DIdentity
        scale.duration = 0.55
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.4, 0.4, 1) // overshoot
        card.layer?.add(scale, forKey: "intro")
        card.layer?.transform = CATransform3DIdentity
    }

    // MARK: Фон

    private func buildBackground() {
        layer?.backgroundColor = NSColor(hex: "#0A0A0A").cgColor
        let blob1 = DriftingBlob(color: Theme.accent, diameter: 520)
        let blob2 = DriftingBlob(color: Theme.accentSecondary, diameter: 420)
        layer?.addSublayer(blob1)
        layer?.addSublayer(blob2)
        blob1.drift(from: CGPoint(x: 40, y: 460), to: CGPoint(x: 200, y: 560), duration: 9)
        blob2.drift(from: CGPoint(x: 700, y: 80), to: CGPoint(x: 560, y: 180), duration: 11)
    }

    // MARK: Картка

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(hex: "#141414").withAlphaComponent(0.92).cgColor
        card.layer?.cornerRadius = 24
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 40
        card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48),
        ])

        skipButton.title = "Пропустити"
        skipButton.isBordered = false
        skipButton.font = Theme.Typo.small
        skipButton.contentTintColor = Theme.textSecondary
        (skipButton.cell as? NSButtonCell)?.attributedTitle = NSAttributedString(
            string: "Пропустити", attributes: [.foregroundColor: Theme.textSecondary, .font: Theme.Typo.small])
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.translatesAutoresizingMaskIntoConstraints = false

        backButton.title = "←"
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 15, weight: .medium)
        backButton.contentTintColor = Theme.textSecondary
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        eyebrowLabel.font = .systemFont(ofSize: 12, weight: .bold)
        eyebrowLabel.textColor = Theme.accent
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 460
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        stageHost.translatesAutoresizingMaskIntoConstraints = false

        continueButton.target = self
        continueButton.clickAction = { [weak self] in self?.advance() }
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        dotsStack.orientation = .horizontal
        dotsStack.spacing = 6
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in steps {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            dotsStack.addArrangedSubview(dot)
        }

        card.addSubview(skipButton)
        card.addSubview(backButton)
        card.addSubview(eyebrowLabel)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(stageHost)
        card.addSubview(dotsStack)
        card.addSubview(continueButton)

        contentTopConstraint = eyebrowLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 64)
        NSLayoutConstraint.activate([
            skipButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            skipButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),

            backButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            backButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            contentTopConstraint,
            eyebrowLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -64),
            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 12),

            subtitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -64),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),

            stageHost.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),
            stageHost.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -64),
            stageHost.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            stageHost.heightAnchor.constraint(equalToConstant: 120),

            dotsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 64),
            dotsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -36),

            continueButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -48),
            continueButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -32),
            continueButton.widthAnchor.constraint(equalToConstant: 168),
            continueButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: Крок / переходи

    private func renderStep(animated: Bool) {
        let step = steps[index]
        eyebrowLabel.stringValue = step.eyebrow
        titleLabel.stringValue = step.title
        subtitleLabel.stringValue = step.subtitle
        continueButton.setTitle(index == steps.count - 1 ? "Почати" : "Продовжити")
        backButton.isHidden = index == 0
        skipButton.isHidden = index == steps.count - 1

        for (i, dot) in dotsStack.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = (i == index ? Theme.accent : NSColor.white.withAlphaComponent(0.15)).cgColor
        }

        buildStage(for: index)

        if animated {
            let group = [eyebrowLabel, titleLabel, subtitleLabel, stageHost] as [NSView]
            group.forEach { $0.alphaValue = 0 }
            contentTopConstraint.constant = 76
            layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                ctx.allowsImplicitAnimation = true
                contentTopConstraint.constant = 64
                group.forEach { $0.animator().alphaValue = 1 }
                layoutSubtreeIfNeeded()
            }
        }
    }

    private func buildStage(for index: Int) {
        typewriterTimer?.invalidate()
        stageHost.subviews.forEach { $0.removeFromSuperview() }

        switch index {
        case 1: stageHost.addSubview(makeTypewriterDemo())
        case 2: stageHost.addSubview(makeThemePicker())
        case 3: stageHost.addSubview(makeSecurityPicker())
        default: break
        }
    }

    @objc private func backTapped() {
        guard index > 0 else { return }
        index -= 1
        renderStep(animated: true)
    }

    @objc private func skipTapped() { onFinish?() }

    private func advance() {
        if index == steps.count - 1 {
            onFinish?()
            return
        }
        index += 1
        renderStep(animated: true)
    }

    // MARK: Крок 2 — typewriter-демо

    private func makeTypewriterDemo() -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 56))
        host.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        row.layer?.cornerRadius = 12
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let logo = LogoBadge(size: 16)
        logo.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textColor = .white
        text.translatesAutoresizingMaskIntoConstraints = false

        let cursor = NSView()
        cursor.wantsLayer = true
        cursor.layer?.backgroundColor = Theme.accent.cgColor
        cursor.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(logo)
        row.addSubview(text)
        row.addSubview(cursor)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -40),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.heightAnchor.constraint(equalToConstant: 44),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            logo.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            logo.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            text.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            cursor.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 2),
            cursor.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            cursor.widthAnchor.constraint(equalToConstant: 2),
            cursor.heightAnchor.constraint(equalToConstant: 16),
            row.trailingAnchor.constraint(greaterThanOrEqualTo: cursor.trailingAnchor, constant: 14),
        ])

        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1; blink.toValue = 0.15
        blink.duration = 0.6; blink.autoreverses = true; blink.repeatCount = .infinity
        cursor.layer?.add(blink, forKey: "blink")

        let full = "g swift concurrency"
        var chars = Array(full)
        var typed = ""
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak text] timer in
            guard !chars.isEmpty else { timer.invalidate(); return }
            typed.append(chars.removeFirst())
            text?.stringValue = typed
        }
        return host
    }

    // MARK: Крок 3 — тема

    private func makeThemePicker() -> NSView {
        let host = NSStackView()
        host.orientation = .horizontal
        host.spacing = 12
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addArrangedSubview(makeChoiceCard(title: "🌙 Темна", selected: Theme.isDark) { [weak self] in
            self?.selectTheme(dark: true)
        })
        host.addArrangedSubview(makeChoiceCard(title: "☀️ Світла", selected: !Theme.isDark) { [weak self] in
            self?.selectTheme(dark: false)
        })
        return host
    }

    private func selectTheme(dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        ConfigStore.shared.update { $0.theme = dark ? "dark" : "light" }
        Theme.update(dark: dark)
        buildStage(for: index)
    }

    // MARK: Крок 4 — безпека

    private func makeSecurityPicker() -> NSView {
        let host = NSStackView()
        host.orientation = .horizontal
        host.spacing = 10
        host.translatesAutoresizingMaskIntoConstraints = false
        let current = SecurityMode(rawValue: ConfigStore.shared.config.mode) ?? .safe
        for mode in SecurityMode.allCases {
            host.addArrangedSubview(makeChoiceCard(title: mode.label, selected: mode == current) {
                SecurityManager.shared.setMode(mode)
                self.buildStage(for: self.index)
            })
        }
        return host
    }

    private func makeChoiceCard(title: String, selected: Bool, action: @escaping () -> Void) -> NSView {
        HoverChoiceCard(title: title, selected: selected, action: action)
    }
}

// MARK: - Компоненти

/// Селектована картка вибору (тема/безпека): акцентна рамка, hover-підсвітка.
private final class HoverChoiceCard: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(title: String, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? 0.1 : 0.04).cgColor
        layer?.borderWidth = selected ? 1.5 : 1
        layer?.borderColor = (selected ? Theme.accent : NSColor.white.withAlphaComponent(0.1)).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 140),
            heightAnchor.constraint(equalToConstant: 52),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func tapped() { action() }

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
}

/// Велика акцентна кнопка (Продовжити/Почати): pill-форма, hover — легкий grow + світіння.
private final class PillButton: NSButton {
    var clickAction: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        self.title = ""
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.backgroundColor = Theme.accent.cgColor

        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        target = self
        action = #selector(tapped)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setTitle(_ text: String) { label.stringValue = text }

    @objc private func tapped() { clickAction?() }

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
            animator().alphaValue = 0.88
            layer?.shadowColor = Theme.accent.cgColor
            layer?.shadowOpacity = 0.6
            layer?.shadowRadius = 16
        }
    }
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.hover
            animator().alphaValue = 1
            layer?.shadowOpacity = 0
        }
    }
}

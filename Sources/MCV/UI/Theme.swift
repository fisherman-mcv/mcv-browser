import AppKit

extension Notification.Name {
    static let mcvThemeChanged = Notification.Name("mcv.themeChanged")
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// Дизайн-система MCV: "Браузер для архітекторів". Кольори тримаються як
/// точні значення поверх dark/light appearance. Режим `system` слідує macOS.
/// Хто змінює зовнішній вигляд — підписується
/// на `.mcvThemeChanged` і перечитує токени в `applyStyle()`.
enum Theme {
    private(set) static var isDark = resolvedDark(for: ConfigStore.shared.config.theme)

    static func resolvedDark(for mode: String) -> Bool {
        if mode == "dark" { return true }
        if mode == "light" { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func apply(mode: String) {
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        update(dark: resolvedDark(for: mode))
    }

    /// Всі підписники перефарбовують шари синхронно всередині CATransaction,
    /// тому одна ambient-анімація (0.3s) плавно охоплює весь інтерфейс разом.
    static func update(dark: Bool) {
        isDark = dark
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.theme)
        NotificationCenter.default.post(name: .mcvThemeChanged, object: nil)
        CATransaction.commit()
    }

    // MARK: - Кольори
    static var bgPrimary: NSColor { isDark ? NSColor(hex: "#0A0A0A") : NSColor(hex: "#F8F9FA") }
    static var bgSecondary: NSColor { isDark ? NSColor(hex: "#141414") : NSColor(hex: "#FFFFFF") }
    static var bgCard: NSColor { isDark ? NSColor(hex: "#1A1A1A") : NSColor(hex: "#FFFFFF") }
    static let accent = NSColor(hex: "#6C5CE7")
    static let accentSecondary = NSColor(hex: "#00D2D3")
    static var textPrimary: NSColor { isDark ? NSColor(hex: "#EAEAEA") : NSColor(hex: "#1A1A1A") }
    static var textSecondary: NSColor { isDark ? NSColor(hex: "#888888") : NSColor(hex: "#666666") }
    static var divider: NSColor { isDark ? NSColor(hex: "#2A2A2A") : NSColor(hex: "#E0E0E0") }
    static let danger = NSColor(hex: "#FF4444")

    // MARK: - Метрики (кратні 4px)
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }
    enum Radius {
        static let small: CGFloat = 4
        static let card: CGFloat = 8
        static let commandBar: CGFloat = 16
    }
    enum Motion {
        static let hover: TimeInterval = 0.15
        static let commandBar: TimeInterval = 0.2
        static let tabSwitch: TimeInterval = 0.25
        static let theme: TimeInterval = 0.3
    }

    // MARK: - Типографіка
    // Inter/JetBrains Mono з макета — замінені на SF Pro/SF Mono: візуально
    // близькі, нативні, нульова вага бандла (принцип "мінімальне споживання").
    enum Typo {
        static let h1 = NSFont.systemFont(ofSize: 24, weight: .semibold)
        static let h2 = NSFont.systemFont(ofSize: 18, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 14, weight: .regular)
        static let small = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let tabTitle = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let command = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    }
}

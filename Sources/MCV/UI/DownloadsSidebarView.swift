import AppKit

private final class DownloadRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Theme.Typo.body
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Theme.Typo.small
        statusLabel.textColor = Theme.textSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        track.layer?.backgroundColor = Theme.divider.cgColor
        track.translatesAutoresizingMaskIntoConstraints = false

        fill.wantsLayer = true
        fill.layer?.cornerRadius = 2
        fill.layer?.backgroundColor = Theme.accent.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(track)

        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            track.heightAnchor.constraint(equalToConstant: 4),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(_ item: DownloadItem, trackWidth: CGFloat) {
        nameLabel.stringValue = item.filename
        switch item.state {
        case .inProgress: statusLabel.stringValue = "\(Int(item.fraction * 100))%"
        case .completed: statusLabel.stringValue = "Completed"
        case .failed: statusLabel.stringValue = "Failed"
        }
        fill.layer?.backgroundColor = (item.state == .failed ? Theme.danger : Theme.accent).cgColor
        fillWidth.constant = trackWidth * CGFloat(item.state == .failed ? 1 : item.fraction)
    }
}

/// Бічна панель завантажень (320px, праворуч) — той самий "докований,
/// без рамки" підхід, що й лівий SidebarChromeView: обидві прилягають до
/// краю вікна впритул, тож мають виглядати однією поверхнею, не карткою.
final class DownloadsSidebarView: NSView {
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let stack = NSStackView()
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "Nothing here yet")

    init() {
        super.init(frame: .zero)

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

        titleLabel.font = Theme.Typo.h2
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.Typo.small
        emptyLabel.textColor = Theme.textSecondary

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false

        clearButton.isBordered = false
        clearButton.font = Theme.Typo.small
        clearButton.contentTintColor = Theme.textSecondary
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleLabel)
        effect.addSubview(stack)
        effect.addSubview(clearButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Theme.Spacing.lg),
            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: Theme.Spacing.lg),

            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Theme.Spacing.lg),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Theme.Spacing.lg),

            clearButton.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Theme.Spacing.lg),
            clearButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Theme.Spacing.lg),
        ])

        DownloadsCenter.shared.onChange = { [weak self] in self?.reload() }
        NotificationCenter.default.addObserver(self, selector: #selector(applyStyle),
                                                name: .mcvThemeChanged, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyStyle() {
        titleLabel.textColor = Theme.textPrimary
        emptyLabel.textColor = Theme.textSecondary
        clearButton.contentTintColor = Theme.textSecondary
        reload()
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = DownloadsCenter.shared.items
        if items.isEmpty {
            stack.addArrangedSubview(emptyLabel)
            return
        }
        let rowWidth: CGFloat = 320 - Theme.Spacing.lg * 2
        for item in items {
            let row = DownloadRow()
            row.configure(item, trackWidth: rowWidth)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    @objc private func clearTapped() {
        DownloadsCenter.shared.clear()
    }
}

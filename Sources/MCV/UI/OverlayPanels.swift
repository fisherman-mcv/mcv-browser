import AppKit

/// Командна палітра (⌘E, тоглюється): поле вводу + живі підказки команд.
/// ↑↓ — вибір, Tab — підставити, Enter — виконати, Esc — закрити.
final class CommandPaletteView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let glass = CardSurface(cornerRadius: 16, shadow: true)
    private let field = NSTextField()
    private let listStack = NSStackView()
    private var matches: [CommandDescriptor] = []
    private var selected = -1

    init() {
        super.init(frame: .zero)

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        field.placeholderString = "Команда…  (Tab — підставити, Enter — виконати)"
        field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 3

        let stack = NSStackView(views: [field, listStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentHost.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentHost.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        isHidden = false
        field.stringValue = ""
        refresh("")
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        onDismiss?()
    }

    @objc private func submit() {
        let text = field.stringValue
        dismiss()
        if !text.isEmpty { onSubmit?(text) }
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertTab(_:)): accept(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
        renderList()
    }

    private func accept() {
        guard matches.indices.contains(selected) else { return }
        field.stringValue = matches[selected].name + " "
        field.currentEditor()?.moveToEndOfLine(nil)
        refresh(field.stringValue)
    }

    private func refresh(_ text: String) {
        let head = text.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        matches = CommandEngine.descriptors.filter { head.isEmpty || $0.name.hasPrefix(head) }
        if matches.count > 10 { matches = Array(matches.prefix(10)) }
        selected = matches.isEmpty ? -1 : 0
        renderList()
    }

    private func renderList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, descriptor) in matches.enumerated() {
            let isSelected = index == selected
            let label = NSTextField(labelWithString: "\(descriptor.usage)  —  \(descriptor.help)")
            label.font = .monospacedSystemFont(ofSize: 12, weight: isSelected ? .bold : .regular)
            label.textColor = isSelected ? Theme.accent : Theme.textSecondary
            label.lineBreakMode = .byTruncatingTail
            listStack.addArrangedSubview(label)
        }
    }
}

/// Перемикач вкладок (⌘P, тоглюється): ↑↓ — вибір, Enter — перейти, w — закрити,
/// 1–9 — миттєвий перехід, Esc — вихід. Рядки клікабельні.
final class TabSwitcherView: NSView {
    var onSelect: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    /// Постачає актуальний список вкладок при кожному рендері.
    var provider: (() -> (titles: [String], current: Int))?

    private let glass = CardSurface(cornerRadius: 16, shadow: true)
    private let listStack = NSStackView()
    private var highlighted = 0
    private var count = 0

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let header = NSTextField(labelWithString: "Вкладки   ↑↓ вибір · Enter перейти · w закрити · 1–9 · Esc")
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = Theme.textSecondary

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4

        let stack = NSStackView(views: [header, listStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentHost.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentHost.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        guard let data = provider?() else { return }
        count = data.titles.count
        highlighted = max(0, min(data.current, count - 1))
        isHidden = false
        render(data)
        window?.makeFirstResponder(self)
    }

    func dismiss() {
        isHidden = true
    }

    /// Перерендер після закриття вкладки, якщо панель ще відкрита.
    func refreshIfVisible() {
        guard !isHidden, let data = provider?() else { return }
        count = data.titles.count
        if count == 0 { dismiss(); return }
        highlighted = min(highlighted, count - 1)
        render(data)
    }

    private func render(_ data: (titles: [String], current: Int)) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in data.titles.enumerated() {
            let marker = index == data.current ? "●" : "○"
            let number = index < 9 ? "\(index + 1)" : "·"
            let label = NSTextField(labelWithString: " \(number)  \(marker)  \(title)")
            label.font = .monospacedSystemFont(ofSize: 13, weight: index == highlighted ? .bold : .regular)
            label.textColor = index == highlighted ? Theme.textPrimary : Theme.textSecondary
            label.lineBreakMode = .byTruncatingTail
            label.tag = index
            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            label.addGestureRecognizer(click)
            listStack.addArrangedSubview(label)
        }
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        if let row = gesture.view as? NSTextField {
            onSelect?(row.tag)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
        case 36, 76: // Return / Enter
            onSelect?(highlighted)
        case 125: // ↓
            highlighted = min(count - 1, highlighted + 1)
            refreshIfVisible()
        case 126: // ↑
            highlighted = max(0, highlighted - 1)
            refreshIfVisible()
        case 13: // w
            onCloseTab?(highlighted)
        default:
            if let chars = event.characters, let n = Int(chars), n >= 1, n <= count {
                onSelect?(n - 1)
            }
        }
    }
}

import AppKit

private struct Suggestion {
    enum Kind { case history, bookmark, remote }
    let display: String     // текст у полі після Tab
    let subtitle: String    // URL / "Пошук у Google" тощо
    let kind: Kind
    let url: URL?           // не nil → перехід напряму; nil → пошук
    let engineKey: String?  // для remote-варіанту — яким рушієм шукати
}

/// Живі підказки для адресного/командного рядка: локальна історія + закладки
/// миттєво, підказки Google/DuckDuckGo — з дебаунсом через мережу.
/// Приєднується до будь-якого NSTextField і рендерить дропдаун під заданим
/// якорем (capsule), не втручаючись у решту логіки поля.
final class AddressAutocomplete: NSObject {
    var onAccept: ((String) -> Void)?      // Tab — підставити текст, не виконувати
    var onExecuteURL: ((URL) -> Void)?     // Enter на історії/закладці
    var onExecuteSearch: ((String, String) -> Void) // Enter на remote-підказці: (engineKey, query)

    private weak var field: NSTextField?
    private let glass = CardSurface(cornerRadius: 10)
    private let stack = NSStackView()
    private var rows: [NSView] = []
    private var suggestions: [Suggestion] = []
    private var selected = -1
    private var debounce: Timer?
    private var pendingQuery = ""

    init(field: NSTextField, anchor: NSView, container: NSView,
         onExecuteSearch: @escaping (String, String) -> Void) {
        self.field = field
        self.onExecuteSearch = onExecuteSearch
        super.init()

        glass.isHidden = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentHost.addSubview(stack)
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.contentHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentHost.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            glass.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 6),
        ])
    }

    // MARK: - Вхідні події від поля

    func textDidChange() {
        guard let text = field?.stringValue else { hide(); return }
        guard let (engineKey, query) = Self.searchable(from: text), query.count >= 2 else {
            hide()
            return
        }

        pendingQuery = text
        let local = Self.localMatches(query: query)
        suggestions = local
        selected = -1
        render()

        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            self?.fetchRemote(engineKey: engineKey, query: query, forText: text)
        }
    }

    /// true — подія оброблена автодоповненням, поле не повинно реагувати саме.
    func handle(_ selector: Selector) -> Bool {
        guard !glass.isHidden, !suggestions.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selected = (selected + 1) % suggestions.count
            render()
            return true
        case #selector(NSResponder.moveUp(_:)):
            selected = (selected - 1 + suggestions.count) % suggestions.count
            render()
            return true
        case #selector(NSResponder.insertTab(_:)):
            let index = selected == -1 ? 0 : selected
            accept(suggestions[index])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard selected >= 0, suggestions.indices.contains(selected) else { return false }
            execute(suggestions[selected])
            return true
        default:
            return false
        }
    }

    func hide() {
        debounce?.invalidate()
        suggestions = []
        selected = -1
        glass.isHidden = true
    }

    // MARK: - Джерела підказок

    /// Розбирає введений текст: чи це щось, що варто автодоповнювати, і яким рушієм.
    /// nil — команда/URL/порожньо, підказки недоречні.
    private static func searchable(from text: String) -> (engineKey: String, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let head = String(parts[0]).lowercased()

        if CommandEngine.searchEngines[head] != nil {
            let rest = parts.count > 1 ? String(parts[1]) : ""
            return rest.isEmpty ? nil : (head, rest)
        }
        // Розпізнана не-пошукова команда (open, calc, mode…) — підказки не потрібні.
        if CommandEngine.descriptors.contains(where: { $0.name == head }), parts.count > 1 {
            return nil
        }
        if CommandEngine.url(from: trimmed) != nil { return nil } // схоже на прямий URL
        return (ConfigStore.shared.config.searchEngine, trimmed)
    }

    private static func localMatches(query: String) -> [Suggestion] {
        var result: [Suggestion] = []
        for (name, target) in ConfigStore.shared.config.bookmarks {
            guard name.lowercased().contains(query.lowercased()), let url = URL(string: target) else { continue }
            result.append(Suggestion(display: name, subtitle: target, kind: .bookmark, url: url, engineKey: nil))
        }
        for entry in HistoryStore.shared.matching(query, limit: 4) {
            guard let url = URL(string: entry.url) else { continue }
            result.append(Suggestion(display: entry.title, subtitle: entry.url, kind: .history, url: url, engineKey: nil))
        }
        return Array(result.prefix(6))
    }

    private func fetchRemote(engineKey: String, query: String, forText text: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = engineKey == "g"
            ? "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)"
            : "https://duckduckgo.com/ac/?q=\(encoded)&type=list"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let list = json[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self, self.pendingQuery == text else { return } // текст змінився — відкидаємо
                let remote = list.prefix(6).map {
                    Suggestion(display: $0, subtitle: "Пошук · \(engineKey)", kind: .remote,
                              url: nil, engineKey: engineKey)
                }
                self.suggestions += remote
                self.render()
            }
        }.resume()
    }

    // MARK: - Дії

    private func accept(_ suggestion: Suggestion) {
        onAccept?(suggestion.display)
        selected = suggestions.firstIndex { $0.display == suggestion.display } ?? -1
        render()
    }

    private func execute(_ suggestion: Suggestion) {
        hide()
        if let url = suggestion.url {
            onExecuteURL?(url)
        } else if let engine = suggestion.engineKey {
            onExecuteSearch(engine, suggestion.display)
        }
    }

    // MARK: - Рендер

    private func render() {
        guard !suggestions.isEmpty else { hide(); return }
        glass.isHidden = false
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        for (index, suggestion) in suggestions.enumerated() {
            let icon: String
            switch suggestion.kind {
            case .history: icon = "🕘"
            case .bookmark: icon = "★"
            case .remote: icon = "🔍"
            }
            let row = NSStackView(views: [
                NSTextField(labelWithString: icon),
                NSTextField(labelWithString: suggestion.display),
            ])
            row.orientation = .horizontal
            row.spacing = 8
            let isSelected = index == selected
            if let label = row.arrangedSubviews.last as? NSTextField {
                label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
                label.textColor = isSelected ? Theme.accent : Theme.textPrimary
                label.lineBreakMode = .byTruncatingTail
            }
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            row.layer?.backgroundColor = isSelected
                ? Theme.accent.withAlphaComponent(0.15).cgColor : .clear
            row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(click)
            row.identifier = NSUserInterfaceItemIdentifier("row-\(index)")
            rows.append(row)
            stack.addArrangedSubview(row)
        }
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view,
              let id = view.identifier?.rawValue,
              let index = Int(id.split(separator: "-").last ?? ""),
              suggestions.indices.contains(index) else { return }
        execute(suggestions[index])
    }
}

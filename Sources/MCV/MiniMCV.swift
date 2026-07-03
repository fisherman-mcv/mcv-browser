import AppKit
import Carbon.HIToolbox

/// Панель без рамки, що вміє ставати key window (інакше не прийме текст).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Mini MCV (Option+Space): плаваючий скляний командний рядок поверх усього,
/// у стилі Spotlight. Не активує застосунок, поки не виконано команду.
final class MiniMCVController: NSObject, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?

    private let panel: KeyPanel
    private let field = NSTextField()

    override init() {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let glass = CardSurface(cornerRadius: Theme.Radius.commandBar, shadow: true)

        field.placeholderString = "MCV — команда або запит…"
        field.font = Theme.Typo.command
        field.textColor = Theme.textPrimary
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false

        glass.contentHost.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: glass.contentHost.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: glass.contentHost.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glass.contentHost.centerYAnchor),
        ])
        panel.contentView = glass
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62
        ))
        field.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        hide()
        if !text.isEmpty { onSubmit?(text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
}

/// Системний глобальний хоткей через Carbon RegisterEventHotKey —
/// працює без дозволів Accessibility, навіть коли MCV у фоні.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    private init() {}

    func register(keyCode: UInt32, carbonModifiers: UInt32) {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        if !handlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                DispatchQueue.main.async { GlobalHotKey.shared.onPressed?() }
                return noErr
            }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D43_5631), id: 1) // 'MCV1'
        RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

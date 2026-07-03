import AppKit
import CoreGraphics

/// Inserts text into whatever app has focus: write to the pasteboard, post a
/// synthetic Cmd-V, then restore the previous clipboard. Paste-based injection
/// is the most app-compatible method (per-character synthetic keystrokes break
/// on non-QWERTY layouts; AX value-setting is unsupported in many apps).
enum TextInjector {
    static func inject(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCmdV()

        // Give the frontmost app time to service the paste before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            restore(savedItems, to: pasteboard)
        }
    }

    private static func postCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Don't let the user's still-held physical modifiers leak into the paste.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let vKeycode: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeycode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeycode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}

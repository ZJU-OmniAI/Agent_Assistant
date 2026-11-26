import AppKit
import ApplicationServices

/// `defaults write org.agent-assistant.app debugSelection -bool true`, then
/// `log stream --predicate 'process == "AgentAssistant"'` shows each step.
enum SelectionLog {
    static func note(_ message: @autoclosure () -> String) {
        if UserDefaults.standard.bool(forKey: "debugSelection") { NSLog("[selection] %@", message()) }
    }
}

// AX calls cross process boundaries. Keep them off the AppKit event loop.
private enum SelectionReader {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func selectedText(in node: AXUIElement) -> String? {
        if let text = attribute(node, kAXSelectedTextAttribute) as? String, !text.trimmed.isEmpty {
            return text.trimmed
        }
        // WebKit and Chromium can expose a document selection through opaque text markers.
        for (rangeName, stringName) in [
            ("AXSelectedTextMarkerRange", "AXStringForTextMarkerRange"),
            (kAXSelectedTextRangeAttribute, kAXStringForRangeParameterizedAttribute)
        ] {
            guard let range = attribute(node, rangeName) else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(node, stringName as CFString, range, &value) == .success,
               let text = value as? String, !text.trimmed.isEmpty { return text.trimmed }
        }
        return nil
    }

    enum Result {
        case text(String)
        /// A password field has focus. Never fall back to copying.
        case secure
        case none
    }

    static func read(pid: pid_t, at point: CGPoint, isCancelled: () -> Bool) -> Result {
        let app = AXUIElementCreateApplication(pid)
        let focused = element(attribute(app, kAXFocusedUIElementAttribute))
        func isSecure(_ node: AXUIElement) -> Bool {
            attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        }
        if let focused, isSecure(focused) { return .secure }
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        var visited = Set<AXUIElement>()
        for start in [hit, focused] {
            var current = start
            for _ in 0..<14 {
                guard !isCancelled(), let node = current, visited.insert(node).inserted else { break }
                if isSecure(node) { return .secure }
                if let text = selectedText(in: node) { return .text(text) }
                current = element(attribute(node, kAXParentAttribute))
            }
        }
        return .none
    }

    /// Dragging a tab, scroll bar or button is not a text selection.
    static func pointsAtControl(pid: pid_t, at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              let hit, let role = attribute(hit, kAXRoleAttribute) as? String else { return false }
        SelectionLog.note("hit role \(role)")
        return [kAXButtonRole, kAXScrollBarRole, kAXSliderRole, kAXToolbarRole, kAXTabGroupRole, kAXRadioButtonRole,
                kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuItemRole, kAXCheckBoxRole, kAXPopUpButtonRole,
                kAXDisclosureTriangleRole, kAXSplitterRole, kAXIncrementorRole, kAXImageRole].contains(role)
    }
}

/// Reads the selection the way a user would: ⌘C, then put the clipboard back.
/// Chrome's PDF viewer and many Electron apps never expose their selection to
/// Accessibility, but all of them implement Copy.
enum ClipboardCopy {
    private static func snapshot() -> (items: [NSPasteboardItem], count: Int) {
        let board = NSPasteboard.general
        let items = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        return (items, board.changeCount)
    }

    /// Call off the main thread. Returns nil when the app copied nothing.
    static func copySelection(from pid: pid_t, isCancelled: () -> Bool) -> String? {
        let saved = DispatchQueue.main.sync(execute: snapshot)
        // A private source keeps the user's physical modifier keys out of the shortcut.
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 8 /* kVK_ANSI_C */, keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
        var changed = false
        var text: String?
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline, !isCancelled() {
            Thread.sleep(forTimeInterval: 0.02)
            let state = DispatchQueue.main.sync { () -> (Bool, String?) in
                let board = NSPasteboard.general
                guard board.changeCount != saved.count else { return (false, nil) }
                return (true, board.string(forType: .string))
            }
            changed = state.0
            text = state.1
            // The count changes on clearContents, possibly before the text arrives.
            if changed && text != nil { break }
        }
        if changed {
            DispatchQueue.main.sync {
                let board = NSPasteboard.general
                board.clearContents()
                if !saved.items.isEmpty { board.writeObjects(saved.items) }
            }
        }
        guard let text = text?.trimmed, !text.isEmpty, !isCancelled() else { return nil }
        return text
    }
}

final class SelectionMonitor {
    var onSelection: ((String, NSPoint) -> Void)?
    var onDismiss: (() -> Void)?
    private let queue = OperationQueue()
    private var monitor: Any?
    private var start: NSPoint?
    private var startWindow: (id: CGWindowID, frame: CGRect)?
    private var revision = 0
    private var delayed: DispatchWorkItem?
    private var pendingRead: BlockOperation?
    private var lastBrowserPID: pid_t?

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]) {
                [weak self] event in self?.handle(event)
            }
            prepareFrontBrowser()
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            lastBrowserPID = nil
            dismiss()
        }
    }

    func dismiss() {
        revision &+= 1
        start = nil
        delayed?.cancel()
        delayed = nil
        pendingRead?.cancel()
        pendingRead = nil
        onDismiss?()
    }

    func frontAppChanged() {
        // Activating an inactive Chrome window can occur between mouse-down and mouse-up.
        if start == nil || NSEvent.pressedMouseButtons & 1 == 0 { dismiss() }
        prepareFrontBrowser()
    }

    private func prepareFrontBrowser() {
        guard monitor != nil, let app = NSWorkspace.shared.frontmostApplication,
              let browser = app.bundleIdentifier,
              browser.hasPrefix("com.google.Chrome") || browser.hasPrefix("com.microsoft.edgemac")
                  || browser.hasPrefix("com.brave.Browser") || browser == "company.thebrowser.Browser",
              lastBrowserPID != app.processIdentifier else { return }
        let pid = app.processIdentifier
        lastBrowserPID = pid
        queue.addOperation {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            _ = SelectionReader.attribute(app, kAXFocusedUIElementAttribute)
        }
    }

    private static func window(at point: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            var frame = CGRect.zero
            guard let bounds = info[kCGWindowBounds as String] as! CFDictionary?,
                  CGRectMakeWithDictionaryRepresentation(bounds, &frame), frame.contains(point),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (id, frame)
        }
        return nil
    }

    private static func frame(of id: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        var frame = CGRect.zero
        guard let bounds = list.first?[kCGWindowBounds as String] as! CFDictionary?,
              CGRectMakeWithDictionaryRepresentation(bounds, &frame) else { return nil }
        return frame
    }

    private func handle(_ event: NSEvent) {
        if event.type == .scrollWheel || event.type == .rightMouseDown {
            dismiss()
            return
        }
        guard let main = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        let quartz = event.cgEvent?.location ?? CGPoint(x: mouse.x, y: main.frame.maxY - mouse.y)
        let point = NSPoint(x: quartz.x, y: main.frame.maxY - quartz.y)
        if event.type == .leftMouseDown {
            dismiss()
            start = point
            startWindow = Self.window(at: quartz)
            prepareFrontBrowser()
            return
        }
        let dragged = start.map { hypot(point.x - $0.x, point.y - $0.y) >= 3 } ?? false
        let window = startWindow
        start = nil
        startWindow = nil
        // Moving or resizing a window is a drag too, but never a text selection.
        if dragged, let window, let now = Self.frame(of: window.id), now != window.frame {
            SelectionLog.note("window moved or resized; not a selection")
            return
        }
        guard event.clickCount >= 2 || dragged || event.modifierFlags.contains(.shift),
              let sourceApp = NSWorkspace.shared.frontmostApplication,
              sourceApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let pid = sourceApp.processIdentifier
        let current = revision
        SelectionLog.note("gesture in \(sourceApp.bundleIdentifier ?? "?") pid \(pid), clicks \(event.clickCount), dragged \(dragged)")
        prepareFrontBrowser()
        let isBrowser = lastBrowserPID == pid
        // Copying in Finder would pick up file names, not text.
        let canCopy = UserDefaults.standard.bool(forKey: "copyFallback") && sourceApp.bundleIdentifier != "com.apple.finder"
        let item = DispatchWorkItem { [weak self] in
            guard let self, current == self.revision else { return }
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let operation, !operation.isCancelled else { return }
                let cancelled = { operation.isCancelled }
                // A freshly opened Chrome page builds its accessibility tree on first use and
                // every query can wait out the messaging timeout. Walking twenty-odd ancestors
                // could then take many seconds, so Accessibility gets a fixed budget and the
                // ⌘C fallback takes over when it runs out.
                let started = Date()
                let deadline = started.addingTimeInterval(0.35)
                let stop = { operation.isCancelled || Date() >= deadline }
                var result = SelectionReader.read(pid: pid, at: quartz, isCancelled: stop)
                if isBrowser, case .none = result, Date().addingTimeInterval(0.12) < deadline, !cancelled() {
                    // Chromium publishes its first renderer accessibility tree asynchronously.
                    Thread.sleep(forTimeInterval: 0.12)
                    if !cancelled() { result = SelectionReader.read(pid: pid, at: quartz, isCancelled: stop) }
                }
                SelectionLog.note("AX result for pid \(pid) after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(result)")
                var text: String?
                switch result {
                case .text(let value): text = value
                case .secure: return
                case .none:
                    guard canCopy, !cancelled(), !SelectionReader.pointsAtControl(pid: pid, at: quartz) else { return }
                    text = ClipboardCopy.copySelection(from: pid, isCancelled: cancelled)
                    SelectionLog.note("copy fallback: \(text.map { "\($0.count) characters" } ?? "nothing copied")")
                }
                guard let text, !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, current == self.revision,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        SelectionLog.note("dropped: selection changed or app no longer frontmost")
                        return
                    }
                    self.onSelection?(text, point)
                }
            }
            self.pendingRead = operation
            self.queue.addOperation(operation)
        }
        delayed = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: item)
    }
}

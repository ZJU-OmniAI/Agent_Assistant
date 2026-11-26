import AppKit
import SwiftUI

/// A button on the selection strip. The strip never becomes key, and standard bezels
/// draw in a non-key window as pale gray, so these draw their own fill to stay legible.
private final class ActionButton: NSButton {
    var hovering = false { didSet { refreshFill() } }
    override var isHighlighted: Bool { didSet { refreshFill() } }

    convenience init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.init(title: title, target: target, action: action)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        contentTintColor = .labelColor
        font = .systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 7
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        refreshFill()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 18, height: max(size.height, 18) + 8)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }

    private func refreshFill() {
        let fill = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.18 : hovering ? 0.12 : 0.06)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private func origin(for size: NSSize, near point: NSPoint) -> NSPoint {
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return point }
    let area = screen.visibleFrame.insetBy(dx: 6, dy: 6)
    let below = point.y - size.height - 12
    return NSPoint(x: max(area.minX, min(point.x + 8, area.maxX - size.width)),
                   y: max(area.minY, min(below >= area.minY ? below : point.y + 14, area.maxY - size.height)))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = SelectionMonitor()
    private var strip: NSPanel?
    private var selection: String?
    private var anchor = NSPoint.zero
    private var chat: NSPanel?
    private var session: Session?
    private var settingsWindow: NSWindow?
    private var localMouse: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.migrateModel()
        UserDefaults.standard.register(defaults: ["automaticSelection": true, "copyFallback": true])
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        installMenus()
        monitor.onSelection = { [weak self] text, point in self?.showStrip(text, at: point) }
        monitor.onDismiss = { [weak self] in self?.hideStrip() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontAppChanged),
                                                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Local panel events do not pass through the global monitor.
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.strip { self?.monitor.dismiss() }
            return event
        }
        refreshMonitor()
        if !UserDefaults.standard.bool(forKey: "hasLaunched")
            || (UserDefaults.standard.bool(forKey: "automaticSelection") && !AXIsProcessTrusted()) {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            openSettings(tab: "selection")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showSettings() }
        return true
    }

    private func installMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Agent Assistant")
        statusItem.button?.toolTip = "Agent Assistant"
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        add("自动划词", #selector(toggleAutomatic))
        add("翻译剪贴板文字", #selector(translateClipboard))
        add("用剪贴板文字提问…", #selector(askClipboard))
        menu.addItem(.separator())
        add("响应时间…", #selector(showResponseTimes))
        add("设置…", #selector(showSettings))
        add("退出 Agent Assistant", #selector(quit))
        statusItem.menu = menu

        let main = NSMenu()
        for (title, entries) in [
            ("Agent Assistant", [("退出", "terminate:", "q")]),
            ("编辑", [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                    ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")]),
            ("窗口", [("关闭", "performClose:", "w")])
        ] {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            entries.forEach { sub.addItem(withTitle: $0.0, action: NSSelectorFromString($0.1), keyEquivalent: $0.2) }
            item.submenu = sub
        }
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        monitor.dismiss()
        refreshMonitor()
        let enabled = UserDefaults.standard.bool(forKey: "automaticSelection")
        menu.items.first?.title = enabled && !AXIsProcessTrusted() ? "自动划词需要授权…" : "自动划词"
        menu.items.first?.state = enabled && AXIsProcessTrusted() ? .on : .off
    }

    @objc private func toggleAutomatic() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "automaticSelection") && !AXIsProcessTrusted() {
            openSettings(tab: "selection")
            return
        }
        defaults.set(!defaults.bool(forKey: "automaticSelection"), forKey: "automaticSelection")
        refreshMonitor()
        if defaults.bool(forKey: "automaticSelection") && !AXIsProcessTrusted() { openSettings(tab: "selection") }
    }

    @objc private func frontAppChanged() {
        refreshMonitor()
        monitor.frontAppChanged()
    }

    private func refreshMonitor() {
        monitor.setEnabled(UserDefaults.standard.bool(forKey: "automaticSelection") && AXIsProcessTrusted())
    }

    private func hideStrip() {
        selection = nil
        if strip?.isVisible == true { strip?.orderOut(nil) }
    }

    private func showStrip(_ text: String, at point: NSPoint) {
        if strip == nil {
            let stack = NSStackView()
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
            for (title, icon, action) in [("翻译", "character.book.closed", #selector(translate)),
                                         ("提问", "bubble.left", #selector(ask))] {
                stack.addArrangedSubview(ActionButton(title: title, symbol: icon, target: self, action: action))
            }
            let surface = NSVisualEffectView()
            surface.material = .popover
            surface.state = .active
            // A mask image, unlike a layer corner radius, also shapes the window shadow.
            let mask = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            mask.resizingMode = .stretch
            surface.maskImage = mask
            stack.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                                         stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                                         stack.topAnchor.constraint(equalTo: surface.topAnchor),
                                         stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor)])
            let panel = SelectionPanel(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = surface
            strip = panel
        }
        selection = text
        anchor = point
        guard let strip else { return }
        // A hidden strip gets no mouse-exited event, so clear any leftover hover.
        (strip.contentView?.subviews.first as? NSStackView)?.arrangedSubviews.forEach { ($0 as? ActionButton)?.hovering = false }
        strip.setFrameOrigin(origin(for: strip.frame.size, near: point))
        strip.orderFrontRegardless()
    }

    @objc private func translate() { useStrip(translate: true) }
    @objc private func ask() { useStrip(translate: false) }

    private func useStrip(translate: Bool) {
        guard let selection else { return }
        openConversation(selection, at: anchor, translate: translate)
    }

    @objc private func askClipboard() { openClipboard(translate: false) }
    @objc private func translateClipboard() { openClipboard(translate: true) }

    private func openClipboard(translate: Bool) {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmed, !text.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "剪贴板中没有文字"
            alert.informativeText = "在网页或 PDF 中选中文字，按 ⌘C 复制，再点击翻译或提问。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        openConversation(text, at: NSEvent.mouseLocation, translate: translate)
    }

    @objc(useSelection:userData:error:)
    func useSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = board.string(forType: .string)?.trimmed, !text.isEmpty else {
            error.pointee = "请先选中一段文字。"
            return
        }
        openConversation(text, at: NSEvent.mouseLocation, translate: userData == "translate")
    }

    private func openConversation(_ text: String, at point: NSPoint, translate: Bool) {
        monitor.dismiss()
        chat?.close()
        let session = Session(source: text)
        self.session = session
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 422, height: 370),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Agent Assistant"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AssistantView(session: session, settings: { [weak self] in self?.openSettings(tab: "model") }))
        panel.setContentSize(NSSize(width: 422, height: 370))
        panel.contentMinSize = NSSize(width: 340, height: 275)
        panel.delegate = self
        chat = panel
        panel.setFrameOrigin(origin(for: panel.frame.size, near: point))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if translate { session.submit(Preferences.translationPrompt) }
    }

    @objc private func showResponseTimes() { openSettings(tab: "latency") }

    @objc private func showSettings() { openSettings(tab: nil) }

    private func openSettings(tab: String?) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Agent Assistant · 设置"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SettingsView(
                updateMonitor: { [weak self] in self?.refreshMonitor() },
                useClipboard: { [weak self] translate in self?.openClipboard(translate: translate) }))
            // Keep the chosen window size; by default the window grows to fit the tallest tab.
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setContentSize(NSSize(width: 720, height: 560))
            window.contentMinSize = NSSize(width: 600, height: 420)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === chat {
            session?.stop()
            session = nil
            chat = nil
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum AgentAssistantApp {
    @MainActor static func main() {
        // Writing to a CLI that already exited must not terminate the app.
        signal(SIGPIPE, SIG_IGN)
        CLIEnvironment.prepare()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

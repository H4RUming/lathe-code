import AppKit
import LatheLocalization
import SwiftUI

/// AppKit owns the quit decision so both Command-Q and the last workspace's red
/// close button await the same runtime cleanup before the process exits.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private weak var model: LatheAppModel?
    private var reopenWorkspace: (() -> Void)?
    private let workspaceWindows = NSHashTable<NSWindow>.weakObjects()
    private var windowDelegates: [ObjectIdentifier: WorkspaceWindowDelegate] = [:]
    private var terminationTask: Task<Void, Never>?
    private var terminationFinished = false
    private var statusItem: NSStatusItem?

    func configure(model: LatheAppModel, reopen: @escaping () -> Void) {
        self.model = model
        reopenWorkspace = reopen
    }

    func register(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let proxy = windowDelegates[key], window.delegate === proxy { return }
        let proxy = WorkspaceWindowDelegate(lifecycle: self, original: window.delegate)
        windowDelegates[key] = proxy
        workspaceWindows.add(window)
        window.delegate = proxy
    }

    fileprivate func shouldClose(_ window: NSWindow) -> Bool {
        if terminationFinished { return true }
        let otherWindows = workspaceWindows.allObjects.filter { $0 !== window }
        if !otherWindows.isEmpty { return true }
        // Keep this window intact until the user decides. Cancelling a close
        // must preserve the visible workspace and its draft.
        NSApp.terminate(nil)
        return false
    }

    fileprivate func didClose(_ window: NSWindow) {
        workspaceWindows.remove(window)
        windowDelegates.removeValue(forKey: ObjectIdentifier(window))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationFinished { return .terminateNow }
        if terminationTask != nil { return .terminateLater }
        guard let model else { return .terminateNow }
        model.beginExitDecision()
        terminationTask = Task { [weak self] in
            guard let self else { return }
            if await model.requiresTerminationConfirmation() {
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.text("app.exit.title", table: "AppMessages")
                alert.informativeText = L10n.text("app.exit.message", table: "AppMessages")
                alert.addButton(withTitle: L10n.text("app.exit.stopAndQuit", table: "AppMessages"))
                alert.addButton(withTitle: L10n.text("app.exit.keepInBackground", table: "AppMessages"))
                alert.addButton(withTitle: L10n.text("app.exit.cancel", table: "AppMessages"))
                alert.buttons.last?.keyEquivalent = "\u{1b}"
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    break
                case .alertSecondButtonReturn:
                    model.cancelExitDecision()
                    self.terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                    // Cocoa may restore windows while cancelling termination.
                    // Apply the user's background choice after that transition.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.terminationTask == nil, self.model?.isShuttingDown != true else { return }
                        self.enterBackground()
                    }
                    return
                default:
                    model.cancelExitDecision()
                    self.terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await model.shutdown()
            self.terminationFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWorkspace() }
        return false
    }

    private func enterBackground() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "hammer.circle", accessibilityDescription: L10n.text("app.menu.backgroundStatus", table: "AppMessages"))
            item.button?.toolTip = L10n.text("app.menu.backgroundStatus", table: "AppMessages")
            let menu = NSMenu()
            let open = NSMenuItem(title: L10n.text("app.menu.open", table: "AppMessages"), action: #selector(showWorkspace), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: L10n.text("app.menu.quit", table: "AppMessages"), action: #selector(quitFromMenu), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            item.menu = menu
            statusItem = item
        }
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows { window.orderOut(nil) }
    }

    @objc private func showWorkspace() {
        guard model?.isShuttingDown != true else { return }
        NSApp.setActivationPolicy(.regular)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        let windows = workspaceWindows.allObjects
        if windows.isEmpty {
            reopenWorkspace?()
        } else {
            for window in windows {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

/// Preserve SwiftUI's original window delegate for events we do not own.
@MainActor
private final class WorkspaceWindowDelegate: NSObject, NSWindowDelegate {
    weak var lifecycle: AppLifecycleDelegate?
    weak var original: (any NSWindowDelegate)?

    init(lifecycle: AppLifecycleDelegate, original: (any NSWindowDelegate)?) {
        self.lifecycle = lifecycle
        self.original = original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        return lifecycle?.shouldClose(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow { lifecycle?.didClose(window) }
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        MainActor.assumeIsolated {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        // Objective-C forwarding is synchronous on AppKit's main thread. The
        // wrapper carries its non-Sendable return through assumeIsolated without
        // introducing an executor hop or exposing the delegate to another task.
        MainActor.assumeIsolated {
            ForwardedDelegate(value: original?.responds(to: selector) == true
                ? original : super.forwardingTarget(for: selector))
        }.value
    }

    private struct ForwardedDelegate: @unchecked Sendable { let value: Any? }
}

struct WorkspaceWindowRegistration: NSViewRepresentable {
    let lifecycle: AppLifecycleDelegate

    func makeNSView(context: Context) -> WindowRegistrationView {
        let view = WindowRegistrationView()
        view.lifecycle = lifecycle
        return view
    }

    func updateNSView(_ view: WindowRegistrationView, context: Context) {
        view.lifecycle = lifecycle
        if let window = view.window { lifecycle.register(window) }
    }
}

final class WindowRegistrationView: NSView {
    weak var lifecycle: AppLifecycleDelegate?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { lifecycle?.register(window) }
    }
}

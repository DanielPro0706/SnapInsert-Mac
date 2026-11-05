import AppKit
import Combine
import SwiftUI

@main
struct SnapInsertMacApp: App {
    @NSApplicationDelegateAdaptor(ReceiverAppDelegate.self) private var appDelegate
    private var receiver: MacReceiver { appDelegate.receiver }
    @AppStorage(ReceiverWindow.menuIconPreference) private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup("SnapInsert", id: ReceiverWindow.id) {
            ReceiverMainWindow(receiver: receiver, appDelegate: appDelegate)
        }
        .defaultSize(width: 400, height: 640)
        .windowResizability(.contentMinSize)
        .commands { ReceiverWindowCommands() }
        .suppressAutomaticReceiverPresentation()

        MenuBarExtra("SnapInsert", systemImage: receiver.isListening ? "camera.badge.ellipsis" : "camera", isInserted: $showMenuBarIcon) {
            MenuReceiverSurface(receiver: receiver)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Presentation and application lifetime stay independent of photo transport.
@MainActor
final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    // The delegate lives for the process lifetime, including when neither UI surface is visible.
    let receiver = MacReceiver()
    var reopenControlWindow: (() -> Void)?
    private var mainWindows: [ObjectIdentifier: TrackedReceiverWindow] = [:]
    private var recoveryWindow: NSWindow?

    override init() {
        super.init()
        ReceiverWindow.activationController = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApplication.shared.windows where window.identifier?.rawValue == ReceiverWindow.id {
            registerMainWindow(window)
        }
        updateActivationPolicy()
        // A saved hidden menu icon must never turn a fresh launch into an inaccessible receiver.
        let menuVisible = UserDefaults.standard.object(forKey: ReceiverWindow.menuIconPreference) as? Bool ?? true
        if !menuVisible, !hasOpenMainWindow { reopenMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Ignore the unscoped flag: a menu popover is not the app's control window.
        reopenMainWindow()
        return false
    }

    func registerMainWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == ReceiverWindow.id else { return }
        let id = ObjectIdentifier(window)
        guard mainWindows[id] == nil else { return }
        let tracked = TrackedReceiverWindow(window: window)
        mainWindows[id] = tracked
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification, NSWindow.willCloseNotification]
        for name in names {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self, weak window] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window, let entry = self.mainWindows[ObjectIdentifier(window)] else { return }
                        if closing {
                            entry.isClosing = true
                            entry.subscriptions.removeAll()
                            self.mainWindows.removeValue(forKey: ObjectIdentifier(window))
                        } else if window.isVisible || window.isMiniaturized {
                            entry.hasBeenPresented = true
                        }
                        self.updateActivationPolicy()
                    }
                }
                .store(in: &tracked.subscriptions)
        }
        // SwiftUI attaches its content before ordering a new or restored window onto the screen.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, let entry = self.mainWindows[ObjectIdentifier(window)] else { return }
            if !entry.isClosing, window.isVisible || window.isMiniaturized { entry.hasBeenPresented = true }
            self.updateActivationPolicy()
        }
    }

    func presentMainWindow(_ window: NSWindow) {
        registerMainWindow(window)
        if let tracked = mainWindows[ObjectIdentifier(window)] {
            tracked.isClosing = false
            tracked.hasBeenPresented = true
        }
        updateActivationPolicy()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var hasOpenMainWindow: Bool {
        mainWindows.values.contains { tracked in
            guard let window = tracked.window, !tracked.isClosing else { return false }
            // A hidden or minimized window is still open; keep its Dock recovery entry.
            return tracked.hasBeenPresented || window.isVisible || window.isMiniaturized
        }
    }

    private func updateActivationPolicy() {
        mainWindows = mainWindows.filter { $0.value.window != nil }
        let desired: NSApplication.ActivationPolicy = hasOpenMainWindow ? .regular : .accessory
        let application = NSApplication.shared
        if application.activationPolicy() != desired { application.setActivationPolicy(desired) }
    }

    private func reopenMainWindow() {
        if let existing = ReceiverWindow.existing {
            presentMainWindow(existing)
        } else if let recoveryWindow {
            presentMainWindow(recoveryWindow)
        } else if let reopenControlWindow {
            reopenControlWindow()
        } else {
            // The SwiftUI opener doesn't exist until its scene has appeared at least once.
            // This fallback also works on a first launch with a previously hidden menu icon.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "SnapInsert"
            window.identifier = NSUserInterfaceItemIdentifier(ReceiverWindow.id)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:
                ReceiverPanel(receiver: receiver, placement: .mainWindow).frame(minWidth: 368, minHeight: 320))
            window.center()
            recoveryWindow = window
            presentMainWindow(window)
        }
    }
}

@MainActor
private final class TrackedReceiverWindow {
    weak var window: NSWindow?
    var hasBeenPresented: Bool
    var isClosing = false
    var subscriptions = Set<AnyCancellable>()

    init(window: NSWindow) {
        self.window = window
        hasBeenPresented = window.isVisible || window.isMiniaturized
    }
}

enum ReceiverWindow {
    static let id = "snapinsert-receiver"
    static let menuIconPreference = "showMenuBarIcon"
    @MainActor static weak var activationController: ReceiverAppDelegate?

    @MainActor
    static var existing: NSWindow? {
        let windows = NSApplication.shared.windows.filter { $0.identifier?.rawValue == id }
        return windows.first(where: { $0.isVisible || $0.isMiniaturized }) ?? windows.first
    }

    @MainActor
    static func show(using openWindow: OpenWindowAction) {
        if let existing {
            if let activationController { activationController.presentMainWindow(existing) }
            else { existing.makeKeyAndOrderFront(nil) }
        } else {
            openWindow(id: id)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private extension Scene {
    func suppressAutomaticReceiverPresentation() -> some Scene {
        // SceneBuilder doesn't support an if/else. Its public availability erasure
        // preserves a single return type while keeping the macOS 14 scene intact.
        if #available(macOS 15.0, *) {
            // Suppress a new default window while leaving system window restoration enabled.
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(defaultLaunchBehavior(.suppressed)))
        } else {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
        }
    }
}

private struct ReceiverMainWindow: View {
    let receiver: MacReceiver
    let appDelegate: ReceiverAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ReceiverPanel(receiver: receiver, placement: .mainWindow)
            .frame(minWidth: 368, minHeight: 320)
            .background(ReceiverWindowMarker(appDelegate: appDelegate))
            .onAppear {
                let action = openWindow
                appDelegate.reopenControlWindow = { ReceiverWindow.show(using: action) }
            }
    }
}

private struct ReceiverWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开主窗口") { ReceiverWindow.show(using: openWindow) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

private struct MenuReceiverSurface: View {
    let receiver: MacReceiver
    @State private var height: CGFloat = 620

    var body: some View {
        ReceiverPanel(receiver: receiver, placement: .menuBar)
            // A ScrollView has no useful intrinsic height for a MenuBarExtra window.
            .frame(width: 368, height: height)
            .background(AvailableScreenHeightReader { available in
                height = min(620, max(1, available - 32))
            })
    }
}

private struct ReceiverWindowMarker: NSViewRepresentable {
    let appDelegate: ReceiverAppDelegate
    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.appDelegate = appDelegate
        return view
    }
    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.appDelegate = appDelegate
        nsView.markWindow()
    }

    final class MarkerView: NSView {
        weak var appDelegate: ReceiverAppDelegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            markWindow()
        }
        func markWindow() {
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(ReceiverWindow.id)
            appDelegate?.registerMainWindow(window)
        }
    }
}

/// Read the popover's own screen, including when it moves between displays.
private struct AvailableScreenHeightReader: NSViewRepresentable {
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenView { ScreenView() }
    func updateNSView(_ nsView: ScreenView, context: Context) {
        nsView.onHeightChange = onHeightChange
        nsView.reportHeight()
    }

    final class ScreenView: NSView {
        var onHeightChange: ((CGFloat) -> Void)?
        private var subscriptions = Set<AnyCancellable>()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            subscriptions.removeAll()
            guard window != nil else { return }
            for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
                NotificationCenter.default.publisher(for: name)
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in self?.reportHeight() }
                    }
                    .store(in: &subscriptions)
            }
            reportHeight()
        }

        func reportHeight() {
            guard let available = window?.screen?.visibleFrame.height else { return }
            Task { @MainActor [weak self] in self?.onHeightChange?(available) }
        }
    }
}

import AppKit
import Combine
import SwiftUI

/// The menu bar item and its panel, drawn by DeskBar itself (rather than SwiftUI's MenuBarExtra,
/// which on macOS 26 forces Liquid Glass) on the standard frosted popover material.
@MainActor
final class StatusPanel: NSObject {
    static private(set) var shared: StatusPanel?

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel()
    private let host: ResizingHostingView<AnyView>
    private var outsideClick: Any?
    private var escape: Any?
    private var labelUpdates: AnyCancellable?
    /// Opens the DeskBar window. SwiftUI's openWindow only works from a hosted view, so a tiny one
    /// lives off-screen for as long as the app runs.
    private let opener = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1),
                                 styleMask: .borderless, backing: .buffered, defer: false)
    private var openDashboardAction: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        // Empty while closed: the panel's views only exist (and only update) while you can see them.
        host = ResizingHostingView(rootView: AnyView(EmptyView()))
        super.init()
        Self.shared = self

        // A stable name, so macOS remembers where you ⌘-drag the item.
        item.autosaveName = "DeskBar"
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
        }
        updateLabel()
        labelUpdates = model.stats.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.updateLabel() }

        host.sizingOptions = [.intrinsicContentSize]
        host.onResize = { [weak self] in self?.place() }
        // The standard frosted material macOS uses for menus and popovers.
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        // The content hangs from the top edge at its own height, and place() sizes the window to it.
        // (Pinned to all four edges, a frame where the two sizes disagreed centred the content,
        // so the top of the panel jumped.)
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
        ])
        panel.contentView = material

        opener.contentView = NSHostingView(rootView: DashboardOpener { [weak self] action in self?.openDashboardAction = action })
        opener.orderFrontRegardless()
    }

    var isOpen: Bool { panel.isVisible }

    @objc func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        host.rootView = AnyView(Panel(model: model))
        host.layoutSubtreeIfNeeded()
        place()
        // Like Apple's menu bar panels: take focus while open, so Escape and the shortcuts work.
        // (macOS grants this for a real click on the menu bar item; a click inside the panel also does.)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        // Close on a click anywhere else, or Escape, like a menu.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.close() }; return nil }
            return event
        }
    }

    func close() {
        panel.orderOut(nil)
        host.rootView = AnyView(EmptyView())
        item.button?.highlight(false)
        [outsideClick, escape].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideClick = nil
        escape = nil
    }

    func openDashboard() {
        openDashboardAction?()
        NSApp.activate()
        close()
    }

    /// Under the menu bar item, top edge fixed, kept on screen.
    private func place() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let top = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private var shownLabel = ""

    /// Redraws the menu bar item only when what it says changes (stats publish every 2 s).
    private func updateLabel() {
        guard let button = item.button else { return }
        let label = MenuBarLabel.content(stats: model.stats)
        button.setAccessibilityLabel("DeskBar: " + label.accessibility)   // cheap; VoiceOver hears the details
        // Redraw only when what you see changes, not with every temperature tick.
        guard label.symbol + label.text != shownLabel else { return }
        shownLabel = label.symbol + label.text
        button.image = NSImage(systemSymbolName: label.symbol, accessibilityDescription: "DeskBar")
        button.image?.isTemplate = true
        button.title = label.text.isEmpty ? "" : " " + label.text   // the glyph alone when all's clear
    }
}

/// A borderless panel that can take key status (for Escape and the footer's shortcuts)
/// without activating DeskBar or taking focus from your app's windows.
final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

/// Reports when its SwiftUI content changes size, so the panel can grow and shrink with it.
final class ResizingHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

/// Hands SwiftUI's openWindow action to AppKit.
private struct DashboardOpener: View {
    let provide: (@escaping () -> Void) -> Void
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onAppear { provide { openWindow(id: "dashboard") } }
    }
}

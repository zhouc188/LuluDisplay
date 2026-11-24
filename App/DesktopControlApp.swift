import AppKit
import SwiftUI
import Combine

#if !APPKIT_SMOKE_TEST
@main @MainActor
struct DesktopControlApp {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}
#endif

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    let model: DesktopModel
    private(set) var status: NSStatusItem?
    private var menuPanel: MenuPanel?
    private var settings: NSWindow?
    private var outsideClickMonitors: [Any] = []
    private var confirmation: NSPanel?
    private var resolutionChanges: AnyCancellable?
    private var blackoutChanges: AnyCancellable?
    private var screenChanges: AnyCancellable?
    private var screenGeometry = [ScreenGeometry]()

    private struct ScreenGeometry: Equatable {
        let id: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private func currentScreenGeometry() -> [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(id: $0.displayID, frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
    private(set) var blackoutVerification: NSPanel?
    let brightnessHUD = BrightnessHUDController()

    init(model: DesktopModel = DesktopModel()) {
        self.model = model
    }

    var popoverWindow: NSWindow? { menuPanel }
    var isPopoverVisible: Bool { menuPanel?.isVisible == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onBrightnessFeedback = { [weak self] feedback in
            if let feedback { self?.brightnessHUD.show(feedback) }
            else { self?.brightnessHUD.hide() }
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "LuluDisplay")
        status?.button?.toolTip = String(localized: "LuluDisplay")
        status?.button?.target = self
        status?.button?.action = #selector(togglePopover)
        resolutionChanges = model.resolution.$active.sink { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                if change != nil && self.model.resolution.active != nil {
                    self.showResolutionConfirmation()
                } else if self.model.resolution.active == nil {
                    self.confirmation?.orderOut(nil)
                }
            }
        }
        blackoutChanges = model.$awaitingProof.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.model.awaitingProof { self.showBlackoutVerification() }
                else { self.blackoutVerification?.orderOut(nil) }
            }
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPanelOutsideMouse() }
        }) { outsideClickMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if let self, event.window !== self.menuPanel, event.window !== self.status?.button?.window {
                self.dismissPanelOutsideMouse()
            }
            return event
        }) { outsideClickMonitors.append(monitor) }
        screenGeometry = currentScreenGeometry()
        screenChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let geometry = self.currentScreenGeometry()
                    guard geometry != self.screenGeometry else { return }
                    self.screenGeometry = geometry
                    // The old anchor may no longer exist after hot-plug or a scale change.
                    self.menuPanel?.orderOut(nil)
                    self.brightnessHUD.hide()
                }
            }
        model.start()
        #if !APPKIT_SMOKE_TEST
        model.configureDefaultLoginItem()
        #endif
    }

    @objc private func togglePopover() {
        if isPopoverVisible {
            menuPanel?.orderOut(nil)
            return
        }
        guard let button = status?.button, let anchor = button.window else { return }
        let buttonFrame = anchor.convertToScreen(button.convert(button.bounds, to: nil))
        let center = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? anchor.screen else {
            #if APPKIT_SMOKE_TEST
            print("DIAGNOSTIC no anchor screen for \(buttonFrame)")
            #endif
            return
        }
        screenGeometry = currentScreenGeometry()
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(442, bounds.width)
        let target = NSWorkspace.shared.frontmostApplication
        model.refreshLoginStatus()
        model.refreshAccessibilityStatus()
        let content = NSHostingView(rootView: PanelView(
            model: model, settings: showSettings, windowAction: { [weak self] action in
                guard let self else { return }
                self.model.refreshAccessibilityStatus()
                if !self.model.accessibilityAuthorized {
                    self.model.notice = WindowManagementService.permissionMessage
                    return
                }
                self.menuPanel?.orderOut(nil)
                self.model.windows.perform(action, in: target)
            }, width: width, maximumHeight: bounds.height
        ))
        let height = min(ceil(content.fittingSize.height), bounds.height)
        let frame = CGRect(x: max(bounds.minX, min(center.x - width / 2, bounds.maxX - width)),
                           y: max(bounds.minY, min(buttonFrame.minY - 6, bounds.maxY) - height),
                           width: width, height: height)
        let panel = menuPanel ?? MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        content.sizingOptions = []
        panel.contentView = content
        panel.setFrame(frame, display: false)
        menuPanel = panel
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func dismissPanelOutsideMouse() {
        guard let panel = menuPanel, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        panel.orderOut(nil)
    }

    func showSettings() {
        model.refreshAccessibilityStatus()
        menuPanel?.orderOut(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "LuluDisplay 设置")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settings = window
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    private func showResolutionConfirmation() {
        menuPanel?.orderOut(nil)
        if confirmation == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                                styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            panel.title = String(localized: "确认显示模式")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: ModeConfirmation(service: model.resolution)
                .padding(16).frame(width: 420))
            confirmation = panel
        }
        confirmation?.center()
        NSApp.activate()
        confirmation?.makeKeyAndOrderFront(nil)
    }

    private func showBlackoutVerification() {
        brightnessHUD.hide()
        guard model.overlays.sessionSafe else { return }
        menuPanel?.orderOut(nil)
        if blackoutVerification == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 225),
                                styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            panel.title = String(localized: "同步全黑前验证恢复键")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // Remain readable above software dimming without entering a modal event loop.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: BlackoutVerificationView(model: model))
            blackoutVerification = panel
        }
        blackoutVerification?.center()
        NSApp.activate()
        blackoutVerification?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
        model.stop()
        brightnessHUD.hide()
        blackoutVerification?.orderOut(nil)
    }
}


@MainActor
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class BrightnessHUDController {
    private(set) var window: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var content: NSHostingView<BrightnessHUDView>?

    func show(_ feedback: BrightnessFeedback) {
        guard feedback.value > 0,
              let screen = NSScreen.screens.first(where: { $0.displayID == feedback.displayID }) else {
            hide()
            return
        }
        dismissal?.cancel()
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(254, bounds.width), height: min(68, bounds.height))
        let frame = CGRect(x: bounds.midX - size.width / 2,
                           y: min(bounds.maxY - size.height, bounds.minY + min(80, bounds.height * 0.1)),
                           width: size.width, height: size.height)
        let panel = window ?? BrightnessHUDPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let appearing = !panel.isVisible
        if let content, !appearing {
            // Preserve view identity so repeated key presses animate from the previous value.
            content.rootView = BrightnessHUDView(feedback: feedback)
        } else {
            let content = NSHostingView(rootView: BrightnessHUDView(feedback: feedback))
            content.sizingOptions = []
            panel.contentView = content
            self.content = content
        }
        panel.setFrame(frame, display: false)
        window = panel
        if appearing { panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            self?.window?.orderOut(nil)
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        window?.orderOut(nil)
    }
}

@MainActor
private final class BrightnessHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

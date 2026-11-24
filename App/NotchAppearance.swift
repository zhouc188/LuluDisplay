import AppKit

@MainActor final class NotchAppearanceService {
    private var overlays = [CGDirectDisplayID: OverlayWindow]()
    private(set) var available = false

    func update(_ displays: [Display], enabled: Bool) {
        clear()
        let notched = displays.filter { $0.builtIn && ($0.screen?.safeAreaInsets.top ?? 0) > 0 }
        available = !notched.isEmpty
        guard enabled else { return }
        for display in notched {
            guard let screen = display.screen else { continue }
            let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                               width: screen.frame.width, height: screen.safeAreaInsets.top)
            let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            let window = OverlayWindow(frame: frame, level: level)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.orderFrontRegardless()
            overlays[display.id] = window
        }
    }

    func clear() {
        overlays.values.forEach { $0.close() }
        overlays = [:]
    }
}

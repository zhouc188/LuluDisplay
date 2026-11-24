import AppKit
import Carbon

@MainActor final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = level
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

@MainActor final class BlackoutCoordinator {
    private var windows = [CGDirectDisplayID: OverlayWindow]()
    private var animations = [CGDirectDisplayID: Task<Void, Never>]()
    private var black = Set<CGDirectDisplayID>()
    var hasOverlays: Bool { !windows.isEmpty }
    var blackIDs: Set<CGDirectDisplayID> { black }
    #if APPKIT_SMOKE_TEST
    var testOpacities: [CGDirectDisplayID: Double] { windows.mapValues { Double($0.alphaValue) } }
    #endif
    var sessionActive = true

    var sessionSafe: Bool {
        guard sessionActive, !IsSecureEventInputEnabled(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey] as? Bool == true,
              session[kCGSessionLoginDoneKey] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return false }
        return true
    }

    @discardableResult
    func apply(_ value: Double, display: Display, smooth: Bool) -> Bool {
        guard let screen = display.screen, sessionSafe, CGDisplayIsAsleep(display.id) == 0 else { return false }
        if value >= 100 { remove(display.id); return true }
        let id = display.id
        let wasBlack = black.remove(id) != nil
        if value == 0 { black.insert(id) }
        let window: OverlayWindow
        if let existing = windows[id] { window = existing }
        else {
            window = OverlayWindow(frame: screen.frame, level: .init(rawValue: NSWindow.Level.screenSaver.rawValue - 1))
            window.alphaValue = 0
            windows[id] = window
        }
        let opacity = 1 - value / 100
        animations.removeValue(forKey: id)?.cancel()
        window.orderFrontRegardless()
        if smooth && value > 0 && !wasBlack {
            let start = window.alphaValue
            animations[id] = Task { @MainActor in
                for step in 1...8 {
                    do { try await Task.sleep(for: .milliseconds(15)) } catch { return }
                    window.alphaValue = start + (opacity - start) * Double(step) / 8
                }
                animations[id] = nil
            }
        } else {
            window.alphaValue = opacity
        }
        return true
    }

    func remove(_ id: CGDirectDisplayID) {
        animations.removeValue(forKey: id)?.cancel()
        black.remove(id)
        windows.removeValue(forKey: id)?.close()
    }

    func clear() { for id in Array(windows.keys) { remove(id) } }
}

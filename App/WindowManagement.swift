import AppKit
import ApplicationServices

@MainActor final class WindowManagementService {
    var gap: CGFloat = 8
    var issue: ((String) -> Void)?
    private var monitor: Any?
    private var initialWindow: AXUIElement?
    private var initialFrame: CGRect?
    private var dragged = false

    static let permissionMessage = String(localized: "系统尚未允许当前版本控制窗口。若 LuluDisplay 的授权开关已打开，请退出并重新打开应用；仍无效时，在系统设置中移除旧条目，再添加「应用程序」里的 LuluDisplay。")

    var authorized: Bool {
        let trusted = AXIsProcessTrusted()
        // A real read can detect a stale trust verdict without prompting or changing permissions.
        let foreground = NSWorkspace.shared.frontmostApplication
        let app = foreground?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            ? foreground : NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        guard let app else { return trusted }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.2)
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(target, &names)
        return Self.resolveAuthorization(trusted: trusted, probe: result)
    }

    static func resolveAuthorization(trusted: Bool, probe: AXError) -> Bool {
        switch probe {
        case .success: return true
        case .apiDisabled: return false
        default: return trusted // An unresponsive/unsupported target is not evidence of denial.
        }
    }

    func requestAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setSnapping(_ enabled: Bool) -> Bool {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        initialWindow = nil
        initialFrame = nil
        guard enabled else { return true }
        guard authorized else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.mouse(type) }
        }
        return monitor != nil
    }

    func perform(_ action: HotkeyAction, in application: NSRunningApplication? = nil) {
        guard authorized else {
            issue?(Self.permissionMessage)
            return
        }
        guard let window = focusedWindow(in: application), let frame = frame(of: window) else {
            issue?(String(localized: "无法读取当前窗口。"))
            return
        }
        let screens = NSScreen.screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
        guard let index = screens.indices.max(by: {
            frame.intersection(area(screens[$0].frame)).surface < frame.intersection(area(screens[$1].frame)).surface
        }), !frame.intersection(area(screens[index].frame)).isEmpty else { return }
        let bounds = area(screens[index].visibleFrame).insetBy(dx: gap, dy: gap)
        var target = bounds
        switch action {
        case .left, .right:
            target.size.width = (bounds.width - gap) / 2
            if action == .right { target.origin.x = bounds.maxX - target.width }
        case .topThird, .bottomTwoThirds:
            let split = Self.verticalSplit(in: bounds, gap: gap)
            target = action == .topThird ? split.top : split.bottom
        case .maximize: break
        case .center:
            target.size = CGSize(width: min(frame.width, bounds.width), height: min(frame.height, bounds.height))
            target.origin = CGPoint(x: bounds.midX - target.width / 2, y: bounds.midY - target.height / 2)
        case .previous, .next:
            guard screens.count > 1 else { return }
            let delta = action == .next ? 1 : -1
            let destination = area(screens[(index + delta + screens.count) % screens.count].visibleFrame)
                .insetBy(dx: gap, dy: gap)
            let x = (frame.minX - bounds.minX) / max(1, bounds.width - frame.width)
            let y = (frame.minY - bounds.minY) / max(1, bounds.height - frame.height)
            target.size = CGSize(width: min(frame.width, destination.width), height: min(frame.height, destination.height))
            target.origin = CGPoint(x: destination.minX + min(1, max(0, x)) * (destination.width - target.width),
                                    y: destination.minY + min(1, max(0, y)) * (destination.height - target.height))
        default: return
        }
        move(window, to: target)
    }

    // Accessibility coordinates increase downward; bounds already excludes the menu bar,
    // Dock and outer window margins. Divide the remaining height in a 1:2 ratio.
    static func verticalSplit(in bounds: CGRect, gap: CGFloat) -> (top: CGRect, bottom: CGRect) {
        let height = max(0, bounds.height - gap)
        var top = bounds
        top.size.height = height / 3
        var bottom = bounds
        bottom.origin.y = top.maxY + gap
        bottom.size.height = height * 2 / 3
        return (top, bottom)
    }

    private func mouse(_ event: NSEvent.EventType) {
        switch event {
        case .leftMouseDown:
            initialWindow = focusedWindow()
            initialFrame = initialWindow.flatMap { frame(of: $0) }
            dragged = false
        case .leftMouseDragged:
            dragged = true
        case .leftMouseUp:
            defer { initialWindow = nil; initialFrame = nil; dragged = false }
            guard dragged, authorized, let original = initialWindow, let initialFrame,
                  let current = focusedWindow(), CFEqual(original, current),
                  let frame = frame(of: current), frame.size == initialFrame.size,
                  hypot(frame.minX - initialFrame.minX, frame.minY - initialFrame.minY) > 3 else { return }
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) else { return }
            let bounds = area(screen.visibleFrame).insetBy(dx: gap, dy: gap)
            var target = bounds
            if point.x <= screen.frame.minX + 8 {
                target.size.width = (bounds.width - gap) / 2
            } else if point.x >= screen.frame.maxX - 8 {
                target.size.width = (bounds.width - gap) / 2
                target.origin.x = bounds.maxX - target.width
            } else if point.y < screen.visibleFrame.maxY - 3 {
                return
            }
            move(current, to: target)
        default: break
        }
    }

    private func focusedWindow(in application: NSRunningApplication? = nil) -> AXUIElement? {
        guard let app = application ?? NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == kAXStandardWindowSubrole else { return nil }
        var full: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full)
        return (full as? Bool) == true ? nil : window
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func move(_ window: AXUIElement, to target: CGRect) {
        var position = target.origin
        var size = target.size
        guard let point = AXValueCreate(.cgPoint, &position), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        let positionKey = kAXPositionAttribute as CFString
        let sizeKey = kAXSizeAttribute as CFString
        var positionWritable = DarwinBoolean(false)
        var sizeWritable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, positionKey, &positionWritable) == .success, positionWritable.boolValue,
              let original = frame(of: window) else {
            issue?(String(localized: "应用不允许移动此窗口。"))
            return
        }
        let resize = original.size != target.size
        if resize {
            guard AXUIElementIsAttributeSettable(window, sizeKey, &sizeWritable) == .success, sizeWritable.boolValue,
                  AXUIElementSetAttributeValue(window, sizeKey, dimensions) == .success else {
                issue?(String(localized: "应用限制了此窗口的大小。"))
                return
            }
        }
        if AXUIElementSetAttributeValue(window, positionKey, point) != .success {
            var oldSize = original.size
            if resize, let old = AXValueCreate(.cgSize, &oldSize) { AXUIElementSetAttributeValue(window, sizeKey, old) }
            issue?(String(localized: "应用不允许移动此窗口。"))
        }
    }

    private func area(_ cocoa: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: cocoa.minX, y: top - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }
}

private extension CGRect {
    var surface: CGFloat { isNull ? 0 : width * height }
}

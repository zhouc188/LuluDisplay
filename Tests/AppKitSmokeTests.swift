import AppKit
import SwiftUI
import Carbon
import ApplicationServices

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

private struct NoHardwareWrites: BrightnessProvider {
    func probe(_ display: HardwareDisplay, experimental: Bool) async -> HardwareReading? { nil }

    func write(_ value: Double, to display: HardwareDisplay, path: BrightnessPath) async -> Double? {
        preconditionFailure("AppKit smoke tests must not write physical brightness.")
    }
}

@main @MainActor
struct AppKitSmokeTests {
    static func main() {
        let domain = "local.desktopcontrol.appkit-smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            FileHandle.standardError.write(Data("FAIL Could not open isolated preferences\n".utf8))
            exit(1)
        }
        let model = DesktopModel(hardware: NoHardwareWrites(), preferences: PreferencesStore(defaults))
        let controller = MenuBarController(model: model)
        let app = NSApplication.shared
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var exitCode: Int32 = 0
            do {
                for _ in 0..<30 where controller.status == nil { try await Task.sleep(for: .milliseconds(100)) }
                try await run(app, controller: controller)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                exitCode = 1
            }
            controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.delegate = nil
            defaults.removePersistentDomain(forName: domain)
            if exitCode == 0 { print("PASS AppKit smoke completed") }
            exit(exitCode)
        }
        app.run()
    }

    private static func run(_ app: NSApplication, controller: MenuBarController) async throws {
        let model = controller.model
        for bounds in [CGRect(x: 8, y: 32, width: 1424, height: 860),
                       CGRect(x: -1882, y: -400, width: 1874, height: 3300)] {
            for gap: CGFloat in [0, 8, 32] {
                let split = WindowManagementService.verticalSplit(in: bounds, gap: gap)
                try require(abs(split.top.minY - bounds.minY) < 0.001 &&
                            abs(split.bottom.maxY - bounds.maxY) < 0.001,
                            "Vertical presets must align to the usable screen edges in AX coordinates")
                try require(abs(split.bottom.minY - split.top.maxY - gap) < 0.001 &&
                            abs(split.bottom.height - 2 * split.top.height) < 0.001,
                            "Vertical presets must preserve the configured gap and 1:2 ratio")
                try require(split.top.minX == bounds.minX && split.bottom.width == bounds.width,
                            "Vertical presets must use the full usable width on secondary displays")
            }
        }
        print("PASS 上三分之一、下三分之二的比例、间距和横竖屏坐标")
        try testBrightnessKeys()
        try require(WindowManagementService.resolveAuthorization(trusted: false, probe: .success),
                    "A successful real AX read must override a stale denied trust verdict")
        try require(!WindowManagementService.resolveAuthorization(trusted: true, probe: .apiDisabled),
                    "A real AX denial must override a stale trusted verdict")
        try require(WindowManagementService.resolveAuthorization(trusted: true, probe: .cannotComplete),
                    "An unresponsive target must not be misreported as denied permission")
        try require(!WindowManagementService.resolveAuthorization(trusted: false, probe: .cannotComplete),
                    "An inconclusive probe must not grant permission")
        model.notice = "unrelated display notice"
        model.refreshAccessibilityStatus()
        try require(model.notice == "unrelated display notice", "Permission refresh must preserve unrelated errors")
        print("PASS 辅助功能缓存判定、真实拒绝与无关错误保留")
        try require(app.activationPolicy() == .accessory, "The application must launch as accessory")
        guard let button = controller.status?.button else { throw SmokeFailure(description: "Menu bar button missing") }
        for _ in 0..<30 where button.window?.isVisible != true { try await Task.sleep(for: .milliseconds(100)) }
        try require(button.window?.isVisible == true, "The menu bar must attach the status item")
        // WindowServer attaches the status window before settling its menu-bar position.
        var previousFrame = button.window?.frame
        var stableSamples = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let frame = button.window?.frame
            if frame == previousFrame, button.window?.screen != nil { stableSamples += 1 }
            else { stableSamples = 0 }
            previousFrame = frame
            if stableSamples >= 3 { break }
        }

        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        if !controller.isPopoverVisible {
            print("DIAGNOSTIC status frame=\(String(describing: button.window?.frame)) screens=\(NSScreen.screens.map(\.frame)) panel=\(String(describing: controller.popoverWindow?.frame)) sessionSafe=\(model.overlays.sessionSafe)")
        }
        try require(controller.isPopoverVisible, "The status button must open the popover")
        if let anchor = button.window, let panel = controller.popoverWindow {
            let rect = anchor.convertToScreen(button.convert(button.bounds, to: nil))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? anchor.screen
            try require(screen?.visibleFrame.contains(panel.frame) == true, "The entire popover must fit on the status item's screen")
        }

        controller.showSettings()
        try await Task.sleep(for: .milliseconds(300))
        guard let settings = app.windows.first(where: { $0.title == String(localized: "LuluDisplay 设置") }) else {
            throw SmokeFailure(description: "Settings window missing")
        }
        try require(settings.isVisible, "Opening settings must show the window")
        try require(!controller.isPopoverVisible, "Opening settings must dismiss the popover")
        try require(app.activationPolicy() == .accessory, "Showing settings must preserve accessory mode")
        settings.performClose(nil)
        try await Task.sleep(for: .milliseconds(300))
        try require(!settings.isVisible, "The standard close action must hide settings")
        try require(!controller.applicationShouldTerminateAfterLastWindowClosed(app), "Closing settings must keep the app running")

        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        try require(controller.isPopoverVisible, "The status button must still work after settings closes")
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        try require(!controller.isPopoverVisible, "The second status click must dismiss the popover")
        for _ in 0..<4 {
            button.performClick(nil)
            guard let panel = controller.popoverWindow, let anchor = button.window else {
                throw SmokeFailure(description: "Menu panel missing during repeated clicks")
            }
            let rect = anchor.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? anchor.screen
            try require(panel.isVisible && screen?.visibleFrame.contains(panel.frame) == true,
                        "Rapid reopening must keep the entire panel on screen")
            button.performClick(nil)
            try require(!panel.isVisible, "Rapid closing must hide the panel")
        }
        print("PASS 菜单栏打开、设置关闭、重新打开与 accessory 策略")

        model.notice = String(repeating: "显示器状态说明，需要完整阅读。", count: 30)
        for height: CGFloat in [260, 440, 720] {
            let host = NSHostingView(rootView: PanelView(model: model, settings: {}, windowAction: { _ in },
                                                       width: 442, maximumHeight: height))
            try require(host.fittingSize.height <= height && host.fittingSize.width <= 442,
                        "Long notices must scroll within the bounded panel, including a small screen")
        }
        model.notice = nil
        button.performClick(nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(350))
        try require(controller.isPopoverVisible, "An unchanged screen notification must not dismiss the menu")
        button.performClick(nil)
        print("PASS 小屏长提示布局边界与重复显示参数通知")

        for _ in 0..<50 where !model.probing.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let ready = model.displays.filter { model.canAdjustBrightness($0) }
        if !ready.isEmpty {
            model.setMaster(35)
            model.refresh()
            for _ in 0..<50 where !model.probing.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            try require(model.master == 100 && !model.overlays.hasOverlays,
                        "Refresh must rebase software brightness after clearing the old overlay")
            model.hotkeys.onAction?(.decrease)
            try require(model.master == 95 && ready.allSatisfy { model.values[$0.id] == 95 },
                        "First key after refresh must step down from the current level, not a saved stale value")
            model.recover()
            try require(model.master == 100 && !model.overlays.hasOverlays,
                        "Software recovery must rebase to the actual unobscured state")
            model.setMaster(.nan)
            try require(model.master == 100, "Non-finite input must not enter brightness state")
            model.setMaster(35)
            for display in ready { model.updateCalibration(display) { $0.software = false } }
            try require(!model.canAdjustMaster && model.masterDisplays.isEmpty,
                        "Unavailable brightness paths must not be advertised as adjustable")
            model.setMaster(40)
            try require(model.master == 35 && !model.overlays.hasOverlays,
                        "A request with no usable brightness path must not report success")
            for display in ready { model.updateCalibration(display) { $0.software = true } }
            try require(model.master == 100, "Re-enabling software control must rebase to the unobscured state")
            for display in ready { model.updateCalibration(display) { $0.participates = false } }
            try require(!model.canAdjustMaster, "Opting all displays out must disable the group slider")
            for display in ready { model.updateCalibration(display) { $0.participates = true } }
            model.notice = nil
            print("PASS 软件调暗重探测与恢复定基、无效输入、无可用通道与同步空组")
        }

        if !model.windows.authorized {
            model.setSnapping(true)
            try require(!model.snapping && model.notice != nil, "Window snapping must stay disabled without Accessibility permission")
            print("PASS 辅助功能权限未授予时窗口吸附保持关闭")
        }

        try require(model.hotkeys.isRegistered(.recover), "The default recovery key must be registered")
        let awake = model.displays.filter { $0.controllable && CGDisplayIsAsleep($0.id) == 0 }
        if let screen = NSScreen.screens.first, let displayID = screen.displayID {
            let hud = controller.brightnessHUD
            let keyWindow = app.keyWindow
            hud.show(BrightnessFeedback(displayID: displayID, title: "界面测试", value: 65))
            let content = hud.window?.contentView
            try await Task.sleep(for: .milliseconds(700))
            hud.show(BrightnessFeedback(displayID: displayID, title: "界面测试", value: 70))
            try require(hud.window?.contentView === content, "Repeated HUD updates must preserve the animated view")
            try await Task.sleep(for: .milliseconds(600))
            try require(hud.window?.isVisible == true && hud.window?.alphaValue == 1,
                        "An older dismissal must not hide a freshly updated HUD")
            try require(hud.window?.ignoresMouseEvents == true && app.keyWindow === keyWindow,
                        "Animated HUD must not intercept clicks or change focus")
            hud.show(BrightnessFeedback(displayID: displayID, title: "界面测试", value: 0))
            try require(hud.window?.isVisible == false, "Zero brightness must hide immediately without a fade delay")
            print("PASS 提示视图复用、连续更新计时、不抢焦点与全黑立即隐藏")
        }
        guard awake.count >= 2, let secondary = awake.first(where: { CGDisplayIsMain($0.id) == 0 }),
              model.overlays.sessionSafe else {
            print("SKIP 黑屏联动测试需要两台唤醒的独立显示器及未锁定的控制台")
            return
        }

        for _ in 0..<50 where !model.probing.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try require(model.probing.isEmpty, "Display discovery must finish before brightness tests")
        if let screenA = awake[0].screen, let screenB = awake[1].screen {
            let displayA = awake[0]
            let displayB = awake[1]
            let pointA = CGPoint(x: screenA.frame.midX, y: screenA.frame.midY)
            let pointB = CGPoint(x: screenB.frame.midX, y: screenB.frame.midY)
            model.setSync(true)
            model.setMaster(100)
            model.setSource(displayB.id)
            model.setSync(false)
            let keyWindow = app.keyWindow
            model.handleBrightnessKey(.decrease, at: pointA)
            try require(model.values[displayA.id] == 95 && model.values[displayB.id] == 100,
                        "With sync off, pointer screen must change instead of the selected source")
            try require(model.source == displayB.id, "Pointer routing must not rewrite the selected source")
            try require(controller.brightnessHUD.window?.isVisible == true &&
                        controller.brightnessHUD.window?.screen?.displayID == displayA.id,
                        "Brightness HUD must appear on the pointer's display")
            try require(controller.brightnessHUD.window?.ignoresMouseEvents == true &&
                        controller.brightnessHUD.window?.canBecomeKey == false && app.keyWindow === keyWindow,
                        "HUD must not intercept clicks or take keyboard focus")
            model.handleBrightnessKey(.decrease, at: pointA)
            model.handleBrightnessKey(.increase, at: pointA)
            try require(model.values[displayA.id] == 95 && model.values[displayB.id] == 100,
                        "Repeated pointer keys must retain the correct target")
            model.setSync(true)
            model.setMaster(95)
            model.handleBrightnessKey(.increase, at: pointB)
            try require(awake.allSatisfy { model.values[$0.id] == 100 }, "Sync on must adjust all participants")
            try require(controller.brightnessHUD.window?.screen?.displayID == displayB.id &&
                        controller.brightnessHUD.window.map { screenB.visibleFrame.contains($0.frame) } == true,
                        "HUD must move to the pointer's display and remain inside its visible bounds")
            try await Task.sleep(for: .milliseconds(1400))
            try require(controller.brightnessHUD.window?.isVisible == false, "HUD must dismiss automatically")
            print("PASS 鼠标屏单独调节、同步全部、提示位置、不抢焦点与自动消失")
        }
        model.setMaster(5)
        try require(awake.allSatisfy { model.values[$0.id] == 5 }, "Both screens must reach the same requested minimum step")
        model.hotkeys.onAction?(.decrease)
        try require(model.overlays.blackIDs.isEmpty, "Blackout of every screen must require shortcut verification")
        try require(model.awaitingProof && model.master == 5,
                    "Rejected zero must retain the nonzero value and request visible verification")
        try await Task.sleep(for: .milliseconds(100))
        try require(controller.blackoutVerification?.isVisible == true,
                    "Keyboard-only dimming must show verification without opening the menu")
        try require(controller.blackoutVerification?.level == .screenSaver,
                    "Recovery instructions must remain readable above the dimming layers")
        model.cancelBlackoutVerification()
        try await Task.sleep(for: .milliseconds(100))
        try require(controller.blackoutVerification?.isVisible == false && model.master == 5,
                    "Cancelling verification must close the prompt without darkening screens")
        model.hotkeys.onAction?(.decrease)
        try sendRecoveryEvent()
        try require(model.notice?.contains("已验证") == true, "Recovery event must complete the proof")
        try await Task.sleep(for: .milliseconds(100))
        try require(controller.blackoutVerification?.isVisible == false, "Successful verification must close its panel")
        // Inspect real AppKit windows and restore them in the same run-loop turn,
        // so this test does not leave the user's entire desktop black.
        model.setMaster(0)
        try require(model.master == 0 && model.overlays.blackIDs == Set(awake.map(\.id)),
                    "Verified group zero must cover every participating screen")
        try require(awake.allSatisfy { model.values[$0.id] == 0 && model.overlays.testOpacities[$0.id] == 1 },
                    "Every screen must use exactly opaque black at zero, regardless of panel brightness")
        model.hotkeys.onAction?(.increase)
        try require(!model.overlays.hasOverlays && model.master == 100, "Brightness-up must clear software dimming and rebase the entire group")
        print("PASS 持续降亮度的可见验证提示、取消、双屏 0% 不透明度与提高亮度恢复")
        // Test the real overlay on one secondary display. The main display remains visible.
        model.setSync(false)
        model.setIndividual(secondary, value: 0)
        try require(model.overlays.blackIDs == [secondary.id], "Only the secondary display must be blacked out")
        try sendRecoveryEvent()
        try require(!model.overlays.hasOverlays && model.master == 100, "Recovery event must clear software dimming and rebase to the visible level")
        print("PASS 全屏组预验证、单副屏黑屏及 Carbon 恢复事件")
    }

    private static func sendRecoveryEvent() throws {
        var event: EventRef?
        let result = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                                 EventAttributes(kEventAttributeUserEvent), &event)
        guard result == noErr, let event else { throw SmokeFailure(description: "Could not create recovery event") }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: HotkeyService.signature, id: HotkeyAction.recover.rawValue)
        let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          MemoryLayout<EventHotKeyID>.size, &id)
        try require(parameter == noErr, "Could not set the recovery event parameter")
        try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Recovery event was not handled")
    }

    private static func testBrightnessKeys() throws {
        let f1 = BrightnessKeyPress.decode(type: .keyDown, keyCode: UInt16(kVK_F1))!
        let f2 = BrightnessKeyPress.decode(type: .keyDown, keyCode: UInt16(kVK_F2), modifiers: .function)!
        try require(f1.action == .decrease && f2.action == .increase, "Both function-key modes must decode")
        let mediaUp = BrightnessKeyPress.decode(type: .keyDown, keyCode: 144)!
        let mediaDown = BrightnessKeyPress.decode(type: .keyDown, keyCode: 145)!
        let mediaRelease = BrightnessKeyPress.decode(type: .keyUp, keyCode: 145)!
        try require(mediaUp.action == .increase && mediaDown.action == .decrease && !mediaRelease.down,
                    "Direct media brightness keycodes must work without Fn")
        var mediaRouting = BrightnessKeyRouting()
        try require(mediaRouting.route(mediaDown, available: true).action == .decrease,
                    "Direct media brightness must reach the same brightness action")
        let mediaEnd = mediaRouting.route(mediaRelease, available: true)
        try require(mediaEnd.consume && mediaEnd.action == nil, "Direct media key-up must not adjust again")
        try require(BrightnessKeyPress.decode(type: .keyDown, keyCode: 144, modifiers: .option) == nil,
                    "Modified media brightness must keep its system behavior")
        try require(BrightnessKeyPress.decode(type: .keyDown, keyCode: UInt16(kVK_ANSI_A)) == nil,
                    "Ordinary typing must not be intercepted")
        try require(BrightnessKeyPress.decode(type: .keyDown, keyCode: UInt16(kVK_F1), modifiers: .command) == nil,
                    "Modified function-key shortcuts must pass through")
        try require(BrightnessKeyPress.decode(type: .systemDefined, subtype: 8, data1: (0 << 16) | 0x0a00) == nil,
                    "Volume keys must pass through")
        try require(BrightnessKeyPress.decode(type: .systemDefined, subtype: 7, data1: (2 << 16) | 0x0a00) == nil,
                    "Other system events must pass through")
        let up = BrightnessKeyPress.decode(type: .systemDefined, subtype: 8, data1: (2 << 16) | 0x0a00)!
        let down = BrightnessKeyPress.decode(type: .systemDefined, subtype: 8, data1: (3 << 16) | 0x0a00)!
        let release = BrightnessKeyPress.decode(type: .systemDefined, subtype: 8, data1: (2 << 16) | 0x0b00)!
        try require(up.action == .increase && down.action == .decrease && !release.down, "Media-key direction and release")
        var routing = BrightnessKeyRouting()
        try require(!routing.route(up, available: false).consume, "Unavailable controls must leave the system key alone")
        try require(!routing.route(release, available: true).consume, "Unclaimed key releases must pass through")
        let first = routing.route(up, available: true)
        try require(first.consume && first.action == .increase, "Claimed key-down must dispatch once")
        try require(routing.route(up, available: true).action == .increase, "Held brightness keys must repeat")
        let end = routing.route(release, available: true)
        try require(end.consume && end.action == nil, "Key-up must not change brightness a second time")
        try require(!routing.route(release, available: true).consume, "Release must clear held-key state")
        print("PASS F1/F2、太阳键、长按、抬键、修饰键和其他按键透传")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(description: message) }
    }
}

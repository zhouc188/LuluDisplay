import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices

@MainActor final class DesktopModel: NSObject, ObservableObject {
    @Published private(set) var displays = [Display]()
    @Published private(set) var readings = [CGDirectDisplayID: HardwareReading]()
    @Published private(set) var values = [CGDirectDisplayID: Double]()
    @Published private(set) var calibrations = [CGDirectDisplayID: Calibration]()
    @Published private(set) var issues = [CGDirectDisplayID: String]()
    @Published private(set) var probing = Set<CGDirectDisplayID>()
    @Published var notice: String?
    var onBrightnessFeedback: ((BrightnessFeedback?) -> Void)?
    @Published private(set) var login = SMAppService.mainApp.status
    @Published private(set) var loginError: String?
    @Published private(set) var master = 50.0
    @Published private(set) var source: CGDirectDisplayID?
    @Published private(set) var sync = true
    @Published private(set) var relative = true
    @Published private(set) var smooth = false
    @Published private(set) var experimental = false
    @Published private(set) var followSystemBrightness = false
    @Published private(set) var keyCodes = [HotkeyAction: UInt32]()
    @Published private(set) var conflicts = Set<HotkeyAction>()

    @Published private(set) var snapping = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var brightnessKeysActive = false
    @Published private(set) var notchEnabled = false
    @Published private(set) var notchAvailable = false
    @Published private(set) var windowGap = 8.0

    let windows = WindowManagementService()
    let notch = NotchAppearanceService()
    let resolution: ResolutionService
    let preferences: PreferencesStore
    let hardware: any BrightnessProvider
    let overlays = BlackoutCoordinator()
    let hotkeys = HotkeyService()
    private var safety = BlackoutSafety()
    @Published private(set) var awaitingProof = false
    private var trial: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var brightnessFollow: Task<Void, Never>?
    private var refreshDelay: Task<Void, Never>?
    private var writers = [CGDirectDisplayID: Task<Void, Never>]()
    private var pending = [CGDirectDisplayID: Double]()
    private var writingValues = [CGDirectDisplayID: Double]()

    init(hardware: any BrightnessProvider = BrightnessHardware(), preferences: PreferencesStore = .init()) {
        self.hardware = hardware
        self.preferences = preferences
        self.resolution = ResolutionService(preferences: preferences)
    }

    var launchAtLogin: Bool { login == .enabled || login == .requiresApproval }

    func canAdjustBrightness(_ display: Display) -> Bool {
        display.controllable && CGDisplayIsAsleep(display.id) == 0 &&
            (readings[display.id] != nil || calibration(display.id).software)
    }

    var masterDisplays: [Display] {
        displays.filter { $0.controllable && CGDisplayIsAsleep($0.id) == 0 &&
            (probing.contains($0.id) || canAdjustBrightness($0)) &&
            (sync ? calibration($0.id).participates : $0.id == source) }
    }

    var canAdjustMaster: Bool {
        !masterDisplays.isEmpty && probing.isDisjoint(with: masterDisplays.map(\.id))
    }

    var sourceName: String? { displays.first { $0.id == source }?.name }

    func refreshLoginStatus() { login = SMAppService.mainApp.status }

    func configureDefaultLoginItem() {
        refreshLoginStatus()
        guard !preferences.get("loginItemConfigured", false) else { return }
        setLaunchAtLogin(true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        refreshLoginStatus()
        do {
            if enabled && !launchAtLogin { try SMAppService.mainApp.register() }
            if !enabled && launchAtLogin { try SMAppService.mainApp.unregister() }
            preferences.set("loginItemConfigured", true)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }

    func start() {
        windows.issue = { [weak self] in self?.notice = $0 }
        hotkeys.onBrightnessKeysChanged = { [weak self] active in
            if self?.brightnessKeysActive != active { self?.brightnessKeysActive = active }
        }
        hotkeys.startBrightnessKeyMaintenance { [weak self] in
            guard let self, self.overlays.sessionSafe else { return false }
            // Keyboard access is checked against the OS, not the foreground application's AX tree.
            return CGPreflightPostEventAccess() || AXIsProcessTrusted()
        }
        hotkeys.onBrightnessKey = { [weak self] action, point in self?.handleBrightnessKey(action, at: point) }
        hotkeys.canHandleBrightness = { [weak self] point in
            guard let self, self.overlays.sessionSafe, self.resolution.active == nil else { return false }
            let targets = self.brightnessKeyTargets(at: point)
            // At full software brightness there is nothing left for us to brighten.
            // Let macOS handle an unsupported lone built-in panel instead of swallowing its keys.
            if targets.count == 1, let display = targets.first, display.builtIn,
               self.readings[display.id] == nil, !self.overlays.hasOverlays { return false }
            // During discovery, keep ownership of external/group keys. Passing them
            // to macOS could change a different built-in display instead.
            return !targets.isEmpty
        }
        refreshAccessibilityStatus()
        windowGap = preferences.get("windowGap", 8.0)
        windows.gap = windowGap
        notchEnabled = preferences.get("notch", false)
        if preferences.get("snapping", false), windows.authorized {
            snapping = windows.setSnapping(true)
        }
        sync = preferences.get("sync", true)
        relative = preferences.get("relative", true)
        smooth = preferences.get("smooth", false)
        experimental = preferences.get("experimental", false)
        followSystemBrightness = preferences.get("followSystemBrightness", false)
        master = preferences.get("master", 50.0)
        hotkeys.onAction = { [weak self] in self?.handle($0) }
        hotkeys.start()
        for action in HotkeyAction.allCases {
            let key = preferences.get("key.\(action.rawValue)", action.key)
            keyCodes[action] = key
            if !hotkeys.register(action, key: key) { conflicts.insert(action) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: event, object: nil)
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: event, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(suspend), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(resume), name: .init("com.apple.screenIsUnlocked"), object: nil)
        refresh()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                if self.overlays.hasOverlays && !self.overlays.sessionSafe { self.clearOverlays() }
            }
        }
    }

    @objc private func suspend() {
        hotkeys.setBrightnessSessionActive(false)
        resolution.rollback()
        overlays.sessionActive = false
        notch.clear()
        stopBrightnessFollow()
        cancelWrites()
        clearOverlays()
    }

    @objc private func resume() {
        overlays.sessionActive = true
        hotkeys.setBrightnessSessionActive(true)
        scheduleRefresh()
    }

    @objc private func scheduleRefresh() {
        // The screen-parameters notification is also emitted for resolution changes.
        clearOverlays()
        cancelWrites()
        stopBrightnessFollow()
        discovery?.cancel()
        refreshDelay?.cancel()
        refreshDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.refresh()
        }
    }

    func refresh() {
        clearOverlays()
        cancelWrites()
        stopBrightnessFollow()
        discovery?.cancel()
        displays = DisplayDiscoveryService.discover()
        resolution.topologyChanged(displays)
        notch.update(displays, enabled: notchEnabled && overlays.sessionSafe)
        notchAvailable = notch.available
        let savedSource = preferences.get("source", "")
        source = displays.first { $0.controllable && $0.identity == savedSource }?.id
            ?? displays.first { $0.controllable && $0.builtIn }?.id
            ?? displays.first { $0.controllable }?.id
        readings = [:]
        issues = [:]
        values = [:]
        calibrations = Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.id, display.identity.map { preferences.get("calibration.\($0)", Calibration()) } ?? Calibration())
        })
        let eligible = displays.filter(\.controllable)
        probing = Set(eligible.map(\.id))
        discovery = Task { [weak self] in
            guard let self else { return }
            for display in eligible {
                guard !Task.isCancelled else { return }
                let reading = await self.hardware.probe(HardwareDisplay(display.id), experimental: self.experimental)
                guard !Task.isCancelled else { return }
                self.probing.remove(display.id)
                if let reading {
                    self.readings[display.id] = reading
                    if self.writers[display.id] == nil { self.values[display.id] = reading.value }
                } else if self.values[display.id] == nil, self.calibration(display.id).software {
                    self.values[display.id] = 100
                }
                // A refresh removes dimming overlays. Rebase keys on the resulting visible
                // level, including software-only displays, instead of a persisted old target.
                if display.id == self.source, let value = self.values[display.id] {
                    self.master = max(1, value)
                }
            }
            self.updateBrightnessFollow()
        }
    }

    func calibration(_ id: CGDirectDisplayID) -> Calibration { calibrations[id] ?? Calibration() }

    func updateCalibration(_ display: Display, _ update: (inout Calibration) -> Void) {
        var value = calibration(display.id)
        update(&value)
        calibrations[display.id] = value
        if let identity = display.identity { preferences.set("calibration.\(identity)", value) }
        if !value.software && !overlays.blackIDs.contains(display.id) {
            overlays.remove(display.id)
            values[display.id] = readings[display.id]?.value
        }
        if value.software && readings[display.id] == nil && values[display.id] == nil && !probing.contains(display.id) {
            values[display.id] = 100
            if display.id == source { master = 100 }
        }
        updateBrightnessFollow()
    }

    func setSync(_ value: Bool) {
        sync = value
        preferences.set("sync", value)
        updateBrightnessFollow()
    }
    func setRelative(_ value: Bool) { relative = value; preferences.set("relative", value) }
    func setSmooth(_ value: Bool) { smooth = value; preferences.set("smooth", value) }
    func setExperimental(_ value: Bool) { experimental = value; preferences.set("experimental", value); refresh() }
    func setFollowSystemBrightness(_ enabled: Bool) {
        followSystemBrightness = enabled
        preferences.set("followSystemBrightness", enabled)
        updateBrightnessFollow()
    }

    func setSource(_ id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id && $0.controllable }) else { return }
        source = id
        preferences.set("source", display.identity ?? "")
        if let value = values[id] { master = value }
        stopBrightnessFollow()
        updateBrightnessFollow()
    }

    private var systemBrightnessSource: Display? {
        guard let source, let display = displays.first(where: { $0.id == source && $0.builtIn && $0.controllable }),
              calibration(source).participates, let reading = readings[source] else { return nil }
        switch reading.path {
        case .native, .appleNative: return display
        case .ddc, .experimentalDDC: return nil
        }
    }

    private var systemBrightnessFollowers: [Display] {
        displays.filter { display in
            !display.builtIn && display.controllable && calibration(display.id).participates &&
                !probing.contains(display.id) && (readings[display.id] != nil || calibration(display.id).software)
        }
    }

    var canFollowSystemBrightness: Bool {
        sync && systemBrightnessSource != nil && !systemBrightnessFollowers.isEmpty
    }

    private func stopBrightnessFollow() {
        brightnessFollow?.cancel()
        brightnessFollow = nil
    }

    private func updateBrightnessFollow() {
        guard let source = systemBrightnessSource,
              writers[source.id] == nil else {
            stopBrightnessFollow()
            return
        }
        guard brightnessFollow == nil else { return }
        let device = HardwareDisplay(source.id)
        brightnessFollow = Task { [weak self] in
            var samples = NativeBrightnessSamples()
            if let value = self?.readings[device.id]?.value { _ = samples.changedValue(value) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(300)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                guard self.canSampleSystemBrightness(device) else {
                    samples = NativeBrightnessSamples()
                    if let value = self.readings[device.id]?.value { _ = samples.changedValue(value) }
                    continue
                }
                // The built-in-only probe returns without attempting DDC.
                let reading = await self.hardware.probe(device, experimental: self.experimental)
                guard !Task.isCancelled, self.canSampleSystemBrightness(device) else { continue }
                guard let reading else {
                    samples = NativeBrightnessSamples()
                    continue
                }
                switch reading.path {
                case .native, .appleNative: break
                case .ddc, .experimentalDDC: continue
                }
                guard let value = samples.changedValue(reading.value) else { continue }
                self.readings[device.id] = reading
                self.values[device.id] = reading.value
                self.master = value
                guard self.followSystemBrightness, self.canFollowSystemBrightness else { continue }
                let eligible = self.systemBrightnessFollowers.filter { CGDisplayIsAsleep($0.id) == 0 }
                let targets = brightnessTargets(eligible.map { ($0.id, self.calibration($0.id)) },
                                                master: value, relative: self.relative)
                if !targets.isEmpty, self.apply(targets) { self.master = value }
            }
        }
    }

    private func canSampleSystemBrightness(_ device: HardwareDisplay) -> Bool {
        systemBrightnessSource?.id == device.id &&
            device.isCurrent && CGDisplayIsAsleep(device.id) == 0 && overlays.sessionSafe &&
            overlays.blackIDs.isEmpty && resolution.active == nil && writers[device.id] == nil
    }

    func setMaster(_ value: Double) { _ = applyMaster(value) }

    @discardableResult private func applyMaster(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let value = min(100, max(0, value))
        let eligible = displays.filter { canAdjustBrightness($0) }
        let targets = sync ? brightnessTargets(eligible.map { ($0.id, calibration($0.id)) },
                                               master: value, relative: relative)
            : Dictionary(uniqueKeysWithValues: eligible.filter { $0.id == source }.map { ($0.id, value) })
        guard !targets.isEmpty else {
            notice = String(localized: "没有可调节的显示器。")
            return false
        }
        guard apply(targets) else { return false }
        master = value
        if value > 0 { cancelBlackoutVerification() }
        if value > 0 { preferences.set("master", value) }
        return true
    }

    private func brightnessKeyTargets(at point: CGPoint) -> [Display] {
        let eligible = displays.filter { $0.controllable && CGDisplayIsAsleep($0.id) == 0 &&
            (probing.contains($0.id) || canAdjustBrightness($0)) }
        if sync { return eligible.filter { calibration($0.id).participates } }
        let id = displayUnderPointer(at: point, frames: eligible.compactMap { display in
            display.screen.map { (display.id, $0.frame) }
        })
        return eligible.filter { $0.id == id }
    }

    func handleBrightnessKey(_ action: HotkeyAction, at point: CGPoint) {
        guard action == .increase || action == .decrease, overlays.sessionSafe,
              resolution.active == nil else { return }
        let targets = brightnessKeyTargets(at: point)
        guard let target = targets.first, probing.isDisjoint(with: targets.map(\.id)) else { return }
        let delta = action == .increase ? 5.0 : -5.0
        if sync {
            if action == .increase, !overlays.blackIDs.isEmpty { recover() }
            else if !applyMaster(min(100, max(0, master + delta))) { return }
        } else {
            // Use the latest queued request during key repeat, not an older hardware readback.
            guard let current = pending[target.id] ?? writingValues[target.id] ?? values[target.id] else { return }
            let value = min(100, max(0, current + delta))
            guard apply([target.id: value]) else { return }
            if target.id == source { master = value }
            if value > 0 { cancelBlackoutVerification() }
        }
        let value = sync ? master : (pending[target.id] ?? writingValues[target.id] ?? values[target.id] ?? 0)
        let feedbackID = displayUnderPointer(at: point, frames: displays.compactMap { display in
            display.screen.map { (display.id, $0.frame) }
        })
        guard let feedbackID else { return }
        guard value > 0, !overlays.blackIDs.contains(feedbackID) else { onBrightnessFeedback?(nil); return }
        onBrightnessFeedback?(BrightnessFeedback(displayID: feedbackID,
            title: sync ? String(localized: "同步亮度 · \(targets.count) 台") : target.name, value: value))
    }

    func setIndividual(_ display: Display, value: Double) {
        guard canAdjustBrightness(display), value.isFinite else { return }
        let value = min(100, max(0, value))
        if display.id == source && sync && calibration(display.id).participates {
            setMaster(value)
        } else if apply([display.id: value]), display.id == source && !sync {
            master = value
        }
    }

    private func apply(_ targets: [CGDirectDisplayID: Double]) -> Bool {
        guard overlays.sessionSafe, probing.isDisjoint(with: targets.keys) else { return false }
        let zero = Set(targets.filter { $0.value == 0 }.keys)
        if !zero.isEmpty {
            guard resolution.active == nil else {
                notice = String(localized: "请先确认或回退当前分辨率。")
                return false
            }
            let visible = displays.filter { $0.controllable && CGDisplayIsAsleep($0.id) == 0 }
            let visibleIDs = Set(visible.map(\.id))
            let prospective = overlays.blackIDs.subtracting(targets.keys).union(zero)
            guard zero.isSubset(of: visibleIDs), safety.allows(
                covering: prospective.count, visible: visible.count,
                shortcutRegistered: hotkeys.isRegistered(.recover), sessionSafe: overlays.sessionSafe
            ) else {
                if !hotkeys.isRegistered(.recover) {
                    notice = String(localized: "恢复快捷键未注册。请在通用设置中解决冲突后再启用全黑。")
                } else if overlays.sessionSafe && !safety.verified && !visible.isEmpty && prospective.count >= visible.count {
                    awaitingProof = true
                    notice = String(localized: "全屏组全黑前，请先按 \(keyLabel(.recover)) 验证恢复快捷键，再重新设为 0%。第一次试用将在 8 秒后自动解除。")
                } else {
                    notice = String(localized: "当前会话或显示器状态不允许全黑。")
                }
                return false
            }
            if prospective.count >= visible.count && !safety.trialCompleted && trial == nil {
                trial = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self else { return }
                    self.safety.verified = false
                    self.recover()
                    self.notice = String(localized: "试用已超时并恢复。请用恢复快捷键结束下一次试用。")
                }
            }
        }
        for display in displays where display.controllable {
            guard let value = targets[display.id] else { continue }
            let id = display.id
            issues[id] = nil
            if value == 0 {
                writers.removeValue(forKey: id)?.cancel()
                writingValues[id] = nil
                pending[id] = nil
                guard overlays.apply(0, display: display, smooth: false) else {
                    clearOverlays()
                    notice = String(localized: "全黑应用失败，已撤去遮罩。")
                    return false
                }
                values[id] = 0
            } else if readings[id] != nil {
                overlays.remove(id)
                enqueue(value, display: display)
            } else if calibration(id).software && overlays.apply(value, display: display, smooth: smooth) {
                values[id] = value
            } else {
                overlays.remove(id)
                values[id] = nil
                issues[id] = String(localized: "当前无法调整亮度。")
            }
        }
        if overlays.blackIDs.isEmpty { cancelTrial() }
        return true
    }

    private func enqueue(_ value: Double, display: Display) {
        let id = display.id
        pending[id] = value
        guard writers[id] == nil, let reading = readings[id] else { return }
        // Rebaseline after our own hardware write so it cannot echo back into the group.
        if id == source { stopBrightnessFollow() }
        let hardwareDisplay = HardwareDisplay(id)
        writers[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let value = self.pending.removeValue(forKey: id) {
                self.writingValues[id] = value
                let applied = await self.hardware.write(value, to: hardwareDisplay, path: reading.path)
                guard !Task.isCancelled else { return }
                self.writingValues[id] = nil
                if let applied {
                    self.readings[id] = HardwareReading(path: reading.path, value: applied)
                    self.values[id] = applied
                } else {
                    self.clearOverlays()
                    self.readings[id] = nil
                    self.issues[id] = String(localized: "硬件亮度写入失败。")
                    self.values[id] = nil
                    let latest = self.pending.removeValue(forKey: id) ?? value
                    if self.calibration(id).software, self.overlays.apply(latest, display: display, smooth: false) {
                        self.values[id] = latest
                        self.issues[id] = String(localized: "硬件亮度写入失败，已改用软件调暗。")
                    }
                    break
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            self.writers[id] = nil
            if id == self.source { self.updateBrightnessFollow() }
        }
    }

    private func cancelWrites() {
        for writer in writers.values { writer.cancel() }
        writers = [:]
        pending = [:]
        writingValues = [:]
    }

    private func cancelTrial() { trial?.cancel(); trial = nil }

    private func clearOverlays() {
        onBrightnessFeedback?(nil)
        cancelBlackoutVerification()
        cancelTrial()
        overlays.clear()
        for display in displays {
            if let reading = readings[display.id] { values[display.id] = reading.value }
            else if values[display.id] != nil { values[display.id] = calibration(display.id).software ? 100 : nil }
        }
        if master == 0 { master = source.flatMap { values[$0] } ?? 50 }
    }

    func recover() {
        cancelWrites()
        clearOverlays()
        master = 50
        guard overlays.sessionSafe else { return }
        // Remove every overlay first. Only then request positive hardware brightness.
        for display in displays where display.controllable && readings[display.id] != nil {
            enqueue(50, display: display)
        }
        if let source, readings[source] == nil, let visible = values[source] {
            // Software recovery removes the overlay entirely; the next key starts there.
            master = visible
        }
    }

    func cancelBlackoutVerification() {
        guard awaitingProof else { return }
        awaitingProof = false
        notice = nil
    }

    func keyLabel(_ action: HotkeyAction) -> String {
        let key = keyCodes[action] ?? action.key
        let name = HotkeyService.keys.first { $0.0 == key }?.1 ?? "?"
        return (action.rawValue <= 3 ? "⌃⌥⌘" : "⌃⌥") + name
    }

    func setKey(_ action: HotkeyAction, _ key: UInt32) {
        guard keyCodes[action] != key || conflicts.contains(action) else { return }
        guard hotkeys.register(action, key: key) else {
            notice = String(localized: "快捷键注册失败，可能已被系统或其他应用使用。")
            return
        }
        if action == .recover {
            clearOverlays()
            safety = BlackoutSafety()
            awaitingProof = false
        }
        keyCodes[action] = key
        conflicts.remove(action)
        preferences.set("key.\(action.rawValue)", key)
        notice = nil
    }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .recover:
            if awaitingProof && overlays.sessionSafe {
                awaitingProof = false
                safety.verified = true
                if overlays.hasOverlays { recover() }
                notice = String(localized: "恢复快捷键已验证。可重新设为 0% 试用全黑。")
                return
            } else if trial != nil && !overlays.blackIDs.isEmpty {
                safety.trialCompleted = true
                notice = String(localized: "已通过快捷键结束全黑试用。")
            }
            recover()
        case .increase:
            if !overlays.blackIDs.isEmpty { recover() }
            else { setMaster(min(100, master + 5)) }
        case .decrease:
            setMaster(max(0, master - 5))
        default:
            if overlays.sessionSafe { windows.perform(action) }
        }
    }

    func setSnapping(_ enabled: Bool) {
        refreshAccessibilityStatus()
        guard windows.setSnapping(enabled) else {
            notice = WindowManagementService.permissionMessage
            return
        }
        snapping = enabled
        preferences.set("snapping", enabled)
        notice = nil
    }

    func refreshAccessibilityStatus() {
        let granted = windows.authorized
        hotkeys.refreshBrightnessKeys()
        if accessibilityAuthorized != granted { accessibilityAuthorized = granted }
        if granted, notice == WindowManagementService.permissionMessage { notice = nil }
        if !granted, snapping {
            _ = windows.setSnapping(false)
            snapping = false
        }
    }

    func setWindowGap(_ value: Double) {
        windowGap = value
        windows.gap = value
        preferences.set("windowGap", value)
    }

    func setNotch(_ enabled: Bool) {
        notchEnabled = enabled
        preferences.set("notch", enabled)
        notch.update(displays, enabled: enabled && overlays.sessionSafe)
    }

    func stop() {
        _ = windows.setSnapping(false)
        notch.clear()
        resolution.rollback()
        refreshDelay?.cancel()
        discovery?.cancel()
        monitor?.cancel()
        stopBrightnessFollow()
        cancelWrites()
        clearOverlays()
        hotkeys.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

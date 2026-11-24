import AppKit
import SwiftUI

struct DisplayModeChoice: Identifiable {
    let mode: CGDisplayMode
    var size: ResolutionSize { ResolutionSize(mode.width, mode.height) }
    var pixels: ResolutionSize { ResolutionSize(mode.pixelWidth, mode.pixelHeight) }
    var hiDPI: Bool { pixels.width > size.width && pixels.height > size.height }
    var id: String { "\(mode.ioDisplayModeID):\(size.label):\(pixels.label):\(mode.refreshRate)" }
    var detail: String {
        let refresh = mode.refreshRate > 0 ? "\(mode.refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Hz" : String(localized: "刷新率未报告")
        return String(localized: "逻辑 \(size.label) · 模式像素 \(pixels.label) · \(refresh) · \(hiDPI ? "HiDPI" : "1×")")
    }
}

@MainActor protocol DisplayModeProvider {
    func current(_ id: CGDirectDisplayID) -> DisplayModeChoice?
    func available(_ id: CGDirectDisplayID) -> [DisplayModeChoice]
    func change(_ id: CGDirectDisplayID, to mode: DisplayModeChoice) -> CGError
}

@MainActor struct SystemDisplayModes: DisplayModeProvider {
    func current(_ id: CGDirectDisplayID) -> DisplayModeChoice? {
        CGDisplayCopyDisplayMode(id).map(DisplayModeChoice.init)
    }

    func available(_ id: CGDirectDisplayID) -> [DisplayModeChoice] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        var seen = Set<String>()
        return modes.filter { $0.isUsableForDesktopGUI() }.map(DisplayModeChoice.init).filter {
            seen.insert($0.id).inserted
        }.sorted { ($0.size.width, $0.size.height, $0.pixels.width, $0.mode.refreshRate) <
                    ($1.size.width, $1.size.height, $1.pixels.width, $1.mode.refreshRate) }
    }

    func change(_ id: CGDirectDisplayID, to mode: DisplayModeChoice) -> CGError {
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { return begun == .success ? .failure : begun }
        let result = CGConfigureDisplayWithDisplayMode(config, id, mode.mode, nil)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return result
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }
}

@MainActor final class ResolutionService: ObservableObject {
    struct Change {
        let display: Display
        let hardwareDisplay: HardwareDisplay
        let rollback: ModeRollback<DisplayModeChoice>
        let requested: DisplayModeChoice
    }

    @Published private(set) var active: Change?
    @Published private(set) var remaining = 0
    @Published private(set) var issue: String?
    private var timer: Task<Void, Never>?
    private var deferred = [String: Change]()
    private let provider: any DisplayModeProvider
    private let preferences: PreferencesStore

    init(provider: any DisplayModeProvider = SystemDisplayModes(), preferences: PreferencesStore) {
        self.provider = provider
        self.preferences = preferences
    }

    func modes(_ display: Display) -> [DisplayModeChoice] {
        display.controllable ? provider.available(display.id) : []
    }

    func current(_ display: Display) -> DisplayModeChoice? { provider.current(display.id) }

    func savedModeID(_ display: Display) -> String? {
        guard let identity = display.identity else { return nil }
        let key = preferences.get("mode.\(identity)", "")
        return key.isEmpty ? nil : key
    }

    func presetModes(_ display: Display, available: [DisplayModeChoice]) -> [DisplayModeChoice?] {
        let current = current(display)
        let rotation = CGDisplayRotation(display.id)
        let size = current?.size
        guard abs(rotation.truncatingRemainder(dividingBy: 180)) < 1,
              size.map({ abs(Double($0.width) / Double(max(1, $0.height)) - 16.0 / 9) < 0.015 }) == true else {
            return ResolutionSize.mapTiers { _ in nil }
        }
        return ResolutionSize.mapTiers { tier in
            let matches = available.filter { $0.size == tier }
            return matches.first { $0.id == current?.id } ?? matches.sorted {
                if $0.hiDPI != $1.hiDPI { return $0.hiDPI }
                let refresh = current?.mode.refreshRate ?? 60
                return abs($0.mode.refreshRate - refresh) < abs($1.mode.refreshRate - refresh)
            }.first
        }
    }

    func begin(_ display: Display, mode: DisplayModeChoice) {
        guard active == nil, display.controllable, CGDisplayIsAsleep(display.id) == 0,
              let original = current(display), original.id != mode.id,
              let available = modes(display).first(where: { $0.id == mode.id }) else { return }
        issue = nil
        let change = Change(display: display, hardwareDisplay: HardwareDisplay(display.id),
                            rollback: ModeRollback(original: original, deadline: Date().addingTimeInterval(15)),
                            requested: available)
        let result = provider.change(display.id, to: available)
        guard result == .success else {
            restore(change)
            if issue == nil { issue = String(localized: "切换失败（CoreGraphics \(result.rawValue)）。已尝试恢复原模式。") }
            return
        }
        remaining = 15
        active = change
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let active = self.active else { return }
                let date = Date()
                let disconnected = !active.hardwareDisplay.isCurrent || CGDisplayIsAsleep(active.display.id) != 0
                if active.rollback.shouldRollback(at: date, disconnected: disconnected) {
                    self.rollback()
                    return
                }
                let remaining = max(0, Int(ceil(active.rollback.deadline.timeIntervalSince(date))))
                if remaining <= 13 && self.current(active.display)?.id != active.requested.id {
                    self.rollback()
                    if self.issue == nil { self.issue = String(localized: "系统未确认目标模式，已尝试回退。") }
                    return
                }
                if self.remaining != remaining { self.remaining = remaining }
            }
        }
    }

    func confirm() {
        guard let active, active.hardwareDisplay.isCurrent,
              CGDisplayIsAsleep(active.display.id) == 0,
              Date() < active.rollback.deadline,
              current(active.display)?.id == active.requested.id else { return }
        if let identity = active.display.identity {
            let mode = active.requested
            preferences.set("mode.\(identity)", mode.id)
        }
        finish()
    }

    func rollback() {
        guard let active else { return }
        finish()
        restore(active)
    }

    func topologyChanged(_ displays: [Display]) {
        if let active, !displays.contains(where: { $0.id == active.display.id && $0.controllable }) {
            rollback()
        }
        for display in displays {
            guard display.controllable, let identity = display.identity,
                  let change = deferred.removeValue(forKey: identity) else { continue }
            restore(change, using: display)
        }
    }

    private func restore(_ change: Change, using reconnected: Display? = nil) {
        let display = reconnected ?? change.display
        guard reconnected != nil || change.hardwareDisplay.isCurrent else {
            if let identity = change.display.identity { deferred[identity] = change }
            issue = String(localized: "显示器已断开，暂时无法回退分辨率。")
            return
        }
        let original = change.rollback.original
        if current(display)?.id == original.id { return }
        let choices = modes(display)
        let mode = choices.first { $0.id == original.id } ?? choices.first {
            $0.size == original.size && $0.pixels == original.pixels &&
            abs($0.mode.refreshRate - original.mode.refreshRate) < 0.01
        }
        guard let mode else {
            issue = String(localized: "无法回退，原模式已不在系统可用列表中。")
            return
        }
        let result = provider.change(display.id, to: mode)
        if result != .success {
            issue = String(localized: "回退分辨率失败（CoreGraphics \(result.rawValue)）。")
        }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        active = nil
        remaining = 0
    }
}

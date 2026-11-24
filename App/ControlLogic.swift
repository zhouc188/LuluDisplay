import Foundation
import CoreGraphics

func displayUnderPointer<ID>(at point: CGPoint, frames: [(ID, CGRect)]) -> ID? {
    frames.first { $0.1.contains(point) }?.0
}

struct BrightnessFeedback {
    let displayID: UInt32
    let title: String
    let value: Double
}

struct Calibration: Codable, Equatable {
    var participates = true
    var offset = 0.0
    var minimum = 1.0
    var maximum = 100.0
    var software = true

    func target(_ master: Double, relative: Bool) -> Double {
        guard master > 0 else { return 0 }
        guard relative else { return min(100, max(1, master)) }
        let low = min(100, max(1, minimum))
        let high = min(100, max(low, maximum))
        return min(high, max(low, low + (high - low) * (master - 1) / 99 + offset))
    }
}

func brightnessTargets<ID: Hashable>(_ devices: [(ID, Calibration)], master: Double,
                                     relative: Bool) -> [ID: Double] {
    Dictionary(uniqueKeysWithValues: devices.compactMap { id, calibration in
        calibration.participates ? (id, calibration.target(master, relative: relative)) : nil
    })
}

struct NativeBrightnessSamples {
    private var baseline: Double?

    mutating func changedValue(_ reading: Double) -> Double? {
        guard (0...100).contains(reading) else { return nil }
        let value = max(1, reading)
        guard let baseline else {
            self.baseline = value
            return nil
        }
        guard abs(value - baseline) >= 1 else { return nil }
        self.baseline = value
        return value
    }
}

struct BlackoutSafety {
    var verified = false
    var trialCompleted = false

    func allows(covering: Int, visible: Int, shortcutRegistered: Bool, sessionSafe: Bool) -> Bool {
        sessionSafe && shortcutRegistered && visible > 0 &&
            (covering < visible || verified)
    }
}

struct ResolutionSize: Hashable, Codable {
    let width: Int
    let height: Int
    init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    var label: String { "\(width) × \(height)" }

    static let tiers = [
        Self(1280, 720), Self(1600, 900), Self(1920, 1080), Self(2048, 1152),
        Self(2560, 1440), Self(3008, 1692), Self(3360, 1890), Self(3840, 2160)
    ]

    static func mapTiers<Mode>(_ modeForSize: (Self) -> Mode?) -> [Mode?] {
        tiers.map(modeForSize)
    }
}

struct ModeRollback<Mode> {
    let original: Mode
    let deadline: Date
    var confirmed = false

    func shouldRollback(at date: Date, disconnected: Bool = false) -> Bool {
        !confirmed && (disconnected || date >= deadline)
    }
}

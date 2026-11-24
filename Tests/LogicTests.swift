import Foundation

#if XCODE_TEST
import XCTest
#endif
struct LogicTests {
    static func main() {
        let tests: [(String, () -> Void)] = [
            ("鼠标所在显示器选择", pointerDisplay),
            ("亮度映射和边界", mapping),
            ("同步组成员变化", membership),
            ("内置屏亮度采样", nativeSamples),
            ("0% 和恢复验证", blackout),
            ("八档与真实可用模式映射", tiers),
            ("分辨率确认及超时/断线回退", rollback)
        ]
        for (name, run) in tests {
            run()
            print("PASS \(name)")
        }
        print("共通过 \(tests.count) 组测试")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        #if XCODE_TEST
        XCTAssertTrue(condition(), message)
        #else
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            exit(1)
        }
        #endif
    }

    fileprivate static func pointerDisplay() {
        let screens = [("A", CGRect(x: -1440, y: 0, width: 1440, height: 900)),
                       ("B", CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                       ("C", CGRect(x: 0, y: 1080, width: 900, height: 1600))]
        expect(displayUnderPointer(at: CGPoint(x: -100, y: 400), frames: screens) == "A", "negative-origin display")
        expect(displayUnderPointer(at: CGPoint(x: 500, y: 400), frames: screens) == "B", "primary display")
        expect(displayUnderPointer(at: CGPoint(x: 0, y: 400), frames: screens) == "B", "shared edge chooses one display")
        expect(displayUnderPointer(at: CGPoint(x: 400, y: 2000), frames: screens) == "C", "portrait display above primary")
        expect(displayUnderPointer(at: CGPoint(x: 3000, y: 0), frames: screens) == nil, "no fallback to wrong screen")
    }

    fileprivate static func mapping() {
        let cal = Calibration(participates: true, offset: 10, minimum: 20, maximum: 80)
        expect(cal.target(0, relative: true) == 0, "0 bypasses minimum")
        expect(cal.target(0, relative: false) == 0, "absolute zero")
        expect(cal.target(1, relative: true) == 30, "lower bound + offset")
        expect(cal.target(100, relative: true) == 80, "upper clamp")
        expect(abs(cal.target(50, relative: true) - (30 + 60 * 49 / 99.0)) < 0.001, "linear mapping")
        expect(cal.target(50, relative: false) == 50, "absolute sync ignores calibration")
        let inverted = Calibration(participates: true, offset: -90, minimum: 40, maximum: 10)
        expect(inverted.target(25, relative: true) == 40, "invalid calibration is bounded")
    }

    fileprivate static func membership() {
        var a = Calibration()
        let b = Calibration(participates: false)
        expect(brightnessTargets([(1, a), (2, b)], master: 0, relative: true) == [1: 0], "zero only affects group members")
        a.participates = false
        expect(brightnessTargets([(1, a), (2, b)], master: 50, relative: false).isEmpty, "opt out")
        a.participates = true
        expect(brightnessTargets([(1, a), (2, b)], master: 50, relative: false) == [1: 50], "rejoin")
    }

    fileprivate static func nativeSamples() {
        var samples = NativeBrightnessSamples()
        expect(samples.changedValue(.nan) == nil, "reject invalid native reading")
        expect(samples.changedValue(50) == nil, "initial sample only sets baseline")
        expect(samples.changedValue(50.5) == nil, "ignore sub-percent fluctuations")
        expect(samples.changedValue(51) == 51, "small changes accumulate against baseline")
        expect(samples.changedValue(0) == 1, "observed native zero never requests blackout")
        expect(samples.changedValue(1) == nil, "observed zero and floor are equivalent")
        samples = NativeBrightnessSamples()
        expect(samples.changedValue(80) == nil, "new baseline after app writes is not echoed")
    }

    fileprivate static func blackout() {
        var safety = BlackoutSafety()
        expect(safety.allows(covering: 1, visible: 2, shortcutRegistered: true, sessionSafe: true), "one of two screens")
        expect(!safety.allows(covering: 2, visible: 2, shortcutRegistered: true, sessionSafe: true), "all-screen proof required")
        safety.verified = true
        expect(safety.allows(covering: 2, visible: 2, shortcutRegistered: true, sessionSafe: true), "verified")
        expect(!safety.allows(covering: 1, visible: 1, shortcutRegistered: false, sessionSafe: true), "conflict must reject")
        expect(!safety.allows(covering: 1, visible: 1, shortcutRegistered: true, sessionSafe: false), "unsafe session")
    }

    fileprivate static func tiers() {
        let expected = [ResolutionSize(1280, 720), .init(1600, 900), .init(1920, 1080), .init(2048, 1152),
                        .init(2560, 1440), .init(3008, 1692), .init(3360, 1890), .init(3840, 2160)]
        expect(ResolutionSize.tiers == expected, "eight exact tiers")
        let available = [expected[1]: 2, expected[6]: 7, ResolutionSize(3440, 1440): 9]
        expect(ResolutionSize.mapTiers { available[$0] } ==
               [nil, 2, nil, nil, nil, nil, 7, nil], "unsupported modes retain positions")
    }

    fileprivate static func rollback() {
        let now = Date(timeIntervalSince1970: 100)
        var change = ModeRollback(original: "original", deadline: now.addingTimeInterval(15))
        expect(!change.shouldRollback(at: now), "confirm window is open")
        expect(change.shouldRollback(at: now, disconnected: true), "disconnect")
        expect(change.shouldRollback(at: now.addingTimeInterval(15)), "deadline")
        expect(change.original == "original", "keep rollback target")
        change.confirmed = true
        expect(!change.shouldRollback(at: now.addingTimeInterval(30), disconnected: true), "confirmed mode")
    }
}

#if XCODE_TEST
final class DesktopControlLogicTests: XCTestCase {
    func testPointerDisplay() { LogicTests.pointerDisplay() }
    func testBrightnessMapping() { LogicTests.mapping() }
    func testSyncMembership() { LogicTests.membership() }
    func testNativeBrightnessSamples() { LogicTests.nativeSamples() }
    func testBlackoutSafety() { LogicTests.blackout() }
    func testResolutionTiers() { LogicTests.tiers() }
    func testResolutionRollback() { LogicTests.rollback() }
}
#endif

#if !XCODE_TEST
@main struct RunLogicTests {
    static func main() { LogicTests.main() }
}
#endif

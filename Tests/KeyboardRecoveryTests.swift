import AppKit

private struct RecoveryFailure: Error, CustomStringConvertible {
    let description: String
}

@main @MainActor
struct KeyboardRecoveryTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("PASS real keyboard tap recovery completed")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func run() async throws {
        let keys = HotkeyService()
        // Exercise actual OS ports; never consume user input or adjust brightness.
        keys.canHandleBrightness = { _ in false }
        var allowed = true
        keys.startBrightnessKeyMaintenance { allowed }
        defer { keys.stop() }
        try check(keys.brightnessKeysActive, "No permission to create the real event tap")

        keys.testDisableBrightnessTap()
        try check(!keys.brightnessKeysActive, "Test must disable the live tap")
        try await Task.sleep(for: .milliseconds(1400))
        try check(keys.brightnessKeysActive, "Background maintenance must re-enable a disabled tap")
        print("PASS disabled tap recovers without opening settings")

        keys.testInvalidateBrightnessTap()
        try check(!keys.brightnessKeysActive, "Invalid port must not appear active")
        try await Task.sleep(for: .milliseconds(1400))
        try check(keys.brightnessKeysActive, "Invalidated port must be recreated")
        keys.testInvalidateBrightnessSource()
        try await Task.sleep(for: .milliseconds(1400))
        try check(keys.brightnessKeysActive, "Invalidated run-loop source must be recreated")
        print("PASS invalid port and source recover")

        keys.setBrightnessSessionActive(false)
        try await Task.sleep(for: .milliseconds(1400))
        try check(!keys.brightnessKeysActive, "Maintenance must respect inactive sessions")
        keys.setBrightnessSessionActive(true)
        try check(keys.brightnessKeysActive, "Wake must reconnect the tap")
        print("PASS session suspend and resume")

        allowed = false
        try await Task.sleep(for: .milliseconds(1400))
        try check(!keys.brightnessKeysActive, "Denied authorization must stop the tap")
        allowed = true
        try await Task.sleep(for: .milliseconds(1400))
        try check(keys.brightnessKeysActive, "Restored authorization must reconnect without opening settings")
        keys.stop()
        try await Task.sleep(for: .milliseconds(1400))
        try check(!keys.brightnessKeysActive, "Stopped maintenance must not recreate a tap")
        print("PASS authorization gate and shutdown")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RecoveryFailure(description: message) }
    }
}

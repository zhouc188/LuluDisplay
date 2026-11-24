import AppKit
import CoreGraphics

struct Display: Identifiable {
    let id: CGDirectDisplayID
    let identity: String?
    let screen: NSScreen?
    let name: String
    let builtIn: Bool
    var mode: CGDisplayMode? { CGDisplayCopyDisplayMode(id) }
    var controllable: Bool { screen != nil && CGDisplayIsInMirrorSet(id) == 0 }
}

@MainActor enum DisplayDiscoveryService {
    static func discover() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let online = ids.prefix(Int(count))
        let signatures = Dictionary(grouping: online, by: hardwareSignature)
        let displays = online.map { id in
            let screen = NSScreen.screens.first { $0.displayID == id }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            // Avoid persisting port-derived identities for indistinguishable external panels.
            let uuid = (builtIn || (CGDisplaySerialNumber(id) != 0 && signatures[hardwareSignature(id)]?.count == 1))
                ? CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() : nil
            let key = uuid.map { CFUUIDCreateString(nil, $0) as String }
            return Display(id: id, identity: key, screen: screen,
                           name: screen?.localizedName ?? (builtIn ? "内置显示器" : "外接显示器 \(id)"),
                           builtIn: builtIn)
        }
        let counts = Dictionary(grouping: displays.compactMap(\.identity), by: { $0 })
        return displays.map { display in
            guard let identity = display.identity, counts[identity]?.count != 1 else { return display }
            return Display(id: display.id, identity: nil, screen: display.screen,
                           name: display.name, builtIn: display.builtIn)
        }
    }

    private static func hardwareSignature(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
